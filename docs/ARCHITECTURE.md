# Architecture audit: leaky abstractions and the cleanup plan

An audit of how well the "platform-pure, headless-testable core" claim
(`src/egui.cr:8-9`) holds in practice, where the sokol backend leaks
through the seams, and what to change. Companion to `docs/ANALYSIS.md`
(the upstream port map). File:line references are facts at audit time;
they drift.

## Layering as designed

```
app (examples/)            requires src/egui + a backend file
  └─ core src/egui/*       platform-pure, headless-testable
       ├─ Runtime hooks    natural_scheduler?, wake   (runtime.cr)
       ├─ Fonts seam       abstract Fonts + MonospaceFonts
       ├─ Texture seam     TextureRegistry + Dummy
       ├─ SystemPorts      installable Implementations
       └─ Terminal seam    abstract Terminal::Backend
  └─ backend/              sokol.cr (2k lines), text.cr, crystalfonts.cr, …
       └─ backend/*.c      shims linked into libegui_cr_sokol.a
```

## What is already clean (keep these, extend by example)

- `Egui::Runtime` (runtime.cr) — two class-level hooks, set by the
  backend, read by the core. Minimal, explicit. This is the model.
- `TextureRegistry` / `DummyTextureRegistry` (textures.cr) — GPU
  resources behind opaque `UInt64` ids; specs run headless.
- `Fonts` abstract base (fonts.cr) — layout/wrap logic is a template
  method over `measure`; headless `MonospaceFonts` is deterministic.
- `SystemPorts` installable implementations (window/screen/clipboard/
  quit) — `.use(impl)` pattern, default no-op.
- `Egui::Svg.external_rasterizer` — inversion of dependency for the
  dev-only C NanoSVG accelerator.
- `Terminal::Backend` (terminal/backend.cr) — the TermView renders
  against the seam; specs drive it with a fake.
- The detached loop contract (event ring + FramePackets + wake pipe) —
  already backend-neutral in shape (`EventRecord`, not `sapp_event`).

The problems below are graded by danger: **A** breaks the core promise
or hard-binds apps to sokol; **B** is layering violation / implicit
contract; **C** is hygiene.

---

## Class A — critical (the promise is already broken)

### A1. The app entry point is the concrete backend class

All 17 examples call `Egui::Backend::Sokol.run(app, …)` (hello.cr:92,
notepad.cr:570, paint.cr:1876, …). The namespace says "backend-agnostic
module", the code says "sokol". Every app hard-requires
`backend/sokol.cr` and links GL/X11 unconditionally. Swapping backends
means editing every app; "egui-cr app" and "sokol app" are the same
thing today.

**Fix — `Egui.run` facade.** One file, no behavior change:

```crystal
# src/egui/backend_selector.cr (required by src/egui.cr)
module Egui
  def self.run(app : App, **opts) : Nil
    {% if flag?(:egui_no_backend) %}
      raise "no backend compiled in"
    {% else %}
      require "./egui/backend/sokol"   # default; overridable per-target
      Backend::Sokol.run(app, **opts)
    {% end %}
  end
end
```

Mechanics: examples change one line (`Egui.run(…)`); `Backend::Sokol`
stays public for sokol-specific knobs (`chrome_style`, detached-mode
env). A second backend later adds a compile-time selector (env var /
shard target), and apps never change again.

### A2. Font lifecycle API lives on the backend, with a dual source of truth

Apps select fonts through backend class methods —
`Sokol.fonts_from_system` / `select_fonts(font : AtlasFonts, …)` /
`register_font` / `register_deferred_font` (sokol.cr:926-986,
terminal.cr:341-342, fontpreview.cr:87) — typed by `AtlasFonts`, a
backend-internal type. Meanwhile the Context mirrors the same state
(`fonts`, `mono_fonts`, `font_families`, `deferred_font_paths`,
context.cr:35-75), and `select_fonts` syncs the copies with
`@@app.try &.ctx.fonts = font` (sokol.cr:960-965). Two registries,
manual sync, backend-named API in app code, and the core docstrings
document the backend names (context.cr:39, 52).

**Fix — move the registry into the core.** The seam already exists:
`ctx.font_loader : Proc(Array(String), Fonts?)?` (context.cr:75) is
exactly a font factory installed by the backend. Generalize it:

- `ctx.select_fonts(font : Fonts, mono : Fonts? = nil)`,
  `ctx.register_font_family(...)` (already there),
  `Egui::Fonts.from_system(paths)` → routed through the installed
  factory; state lives in ONE place (the Context).
- The backend keeps only: building stacks (CrystalFonts chain — itself
  backend-agnostic and movable to core or a `text/` dir) and the
  per-frame atlas/scale sync it already does.

### A3. The shared text stack cannot be instantiated headless — and it's worked around, not fixed

`backend/text.cr` (AtlasFonts, GlyphAtlas — the base of EVERY real font
stack) calls the native shim directly:

- `GlyphAtlas#flush` → `LibEguiCr.atlas_create/atlas_update`
  (text.cr) — renderer texture handles baked inside the
  text stack — and `lib LibEguiCr` is
  declared in sokol.cr, so text.cr only even compiles as part of
  the sokol compilation unit.

Consequence, already known in-tree: an `AtlasFonts` subclass cannot be
linked into `crystal spec` without the native lib, so the font specs
are deliberately demoted to runnable scripts —
`spec/font_chain_smoke.cr:1-5` documents the workaround ("instantiating
an AtlasFonts subclass … would link the native lib into
`crystal spec`"). The headless-core promise has an asterisk exactly
where text is concerned.

**Fix, two independent steps:**

1. Atlas upload goes through the `TextureRegistry` seam —
   `flush` becomes `registry.register_rgba(size, size, rgba)` /
   `registry.update(id, …)`. The renderer then owns GPU handles by
   construction, and `GlyphAtlas` is pure data + packing.
2. The stb FFI gets its own `lib` declaration + link unit (see A4), so
   the fallback stack's dependency is visible and separable instead of
   riding on sokol.cr's declaration.

### A4. The PTY shim drags the whole windowing backend

`src/egui/terminal/pty.cr` — the native `Terminal::Backend`
implementation — sits in the CORE tree (`src/egui/terminal/`, required
alongside pure files by convention) and declares
`@[Link("egui_cr_sokol")]` (pty.cr:25) because `pty_shim.o` happens to
be archived into the same `libegui_cr_sokol.a`. A terminal embedder
that never opens a window still links sokol, GL, X11, Xcursor. Same
archive hosts `nanosvg_shim.o` — every shim
depends on every other by packaging accident.

**Fix:** split the static library per shim (`libegui_cr_pty.a`,
`libegui_cr_sokol.a`), move `pty.cr` under
`backend/` next to the other native implementations (it already
implements an existing core seam; nothing in `src/egui.cr` requires
it — only `examples/terminal.cr:21` does). The Rakefile already
compiles the shims separately; only archiving is shared.

### A5. Pixel utilities are backend class methods used by apps

`Sokol.load_rgba` (paint.cr:822) and `Sokol.image_alpha_mask`
(splash.cr:44) — CPU-side image decoding exposed on the windowing
backend because the C shim has stb_image handy. Apps that decode a PNG
now depend on sokol.

**Fix:** a `SystemPorts::Images` port (`decode_rgba(path)` /
`alpha_mask(path)`), default nil-returning headless, installed by the
backend — the same `@[Link]`-free shape NanoSvgCr took for SVG (core
fallback, C accelerator optional).

---

## Class B — serious (layering violations, implicit contracts)

### B1. `Sokol.run` is an app-compositor, not a backend

`sokol.cr:run` (557-650) knows about: the framework CLI and the Router
(595-598), the ecss debug session (587-589), the inspector flags
(574-581), the client-side chrome theme (`chrome_style`,
WindowFrame::Style), and core widget state (`Egui::WindowFrame.icon =
icon`, 601). Every frame the backend then calls core UI policy:
`AsyncDialogs.pump_pass` + `take_delivered` (1154-1155),
`ctx.inspector.before_update` (1211), and renders the caption itself —
`Egui::WindowFrame.show(app.ctx, @@title, @@chrome_style)` (1214). The
backend decides what the app's title bar looks like.

**Fix — a host layer between backend and core** (upstream eframe's
role, currently fused into sokol.cr):

```crystal
# src/egui/host.cr — core-side, backend-agnostic
class Egui::Host
  def initialize(@app : App, @opts : RunOptions); end
  def before_update(ctx)    # pump dialogs, inspector.before_update,
    ...                     # scheduler pass when !natural_scheduler?
  end
  def after_update(ctx)     # chrome (WindowFrame.show) if enabled
    ...
  end
end
```

The backend's frame loop shrinks to: gather RawInput →
`host.before_update` → `ctx.begin_frame` → `app.update` →
`host.after_update` → `ctx.end_frame` → paint. CLI/router/ecss/inspector
policy moves into `Host`/`RunOptions` (core), where it is testable.

### B2. The backend's obligations are an unwritten checklist

A new backend implementer must TODAY know to: call
`AsyncDialogs.pump_pass` before `begin_frame` (dialog.cr:17 documents
it in a comment), `flush_destroys` after the pass (textures.cr:53),
`set_clear_color` from the theme's `panel_fill` BEFORE window map
(sokol.cr:612-622), sync `ctx.pixels_per_point` every frame (1180),
feed `WindowFrame.icon`, rotate `@@events` into RawInput. No interface
defines this; nothing tests it; a wrong order fails silently or
visually.

**Fix:** the `Host` template method above IS the fix — the checklist
becomes code the backend calls, not memory. What remains backend-only
(clear color, ppp sync) goes into a short `Backend::Interface` doc
block with the invariants spelled out (one screenful, referenced from
sokol.cr's header).

### B3. WindowFrame global class state, written through a side door

`WindowFrame` (core container) holds process-global mutable state —
`@@icon`, `@@caption_content`, `@@caption_height` (window_frame.cr:100,
120-127) — set by `Sokol.run(icon:)` at startup. Window chrome config
travels backend → core widget through class variables.

**Fix:** part of B1 — `RunOptions` (title, icon, chrome style) is owned
by the Host and passed explicitly; `WindowFrame.show(ctx, opts)` reads
its parameters instead of class vars. (Also the only thing standing
between the current design and multiwindow — see C2.)

### B4. `Terminal::Backend#evented_pass` — a scheduler workaround codified in a domain seam

The seam's own doc (terminal/backend.cr:16-25) explains it exists
because "under the native backend the sokol loop never yields to the
Crystal scheduler". The widget dutifully calls it every frame
(widget.cr:138). With the detached loop (`natural_scheduler = true`)
it is dead weight; with a hypothetical third backend it is a question
mark. A UI widget should not participate in scheduler management.

**Fix:** move the pass into `Host#before_update` guarded by
`!Runtime.natural_scheduler?` (exactly what runtime.cr:10-11 already
anticipates: "the per-frame scheduler crutches (`evented_pass`,
`AsyncDialogs.pump`) are unnecessary and are skipped"). The seam method
is then deleted; the fake backends in specs shrink.

---

## Class C — hygiene (no runtime danger, rots the codebase)

### C1. Core docstrings reference concrete backend API names

context.cr:39, 52, 175, 505; painter.cr:42, 247; ecss.cr:13, 424, 662;
window_frame.cr:3, 115; terminal/widget.cr:57; inspector.cr:826 — all
name `Sokol.run` / `Sokol.register_font` / `Sokol.select_fonts` as the
way to do things. After A1/A2 land these all lie. One doc sweep in the
same PRs that introduce the facade; a doc-comment that names a backend
class in `src/egui/**` (outside `backend/`) is a review flag from then
on.

### C2. Backend process-global singletons vs `multiwindow-plan.md`

`Sokol.@@app`, `@@events`, `@@last_commands`, `@@cbs`, plus
`WindowFrame`'s class vars — the entire runtime assumes one window per
process. Fine today; the day `multiwindow-plan.md` executes, every one
of these is a refactor site. Not a leak to fix now — a constraint to
record so new singleton state stops being added.

### C3. Two system-port patterns, undocumented

Ports either shell out in-core (dialogs→zenity, message_box, shell,
notifications) or delegate to an installable `Implementation`
(quit/window/screen/clipboard), and `dialog` mixes both (zenity in the
port, a native Win32 impl installed by the backend at sokol.cr:607,
plus backend-pumped delivery fibers). Legitimate — but which pattern a
new port should use is tribal knowledge. One paragraph in
`system_ports/system_ports.cr`'s header (the comment there is good —
extend it with the decision rule) closes this.

### C4. `CursorIcon#to_css` — accepted coupling, not a bug

cursor_icon.cr serializes to CSS `cursor` keywords because sokol_app,
Xcursor and the web all share that namespace (and upstream egui does
the same). Record as an accepted convention so nobody "fixes" it.

---

## Fix plan, ordered

| # | Change | Class | Effort | Unlocks |
|---|--------|-------|--------|---------|
| 1 | `Egui.run` facade + example sweep | A1 | tiny | apps stop naming sokol |
| 2 | Font registry → Context, `font_loader` factory generalized | A2 | medium | A2 + kills dual state; C1 partially |
| 3 | `GlyphAtlas#flush` via `TextureRegistry`; stb lib split out | A3 | medium | font specs back into `crystal spec` |
| 4 | Shim archive split + `pty.cr` → `backend/` | A4 | small (build) | embedders link what they use |
| 5 | `Egui::Host` + `RunOptions`; run() policy moves core-side | B1-B3 | medium-large | B2 checklist becomes code; C2 headroom |
| 6 | Retire `evented_pass` into the host tick | B4 | small | simpler Terminal seam |
| 7 | Doc sweep of backend names in core | C1 | small, rides along with 1-2 | — |

Steps 1, 4, 6 are low-risk and independently shippable. Step 5 is the
one that deserves its own plan (it touches the frame loop of both the
detached and legacy paths). Nothing here changes rendering, input, or
behavior — every step is movable-seam work, which is what the audit
found the architecture is otherwise well-shaped for.
