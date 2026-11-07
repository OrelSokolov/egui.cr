# macOS style findings — native oracle vs egui.cr twin

**Update (round 2): the 1:1 style is implemented** —
`Egui::MacOsTheme.light` (src/egui/macos_theme.cr) applies everything
below; the twin sheets are rendered WITH it and diffed down from
3.5–14.6% to **3.2–5.3%** (the residue is AA + the widget-level gaps
listed at the bottom). Two live apps run side by side:

```sh
cd oracle/macos && ./render gallery      # native AppKit gallery window
rake build:dev[macos_gallery] && bin/macos_gallery   # egui.cr twin
```

**Round 4** (capsule/rounded-rect pass): the switch knob is now a
rounded RECT measured off the native oracle (30×20, ~7pt corners,
inside the 54×24 capsule track — `knob_width`/`knob_rounding` style
keys; the old circle knob was 20×20 in a 48×24 track), and the
progress bar rounds through the `rounding` class key with the
"capsule" keyword (semicircle ends at any width; `rounding: 9999`
works too — CSS border-radius semantics, clamped in `Painter#rect`).
Switch 3.23%, progress 2.40% (same pixel-differ metric).

**Round 3** (driven by the twinshot diff images, 8× crops): fixed
the field box to exactly 200×26 (per-widget `text_edit` padding
class), the switch to 54×24 with a track rim + knob stroke
(`track_width`/`knob_stroke` keys), the slider handle to the 18pt
white thumb (`Slider` gained `style_class` — its class rules never
reached the paint before), the checkbox mark to 2.4pt
(`check_width`), and a sheet-harness bug (one shared area id froze
every row at the first sheet's y — areas remember positions in
`ctx.memory`; ids are now per sheet). Round-3 numbers: label 3.08%,
radio 3.13%, search 3.35%, checkbox 3.60%, progress 3.63%, button
3.47%, slider 3.84%, popup 3.89%, text_field 4.08%, stepper 4.35%,
switch 4.73%, segmented 5.31% — everything sat within ~1–2% of the
pure-AA noise floor (label = text only = 3.08%).

**Round 4** (toggle/capsule parity): the sheet harness painted a 1px
`window_stroke` rim around every egui sheet (the panel's border —
native sheets are solid background to the edge; ~1.3% of every diff);
the twin now overpaints the border strips inside the panel block
(after `ctx.area` the painter stays clipped to the area rect — reset
`painter.clip` first). The second sheet column sat at x=258 instead
of the native 250 (the spacer gap must subtract TWO item_spacings —
layout adds one on each side of the spacer). The switch itself: knob
geometry 30×20 at +3 with travel 18 (was inset 2, travel 20 — the
knob kissed the track's right rim), the knob rim replaced by a 1pt
shadow ring (`track_fill` darkened 6% on a rect expanded 1pt under
the fill — native casts the knob as a shadow, and the old centered
stroke shrank the white to 28×18), the track rim drawn fully INSIDE
the capsule edge (a centered stroke band pokes half a pixel outside
the rect — a halo native has not), and the rim cross-fades with the
fill (a gray ring around the on-track's blue capsule was the
"capsule bug"). Colors measured honest: selection surfaces (checkbox
fill, radio dot, switch track, selected segment) are `#0077F9`
(0,119,249) — `SELECTION` — while push-button bezels and progress
fills keep the brighter `ACCENT` (0,122,255); the off-track is
#D5D5D5 via the new `track_fill` key. Round-4 numbers (noise floor
label = 1.44): button 1.23, radio 1.42, label 1.44, checkbox 1.65,
switch 1.68, search_field 1.69, slider 2.17, popup 2.23, segmented
2.34, text_field 2.42, progress 1.97, stepper 2.69.

**Round 4b** (text inputs): the focused field's ring and the selected
text. First attempt drew the ring as a fat INSIDE stroke on the box —
wrong twice: the backends draw a rect stroke fully inward (5pt stroke
= 5pt ring), and once the width nears the corner radius the corner
arcs collapse into the straight bars (a squarish ring clipped by the
fill). Native NSTextField paints the ring OUTSIDE the bezel — the
widget now paints a 3pt accent ring on a rect expanded 3pt past the
box, BEFORE it, so the bezel's own fill/border stay untouched
(TextEdit + NumberInput; the `text_edit:focus` state rule is gone).
Selected text fills `selectedTextBackgroundColor` #ACDBFF
(172,219,255) — a new `Visuals#text_selection_fill` slot (nil →
selection_fill), set by MacOsTheme and read by TextEdit, Textarea
(the old 0.4-faded accent gone) and selectable labels; the saturated
ACCENT stays on state surfaces.

Measured from `oracle/macos/png` (native AppKit, light aqua, active,
multicolor accent) vs `oracle/egui/png` (egui.cr, MacOsTheme, 13pt SF
Pro), diffed with twinshot (`oracle/twinshot-report/default/`).
All sizes in @1x points; colors sRGB.

Diff ratios, before theme → after round 2 → after round 3:

| sheet | r1 | r2 | r3 | | sheet | r1 | r2 | r3 |
|---|---|---|---|---|---|---|---|---|
| label | 3.5 | 3.2 | 3.1 | | slider | 6.1 | 4.8 | 3.8 |
| radio | 3.5 | 3.3 | 3.1 | | segmented | 8.8 | 5.3 | 5.3 |
| checkbox | 4.2 | 4.0 | 3.6 | | text_field | 9.0 | 5.1 | 4.1 |
| stepper | 4.5 | 4.3 | 4.3 | | search_field | 9.5 | 4.5 | 3.4 |
| switch | 5.4 | 4.7 | 4.7 | | button | 10.1 | 3.9 | 3.5 |
| popup | 8.3 | 3.9 | 3.9 | | progress | 14.6 | 5.0 | 3.6 |

## What the theme changed (src/egui/macos_theme.cr)

- 13pt font, 24pt controls: button padding 4.5/12 (24pt tall),
  `interact_size.y` 15 + `button_padding.y` 3.5 → 26pt fields.
- Accent `#007AFF` on state: `checkbox:checked` (blue box + white
  check), `radio:selected` dot, switch on-track, progress fill,
  selected segment; default button helper (blue bezel + white text).
- Fields: white fill, `#D6D6D6` border, 6pt rounding (new
  `text_edit` class: fill/stroke/rounding + `TextEdit#width` for
  fixed-width fields).
- Thin tracks: progress 9pt (height rule), slider rail 4pt + 18pt
  white thumb (new `slider.handle_size` rule) + fixed width.
- Segmented: single #DADADA capsule container (widget now draws a
  container + accent segment inset), 220×24 total.
- Mobile-media override: the default theme's touch rule (14/16
  padding, 44pt target) is re-declared with desktop metrics so
  narrow viewports keep the 24pt look.

Widget-level changes that made the theme possible (all
style-rule-driven, defaults unchanged):
`checkbox:checked` / `radio:selected` rule layers, toggle knob color,
`text_edit` class + `TextEdit#width(w)` + `text_edit_singleline(width:)`,
`slider.handle_size`, segmented container + class styling.

## Remaining gaps (the 3–5% residue)

- **Search field icon** — TextEdit has no leading-icon slot yet
  (native draws a magnifier at ~x=6).
- **Stepper** — NumberInput is a single 60×29 box; native is a bare
  label + 20×26 up/down capsule. Needs a stepper widget/variant.
- **Switch knob shape** — CLOSED in Round 4: the knob is a rounded
  rect (30×20, ~7pt corners) sized by `knob_width`/`knob_rounding`,
  riding a 1pt shadow ring (the track fill darkened 6% — native
  casts the knob as a shadow, no light rim at all).
- **Text field 29 vs 26 tall** — the SF Pro line box is ~17.7pt;
  a per-widget height override for single-line fields would close it.
- Sub-pixel AA of SF Pro vs the freetype rasterizer — irreducible
  without matching AppKit's AA/gamma.

## Per-widget measurements

| widget | native | egui | what to change |
|---|---|---|---|
| button | 65×24 / 43×24, fill #DADADA, radius ~6, text 13pt padded 12px | 79×47 / 54×47, fill #E4E4E4, radius 4 | height 24, radius 6, tighter h-padding, add `.default` variant: #007AFF bezel + white label |
| checkbox | box 16×16, checked = blue fill + white check | box 15×16, dark check on light box | check/box fill = accent when checked, white glyph |
| radio | 16×16, dot = accent blue | 15×16, dot near-black | dot color = accent |
| switch | 54×24 capsule, white thumb, track gray→blue | 31×16 rounded rect + "off/on" text, blue fill | capsule 38–54×24, no text, thumb white w/ 1px shadow |
| text field | 202×26 white, radius 6, border #D0D0D0, text starts ~6px in | 88×31 gray #E4E4E4 | white fill, radius 6, 26pt height, explicit width |
| search field | 222×26 + magnifier glyph left | 61×31, no icon | leading search icon, width, same box style as text field |
| slider | 220×18: 4pt track #B7B7B7, 20pt white thumb | 432×12 track #C6C6C6 filled blue, square-ish handle | thin track, round white thumb, region-width → fixed width |
| segmented | one 220×24 capsule #DADADA; selected seg tinted #0077F9 (soft, inset) | glued buttons, selected = solid #007ACC | single capsule container, soft tint for selection |
| popup | 200×24 #DADADA, chevron right | 84×24 #E4E4E4 | width param, radius 6, chevron spacing |
| progress | bar 200×8, fill #007AFF, track #DEDEDE rounded | 432×23 gray box | 8–10pt height, accent fill, rounded ends |
| stepper | label "42" + 20×26 up/down capsule | 56×31 single box with tiny arrows | split: plain label + compact stepper capsule |
| label | #060606 text, secondary #8E8E93-ish | #232323, secondary fine | label color #060606; SF Pro at 13pt already renders well |

## Sheet mechanics (for iterating)

- `central_panel` paints its own fill over `panel_fill` — the twin
  passes `fill: #ECECEC` explicitly so the background matches the
  native sheets exactly.
- Native renders require an ACTIVE app + KEY window or AppKit draws
  everything desaturated gray (borderless windows never become key —
  see render.swift comments).
- **Live font pitfall**: in a real (sokol) app, `ctx.fonts = …` in
  `App#initialize` is clobbered by the backend's startup (it installs
  the default system font after the app is built), and
  `Sokol.select_fonts` BEFORE `Egui.run` makes the app exit silently —
  swap the font from the FIRST `#update` frame instead (what
  examples/macos_gallery.cr does; `PROGRAM_NAME` guards the run for a
  compiled binary too).
- Regenerate: `cd oracle/macos && make` (native), `crystal run
  scripts/make_macos_oracle_shots.cr` (egui), then
  `twinshot compare --no-open` in `oracle/` (needs ruby + vips:
  `brew install ruby vips`, `gem install twinshot`).
