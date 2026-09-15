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
- the Windows system ports are native: file dialogs run the WinForms
  picker through PowerShell (`-EncodedCommand`), MessageBox calls
  `MessageBoxW` (user32), OpenUrl/reveal use `ShellExecuteW` (shell32),
  notifications are NotifyIcon balloons, and user dirs come from
  `%APPDATA%`/`%LOCALAPPDATA%` + `SHGetKnownFolderPath`; Linux keeps the
  `zenity`/`kdialog`/`xdg-open` subprocess ports

## Status

Slice 1: the core frame loop (RawInput → begin_frame → app update →
end_frame → paint), `Id`/`Memory` interaction tracking, `Ui` with
vertical/horizontal layout, `Label` and `Button` widgets, sokol_app
window + sokol_gfx rendering + fontstash text. See `docs/ANALYSIS.md`
for the full upstream map and what is next.
