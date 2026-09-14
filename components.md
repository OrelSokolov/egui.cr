# egui.cr widget-parity plan

Reference: `egui-upstream/` = emilk/egui @ tag `0.36.2` (read-only reference
clone, see `docs/ANALYSIS.md`). Phases are ordered by dependency and payoff;
each phase is one or more iterations. Tick the boxes as work lands, and update
`docs/ANALYSIS.md` (deltas section) after each phase.

Conventions for every phase:

- New widget files live in `src/egui/widgets/`, containers in
  `src/egui/containers/` (new dir), each starting with the standard header
  comment: `# Port of egui_upstream/crates/egui/src/widgets/<x>.rs.`
- Every widget gets a `Ui#<name>` convenience helper in `src/egui/ui.cr`
  mirroring the upstream helper in `crates/egui/src/ui.rs`.
- Widget state is stored per-`Id` in the existing `Memory` IdTypeMap
  (`ctx.memory` / `frame_cache`), never in widget instances.
- Style additions go into `src/egui/style.cr` as plain properties
  (the current `Spacing`/`Visuals` classes grow in place).
- Every phase adds specs to `spec/core_spec.cr` (layout math and interaction
  via synthetic `RawInput`s) and extends `examples/widgets_gallery.cr`
  (created in phase 1) for manual visual checks.
- `Response` gains `changed?`/`mark_changed` (upstream `response.rs:613/625`)
  in phase 1 — stateful widgets report through it.

## Status snapshot

| Component | Upstream file | egui.cr | Phase |
|---|---|---|---|
| Label / Button / CollapsingHeader | `widgets/{label,button}.rs`, `containers/collapsing_header.rs` | done | — |
| Window (move only, no resize) | `containers/window.rs` | done (partial) | P5 resize |
| Popup (basic) / BottomPanel | `containers/popup.rs`, `containers/panel.rs` | done (partial) | P2/P5 |
| Painter line/circle/arc | `epainter/src/tessellation` | missing | **P0** |
| Checkbox, Radio, Separator, ProgressBar, Spinner | `widgets/*.rs` | missing | **P1** |
| Hyperlink (lite → full) | `widgets/hyperlink.rs` | missing | P1 → P4 |
| Slider, DragValue | `widgets/{slider,drag_value}.rs` | missing | **P2** (+P3 typing) |
| ComboBox | `containers/combo_box.rs` | missing | **P2** |
| Frame, Menu, Tooltip, Modal | `containers/{frame,menu,tooltip,modal}.rs` | missing | **P2** |
| Keyboard events + focus nav | `input_state/`, `memory/mod.rs:502` | missing | **P3** |
| RichText / LayoutJob / wrapping | `widget_text.rs`, `epainter` galley | missing | **P4** |
| TextEdit | `widgets/text_edit/` | missing | P4.5 (needs P3+P4) |
| ScrollArea | `containers/scroll_area.rs` | missing | **P5** |
| Panels (top/side/central), Resize, Area | `containers/{panel,resize,area}.rs` | missing | **P5** |
| Textures, Image, button icons | `load/`, `widgets/image.rs` | missing | **P6** |
| ColorPicker | `widgets/color_picker.rs` | missing | **P6** |
| Grid, columns, add_sized, scope, enabled | `grid.rs`, `ui.rs` | missing | P7 |
| Context menu, drag&drop payload, on-demand repaint, IME, clipboard | various | missing | P7 (optional) |
| `scene` container (new in 0.36) | `containers/scene.rs` | missing | deferred |

## Phase 0 — painter primitives (line, circle, arc)

Goal: unblock the visuals of ~8 later widgets (checkmark, radio dot, slider
handle+rail, spinner arc, hyperlink underline, color wheel).

- [x] `src/egui/painter.cr`: new `PaintCmd` variants
      `LineCmd {clip, p1, p2, width, color}` and
      `CircleCmd {clip, center, radius, fill : Color32?, stroke : Color32?, stroke_width}`;
      plus an `ArcCmd {clip, center, radius, start_angle, end_angle, width, color}`
      (used by spinner/color wheel).
- [x] Painter methods: `line(p1, p2, width, color)`, `circle_filled`,
      `circle_stroke`, `arc`.
- [x] `src/egui/backend/sokol.cr`: render the new cmds — thick line as a
      rotated quad computed in Crystal (vertices via existing quad path);
      circle as a 32-segment triangle fan; arc as a strip of quads. No new
      sokol features needed (`sgl_begin_lines` exists but has no line width;
      quads give width support).
- [x] Spec: new cmds appear in `end_frame` output with correct clip.

## Phase 1 — simple widgets

- [x] `Response`: add `changed?`/`mark_changed` (upstream `response.rs`).
- [x] `src/egui/widgets/checkbox.cr` ← `widgets/checkbox.rs`:
      rounded box + checkmark (two `line` cmds), hover/active colors from
      `Visuals#button_fill`. API: `ui.checkbox(checked : Bool, text : String,
      &on_change : Bool ->)` plus `Checkbox` widget class returning
      `Response#changed?`.
- [x] `src/egui/widgets/radio_button.cr` ← `widgets/radio_button.rs`:
      outer ring + inner dot (`circle_stroke`/`circle_filled`).
      `ui.radio(selected : Bool, text : String, &on_click)`.
- [x] `src/egui/widgets/separator.cr` ← `widgets/separator.rs`:
      layout-aware (horizontal line in vertical layout, vertical in
      `horizontal`).
- [x] `src/egui/widgets/progress_bar.cr` ← `widgets/progress_bar.rs`:
      fill fraction animated via `ctx.animate_value_with_time` when the
      value decreases.
- [x] `src/egui/widgets/spinner.cr` ← `widgets/spinner.rs`: rotating `arc`,
      angle from `animate_value_with_time`, `request_repaint` while shown.
- [x] `src/egui/widgets/hyperlink.cr` (lite) ← `widgets/hyperlink.rs`:
      colored + underlined label, `Sense::click`; on click spawn
      `xdg-open <url>` (Linux; rescue-noop). Full rich-text version in P4.
- [x] `examples/widgets_gallery.cr`: demo page listing all phase-1 widgets.
- [x] Specs: toggle-on-click, radio select, separator rect/size, progress
      paint cmds, spinner requests repaint.

## Phase 2 — slider, drag_value (drag), combo box, menus, tooltips, modal, frame

- [x] `src/egui/smart_aim.cr` ← `crates/emath/src/smart_aim.rs`
      (`best_bounds_distance`) — verbatim port, one pure function + spec.
- [x] `src/egui/widgets/slider.cr` ← `widgets/slider.rs`: rail + handle
      (P0 cmds), drag → value mapped through smart_aim, optional text label,
      `SliderState` in IdTypeMap. API:
      `ui.slider(value, range : Range(Float64, Float64), text : String) { |v| }`.
- [x] `src/egui/widgets/drag_value.cr` (drag part) ← `widgets/drag_value.rs`:
      `drag_delta * speed` while dragging, display value as label,
      `Sense::click_and_drag`. Keyboard typing lands in P3.
- [x] `src/egui/containers/combo_box.cr` ← `containers/combo_box.rs`:
      button + reuse `Context#popup`; `ui.combo_box(id, text) { |ui| }`.
- [x] `src/egui/containers/frame.cr` ← `containers/frame.rs`: struct
      `Frame {margin, fill, stroke, rounding}`; `ui.frame(&)`; refactor
      `Context#window`/`#popup` background painting onto it.
- [x] `src/egui/containers/menu.cr` ← `containers/menu.rs`: `MenuBar`,
      `ui.menu_button(text) { }`, submenus; `MenuState` in Memory
      (open menus, hover-to-switch, click-item-closes).
- [x] `src/egui/containers/tooltip.cr` ← `containers/tooltip.rs`:
      `Order::Tooltip` layer already exists in `layer.cr`; implement the
      currently-noop `Response#on_hover_text` (+ `#on_hover_ui`), short hover
      delay via IdTypeMap timestamp.
- [x] `src/egui/containers/modal.cr` ← `containers/modal.rs`: dim rect on
      top of Middle, `Context#modal { }`, blocks input to lower layers,
      does *not* close on outside click.
- [x] Rounded-corner strokes (user request): render `RectCmd` strokes
      with rounded corners in the backend — each corner becomes arc
      segments (the `rounding` field already exists in the cmd, today it
      only affects nothing). Buttons, frames and menus get real soft
      corners.
- [x] Gradient fills (user request): `RectCmd` gains optional
      `fill2 : Color32?` + gradient direction (vertical by default);
      the backend interpolates per-vertex (Gouraud — sgl quads already
      carry per-vertex colors). `Button#gradient(c1, c2)`, gradient
      preset in Visuals for button fills.
- [x] Desktop top menu bar (user request): `ctx.menu_bar { |bar| … }` —
      a native-looking bar pinned to the top of the window,
      `bar.menu_button("File") { |ui| … }` dropdowns with shortcut
      hints, open-on-hover-when-another-menu-is-open (upstream
      `MenuBar::ui` semantics).
- [x] Button icons (user request): `Button#icon(name : Symbol)` — a
      small built-in vector icon set (check, close, left/right/up/down
      arrows, plus, minus) drawn with phase-0 painter primitives;
      raster-image icons land with textures (P6).
- [x] Specs: slider drag raises value monotonically, smart_aim bounds,
      combo open→select→close, menu open→click item, tooltip appears after
      hover delay, modal blocks clicks beneath.

## Phase 3 — keyboard input & focus navigation

- [ ] `src/egui/input.cr`: extend `Event` union with
      `Key(key : KeyCode, pressed : Bool, ctrl : Bool, shift : Bool, alt : Bool)`
      and `Text(text : String)`; `KeyCode` enum mirroring the `sapp_keycode`
      subset we care about (letters, digits, arrows, Tab, Enter, Backspace,
      Delete, Escape, Home/End, PgUp/PgDn, modifiers).
- [ ] `backend/sokol_shim.c` + `src/egui/backend/sokol.cr`: forward
      `SAPP_EVENTTYPE_KEY_DOWN/KEY_UP/CHAR` (+ modifier flags) into the raw
      event queue.
- [ ] `InputState`: `key_pressed?/key_down?/key_released?`, `modifiers`,
      `consume_key` (ownership so TextEdit eats keys first), keep `events`.
- [ ] `src/egui/sense.cr`: add `Focusable` flag; opt in: button, checkbox,
      radio, slider, drag_value, hyperlink, (text_edit later).
- [ ] Focus navigation ← `crates/egui/src/memory/mod.rs:502` (`Focus`):
      Tab / Shift+Tab cycles focusables in the top layer, arrows navigate
      geometrically using stored interaction rects (already in Memory);
      focus ring painted as rect outline on the focused widget.
- [ ] Full `DragValue`: type-to-edit buffer, Up/Down arrows, Ctrl+click
      reset-to-range-start.
- [ ] Specs: synthetic key RawInput — Tab moves focus between two buttons;
      typed digits update drag_value; `consume_key` hides the event from a
      second widget.

## Phase 4 — rich text, LayoutJob, wrapping

- [ ] `src/egui/galley.cr`: simplified Galley — rows of positioned run
      slices + per-row width + caret x-positions (built for P4.5 TextEdit).
- [ ] `src/egui/fonts.cr`: abstract `Fonts#layout(runs) : Galley` with
      greedy word-wrap via the existing `measure`.
- [ ] `src/egui/rich_text.cr` ← `crates/egui/src/widget_text.rs` (subset):
      `RichText {text, size, color?, underline?, background?}` with chainable
      builders; `ui.rich(...)`; `heading`/weak colors moved onto it.
- [ ] Painter: extend `TextCmd` to carry per-run color; underline drawn as a
      `line` cmd at ascent height.
- [ ] `ui.label(text, wrap : Bool)` — multi-line wrapping label.
- [ ] Hyperlink full: underline + hover color via RichText.
- [ ] Specs: long text wraps into N rows within max_rect width; colored run
      produces matching TextCmd + underline LineCmd.

## Phase 4.5 — TextEdit (needs P3 keyboard + P4 galley)

- [ ] `src/egui/widgets/text_edit.cr` ← `widgets/text_edit/` (staged):
      1) single-line: cursor, click-to-place, backspace/char insert,
         `consume_key` priority; 2) selection + copy/cut/paste via shell-out
         to `xclip`/`wl-copy` (optional, rescue-noop); 3) multiline once
         ScrollArea (P5) exists; 4) IME — deferred to P7.
- [ ] `ui.text_edit_singleline(buffer : String, &on_change : String ->)`.
- [ ] Specs: type "ab" → buffer "ab"; backspace; cursor placement on click.

## Phase 5 — scroll area, panels, resize

- [ ] `src/egui/containers/scroll_area.cr` ← `containers/scroll_area.rs`:
      `ScrollState {offset, content_size}` in IdTypeMap; outer Ui sizes the
      viewport, inner child Ui is offset; clipping via existing
      `painter.clip=`; scrollbars painted as rects when content overflows.
- [ ] Scroll arbitration: top-most scrollable containing the pointer
      consumes `input.scroll` (port of upstream scroll-target logic,
      simplified into Memory).
- [ ] Kinetic scrolling: port `crates/emath/src/history.rs` →
      `src/egui/history.cr` (pointer velocity EMA) — nice-to-have.
- [ ] `src/egui/panel.cr`: generalize `bottom_panel`; `Context#available_rect`
      reset each `begin_frame`, each panel takes a bite;
      `#top_panel`, `#side_panel(side)`, `#central_panel`; panels must be
      added before `central_panel` (upstream rule) — this removes the
      documented "contents drawn before bottom_panel don't shift"
      simplification in ANALYSIS.md.
- [ ] `src/egui/containers/resize.cr` ← `containers/resize.rs`: corner grip
      drag, min/max size, size in IdTypeMap; wire into `Context#window`.
- [ ] `src/egui/containers/area.cr`: explicit positioned layer region
      (already implicit in window/popup — expose as public helper).
- [ ] Specs: scroll Event moves offset and clips content; panel rects shrink
      in add-order; window resize drag changes its stored size.

## Phase 6 — textures, image, color picker

- [ ] `src/egui/painter.cr`: `ImageCmd {clip, rect, uv : Rect,
      texture_id : UInt64}`; `painter.image(...)`.
- [ ] Backend: `TextureRegistry` — `register_rgba(w, h, bytes) : TextureId`
      via `sg_make_view` + sampler, bound with `sgl_texture` before quads
      (vendored `sokol_gl.h` supports it — verified). `Context#textures`.
- [ ] Vendor `stb_image.h` for PNG/JPEG decode (update `vendor/VENDORED.md`
      + `Rakefile`); `ctx.load_image(path) : TextureId` with cache.
- [ ] `src/egui/widgets/image.cr` ← `widgets/image.rs`; `Button#image(texture)`
      icon support.
- [ ] `src/egui/color.cr`: HSV↔sRGB (port from `crates/ecolor/src/color.rs`).
- [ ] `src/egui/widgets/color_picker.cr` ← `widgets/color_picker.rs`: hue
      wheel (arc cmds), SV square, alpha slider, current/new swatches;
      `ui.color_edit32(rgba) { |c| }`.
- [ ] Specs: registered texture id flows into ImageCmd; HSV roundtrip within
      epsilon; manual visual check of the wheel in the gallery example.

## Phase 7 — remaining parity & polish (pick on demand)

- [ ] Ui helpers: `add_sized`, `scope`, `enabled(flag)`, `columns`.
- [ ] `src/egui/grid.cr` ← `crates/egui/src/grid.rs`.
- [ ] `Response#context_menu` (right-click menus, needs P2 menu).
- [ ] Drag&drop payload ← `crates/egui/src/drag_and_drop.rs` (optional).
- [ ] On-demand repaint: honor `request_repaint` in the sokol loop instead
      of redrawing every vsync (optional perf).
- [ ] IME (sapp text-input events), clipboard without shell-out (optional).
- [ ] `containers/scene.rs` — evaluate whether anyone needs it; defer.

## Iteration order

0 → 1 → 2 → 3 → 4 → 4.5 → 5 → 6 → 7. Phases 1–2 give the most visible
parity per effort; P3+P4 unlock TextEdit; P5 fixes the last big layout
simplifications; P6/P7 are additive.
