# SPEC.md — the NativeHTML surface contract

The contract for egui.cr's browser-shaped surface (plans/NativeHTML.md):
the cascade order, the element protocol, and the HTML vocabulary. **Any
change to this surface updates this file in the same commit** — the spec
is born from the code, not from aspiration. What is not listed here is
not part of the contract.

Status markers: ✅ shipped · 🔶 shipped with a documented deviation ·
⏳ planned (plans/NativeHTML.md stage).

## 1. Cascade contract

One layer order for EVERY style key — the order never depends on the
key (spec/cascade_order_spec.cr):

```
inline `#style`  >  per-element override (`id`)  >  class rules (states included)  >  theme
```

- **inline** — the widget's `#style` overrides (CSS `style="…"`
  semantics: inline beats `:hover`).
- **id** — per-element overrides: the inspector Element tab and
  `ctx.set_id_style` (CSS `#id` layer; base keys apply across states,
  state-scoped values refine).
- **class** — `StyleSheet` rules, class chain root→leaf, `:state`
  overlays above class bases, media-gated rules in declaration order.
- **theme** — the user-agent default; inside it a documented internal
  fallback chain resolves unset niche slots (style.cr):
  `text_selection = text_selection_fill || selection_fill`,
  `focus_ring = focus_ring_fill || text_selection`,
  `button_fill = button_active | button_hovered | button_weak`.

Mechanics pinned by the contract:

- ONE merge: `WidgetStyle#merge_over` delegates to `StyleVars#apply_over`
  — the single key → Style-slot map.
- ONE selector splitter: `StyleSheet.split_selector` (the ecss `Doc`
  delegates to it).
- Media rules are cancellable: `StyleSheet#cancel_rule(selector,
  media:)` drops an inherited declaration instead of re-declaring it.
- `ctx.theme=` is the single lifecycle owner — it re-applies the live
  `.ecss` session on swap.

## 2. Element protocol

- ONE entry: `Widget#ui(ui) : Response`. `ui.add(widget)` for every
  leaf and container.
- Containers (`ScrollArea`, `Grid`, `ComboBox`, `TreeView`, `Table`)
  are Widgets: content attaches via `.content` (ComboBox:
  `.on_select`) and they render through `ui.add`. `Response.container`
  wraps the aggregate geometry (Sense.none; TreeView carries an empty
  rect — its rows paint individually). The legacy `show(ui)` sugar
  keeps its documented return and stays uncaptured.
- Signal forms (`ui.slider(sig, …)` etc.) share one write-back
  skeleton; events are BLOCKS, never string callbacks.
- Values: `Signal(T)` is the one reactive cell; `on_change` blocks are
  sugar on top.

## 3. HTML vocabulary (`require "egui/html"`)

Opt-in module; the core untouched. Crystal naming (`ui.div`), not HTML
strings. Direct aliases:

| HTML | egui.cr | Status |
|---|---|---|
| `div` | `ui.box` column flow | ✅ |
| `span` | `horizontal` no-wrap row | ✅ |
| `a` | `Hyperlink` (opens through SystemPorts) | ✅ |
| `hr` | `Separator` | ✅ |
| `button` / `textarea` / `svg` / `canvas` / `table` | already match the engine names | ✅ |
| `img` | `Context#load_image` + `Image` | ✅ |
| `progress` / `meter` | `ProgressBar` | ✅ |
| `select` | `ComboBox` / `SelectBox` (see §5) | ✅ |
| `input[type=text]` | `ui.input` → `TextEdit` | ✅ |
| `input[type=range]` | `slider` | ✅ |
| `input[type=checkbox]` / `[type=radio]` | `checkbox` / `radio` | ✅ |
| `input[type=number]` | `number_input` / `drag_value` | ✅ |
| `input[type=color]` | `color_edit32` | ✅ |
| `input[type=date]` / `[type=time]` | `date_picker` / `time_picker` | ✅ |
| `details`/`summary` | `details(summary)` → `CollapsingHeader` | ✅ |
| `dialog` | `ui.dialog` → `ctx.modal` | ✅ |
| `iframe` | `ctx.embedded_window` | ✅ |
| `nav`/`aside` | `ctx.side_panel` | ✅ |
| `header`/`footer` | `ctx.top_panel` / `bottom_panel` | ✅ |
| `main` | `ctx.central_panel` | ✅ |

Thin sugar: `p`, `h1`..`h6` (CSS 2em…0.67em scale, bold),
`strong`/`em`/`code`/`mark`/`small`/`sub`/`sup` (RichText runs), `pre`
(mono, no wrap, hbar scroll), `blockquote` (left-accent frame),
`fieldset`/`legend`, `br`, `ul`/`ol`/`li` (markers over box+label) —
all ✅.

## 4. Attributes

Universal (every alias, through `**attrs`):

| Attribute | Semantics |
|---|---|
| `classes:` | dotted style path ("sidebar tab" → `sidebar.tab`; widgets chain onto their element class) |
| `id:` | explicit widget id |
| `style:` | inline overrides, CSS declaration syntax (`"background: #3584e4; color: #fff"`) |
| `title:` | hover tooltip |
| `disabled:` | `ui.enabled(false)` — dimmed, non-interactive |
| `hidden:` | skip rendering; explicit `id:` keeps memory alive (HTML display:none) |
| `data_testid:` | `Context#data_testids` registry (capybara selectors, inspector) |
| `width:`/`height:` | `add_sized` (as a pair; a lone axis keeps aspect on `img`) |

Per-element (wired where the engine has the semantics): `placeholder:`
→ `hint:`, `value:` → Signal forms, `min`/`max`/`step`, `checked:`,
`selected:`, `src:` (img), `href:` (a), `alt:` (img tooltip fallback),
`rows:` (textarea), `side:` (nav/aside), `start:` (ol), `open:`
(details).

NOT wired — no engine semantics behind them (adding one REQUIRES
wiring the semantics first): `required`/`pattern`/`autocomplete` (no
validation layer), `lang` (no fontchain effect), `role`/`aria-*` (no
a11y layer yet), `tabindex` (Tab navigation not ported —
docs/ANALYSIS.md), `target:` (links already open through SystemPorts).

## 5. Deliberate duplicates and deviations

Duplicates KEPT (distinct HTML elements, distinct native paint — the
vocabulary keeps them apart): `checkbox` vs `radio` (box+check vs
ring+dot), `ComboBox` vs `SelectBox` (native dropdown vs searchable
select), `table` vs `table_view` (static rows vs model/view virtual
list), `label` vs `rich` vs `scrolledlabel` (plain text vs interactive
runs vs wrap+scroll). Dropped: `big_button` (unused; `Button#min_size`
is the parameter form).

Deviations (🔶):

- `@keyframes` overlay sits UNDER the inline `#style` layer (CSS puts
  animations above normal inline declarations). fill-mode is "none":
  during the delay and after a finite run the base cascade applies
  again. In ecss the `animation` shorthand is quoted
  (`animation: "fadeIn 300ms"` — bare values with spaces don't parse);
  `animation.name:`/`animation.duration:` work bare. Wired keys:
  `animation` (shorthand), `animation.name/duration/delay/iterations/
  direction/play_state/easing` (iterations accepts `"infinite"`;
  direction normal/reverse/alternate/alternate-reverse). NOT wired:
  `animation.fill` (fill-mode none is the only behavior), per-stop
  easing functions.
- `sub`/`sup`: 0.75em size only — the engine does not shift baselines.
- `mark`: text tinted with the selection color — no background runs.
- `fieldset`: legend renders inside the frame's first row, not on the
  border itself.
- `br`: acts in horizontal (wrapping) flow; vertical flow already
  breaks per widget.
- `hidden:` without an explicit `id:` does not preserve state (no
  addressable memory cell).
- `TreeView#ui`: empty Response rect (rows paint individually).

## 6. Browser-piece inventory

| Piece | Status |
|---|---|
| CSS cascade (classes, states, media, transitions, units) | ✅ contract §1 |
| border-radius, box-shadow, gradients, per-side borders | ✅ |
| forms | ✅ vocabulary §3–4 |
| canvas (pixel) | ✅; Canvas2D Route A ⏳ plan §4.3 |
| audio | ✅ (system port + minaudio) |
| video | example-level (examples/video) — engine promotion ⏳ |
| svg, lottie, icons | ✅ |
| first frame (exml codegen) | ⏳ plan §6 |
| `@keyframes` | ✅ `animation:*` rule keys + `StyleSheet#keyframes` / ecss `@keyframes` blocks (deviations §5) |
