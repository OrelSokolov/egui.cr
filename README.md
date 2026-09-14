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

## Status

Slice 1: the core frame loop (RawInput → begin_frame → app update →
end_frame → paint), `Id`/`Memory` interaction tracking, `Ui` with
vertical/horizontal layout, `Label` and `Button` widgets, sokol_app
window + sokol_gfx rendering + fontstash text. See `docs/ANALYSIS.md`
for the full upstream map and what is next.
