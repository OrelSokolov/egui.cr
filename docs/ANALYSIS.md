# egui architecture analysis (upstream 0.36.2) → egui-cr port map

Analysis of `egui-upstream/` (emilk/egui @ 0.36.2). This document maps
the upstream architecture onto this Crystal port and records what was
simplified for slice 1. File paths are relative to `egui-upstream/`.

## 1. Crate layout (dependency direction)

```
ecolor  ← emath                (leaf crates: Color32; Pos2/Vec2/Rect/…)
epaint → emath, ecolor         (Shape, Mesh, Tessellator, Fonts/Galley)
egui   → epaint                (the immediate-mode core: Context, Ui, widgets)
egui-winit → egui              (winit events → RawInput; no rendering)
egui-wgpu / egui_glow → epaint (renderers: ClippedPrimitives → GPU)
eframe → egui + egui-winit + renderer   (App trait, owns the event loop)
egui_extras, egui_demo_lib, …  (extras, demo content)
```

egui-cr equivalents:

| upstream | egui-cr |
|---|---|
| emath | `src/egui/math.cr` (Vec2/Pos2/Rect) |
| ecolor | `src/egui/color.cr` (Color32) |
| epaint (subset: paint list) | `src/egui/painter.cr` (RectCmd/TextCmd/NoopCmd) |
| epaint Fonts/Galley | `src/egui/fonts.cr` + backend `FreetypeFonts`/`LightHintedFonts` |
| egui core | `src/egui/{id,sense,input,memory,response,layout,style,ui,context,app}.cr`, `src/egui/widgets/*` |
| egui-winit + renderer | `backend/sokol_shim.c` + `src/egui/backend/sokol.cr` (sokol_app events, sokol_gfx/sokol_gl rendering, fontstash text) |
| eframe | `Egui::App` + `Egui::Backend::Sokol.run` |

## 2. The frame loop (upstream `Context::begin_pass`/`end_pass`)

```
backend gathers RawInput
  → Context::begin_pass(raw)
      memory.begin_pass(raw)              # rotate per-frame state
      input = InputState::begin_pass(raw) # derived pointer/keys/scroll state
      # THE TRICK: hit-test + InteractionSnapshot are computed UP-FRONT
      # from the PREVIOUS pass's widget rects (PassState::widgets), so a
      # Response is already correct the moment a widget is created.
  → user code runs top-to-bottom (widgets call ctx.create_widget)
  → Context::end_pass
      shapes = graphics.drain(layer_order) # paint list, back-to-front
      swap(this_pass, prev_pass)
  → backend tessellates shapes and renders
```

egui-cr: `Context#begin_frame` / `#end_frame` follow the same shape.
The previous-frame hit-test is `Memory#begin_frame`: it resolves the
press-origin widget against `@prev_widget_rects` *before* this frame's
widgets register, then `Memory#interact` answers hover/click/pressed
per widget.

## 3. Core types

### Id (`crates/egui/src/id.rs`)
`Id(NonZeroU64)`, hashed with ahash (seeds fixed per process). Child
ids derive via `Id::with(salt)`; `Ui` mints per-widget ids from
`next_auto_id_salt`. egui-cr: `Egui::Id` (UInt64 + FNV-1a) with
`Id.child(salt)`; `Ui#next_widget_id` is the `next_auto_id` port.

### Memory (`crates/egui/src/memory/mod.rs`)
Cross-frame state: widget interaction (`InteractionState`: potential
click/drag ids set on press, decided by movement/time), `Areas`
(z-order of floating layers), `Focus`, and `data: IdTypeMap`
(persistent per-widget state: collapsing, scroll, TextEdit cursors).
egui-cr: `src/egui/memory.cr` + `src/egui/state.cr` now port all of it:

| upstream | egui-cr |
|---|---|
| `Memory::data` (IdTypeMap) | `Memory#data` (`IdTypeMap`, typed cells, pruned against `used_ids` in `end_frame`) |
| `InteractionState` (potential click/drag) | `Memory` press candidates: click id filtered by `Sense#click?`, drag id by `Sense#drag?`; movement > 6pt promotes the drag candidate |
| click classification | double/triple click (0.3s window, 6pt distance) → `Response#click_count`, `#double_clicked?`, `#triple_clicked?` |
| drag state machine | `Response#dragged?/#drag_started?/#drag_stopped?/#drag_delta` (delta from `InputState#pointer_delta`) |
| `Areas` (layering, window pos) | `Areas` in `state.cr`: positions persist (`pos_for`/`move_by`), `bring_to_top`; `Context#window` is movable via title-bar drag |
| `Focus` | `Focus` with the one-frame dead-man's switch (`id_previous_frame`), `Response#has_focus?/#gained_focus?/#lost_focus?`, `#request_focus`. Tab/arrow geometric navigation: not ported yet |
| `AnimationManager` | `AnimationManager` (Id-keyed, restarts from current value), `Context#animate_value_with_time` |
| popups | `Memory#open_popups` + close-on-outside-click in `end_frame` (layer-aware via widget `LayerId`) |
| `used_ids` | `Memory#duplicate_ids` records same-id-twice-per-frame bugs |
| repaint scheduling | `Context#request_repaint` / `#needs_repaint?` (backend still vsync-continuous) |
| CacheStorage | lite: `Context#frame_cache(key) { … }` cleared each `begin_frame` |
| PointerState history/velocity | `InputState#pointer_delta` + EMA `#pointer_velocity` (kinetic scrolling: later) |

**Simplifications left**: no retained-layout panels (contents drawn
before `bottom_panel` don't get pushed up), no per-widget text caching
(Galley), no scroll-area target arbitration, single drag candidate
(no per-button tracking).

### Input (`data/input.rs`, `input_state.rs`)
`RawInput { screen_rect, time, events, … }` → `InputState` with
`PointerState` (pos, down, press origin, click classification:
max dist 6pt / 0.8s, double-click window 0.3s), modifiers, scroll.
egui-cr: `RawInput`/`InputState` with the pointer subset (pos, down,
pressed/released this frame, scroll, dt). `InputState.build` carries
the previous frame's pointer pos/button state over (the `PointerState`
persistence port) — frames without move/press events keep hover/active
stable instead of flickering. Click tolerance and double-click land
with slice 2 widgets.

### Sense / Response (`sense.rs`, `response.rs`)
`Sense { CLICK, DRAG, FOCUSABLE }`; `Response` carries id/rect/sense
plus flag bits (HOVERED, CLICKED, DRAGGED, …) read off the
pre-computed `InteractionSnapshot`. The app reads `response.clicked()`.
egui-cr: `Sense` (flags enum Click/Drag), `Response` with
`hovered?/clicked?/pressed?/active?` and the Crystal-idiomatic
`response.clicked { … }` block form.

### Ui (`ui.rs`, `layout.rs`, `placer.rs`)
`Ui` = id + next-id counter + `Placer` (Layout + Region{min_rect,
max_rect, cursor}) + painter + style. Widgets:
`allocate_space(size)` → rect (cursor advances; `min_rect` grows),
`ui.interact(rect, id, sense)` → Response, painter calls, return
Response. `ui.horizontal {}` = child Ui with `left_to_right` layout.
egui-cr: `src/egui/ui.cr` mirrors this (cursor, min_rect, child ids,
`allocate_at_least`, `interact`, `horizontal`). Upstream's cursor is a
full Rect with wrapping — slice 1 uses the two plain directions.

### Painter (`painter.rs`, epaint)
`Painter::add(shape)` pushes a `ClippedShape` into the layer's
`PaintList`; `Painter::set(idx, shape)` retro-fills (used by `Frame`
to paint a window background *under* already-emitted children).
egui-cr: `Painter` with `add_noop` + `set` implementing exactly that
trick in `Context#window`; command vocabulary is Rect/Text for now
(tessellation happens implicitly in sokol_gl quads + fontstash).

## 4. Widgets

Trait (`widgets/mod.rs`):

```rust
pub trait Widget {
    fn ui(self, ui: &mut Ui) -> Response;
}
impl<F: FnOnce(&mut Ui) -> Response> Widget for F { … }
```

`ui.add(widget)` is pure delegation; `ui.button("x")` ≡
`ui.add(Button::new("x"))`. egui-cr: `Egui::Widget` module with
abstract `ui(ui : Ui) : Response`; `Ui#add`, `Ui#button`, `Ui#label`.

**Label** (`widgets/label.rs`): builds text layout (`LayoutJob` →
`Galley` via `fonts`), `allocate_exact_size(galley.size, sense)`,
paints `TextShape`. egui-cr: `widgets/label.cr` — measure via
`ctx.fonts.measure`, allocate, paint, `Sense.none` response.

**Button** (`widgets/button.rs`, atomics in 0.36): sense = click;
size = text + 2·button_padding; `allocate` → `interact` → paint frame
(state-colored bg + stroke) + centered text → response. egui-cr:
`widgets/button.cr` follows the same five moves; state colors come
from `Visuals#button_fill(hovered, active)` (upstream
`Widgets::style(response)`).

Upstream widget inventory to port (slice 2+): `checkbox`, `radio`,
`separator`, `slider` (emath `smart_aim`), `drag_value`, `TextEdit`,
`image`, `hyperlink`, `progress_bar`, `spinner`, `color_picker`;
containers: `window` (movable — done, via Areas + title drag),
`panels` (`bottom_panel` — done), `popup` (done, foreground layer +
outside-click close), `collapsing_header` (done, state in IdTypeMap),
`scroll_area`, `menu`, `tooltip`, `frame`.

## 5. Backend (eframe → sokol)

Upstream: winit event loop + glow/wgpu renderer + repaint scheduling
via `ViewportOutput::repaint_delay`. egui-cr slice 1: sokol_app
window/GL context (X11, `SOKOL_NO_ENTRY` + `sapp_run` driven from
Crystal `main`), sokol_gfx pass per frame, sokol_gl quads for rects,
the Crystal text stack (`backend/text.cr`) for text — see section 10 —
continuous repaint (vsync). On-demand repaint (`request_repaint`) is
the next backend step.

## 6. Verified behavior (slice 1)

- `crystal spec` — frame loop, paint list, hover, click
  (press+release), click suppression when press began outside,
  state-driven label change. All headless.
- `bin/hello` — real window on X11: window + title, `Hello World!`
  heading, `Click me` button (hover/active states), `Clicked N times`
  label that changes on click. Verified by running on a live display
  and pixel-analyzing a screenshot (clear color, window fill, button
  fill/stroke, and anti-aliased text pixels all present).

## 7. Delta: cursor icons (CSS `cursor`)

Port of upstream `CursorIcon` (`crates/egui/src/data/output.rs`) +
eframe/winit integration, adapted to sokol:

- Core (`src/egui/cursor_icon.cr`): `CursorIcon` enum with all 35 CSS
  `cursor` keywords (`#to_css` emits the kebab-case keyword,
  `.parse?` reads them back). Pure/headless — specs cover exact
  strings and round-trips.
- Core wiring: `Context#cursor_icon` (upstream
  `PlatformOutput::cursor_icon`) reset each `begin_frame`;
  `Context#set_cursor_icon`; `Response#on_hover_cursor` /
  `#on_hover_and_drag_cursor` (response.rs). `Context#interact`
  applies `style.visuals.interact_cursor` to hovered clickables —
  the CSS `cursor: pointer` style (upstream default is none; here it
  defaults to Pointer so buttons/links show the hand out of the box).
  `Button#cursor(icon)` overrides per widget. Hyperlink → pointer,
  TextEdit → text, DragValue → ew-resize, window resize grip →
  nwse-resize.
- Backend (`backend/sokol_shim.c`, `src/egui/backend/sokol.cr`): the
  eframe→winit role. Crystal applies `ctx.cursor_icon` when it
  changes; the shim's `egui_cr_set_cursor(css_name)` is the
  cross-platform adapter — X11: `XcursorLibraryLoadCursor` by CSS
  name (XDG themes use the CSS keywords) with a core cursor-font
  fallback table; Win32: `IDC_*` stock cursors; macOS: no-op stub
  (needs NSCursor/ObjC — unwired). Note: this sokol version gates
  the X11 backend with `_SAPP_LINUX` (not `_SAPP_X11`).
- Verified live on X11 (Yaru): hand over buttons, I-beam over
  TextEdit, ew-resize over DragValue, animated watch/zoom cursors
  from the gallery demo buttons (XFixes cursor-image probes).

## 8. Delta: theming (`Theme`, `WidgetStyle`)

Upstream keeps `Style` on the Context (`Context::style`) with
`Visuals::dark()`/`light()` presets; egui.cr wraps that in a named
`Theme` and adds a merge-based per-widget override layer:

- `src/egui/theme.cr`: `Theme {name, dark?, style}` with `Theme.dark` /
  `Theme.light` presets (the light palette is new; the dark one is the
  old `Style` defaults). `Context#theme` / `#theme=` — assignment swaps
  the global style instantly (immediate mode re-reads the theme every
  frame, so the next frame repaints with the new palette);
  `Context#style` now delegates to `theme.style` (existing widget code
  unchanged). `App#theme`/`#theme=` delegate to the Context.
- `WidgetStyle`: per-widget overrides where every field is nilable,
  nil = inherit from the theme (`text_color`, `fill`/`fill_hovered`/
  `fill_active`, `border_color`, `selection_fill`, `separator_color`,
  `hyperlink_color`, `font_size`, `button_padding`).
  `#merge_over(base : Style)` clones the theme's Style and copies the
  non-nil fields in — the theme is never mutated.
- `Widget#style { |s| … }` collects overrides on any widget;
  `Widget#effective_style(ui)` is the merge point. Widgets resolve
  their style through it at the top of `#ui` (Button, Label, Checkbox,
  RadioButton, Separator, ProgressBar, Slider, Hyperlink wired).
  Overrides survive theme swaps; nil fields follow the new theme.
- Gallery demo: View menu → light/dark toggle, plus a custom-filled
  "Themed red" button that keeps its fill across swaps. Specs: default
  theme, instant swap repaint, merge semantics, no-aliasing of merged
  styles.
- `Visuals#modal_dim`: the `Context#modal` scrim was hardcoded black;
  it now follows the theme (dark: rgba(0,0,0,140), light:
  rgba(0,0,0,70) — lighter themes dim less).
- `Visuals#dark` + `Visuals#fade_color` (port of upstream
  `fade_out_color`): the "weaker variant" multipliers
  (`mul_color(0.5/0.6/0.8/0.85)` in TextEdit hint, RichText#weak,
  Hyperlink active, Slider handle hover) darkened on both themes —
  inverted on light. fade_color darkens on dark themes and lightens
  (blends to white) on light ones. Also: the sokol shim's hardcoded
  window clear color is now pushed from the theme's `panel_fill` each
  frame (`egui_cr_set_clear_color`), and TextEdit uses
  `spacing.button_padding` + `effective_style` instead of a private
  pad literal.

## 9. Delta: async native dialogs (`AsyncDialogs`)

Upstream opens native file dialogs through `rfd`, which never blocks
the UI thread. The old port called `Process.run` (zenity/kdialog)
straight from `update`, freezing the frame loop for the whole dialog.

- `src/egui/system_ports/dialog.cr`: `OpenFileDialog.show` /
  `SaveFileDialog.show` are now non-blocking — they take an
  `&on_done : String? ->` block and return immediately. The blocking
  `Dialogs.open`/`Dialogs.save` are `protected`: a dialog can never
  run on the caller's fiber.
- `AsyncDialogs` (same file): each request gets a worker fiber; the
  blocking `Process.run` suspends only that fiber. Completed requests
  queue for delivery; everything is single-threaded (fibers switch
  cooperatively), so the queues need no locks.
- The run loop (`sapp_run`) never returns control to the Crystal
  scheduler, so spawned fibers would never run on their own — the
  backend pumps: `Sokol.on_frame` calls `AsyncDialogs.pump` before
  `begin_frame`, which does one bounded scheduler pass
  (`select` + `timeout(1ms)` ≈ 1ms/frame, only while a dialog is
  open) and then delivers callbacks in the main fiber, before
  `app.update` — safe to touch app state. `AsyncDialogs.pending?`
  drives "opening…" UI states (see examples/hello.cr).
- Verified live on X11: while zenity is open the loop keeps rendering
  at ~60fps; cancel/choose delivers the path (nil on cancel) on the
  next frame. Specs (`spec/system_ports_spec.cr`) cover delivery,
  cancel→nil, non-blocking pump, and concurrent requests headlessly
  with fake work procs.

## 10. Delta: Crystal text stack (two font backends)

Upstream 0.34 switched font rendering from `ab_glyph` to `skrifa` +
`vello_cpu` with TrueType hinting on by default ("sharper text");
fontstash's stb_truetype path cannot hint at all, which made port text
look blurry (measured: every glyph edge carried a ~1px gray shoulder,
1px horizontal strokes rendered at ~53% intensity). The port replaces
fontstash with a Crystal-side text stack — fontstash/fons are gone from
the runtime path. Two backends share it:

- `src/egui/backend/freetype.cr` (`FreetypeFonts`) — **primary**: a
  direct Crystal binding of FreeType (`libfreetype`), rasterizing
  hinted 8-bit coverage bitmaps via `FT_Load_Glyph` with
  `FT_LOAD_DEFAULT | FT_LOAD_RENDER`. Real TrueType/CFF hinting instead
  of a heuristic, so stem weights are even and crossbars come out
  crisp. The big opaque structs (`FT_FaceRec`, `FT_GlyphSlotRec`) are
  partially mirrored with field offsets verified via `offsetof(3)`;
  everything else goes through real FreeType functions. Sizes are
  requested via `FT_Request_Size` (NOMINAL, 26.6) as `size` pixels of
  (ascender − descender) height — the same convention the stb backend
  and fontstash's FreeType path used, so widget layout does not shift
  between backends. `FT_Face`'s size is stateful: `set_size` runs
  before every call that depends on it. Vertical metrics are computed
  linearly from font units, because FreeType's scaled ascender/descender
  are rounded to whole pixels (DejaVu: 13/−4 = 17px at size 16).
- `src/egui/backend/text.cr` (`LightHintedFonts`, fallback for systems
  without FreeType): stb_truetype outline → **two-axis light hint** →
  rasterize → atlas. The goal is to approximate FreeType's full
  grid-fitting as closely as a heuristic can (verified glyph-by-glyph
  against the FreeType backend's output at 16px):
  - *Hinting*: straight outline edges perpendicular to an axis (the
    crossbars of e/H/A for Y; the stems of l/I/н for X) are collected,
    clustered in pixel space (≤0.5px) and snapped to whole pixel
    rows/columns. Pairs of edges forming one stroke are quantized as a
    unit — edge to the nearest pixel, thickness to `round(t)` whole
    pixels (min 1), the same rounding FreeType's grid-fitter applies
    (a ~1.2px DejaVu stem renders as a solid 1px column, like FT, not
    a 2px band or a half-intensity smear). The second edge of a stroke
    is found by ray-casting into the polygon when it is a curve.
    Coordinates pass through the resulting piecewise-linear maps with a
    pinned baseline anchor (0→0, Y only) and identity outside the
    anchor range, so hinted glyphs never shift relative to unhinted
    neighbours. Curve-only flanks ('о', 'е' sides) stay unhinted on
    that axis — that is where the heuristic visibly trails FT.
  - *Hinting (X)*: paired stem edges quantize ONLY the thickness —
    the stem stays at its natural position (leading edge untouched,
    trailing edge = natural width, min 1px solid, +0.15px darkening).
    Positional snapping of stem edges was tried and removed: the pen
    is fractional, so an integer snap in glyph-local coordinates never
    lands on a screen pixel column — it only displaced parts of the
    glyph by up to 0.5px (piecewise-linear map ⇒ shear: 'a' leaned
    right, 'b' left, and the pair read as merged). The edge-pair
    window is scaled (`win = 0.13·size`, between a DejaVu stem
    ~0.09·size and a counter ~0.15·size): a fixed ~2.5px window
    stopped pairing stems above ~20px, so at 24/32px both stem edges
    quantized independently and the stem collapsed to a thin column.
    Unpaired straight edges get no X anchor at all (no shear source).
    The +0.15px darkening matches DejaVu's bytecode which widens
    stems on-grid (design 2.05 → FT renders ~2.3px at 24px). Verified
    against FT dumps at 16/24/32px (Е stems: 1.4 / 2+0.3 / 3.0 vs FT
    1.4 / 2+0.3 / 2.8).
  - *Known gap*: advances are linear from font units while FreeType's
    hinted advances are decided per-glyph by the font's bytecode
    (±1px), so string widths drift between the two backends by a few
    percent, changing sign with size (measured on a 25-glyph string:
    +6.1% at 12px, −3.4% at 16, +1.0% at 32). Not reproducible by a
    heuristic; within each backend layout stays self-consistent
    (measure == draw).
  - *Tracking*: `LightHintedFonts#letter_spacing` adds a flat
    +0.22px between letters (`AtlasFonts#walk` applies it between
    glyphs only, never after the last, so `measure` widths stay
    exact; tuned by eye against the FreeType tab). The heuristic
    keeps glyphs at design positions while FreeType's hinted advances
    open the FT tab up, so without it the fallback reads tight next
    to it.
  - *Hinting (Y, blue zones)*: horizontal edges (crossbars) quantize to
    whole pixel rows; the outline's top/bottom extremes snap into the
    nearest zone — baseline / x-height / cap height, measured once from
    reference glyph outlines ('I', 'x') since stb exposes no such
    metrics — so round glyphs ('0'-'9', 'о', 'е') drop their ±0.5px
    overshoot and match FreeType's heights instead of rendering 1-2px
    taller with faint edge rows.
  - *Advances/kerning*: fractional — glyph POSITIONS are snapped to
    whole pixels at draw time (round(pen + bearing), like upstream
    egui), not the advances: rounding each advance accumulates error
    down a run (sum(round) ≠ round(sum)) and long words drift by
    several pixels. The remaining ~2% width gap vs FreeType is the
    DejaVu bytecode widening its advances at small sizes — replicating
    that requires executing font instructions, which is what FreeType
    is for.
  - *Rasterizer*: curves flattened adaptively, nonzero-winding scanline
    with 4×4 supersampling.
- Shared infrastructure (`AtlasFonts`, `Glyph`, `GlyphAtlas` in
  `text.cr`): 1024² RGBA atlas (white RGB, coverage alpha), shelf packer
  with 1px borders against LINEAR bleed, stream texture updated before
  the render pass (`sg_update_image` is illegal inside a pass — hence
  `touch` + `flush` between `end_frame` and `begin_pass`), a
  {glyph id, size} glyph cache, and one `walk` (fractional advances +
  kerning) shared by measure and draw so they can never disagree.
  Coverage goes through the upstream dark-mode contrast curve
  `alpha = 2c − c²` (epaint
  `FontColorTransferFunction::TwoCoverageMinusCoverageSq`) in both
  backends. Atlases are per-instance on the GPU (the shim keeps a
  view-id → image registry), so both backends can coexist and be
  swapped at runtime via `Sokol.select_fonts`.
- *Draw path*: one textured quad per glyph through a dedicated sgl
  pipeline (straight alpha blend; the sokol_gl default pipeline has no
  blending), quads snapped to whole screen pixels, fractional advances
  + kerning (fontstash rounded advances to whole pixels, which made
  letter spacing uneven).
- Backend selection (`backend/sokol.cr` `on_init`): `FreetypeFonts` →
  `LightHintedFonts` → built-in `MonospaceFonts` (stub) — first that
  loads a system font wins. Candidate font files come from the Fonts
  system port (`src/egui/system_ports/fonts.cr`: per-platform lists
  selected at compile time — win32/darwin/Linux). Build-time dep:
  `pkg-config freetype2` (see crosspack.yml); runtime dep: libfreetype6.
- `backend/stb_truetype_shim.c`: the vendored `stb_truetype.h` compiled
  as its own translation unit (default malloc; fontstash compiles the
  same header `STBTT_STATIC` with a FONScontext-bound allocator, which
  is why the exposure cannot live in `sokol_shim.c`). Exposes font
  info/vmetrics/glyph lookup/hmetrics/kern/`stbtt_GetGlyphShape`.
- `bin/fontpreview` (`examples/fontpreview.cr`): full Latin + Cyrillic
  alphabets, digits, punctuation at sizes 12–32 — the visual test bed,
  with two live-switchable tabs (FreeType vs light-hint, both font
  backends loaded and swapped via `Sokol.select_fonts`; automation:
  `echo 0|1 > /tmp/fontpreview.tab`). Verified by pixel analysis with
  the FreeType backend: crossbars of e/A/Е/Б render full-row at even
  weight with 1px stems, baselines stay uniform, Cyrillic descenders
  (д ц щ у) intact.

## 11. Delta: floating containers constrained to the screen

Port of upstream `Area`'s default `constrain: true` (area.rs:
`size.at_most(constrain_rect.size())` +
`Context::constrain_window_rect_to_area`), which the old port skipped
entirely — initial widths were used raw everywhere.

- `Context#constrain_floating(pos, size, min_width, constrain_y)`
  (context.cr): cap the width at the screen width, floor it at
  `min_width` (the parent widget for anchored popups — the floor wins,
  so the popup shifts instead of shrinking below its parent), then
  clamp the position so the rect stays inside. Frames without a screen
  (headless specs, zero `screen_rect`) skip the constraint.
- Applied in `#window` (initial/stored size + position while dragging;
  the resize grip is additionally capped at the screen edges —
  upstream `Resize` max_size), `#area`, `#popup` (new `min_width:`
  param; the anchor shifts left at the right screen edge), and
  `#modal` (width capped at the screen). `ComboBox` passes
  `min_width: rect.width` so its popup is never narrower than the
  button (previously only true on the opening frame).
- Tooltips (`Response#show_tooltip`) flip back left/up at the
  right/bottom screen edge instead of overflowing.

## 12. Delta: window-like modal dialogs (GTK pattern, egui.cr-native)

`WindowModal` (`containers/window_modal.cr`, no upstream counterpart)
is a class of modals that imitate an OS window inside the app — the
GTK `GtkDialog` shape layered on the existing modal machinery
(`Memory#mark_modal` + Foreground layer + scrim):

- Window chrome shared by every subclass: title bar (title text,
  ✕ close button, drag-to-move via a persistent offset from the
  centered position, constrained to the screen), content area
  (`#body`), GTK-style right-aligned button strip (`#buttons`,
  `#button_row` helper with disabled-button graying).
- Open state, drag offset and per-dialog data live in
  `Memory#data`/`layer_sizes` keyed by `Id.from("app_modal/<id>")`
  with high child salts (0x1xx–0x2xx) so they never collide with
  `Ui#next_widget_id` counters; subclasses are stateless value
  objects built each frame. Escape closes (GTK default,
  `close_on_escape = false` opts out).
- `ColorChooserModal` (GtkColorChooserDialog): the phase-6
  ColorPicker plus old/new swatch preview, a two-way-synced `#rrggbb`
  entry, a 19-color default palette; notifies live (GTK
  `notify::rgba`), Select closes, Cancel reverts to the open-time
  color.
- `AboutModal` (GtkAboutDialog): logo/version/comments/website/
  authors/copyright, Close. Laid out centered — block text alignment
  (CSS `text-align`) ships with this phase: `RichText#align`,
  `ui.label(…, align:)`, `ui.heading(align:)`, `Hyperlink`/`
  hyperlink_to(align:)` and the `WidgetStyle#text_align` /
  `Style#text_align` override chain; aligned labels are block-level
  (they take the full row width). The title-bar ✕ is GTK-proportioned
  (small hit target, inset glyph).
- `WizardModal` (GtkAssistant): persistent current page (reset on
  `#open`), Cancel | Back | Next buttons, Back disabled on page 0,
  Next turns into Finish on the last page and fires the
  constructor block.
- Gallery: "Containers → Window Modals" tab opens all three;
  specs cover chrome/blocking, Escape + ✕, title drag, live hue
  notify + Select/Cancel semantics, About contents, and the full
  wizard page cycle.

