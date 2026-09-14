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
| epaint Fonts/Galley | `src/egui/fonts.cr` + backend `FontstashFonts` |
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
fontstash (via `util/sokol_fontstash.h`) for text, continuous repaint
(vsync). On-demand repaint (`request_repaint`) is the next backend
step.

## 6. Verified behavior (slice 1)

- `crystal spec` — frame loop, paint list, hover, click
  (press+release), click suppression when press began outside,
  state-driven label change. All headless.
- `bin/hello` — real window on X11: window + title, `Hello World!`
  heading, `Click me` button (hover/active states), `Clicked N times`
  label that changes on click. Verified by running on a live display
  and pixel-analyzing a screenshot (clear color, window fill, button
  fill/stroke, and anti-aliased text pixels all present).
