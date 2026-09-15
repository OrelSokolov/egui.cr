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
  `fill_active`, `stroke`, `selection_fill`, `separator_color`,
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
