# Egui::Capybara — in-app system tests + screenshots

Capybara-style system-test DSL that runs INSIDE the app, headless, at full
speed: find widgets by explicit id / label / kind, click / type / drag /
scroll, assert on text — and screenshot any state to PNG. The reproduce-a-bug
use-case: a scenario is plain Crystal code against the real `App#update`, no
window, no GL, no external driver (replaces the scripts/make_screenshots.py
xwd/Python pipeline).

## Architecture

The core insight the DSL rides on:

* `Inspector#record_meta` (via `Context#interact`) already records EVERY
  interactive widget per frame: `{id, kind, id_name, label, style_classes}`.
* `Memory#widget_rects` maps widget `Id` → on-screen `Rect`.
* Click semantics live in `Memory#begin_frame`: the press frame resolves
  `@potential_click_id` from the PREVIOUS frame's rects; the release frame
  fires `clicked?`. A synthesized click = press frame + release frame (+ one
  settle frame), exactly like `spec/slider_spec.cr` does by hand.

So a Session just drives `begin_frame → app.update → end_frame` with
synthesized `Event`s and queries the same state the real backend queries.

### Files

* `src/egui/capybara.cr` — `Session` (frame driver + finders + actions +
  expectations), `Element`, error types, `Suite` (mini runner for in-app
  suites). Core-pure: requires only egui core.
* `src/egui/capybara/raster.cr` — CPU rasterizer: a frame's `PaintCmd` list →
  RGBA buffer (SDF-antialiased rects/circles/lines/tris/arcs, gradients,
  replace blend, box-shadows approximated, text via a pluggable renderer).
* `src/egui/capybara/png.cr` — minimal PNG encoder on the stdlib zlib
  (same pattern as lib/nanosvg/examples/png.cr, namespaced under
  `Egui::Capybara::PNG`).
* `src/egui/capybara/fonts.cr` — optional (requires `freetype-cr` through
  `backend/crystalfonts`): installs real headless fonts into a Context and
  registers the atlas text renderer so screenshots have real glyphs.
* `spec/capybara_spec.cr` — DSL spec (click-by-id/label, fill, drag, suite
  runner, PNG output).
* `examples/capybara_demo.cr` — a suite embedded in a real app
  (`--selftest` runs the suite instead of the window) + screenshots.

### Session mechanics

* Own clock (`@time += dt` per step, default 1/60 s) — dt drives
  click/double-click/long-press classification exactly like a live user.
* Constructor runs 2 settle frames so widget rects are registered.
* Forces `ctx.inspector_enabled = true` + `inspector.open = false`
  (meta recording without the F12 panel).
* `step(events, dt)` is public: the low-level escape hatch.

### Selectors

* `"#save"` — explicit widget id (`Button.new("OK", id: "save")`).
* `"Click me"` — exact `label` match; falls back to `id_name`, then widget
  kind (`"Button"` / `"button"`).
* `find` raises `ElementNotFound` with a dump of every widget on screen;
  `find?`/`all` don't.

### Actions

* `click` / `double_click` / `right_click` / `hover(sel_or_element)`
* `drag(sel, to_pos_or_sel, steps)` — press, interpolated moves, release.
* `scroll(delta, at:)`, `press_key(:enter, ctrl: …)`, `type("hi\n")`
  (`\n`→Enter, `\t`→Tab, plain chars batch into one text-input frame).
* `fill(sel, text)` — click to focus, `Ctrl+A`, type (selection-aware
  replace is TextEdit's own behavior).
* `screenshot(path)` — rasterize the LAST frame at 1× → PNG. Background =
  `style.visuals.panel_fill` (what the backend clears to).

### Expectations

`has_text?` / `expect_text` / `expect_no_text` (scan the frame's TextCmds),
`expect_visible` / `expect_widget`. Failures raise `ExpectationFailed` with
the widget dump; the Suite runner auto-saves a failure screenshot.

### Suite

```crystal
suite = Egui::Capybara::Suite.new(-> { NotepadApp.new }, width: 900, height: 640)
suite.scenario "opens a file" do |t|
  t.click "#open"
  t.expect_text "opened"
  t.screenshot "tmp/notepad_open.png"
end
exit suite.run  # prints ✓/✗ per scenario, returns failure count
```

Fresh `App` instance per scenario (the factory), so scenarios are isolated.

## Non-goals (v1)

* Golden-image diffing (`screenshot_match?` — later, needs a PNG decoder).
* `Mesh3DCmd` rasterization (no-op) and textured `ImageCmd` in headless shots
  (checker placeholder — the headless registry has no pixels).
* Live-window GL readback — the existing `EGUI_SHOT` PPM path in
  backend/sokol_shim.c stays as-is.
