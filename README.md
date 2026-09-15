# egui-cr

Immediate-mode GUI for Crystal — a 1:1 port of [egui](https://github.com/emilk/egui)'s
architecture (Rust), rendered through [sokol_gfx](https://github.com/floooh/sokol).

## Layout

- `docs/ANALYSIS.md` — architecture analysis of upstream egui (crates, core
  types, widget model) that this port follows 1:1.
- `egui-upstream/` — read-only reference clone of egui.
- `vendor/sokol`, `vendor/fontstash` — native C dependencies.
- `src/egui/` — the port: platform-pure core (`id`, `memory`, `input`,
  `context`, `response`, `sense`, `layout`, `ui`, `widgets/`) plus the
  sokol backend (`backend/sokol/`).
- `examples/hello.cr` — button + label + label change (Hello World).

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

Differences from the Linux build:

- the native library is `lib\egui_cr_sokol.lib` (MSVC resolves
  `@[Link("egui_cr_sokol")]` to exactly that name; no `lib` prefix),
  and the examples pass the lib dir via `/LIBPATH:`, not `-L`
- the FreeType font backend is compile-time disabled on win32 (no
  FreeType import library is assumed); text rasterization falls back
  to the vendored stb_truetype light-hint path
- system ports that shell out to `zenity`/`xdg-open` (dialogs, URL
  opening, user dirs) return nil/false on Windows — not wired yet

## Status

Slice 1: the core frame loop (RawInput → begin_frame → app update →
end_frame → paint), `Id`/`Memory` interaction tracking, `Ui` with
vertical/horizontal layout, `Label` and `Button` widgets, sokol_app
window + sokol_gfx rendering + fontstash text. See `docs/ANALYSIS.md`
for the full upstream map and what is next.
