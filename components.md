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
  (the current `Spacing`/`Visuals` classes grow in place). Global
  theming lives in `src/egui/theme.cr`: the active `Theme` preset sits
  on `Context#theme` (instantly swappable), and per-widget overrides
  merge over it via `Widget#style { |s| … }` / `WidgetStyle#merge_over`.
- System/OS ports (quit, native dialogs, clipboard, …) live in
  `src/egui/system_ports/`, one file per port under `Egui::SystemPorts`;
  platform-heavy calls stay behind an installable implementation the
  backend wires (see `quit.cr`), stdlib-backed ones may run directly
  (see `dialog.cr`).
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
| Grid, columns, add_sized, scope, enabled | `grid.rs`, `ui.rs` | Grid done; ui.rs helpers missing | P7 |
| Context menu, drag&drop payload, on-demand repaint, IME, clipboard | various | context menu done | P7 (optional) |
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

- [x] `src/egui/input.cr`: extend `Event` union with
      `Key(key : KeyCode, pressed : Bool, ctrl : Bool, shift : Bool, alt : Bool)`
      and `Text(text : String)`; `KeyCode` enum mirroring the `sapp_keycode`
      subset we care about (letters, digits, arrows, Tab, Enter, Backspace,
      Delete, Escape, Home/End, PgUp/PgDn, modifiers).
- [x] `backend/sokol_shim.c` + `src/egui/backend/sokol.cr`: forward
      `SAPP_EVENTTYPE_KEY_DOWN/KEY_UP/CHAR` (+ modifier flags) into the raw
      event queue.
- [x] `InputState`: `key_pressed?/key_down?/key_released?`, `modifiers`,
      `consume_key` (ownership so TextEdit eats keys first), keep `events`.
- [x] `src/egui/sense.cr`: add `Focusable` flag; opt in: button, checkbox,
      radio, slider, drag_value, hyperlink, (text_edit later).
- [x] Focus navigation ← `crates/egui/src/memory/mod.rs:502` (`Focus`):
      Tab / Shift+Tab cycles focusables in the top layer, arrows navigate
      geometrically using stored interaction rects (already in Memory);
      focus ring painted as rect outline on the focused widget.
- [x] Full `DragValue`: type-to-edit buffer, Up/Down arrows, Ctrl+click
      reset-to-range-start.
- [x] Specs: synthetic key RawInput — Tab moves focus between two buttons;
      typed digits update drag_value; `consume_key` hides the event from a
      second widget.

## Phase 4 — rich text, LayoutJob, wrapping

- [x] `src/egui/galley.cr`: simplified Galley — rows of positioned run
      slices + per-row width + caret x-positions (built for P4.5 TextEdit).
- [x] `src/egui/fonts.cr`: abstract `Fonts#layout(runs) : Galley` with
      greedy word-wrap via the existing `measure`.
- [x] `src/egui/rich_text.cr` ← `crates/egui/src/widget_text.rs` (subset):
      `RichText {text, size, color?, underline?, background?}` with chainable
      builders; `ui.rich(...)`; `heading`/weak colors moved onto it.
- [x] Painter: extend `TextCmd` to carry per-run color; underline drawn as a
      `line` cmd at ascent height.
- [x] `ui.label(text, wrap : Bool)` — multi-line wrapping label.
- [x] Hyperlink full: underline + hover color via RichText.
- [x] Specs: long text wraps into N rows within max_rect width; colored run
      produces matching TextCmd + underline LineCmd.

## Phase 4.5 — TextEdit (needs P3 keyboard + P4 galley)

- [x] `src/egui/widgets/text_edit.cr` ← `widgets/text_edit/` (staged):
      1) single-line: cursor, click-to-place, backspace/char insert,
         `consume_key` priority; 2) selection + copy/cut/paste via shell-out
         to `xclip`/`wl-copy` (optional, rescue-noop); 3) multiline once
         ScrollArea (P5) exists; 4) IME — deferred to P7.
      → stage 1 done (single-line, caret, click-to-place, arrows/Home/End,
      blinking caret); stages 2–4 remain.
- [x] `ui.text_edit_singleline(buffer : String, &on_change : String ->)`.
- [x] Specs: type "ab" → buffer "ab"; backspace; cursor placement on click.

## Phase 5 — scroll area, panels, resize

- [x] `src/egui/containers/scroll_area.cr` ← `containers/scroll_area.rs`:
      `ScrollState {offset, content_size}` in IdTypeMap; outer Ui sizes the
      viewport, inner child Ui is offset; clipping via existing
      `painter.clip=`; scrollbars painted as rects when content overflows.
- [x] Scroll arbitration: top-most scrollable containing the pointer
      consumes `input.scroll` (port of upstream scroll-target logic,
      simplified into Memory).
- [ ] Kinetic scrolling: port `crates/emath/src/history.rs` →
      `src/egui/history.cr` (pointer velocity EMA) — nice-to-have.
- [x] `src/egui/panel.cr`: generalize `bottom_panel`; `Context#available_rect`
      reset each `begin_frame`, each panel takes a bite;
      `#top_panel`, `#side_panel(side)`, `#central_panel`; panels must be
      added before `central_panel` (upstream rule) — this removes the
      documented "contents drawn before bottom_panel don't shift"
      simplification in ANALYSIS.md.
- [x] `src/egui/containers/resize.cr` ← `containers/resize.rs`: corner grip
      → implemented as the corner grip wired directly into `Context#window`
      (size persists in Memory#layer_sizes); standalone Resize later if needed.
      drag, min/max size, size in IdTypeMap; wire into `Context#window`.
- [x] `src/egui/containers/area.cr`: explicit positioned layer region
      (already implicit in window/popup — expose as public helper).
- [x] Specs: scroll Event moves offset and clips content; panel rects shrink
      in add-order; window resize drag changes its stored size.

## Phase 6 — textures, image, color picker

- [x] `src/egui/painter.cr`: `ImageCmd {clip, rect, uv : Rect,
      texture_id : UInt64}`; `painter.image(...)`.
- [x] Backend: `TextureRegistry` — `register_rgba(w, h, bytes) : TextureId`
      via `sg_make_view` + sampler, bound with `sgl_texture` before quads
      (vendored `sokol_gl.h` supports it — verified). `Context#textures`.
- [x] Vendor `stb_image.h` for PNG/JPEG decode (update `vendor/VENDORED.md`
      + `Rakefile`); `ctx.load_image(path) : TextureId` with cache.
- [x] `src/egui/widgets/image.cr` ← `widgets/image.rs`; `Button#image(texture)`
      icon support.
- [x] `src/egui/color.cr`: HSV↔sRGB (port from `crates/ecolor/src/color.rs`).
- [x] `src/egui/widgets/color_picker.cr` ← `widgets/color_picker.rs`: hue
      → lite version: SV square + hue bar + swatch (gradient textures cached in
      Memory#texture_cache); alpha editing and the hue wheel come later if needed.
      wheel (arc cmds), SV square, alpha slider, current/new swatches;
      `ui.color_edit32(rgba) { |c| }`.
- [x] Specs: registered texture id flows into ImageCmd; HSV roundtrip within
      epsilon; manual visual check of the wheel in the gallery example.

## Phase 7 — remaining parity & polish (pick on demand)

- [x] Cursor icons (user request): CSS `cursor` support —
      `src/egui/cursor_icon.cr` (all 35 keywords, `#to_css`/`.parse?`),
      `Context#cursor_icon`/`#set_cursor_icon` (upstream
      `PlatformOutput::cursor_icon`), `Response#on_hover_cursor`,
      style `Visuals#interact_cursor` (pointer by default over
      clickables — `cursor: pointer`), `Button#cursor(icon)` override;
      backend adapter `egui_cr_set_cursor` in the shim (X11+Xcursor
      with cursor-font fallback, Win32 IDC map, macOS stub);
      gallery demo: a button per cursor in the "Cursors" section.
      Specs: exact CSS strings, round-trip, hover→pointer + reset,
      per-widget override, drag_value ew-resize.
- [x] Sidebar container (user request): `src/egui/containers/sidebar.cr`
      (egui.cr-native, no upstream counterpart) — titled sections of
      full-width tab rows; the app owns the selection (Checkbox
      pattern: passed in, handed back via `Ui#sidebar` block +
      `Response#changed?`). `examples/widgets_gallery.cr` navigates
      its per-widget galleries through it. Specs: tab/section clicks
      switch the selection, selected tab painted with the accent fill.
- [x] StyleSheet — CSS-like class styling (user request):
      `src/egui/stylesheet.cr` — a global tree of dotted-path classes
      (`sidebar.tab`) holding mergeable `StyleVars` bags (a Hash
      subclass: colors/floats/bools per key; paddings/margins are
      per-side CSS boxes — `padding.top/left/right/bottom` with the
      scalar `padding` shorthand) plus per-state overlays
      (`sidebar.tab:hover`, `:selected`). Two cascade layers, CSS-1:1:
      class rules are defaults (root→leaf, specific wins), state rules
      always override them (root→leaf, leaf wins); per-widget
      `Widget#style` overrides sit above both (inline > stylesheet).
      Merged bags are cached across frames (a `rule` tweak drops the
      cache). Lives on the `Theme` (`ctx.stylesheet`). Introspection:
      `#classes`, `#selectors`, `#dump(io)` / `puts ctx.stylesheet`
      (colors as #rrggbbaa). Sidebar styles entirely through it (tab
      padding box, zero tab gap, section margin box instead of
      separators, hover/selected fills); `Widget#style_class` is the
      adoption hook for other widgets. Gallery demos live restyle
      (Themes tab) + stylesheet dump (View menu). Specs: two-layer
      cascade precedence, cache invalidation, Int32→Float64 coercion,
      per-side boxes with shorthand fallback, dump content, preset
      palettes, sidebar layout read from the sheet.
- [x] DefaultTheme (user request): `src/egui/default_theme.cr` — the
      complete default theme in one file ("user-agent stylesheet"):
      base palette (dark/light) + element class rules for everything
      styled through classes (`sidebar.*`, `button.*`). `Theme.dark` /
      `Theme.light` delegate to it; `DefaultTheme.build("name", dark:)`
      is the derivation point for custom presets. Class rules set only
      what differs from the base Style (the rest inherits). Button is
      the second class consumer (padding box, hover/active fills,
      state text color). Specs: preset assembly, default selectors,
      live button restyle, inline-override precedence.
- [x] Nested buttons / closable tabs (user request): `Section#closable`
      arms an X button nested inside each sidebar tab row. The nested
      widget interacts AFTER its parent, and `Memory#topmost_at` picks
      the latest-created widget under the pointer — so the X eats the
      click (a close never selects the tab) and the tab body still
      selects normally. `Sidebar#closed` / `Ui#sidebar(on_close:)`
      report `{section, tab}`; the gallery removes the tab (and the
      section when it empties), with selection index fix-up and an
      empty-state guard. Specs: X hit targets vs tab rects, close
      without selection, tab click away from the X, empty section
      list.
- [x] Wheel scroll speed (user request): `Style#scroll_speed` —
      pixels per wheel notch (sokol reports ±1.0 per notch; the raw
      delta was being applied as pixels → 1px per notch). Default 60
      (≈ three text lines), theme-tunable at runtime. Spec: one notch
      moves exactly `scroll_speed` px after ownership settles, and a
      live `scroll_speed` change takes effect next frame.
- [x] Ui helpers: `add_sized`, `scope`, `columns`, `enabled(flag)`
      (widgets render through a stable child Ui in both states so ids
      — and thus interaction state — survive disable/enable cycles;
      disabled regions get dead verdicts via `Memory
      push/pop_disabled` + a back-painted scrim).
- [x] `src/egui/containers/grid.cr` ← `grid.rs` (classic API; dropped
      from the vendored 0.36 tree): aligned columns via one-frame width
      convergence — widths measured frame N are persisted per-grid in
      IdTypeMap (cells kept alive through pruning via `Memory#use_id`)
      and applied frame N+1; explicit `widths:` pin the columns (what
      Table builds on), `striped:` back-paints alternate rows.
      `ui.grid(id) { |g| g.label …; g.end_row }`.
- [x] `Response#context_menu` (right-click menus on the P2 popup/menu
      system): `InputState` gains secondary-press tracking
      (`secondary_pressed?` + `secondary_pos`); opens on secondary press
      over the widget's rect (works on labels too — no hover sense
      needed), anchor persisted in `Memory#areas`; `menu_item` rows
      close it, a click elsewhere dismisses it (popup close-on-outside).
- [x] egui.cr-native extras (no upstream counterpart, user request):
      `SelectableLabel` (`widgets/selectable_label.cr`; upstream 0.36
      folds it into `Button::selectable`) + `ui.selectable(selected,
      text) { |v| }`; `ToggleButton` (`widgets/toggle_button.cr`) —
      switch-style checkbox (track + knob); `SegmentedControl`
      (`widgets/segmented.cr`) — joined one-of-many row, chosen index
      via `Response#widget_value`, `ui.segmented(sel, labels) { |i| }`;
      `TreeView` (`containers/tree_view.cr`) — `node`/`leaf` rows,
      open/close persisted in IdTypeMap keyed by node path (app holds
      only the selection), `ui.tree_view(id) { |t| … }`; `Table`
      (`containers/table.cr`) — header + striped body over pinned-width
      Grid (slim cousin of egui_extras' virtualized Table), fractions
      of available width, `ui.table(id, headers, fractions) { |rows| … }`.
      Gallery: "Layout" section (Grid/Table/Tree/Plot/Enabled tabs),
      toggle/segmented/selectable/date-picker in Inputs, context-menu
      demo in Buttons. Specs: selection paint + block helpers,
      segmented index click, grid column alignment from frame 2, tree
      default-open + toggle, table headers/stripes, context-menu open +
      click-elsewhere close, enabled blocking + id stability,
      add_sized cell, columns gaps, date-picker day click, plot
      auto-fit + drag-locks-bounds, drag_value custom format.
- [x] `src/egui/widgets/date_picker.cr` ← `egui_extras/src/datepicker/`
      (slim): `ui.date_picker(id, time) { |t| … }` — button with the
      formatted date (custom strftime), popup calendar (‹ month year ›
      header, weekday row, day grid, Today); shown month persists in
      IdTypeMap; "today" cells tinted with the hyperlink color. Note:
      this Crystal build has no `Time.now` — use `Time.local`.
- [x] `src/egui/containers/plot.cr` ← egui_plot (deliberately slim):
      `ui.plot(id, height) { |p| p.line(name, pts); p.points(name,
      pts) }` — shared data coords, auto-fit bounds (5% padding, flat
      series get a fixed span), drag-to-pan, wheel zoom anchored at
      the pointer, grid + corner axis labels, legend; bounds persist
      in IdTypeMap and leave auto mode on first interaction.
- [x] `DragValue` custom formatter (`ui.drag_value(format: ->(v) { … })`)
      on top of prefix/suffix.
- [x] `examples/openfiledialog.cr` — native pickers (zenity/kdialog on
      Linux/BSD, osascript on macOS) via
      the existing fiber-backed `SystemPorts::OpenFileDialog` /
      `SaveFileDialog` (the Rakefile example list already expected it).
- [ ] Drag&drop payload ← `crates/egui/src/drag_and_drop.rs` (optional).
- [ ] On-demand repaint: honor `request_repaint` in the sokol loop instead
      of redrawing every vsync (optional perf).
- [ ] IME (sapp text-input events), clipboard without shell-out (optional).
- [ ] `containers/scene.rs` — evaluate whether anyone needs it; defer.

## Iteration order

0 → 1 → 2 → 3 → 4 → 4.5 → 5 → 6 → 7. Phases 1–2 give the most visible
parity per effort; P3+P4 unlock TextEdit; P5 fixes the last big layout
simplifications; P6/P7 are additive.
