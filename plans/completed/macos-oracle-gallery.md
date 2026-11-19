# macOS Widget Oracle — flat gallery for screenshot diffing

Goal: pixel-level ground truth from native macOS (AppKit) widgets,
rendered headless to PNG ("oracle"), next to egui.cr renders of the
same flat sheets, diffed with `twinshot` — the diffs tell us what to
change in the egui theme for a real macOS look.

Layout:

```
oracle/
  macos/render.swift     # AppKit oracle renderer (swiftc, headless)
  macos/png/*.png        # native renders (golden)
  egui/png/*.png         # egui.cr renders of the same sheets
  diff/                  # twinshot output
scripts/make_macos_oracle_shots.cr   # renders oracle/egui/png via Capybara
```

Rules that make the diff meaningful:

- One widget (or one small group of its states) per sheet — "flat":
  no window chrome, no panels, plain background, single appearance
  (light aqua), no focus rings, no hover.
- Same canvas size for both sides: **480×160 @1×** (points == pixels).
- Same labels/text on both sides, short and ASCII ("OK", "Button",
  "Search…") so font metrics dominate only where they matter.
- States that matter for styling: on/off, filled/empty, selected.

## Widget priority (most important & common first)

| # | Sheet                | Native (AppKit)                          | egui.cr                    |
|---|----------------------|------------------------------------------|----------------------------|
| 1 | `button`             | NSButton rounded + default (blue, "OK")  | `ui.button` ×2             |
| 2 | `checkbox`           | NSButton checkbox, unchecked + checked   | `ui.checkbox` ×2           |
| 3 | `radio`              | NSButton radio, 2 items, one selected    | `ui.radio` ×2              |
| 4 | `switch`             | NSSwitch off + on                        | `Egui::ToggleButton` ×2    |
| 5 | `text_field`         | NSTextField (rounded bezel), text        | `ui.text_edit_singleline`  |
| 6 | `search_field`       | NSSearchField with text                  | text edit + hint           |
| 7 | `slider`             | NSSlider (linear, tickless), value ~0.6  | `ui.slider`                |
| 8 | `segmented`          | NSSegmentedControl 3 segments, sel. #1   | `ui.segmented`             |
| 9 | `popup`              | NSPopUpButton ("combo")                  | `ui.combo_box`             |
|10 | `progress`           | NSProgressIndicator 45% + spinner        | `ui.progress_bar`+`spinner`|
|11 | `stepper`            | NSStepper (+ number)                     | `Egui::NumberInput`        |
|12 | `label`              | NSTextField label + secondary label      | `ui.label` ×2              |

Tier 1 = 1–6 (every dialog), Tier 2 = 7–11 (most windows), Tier 3 = 12.

## What we expect the diff to measure (the deliverable)

- control heights and paddings (macOS is compact: ~22pt buttons)
- corner radii (macOS: ~6pt on buttons/fields, fully round switches)
- fills/borders per state (button: gray #E9E9E9-ish, default: accent
  blue #007AFF / systemBlue, checkbox check on accent)
- focus/selection colors, text baseline and font (SF Pro Text 13pt)
- slider thumb size/shape vs egui's, segmented control proportions

Workflow:

```sh
# native side (needs macOS + swiftc)
cd oracle/macos && make            # → png/*.png

# egui side
crystal run scripts/make_macos_oracle_shots.cr   # → ../egui/png/*.png

# diff
twinshot ...                       # → oracle/diff/
```
