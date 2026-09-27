<p align="center">
  <img src="assets/icon.png" width="160" alt="egui-cr logo">
</p>

# egui-cr

Immediate-mode GUI for Crystal — inspired by [egui](https://github.com/emilk/egui)'s
architecture (Rust) and its ideas, not a port of it; rendered through
[sokol_gfx](https://github.com/floooh/sokol).

## Layout

- `docs/ANALYSIS.md` — architecture analysis of upstream egui (crates, core
  types, widget model) used as the blueprint this project takes its
  ideas from.
- `egui-upstream/` — read-only reference clone of egui.
- `vendor/sokol`, `vendor/fontstash` — native C dependencies.
- `assets/icon.svg` — the project icon (see `scripts/make_icon.ps1` for
  the generated `.ico`/embed twins).
- `src/egui/` — the library: platform-pure core (`id`, `memory`, `input`,
  `context`, `response`, `sense`, `layout`, `ui`, `widgets/`) plus the
  sokol backend (`backend/sokol/`).
- `examples/hello.cr` — button + label + label change (Hello World).
- `examples/counter_reactive.cr` — reactive demo: signals, computeds,
  fiber-driven ticking, bound widgets.

## Build & run

```bash
crosspack deps        # verify/install build deps (crystal, GL, X11, xcursor)
crosspack build       # specs + native lib + examples -> builds/
./bin/hello
```

Or manually:

```bash
rake spec             # headless core specs
rake build:examples   # vendor C + crystal build
./bin/hello
```

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
- FreeType binaries (x64 import lib + DLL, pinned by SHA256) are
  fetched by `scripts\fetch_freetype.bat` — wired into `crosspack deps`
  (`freetype-dev`) and `rake build:native`. `bin\freetype.dll` must ship
  next to the exes; its VC++ v14 runtime requirement is declared in the
  runtime `deps:` section (`vc-redist` → winget
  `Microsoft.VCRedist.2015+.x64`)
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
- Xcode Command Line Tools (`xcode-select --install`)
- Homebrew FreeType + pkg-config (`brew install freetype pkg-config`) —
  X11/xcursor are not needed, sokol_app uses Cocoa there

Differences from the Linux build:

- the vendor C shim is compiled as Objective-C (`cc -x objective-c`) and
  linked against the Cocoa/OpenGL/QuartzCore frameworks
- system ports shell out to `osascript`/`open` (dialogs, message
  boxes, notifications, URL opening, user dirs) and manage the window
  through AppKit (NSWindow/NSScreen from the ObjC shim)

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

## Status

Slice 1: the core frame loop (RawInput → begin_frame → app update →
end_frame → paint), `Id`/`Memory` interaction tracking, `Ui` with
vertical/horizontal layout, `Label` and `Button` widgets, sokol_app
window + sokol_gfx rendering + fontstash text. See `docs/ANALYSIS.md`
for the full upstream map and what is next.
