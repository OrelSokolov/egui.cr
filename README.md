<p align="center">
  <img src="assets/icon.png" width="160" alt="egui-cr logo">
</p>

# egui.cr — Easy crossplatform GUI on pure Crystal

**[► WATCH DEMO](DEMO.md)** — screenshots of everything below.

| macOS | Windows | Linux | Android | iOS |
|---|---|---|---|---|
| ✓ | ✓ | ✓ | ✗ | ✗ |

**Beautiful UI is already here.** A framework for beautiful UIs in
Crystal — inspired by [egui](https://github.com/emilk/egui)'s
architecture (Rust) and its ideas, not a port of it.

| Feature | Description  |
|---|---|
| **Reactive** | signals, memoized computeds, one-line widget bindings — no manual repaint plumbing |
| **Immediate mode** | egui-style per-frame UI: declare widgets every frame, state lives in your app |
| **CSS cascade** | dotted-path style classes (`sidebar.tab`) with state overlays (`:hover`, `:selected`), resolved like the CSS cascade |
| **Widget Inspector** | right-click any widget to restyle it live — per-element overrides and class rules with `:hover`/`:active` states — then export the tweaks as `ctx.set_id_style(...)` / `ctx.stylesheet.rule(...)` snippets |
| **Font renderer** | [freetype.cr](https://github.com/OrelSokolov/freetype.cr) — our pure-Crystal FreeType port (SFNT, TrueType hinting, ftgrays) |
| **SVG renderer** | [nanosvg.cr](https://github.com/OrelSokolov/nanosvg.cr) — our pure-Crystal NanoSVG port (fills, gradients, transforms, dashes) |
| **Rendering backend** | [sokol_gfx](https://github.com/floooh/sokol) — window + GPU; the only native dependency |

Everything between the backend and your app is pure Crystal — no
libfreetype and no C font or icon code in shipped binaries; C
accelerators exist only as a dev convenience behind
`USE_C_EXTENSIONS=1` — see `.env.example`.

## Build & run

```bash
crosspack deps                    # verify/install build deps (crystal, GL, X11, xcursor)
crosspack run widgets_gallery     # build if needed, launch the gallery
```

Or manually:

```bash
rake spec                  # headless core specs
rake build:examples        # vendor C + crystal build
./bin/widgets_gallery
```

### Optimized iteration: `-O3` instead of `--release`

`crystal build --release` merges the whole program into a single LLVM
module (`Compiler#release!` sets `single_module = true`) so LLVM can
inline across the stdlib⇄shard⇄app boundaries. Side effect: the
compiler's per-unit object cache (units = files of the require graph,
keyed by each unit's generated bitcode) is defeated — any code edit
re-runs `-O3` over everything, stdlib and shards included.

`crystal build -O3` (no `--release`) sets the optimization level
without the single-module merge, so the cache works: editing app code
recompiles only the touched units and reuses the rest. Measured on the
nanosvg benchmark app (Crystal 1.21, this repo's machine):

| rebuild after an edit | `--release` | `-O3` |
|---|---|---|
| time                  | ~9.5 s (full re-opt) | ~2.1 s (405/406 units reused) |

The trade-off: without the single-module merge there is no
cross-module inlining, and the hot stdlib⇄shard boundary pays for it —
the nanosvg rasterizer benchmarks run 2–3x slower than a true
`--release` binary (and the binary is ~50% larger). So `-O3` is for
fast iteration with optimized-ish code; ship the final binary from
`--release`. Plain dev builds remain the fastest loop (~1.8 s, no LLVM
optimization at all).

### C extensions for dev builds

Crystal cannot — architecturally — produce optimal binaries through a
fast cached path: the single-module merge that makes `--release` code
fast defeats the incremental cache (see above), and unoptimized dev
codegen (no regalloc/inlining, bounds checks on every array access)
runs the hot rasterizer loops up to ~10x slower than the same
algorithm in C. In a dev build that gap makes the UI lag; in
`--release` Crystal code is on par with — or faster than — the C
equivalents, so shipped binaries gain nothing from C.

The escape hatch: route the two hot bakes through C extensions of the
Crystal libraries while iterating — font rasterization via the system
libfreetype (C FFI) and SVG rasterization via the C NanoSVG shim.
Output is byte-identical to the pure-Crystal paths, so dev and release
render exactly the same. Enable with `USE_C_EXTENSIONS=1` in `.env`
(copy from `.env.example`) or in the build environment — off by
default (a fresh clone is self-contained pure Crystal), and never
active in `--release` builds.

### Windows

The same rake targets work on Windows. Requirements:

- [Crystal](https://crystal-lang.org/install/) for Windows (`x86_64-pc-windows-msvc`)
- Visual Studio 2022 (or its Build Tools) with the *Desktop development
  with C++* workload — the vendor C code is built with `cl.exe`, and
  Crystal's msvc target links against the MSVC/Windows-SDK runtimes
- Ruby + rake (`gem install rake`)

```bat
rake spec             &:: headless core specs
rake build:examples   &:: vendor C (cl.exe) + crystal build -> bin\
bin\hello
```

`crosspack deps` / `crosspack build` also work on Windows (host
target `windows-11.0`; the matrix entry lands exes + DLLs into
`builds\windows\11.0\x86_64`).

Differences from the Linux build:

- the native library is `lib\egui_cr_sokol.lib` (MSVC resolves
  `@[Link("egui_cr_sokol")]` to exactly that name; no `lib` prefix),
  and the examples pass the lib dir via `/LIBPATH:`, not `-L`
- the Windows system ports are native: file dialogs are the Explorer
  IFileDialog (COM) on a dedicated shim thread (PowerShell+WinForms
  stays as the headless, no-backend fallback), MessageBox calls
  `MessageBoxW` (user32) owned by the app window, OpenUrl uses
  `ShellExecuteW` (shell32), reveal is `explorer /select`, the window
  icon comes from RGBA pixels (`WM_SETICON`, no-op elsewhere),
  notifications are NotifyIcon balloons, and user dirs come from
  `%APPDATA%`/`%LOCALAPPDATA%` + `SHGetKnownFolderPath`; Linux keeps
  the `zenity`/`kdialog`/`xdg-open` subprocess ports

### macOS

The same commands work on macOS (host target `macos`; artifacts land in
`builds/macos/aarch64` on Apple Silicon). Requirements:

- [Crystal](https://crystal-lang.org/install/) for macOS (`brew install crystal`)
- Xcode Command Line Tools (`xcode-select --install`) — X11/xcursor
  are not needed, sokol_app uses Cocoa there

Differences from the Linux build:

- the vendor C shim is compiled as Objective-C (`cc -x objective-c`) and
  linked against the Cocoa/OpenGL/QuartzCore frameworks
- system ports shell out to `osascript`/`open` (dialogs, message
  boxes, notifications, URL opening, user dirs) and manage the window
  through AppKit (NSWindow/NSScreen from the ObjC shim)

## Screenshots

The full gallery lives in **[DEMO.md](DEMO.md)** — notepad in both
themes, the four borderless window frames, the widget gallery (default
and custom-stylesheet), and paint. All shots are script-generated;
regenerate the set for a new release (Linux/X11):

```bash
python3 scripts/make_screenshots.py        # builds + shoots + rewrites DEMO.md
```

## Styling — a CSS cascade

Looks are declarative, like CSS: a global tree of style classes
addressed by dotted paths, each holding style variables for the base
state plus overlays for interaction states — resolved exactly like the
CSS cascade (more specific classes win, states always override
classes, leaves beat ancestors). Merged styles are cached across
frames; editing a rule drops the cache.

```crystal
ctx.stylesheet.rule("sidebar.tab", StyleVars{
  "padding"    => Egui::Vec2.new(12.0, 6.0),
  "text_color" => Egui::Color32.rgb(235, 235, 235),
})
ctx.stylesheet.rule("sidebar.tab:selected", StyleVars{
  "background" => Egui::Color32.rgb(0, 122, 204),
})
```

The sheet rides on the `Theme` (`ctx.theme = …` swaps class styles
together with the palette); the default theme's rules live in
`default_theme.cr`.

## Reactive state

On top of the immediate-mode core sits a thin reactive layer
(`src/egui/reactive.cr`, see `egui-reactive.md` for the design):
mutable state cells with change notification, memoized derivations
and one-line widget bindings — no manual `request_repaint`, no
`if changed?; @field = value` plumbing.

```crystal
class MyApp < Egui::App
  reactive count = 0                      # literal default: type inferred
  reactive name = "world"
  reactive items : Array(String) = [] of String  # otherwise: explicit type

  computed greeting : String = "Hello, #{name}!"  # memoized; re-runs
  computed total : Int32 = count + items.size     # only when inputs change

  def update(ctx)
    ctx.window("demo") do |ui|
      ui.label(greeting)
      ui.text_field(name_signal)     # bound widgets: display + write-back
      ui.checkbox(flag_signal, "On")
      self.count += 1 if ui.button("+1").clicked?
    end
  end
end
```

- `reactive x = default` wraps a field in a `Signal(T)`: a real write
  (same value → no-op) bumps a version, dirties dependent computeds
  and — outside a frame — requests a repaint, so mutations from
  timers/fibers/dialog callbacks wake the UI by themselves.
- `computed name : Type = expr` is lazy and memoized; reads performed
  while it evaluates register as dependencies (a computed may read
  other computeds). Writing an unrelated signal does not dirty it.
- Bound widget forms on `Ui`: `slider(sig, range, text)`,
  `drag_value(sig, …)`, `checkbox(sig, text)`, `toggle_button`,
  `selectable`, `text_field(sig, hint)`, `textarea(sig, rows)`,
  `combo_box(id, sig, options)`. They take the signal itself — the
  generated `*_signal` accessor (`name_signal`) hands it out; the
  plain getter returns the value.
- Writes inside your own methods need an explicit receiver
  (`self.count += 1`) — a bare `count += 1` would create a local.
- Plain fields stay idiomatic for state only touched by input
  handlers (input events already drive repaints); use `reactive` for
  out-of-frame mutations and `computed` inputs.

Runnable demo: `bin/counter_reactive` (fiber-driven ticking signal,
computed run counters in the status panel).

## Routing (pages, modals, deep links)

An app is a set of PAGES addressed `window/page` with an optional
`#widget` fragment (`src/egui/router.cr`). One window exists today
(`root`); every routed app starts at `root/root`:

```crystal
class MyApp < Egui::App
  def update(ctx)
    ctx.routes do |r|
      r.page "root/root" do |ui| …the home UI… end
      r.page "root/settings", title: "Settings" do |ui| … end
      r.modal "root/confirm-close", title: "Save changes?" do |ui| … end
    end
  end
end
```

- `r.page` — a full-window opaque page (an `Egui::Page`); the round
  back button pops the route stack (`router.navigate` / `back` /
  `replace` from code, menus, hotkeys).
- `r.modal` — a modal is just a page: an addressable overlay route
  rendered as the semi-transparent scrim + centered card over the base
  page, blocking input below it. No back button — the scrim IS the
  back: a click on the dimmed area outside the card pops the route
  (clicks on the card itself never do).
- Pages are declared every frame, immediate-mode style; the router
  renders the current stack when the `ctx.routes` block ends.
- `--page root/settings#search` on the command line opens the app
  straight at a page — and lands keyboard focus on the widget created
  with `focus_id: "search"` (`text_edit_singleline`, `TextEdit`,
  `TextArea`, `NumberInput`). Everything else in ARGV passes through
  to the app untouched.
- Unknown addresses are a soft warning: one stderr line and a
  "Page not found" page with a back button — never a crash.

The same mechanism drives debugging and (later) screenshot generation
in arbitrary app states. Runnable demos: `bin/hello` (`root/root`),
`bin/notepad --page root/settings#search` (editor, settings page and
a modal confirm-close page). Demo screenshots for those states:
`python3 scripts/make_notepad_screenshots.py` (Linux/X11 — launches
the app, deep-links each route, drives the modal with synthetic
XTEST input and captures the window into `screenshots/`).

## Terminal

`egui/terminal` is a cross-platform terminal emulator built on the
same core (see `docs/TERMINAL.md` for the full picture): a pure-Crystal
VT500 engine (parser, grid with scrollback, SGR, selection, key
encoding), the `TermView` widget (`ui.terminal(session)`), and a
native PTY — POSIX ptys on Linux/macOS, ConPTY on Windows — compiled
from `backend/pty_shim.c` into the existing native library by
`rake build:native`. `./bin/terminal` is a tabbed terminal: per-tab
shells, OSC-driven tab titles, closable tabs, mouse selection and
scrollback. The engine is headless-spec'd (`spec/terminal_spec.cr`,
`spec/terminal_widget_spec.cr`).

## Status

Core frame loop (RawInput → begin_frame → app update → end_frame →
paint), `Id`/`Memory` interaction tracking, `Ui` with vertical/horizontal
layout, `Label` and `Button` widgets, sokol_app window + sokol_gfx
rendering, and the pure-Crystal text stack (freetype-cr with TrueType
hinting; C-FFI FreeType as an opt-in dev accelerator). See
`docs/ANALYSIS.md` for the full upstream map and what is next.
