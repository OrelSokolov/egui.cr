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
| TextEdit | `widgets/text_edit/` | done | — |
| TextArea (multiline, kinetic scroll) | `widgets/text_edit/` | done (`widgets/textarea.cr`) | — |
| ScrollArea | `containers/scroll_area.rs` | missing | **P5** |
| Panels (top/side/central), Resize, Area | `containers/{panel,resize,area}.rs` | missing | **P5** |
| Textures, Image, button icons | `load/`, `widgets/image.rs` | missing | **P6** |
| ColorPicker | `widgets/color_picker.rs` | missing | **P6** |
| Canvas (pixel editing, Paint-style) | — (egui.cr-native, no upstream counterpart) | done (`widgets/canvas.cr`) | P7 |
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
- [x] Label selectable by default (`userselect : Bool = true`, upstream
      `interaction.selectable_labels`): press/drag selects a range,
      double-click a word, Ctrl+C copies through the Clipboard port;
      `userselect: false` → inert paint-only label.
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
- [x] `src/egui/widgets/textarea.cr` — multiline stage (HTML `<textarea>`
      shape): soft word-wrap, per-line selection/caret, own kinetic-
      scrolled viewport + scrollbar, Enter/row-wise Up/Down/Home/End,
      paste keeps line breaks, UTF-8-aware caret stepping, caret
      auto-scroll. `ui.textarea(buffer, rows:, &on_change)`. Blank
      lines preserved in layout (`Galley::Row#newline_before`).
      Buffers over `BIG_TEXT_BYTES` (512 KiB) switch to a virtual
      `less`-style mode: a one-pass line index, only a window of rows
      around the viewport ever laid out, no soft wrap. Document-wise
      jumps: Ctrl+Home / Ctrl+End (caret to buffer start/end, Shift
      extends the selection).
- [x] Specs: type "ab" → buffer "ab"; backspace; cursor placement on click;
      textarea: Enter/newlines, Up/Down/Home/End, paste, wheel scroll,
      blank-line layout.

## Phase 5 — scroll area, panels, resize

- [x] `src/egui/containers/scroll_area.cr` ← `containers/scroll_area.rs`:
      `ScrollState {offset, content_size}` in IdTypeMap; outer Ui sizes the
      viewport, inner child Ui is offset; clipping via existing
      `painter.clip=`; scrollbars painted as rects when content overflows.
- [x] Bar placement + horizontal axis: `vbar: :left/:right` pins the
      vertical bar to either edge; `hbar: :bottom/:top` turns on
      horizontal scrolling (own kinetic scroller; Shift+wheel routes
      the wheel to it, upstream convention). Both flavors, overlay and
      classic — a classic strip is reserved on the chosen side (the
      Sidebar rides `vbar: :left` so the bar stays clear of the tabs'
      close buttons).
- [x] Scroll arbitration: top-most scrollable containing the pointer
      consumes `input.scroll` (port of upstream scroll-target logic,
      simplified into Memory).
- [x] Kinetic scrolling: port `crates/emath/src/history.rs` →
      `src/egui/history.cr` (+ `KineticScroller`: wheel impulses feed an
      offset History whose velocity estimate flings the content after
      input stops, exponential decay, dead stop at edges; scrollbar
      thumb = direct control). Wired into ScrollArea and TextArea;
      histories persist in `Memory#scroll_history`.
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
      with cursor-font fallback, Win32 IDC map + WndProc subclass so
      WM_SETCURSOR re-applies our cursor instead of the class arrow —
      a plain SetCursor was reset by sokol's own WM_SETCURSOR handler
      on every mouse move; Win32 `none` = 1x1 transparent CreateCursor,
      macOS stub);
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
- [x] Tabs container (user request): `src/egui/containers/tabs.cr`
      (egui.cr-native, no upstream counterpart) — a horizontal tab
      strip for the top of a tab container, same Checkbox-pattern
      selection as the Sidebar (`Ui#tabs` block + `Response#changed?`).
      The active tab is highlighted with a background fill plus an
      underline (`fill`, `underline_color`/`underline_width` of the
      `tabs.tab:selected` overlay) drawn over a full-width baseline
      (`tabs.rule_color`); `closable:` arms the same nested X button
      as the sidebar (the X eats the click, `Tabs#closed` /
      `Ui#tabs(on_close:)` report the index). When the tabs overflow
      the strip it scrolls carousel-style: the active tab always stays
      fully inside the visible window (offset persisted in Memory,
      minimal-scroll clamping), off-screen tabs neither paint nor
      interact, and straddling tabs are clipped to the strip for both
      painting and hit-testing. Styles entirely through the StyleSheet
      (`tabs`, `tabs.tab` + `:hover`/`:selected`). Specs: horizontal
      flush layout + click selection, underline/baseline geometry,
      carousel overflow behavior, selected fill, live
      restyle, nested X hit-testing, empty list.
      `layout: :multiline` (user request) wraps full rows Windows-
      Properties-style instead of scrolling: one line of tabs fills
      up, the next starts below it — the strip grows downward (a
      baseline per row), every tab stays visible and clickable, and a
      tab wider than the strip gets a row of its own (clipped like a
      carousel straddler). Spec: row wrapping, per-row baselines,
      click selection on a later row. Demo:
      `examples/win_properties_demo.cr` (`bin/win_properties_demo`) —
      a Win32-style property sheet: 12 tabs wrapped into several rows,
      per-tab property Grid, OK/Cancel/Apply button row, and a
      checkbox toggling the same strip to `:carousel` for comparison.
      The demo also skins the WHOLE app Win95 (silver/navy/teal
      palette) through the classic-skin engine keys added alongside:
      `tabs.tab`/`button` `bevel_light`/`bevel_dark` (raised 3D
      borders, read per state — `button:active` swapping the colors
      sinks the box), `button`/`checkbox` `rounding`, `tabs`
      `merge_selected` (the baseline skips the active tab, connecting
      it to the page), `underline_width <= 0` disables the selection
      underline, `checkbox` `box_fill`/`box_stroke`/`check_color`, and
      `Visuals#title_bar_fill` + `Visuals#window_rounding` (navy
      square title bar in `Context#window`, flat window by default).
      Specs: tab bevel geometry + baseline gap around the active tab,
      button bevel + rounding + sunken :active, themed title bar.
- [x] Textarea fixes (user request): (1) the wrap width and viewport
      height now follow the ALLOCATED rect instead of the requested
      `rows` box — the max-size rule clamps a fill-the-panel textarea
      to its parent, and a virtual viewport taller than the real rect
      zeroed the scroll range (no wheel scroll in the notepad);
      (2) an empty line inside a selection paints a thin 3px sliver
      (browser behavior) when the selection spans the whole row
      including its newline — previously empty lines showed no
      highlight at all; (3) the selection highlight paints UNDER the
      text (like TextEdit/browsers) — it used to cover the glyphs, so
      the selected text was invisible. Specs: clamped box scrolls by
      wheel, empty middle line gets the sliver rect, highlight goes
      into the paint list before the text.
- [x] Deferred central panel (user request, architectural fix):
      `Context#central_panel` no longer renders in place — it stores
      its block and #end_frame renders it after every other panel has
      bitten #available_rect. The central panel always gets the true
      remainder regardless of declaration order, so a bottom status
      bar declared after it (the notepad idiom) can no longer paint
      over its content (the textarea's last line used to hide under
      the strip). Upstream egui only documents "CentralPanel last";
      here the ordering hazard is structurally impossible. The return
      value is the call-time remainder (exact when declared last).
      Spec: bottom-after-central bites first, no overlap.
- [x] Notepad example (user request): `examples/notepad.cr` — a
      Windows 11 Notepad-style tabbed text editor: borderless window
      with the tab strip IN the caption (TitleBarTabs via the
      WindowFrame caption hook, dirty dots instead of "*"): File menu (New /
      Open… / Save / Save As… / Close Tab / Quit) driven by the
      hotkey/action layer (Ctrl+N/O/S/Shift+S/W/Q hints in the
      menus), native
      open/save dialogs via SystemPorts, a status bar (path, char and
      line counts), and per-tab editor state (the textarea runs in a
      child Ui id'd per tab, so each document keeps its own caret and
      selection). Built by `rake build:examples` (bin/notepad). Closing
      a dirty tab asks first: a Save / Don't save / Cancel modal
      (ctx.modal); "Save" on an untitled doc goes through the async
      save dialog and closes in its callback (cancel keeps the tab),
      the pending target is held by identity — not index — so the
      document list may shift while a native dialog is open. Quit
      (Ctrl+Q) runs the same confirmation as a cascade over every
      dirty document before actually quitting (Cancel aborts it).
      Command-line arguments open straight into tabs: `bin/notepad
      a.txt b.md` — each file is MIME-checked first (content sniffing
      via `file -b --mime-type`, stdlib MIME registry as the fallback
      where file(1) is missing); non-text files are skipped with a
      stderr note, and a successful open drops the welcome tab. Tab
      navigation is action-driven too: View → Next/Previous Tab
      (notepad.next_tab / notepad.prev_tab) bound to Ctrl+Tab /
      Ctrl+Shift+Tab — wrap around, and the carousel scrolls the new
      active tab into view (hotkey dispatch consumes the key in
      begin_frame, so the focused textarea never steals it). The tab
      selection is reactive: `reactive selected` (Signal) +
      `computed editor_ui_id`; "active tab = active editor" holds by
      watching the signal's version — any selection change (click,
      Ctrl+Tab, open, close) requests keyboard focus for the new
      tab's textarea in one place, no per-event plumbing; dialog
      callbacks that switch tabs get their repaint via the reactive
      setter automatically.
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
      switch-style checkbox (track + knob); the tumbler matches the
      text height by default, untie with `sync_with_text => false` +
      `tumbler_size` (CSS class `toggle_button`); `SegmentedControl`
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
      in IdTypeMap and leave auto mode on first interaction;
      `animated: true` adds the double-click reset; the reset pill
      appears on any plot (animated or not) once the view deviates,
      unless `reset_button: false`; `draggable: false` makes the plot
      read-only (no pan/zoom/pill, default view only); `#line`/
      `#points` accept an optional per-series `color:` override.
- [x] `DragValue` custom formatter (`ui.drag_value(format: ->(v) { … })`)
      on top of prefix/suffix.
- [x] `examples/openfiledialog.cr` — native pickers (zenity/kdialog on
      Linux/BSD, osascript on macOS) via
      the existing fiber-backed `SystemPorts::OpenFileDialog` /
      `SaveFileDialog` (the Rakefile example list already expected it).
- [x] OS file drag&drop fixed: `sapp_desc.enable_dragndrop` was never set
      (default false), so sokol silently ignored drops on every platform —
      now enabled in `backend/sokol_shim.c` (8 files, 8 KiB paths max).
- [x] Max-size rule (user request): widgets never overflow their
      region — `Ui#allocate_space` clamps every allocated rect to
      `max_rect`'s far corner (the effective max width/height of any
      widget is bounded by its parent region; semi-infinite regions
      are unaffected). Per-component fit policies on top of that
      floor: Label keeps its `wrap` mode, TextEdit single-line becomes
      a fixed-width field with horizontal scrolling (offset in
      IdTypeMap, caret auto-follow so typing at either end stays
      visible, content clipped to the field rect). Specs: clamped
      allocations in vertical + horizontal regions, long-edit width
      bound, caret-follow scroll > 0, clipped TextCmds, Home snaps
      back to the start.
- [x] Default client-side chrome (user request): `src/egui/containers/
      window_frame.cr` (egui.cr-native) — `Egui::WindowFrame` in four
      selectable looks (`WindowFrame::Style`) — a style changes the
      top caption panel; the 1px #3A3A3A window outline and all
      behavior are shared, except *Windows XP* which also reserves a
      thick 4pt blue frame around the client area (side/bottom panels,
      so app content lays out inside it). *Windows 11 dark* — 32pt
      #202020 caption, 46×32 buttons with pixel-aligned 10×10 1px
      glyphs, #C42B1C close hover, solid hover/press fills; *Windows XP
      (Luna)* — 28pt blue gradient titlebar (bright top band over a
      deep-blue body), glossy rounded caption buttons with a red close,
      title drop shadow, app icon slot, thick #0055EA frame with a
      navy outer outline; *Ubuntu (classic Ambiance, ~2017)* — 28pt
      warm-grey gradient titlebar, centered title, round buttons at the
      right edge with the close in Ubuntu orange #E95420; *macOS* —
      light 28pt titlebar with a separator hairline, centered title,
      traffic lights at the LEFT edge in Apple order (close #FF5F57
      first, then minimize #FEBC2E, zoom #28C840). Shared: native-loop
      drag/double-click-maximize and 8-edge resize grips; titles 14pt.
      The sokol backend draws the frame by DEFAULT while a window is
      borderless (`run(decorations: false)` → `chrome:` nil; opt out
      with `chrome: false`, transparent windows opt out implicitly),
      before the app's own panels; `chrome_style:` picks the look at
      startup and `Sokol.chrome_style=` switches it live (the
      borderless demo's segmented control). `Context#top_panel` gained
      a `height:` pin for the fixed caption (and `#bottom_panel` for
      the XP frame strip). Runtime
      `Window.set_decorations` toggles the frame in step;
      `Window#set_title` keeps the caption text in sync. Specs: caption
      geometry/fill per style, min/close clicks through the ports
      (macOS close = leftmost light, Ubuntu close = orange circle),
      double-click maximize/restore, close hover fill, edge-grip resize
      hand-off.
- [x] Tabs in the window caption / Win11 Notepad title bar (user
      request): `WindowFrame.caption(height:) { |ctx, area| … }` draws
      app content INTO the client-side caption every frame — while
      installed, the title text is not painted (Win11 Notepad shows
      tabs instead), `height:` overrides the caption strip, and
      `area` is the whole bar minus the caption buttons (Windows
      style). Caption buttons never stretch: every style pins them
      to the TOP standard strip (the style's CAPTION_H) at the edge,
      so a taller caption extends the bar BELOW them. App icon slot
      (Windows style, `.icon=` — fed automatically from `run(icon:)`):
      16×16 at the caption's left edge, vertically centered in the top
      strip; while installed the title and the caption content (tabs)
      start only AFTER the icon slot, Win11 order. The texture is
      registered lazily on the context; no icon → layout unchanged. The hook runs
      inside the backend's `WindowFrame.show`, before app panels.
      `WindowFrame.caption!` removes it. On top of it,
      `src/egui/containers/title_bar_tabs.cr` — `Egui::TitleBarTabs`,
      the Win11 Notepad tab strip: rounded-top cards touching the top
      window edge (a rounded rect squared off along the bottom —
      Painter rounding is all-four-corners), the active card lighter
      (#2F2F2F on #202020), a minimum card width, the X only in the
      active tab and on hover (a dot instead while an inactive tab is
      dirty — the X replaces it on hover, Notepad's marker), a "+"
      new-tab button after
      the last tab (shown even on an empty strip), and carousel
      scrolling on overflow (active tab always in view, off-screen
      tabs neither paint nor interact). Cards ride a Middle z=40
      layer — above the drag strip (z=0, so tab clicks never move the
      window; the empty caption around the strip still drags and
      double-click-maximizes) and below the caption buttons (z=50).
      The notepad example is the reference: borderless +
      `WindowFrame.caption` + `TitleBarTabs.show(on_select/on_close/
      on_new)` wired to the same reactive selection / dirty-close
      flow as before. Specs (`spec/title_bar_tabs_spec.cr`): caption
      height override + content area excludes the buttons, title
      hidden while installed and restored after, active-card paint,
      tab click selects, X closes without selecting, dirty dot ↔ X
      swap, "+" fires on_new, tab clicks never drag while the empty
      caption does.
- [x] Page container / in-app routing (user request): `src/egui/
      containers/page.cr` — `ctx.page(id, title:, on_back:, fill:) { |ui| … }`,
      the Win11 Notepad settings-page idiom: a full-window PAGE that
      claims the whole remainder below the window caption (the
      backend's WindowFrame has already bitten its strip, so the page
      is "everything except the drag strip and control buttons") and
      covers the normal UI — menu bar, tabs, panels — for the frames
      it is shown in; unlike central_panel it is NOT deferred (a page
      is an alternative UI, not another panel). Look: an opaque
      stroke-free panel_fill surface, a 44pt header with a round 32×32
      back button (left-arrow glyph, hover fill) and an 18pt title;
      the content block runs in a child Ui below the header. Routing
      is deliberately NOT managed: the app owns the current route
      (e.g. a reactive Signal) and draws whichever page it wants —
      `on_back` is just a click callback. The notepad demonstrates it:
      the Settings menu (Ctrl+Comma — KeyCode gained `Comma = 44`,
      SAPP_KEYCODE_COMMA) opens a settings Page reactively
      (`reactive settings_open`), the caption hook hides the tabs
      while it is open, and the back button returns to the editor.
      Specs (`spec/page_spec.cr`): full-remainder claim with and
      without chrome, opaque stroke-free surface + remainder bitten,
      back button fires once per click, content below the header (and
      no header without title/on_back).
- [ ] Drag&drop payload ← `crates/egui/src/drag_and_drop.rs` (optional).
- [x] Canvas widget + XP Paint demo (user request): `src/egui/widgets/
      canvas.cr` — a retained RGBA8 pixel buffer on a NEAREST-sampled
      stream texture (ImageCmd gained a `nearest` flag, the shim a
      point sampler; `InputState` gained `secondary_down?`/
      `secondary_released?` so right-button drags work — the Paint
      bg-color idiom). Interaction reported in canvas pixel coords
      (pointer, drag start/stop per button, click/double-click), with
      a press counting as a drag start (a pencil click is a dot).
      Raster ops built in: Bresenham line, rect/ellipse (outline,
      filled, thickness), flood fill, region blit with transparency
      skip, coverage blend, invert, undo-across-resize restore.
      Demo: `examples/paint.cr` (bin/paint) — a Windows XP Paint
      clone: 16-tool toolbox with jspaint's classic icons 1:1
      (assets/paint/tools.png, MIT), per-tool option strips, 28-color
      palette (fg/bg swatch, right-click bg, double-click edit),
      status bar with live coords, zoom 1–8×, undo/redo, Image-menu
      transforms (flip/rotate/stretch/skew/invert/attributes), and
      File → New/Open/Save/Save As through the cross-platform
      SystemPorts dialogs + a pure-stdlib PNG codec
      (examples/paint/png.cr, encode + decode incl. sub-byte
      palette). Text tool rasterizes through FreeType directly into
      the canvas (examples/paint/text.cr). Specs:
      spec/canvas_spec.cr. See docs/ANALYSIS.md §14.
- [x] On-demand repaint: honor `request_repaint` in the sokol loop instead
      of redrawing every vsync — idle frames replay the last paint commands
      (`backend/sokol.cr` frame callback).
- [ ] IME (sapp text-input events) (optional). Clipboard without shell-out
      is done: native via sokol_app (`system_ports/clipboard.cr`).
- [ ] `containers/scene.rs` — evaluate whether anyone needs it; defer.

## Iteration order

0 → 1 → 2 → 3 → 4 → 4.5 → 5 → 6 → 7. Phases 1–2 give the most visible
parity per effort; P3+P4 unlock TextEdit; P5 fixes the last big layout
simplifications; P6/P7 are additive.
