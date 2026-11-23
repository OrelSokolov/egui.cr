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
all ✅. Text elements honor `background` (inline `style:` or a class
rule) as a flat fill painted behind the text — CSS semantics, the
swatch idiom `ui.p(" ", style: "background: …", width:, height:)`.

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

### Canvas2D (Route A — `Egui::Canvas2D`, src/egui/canvas2d.cr)

The browser `<canvas>` 2D surface: recorded op list, CPU bake through
the NanoSVG port, one stream texture. CTM applies when a path segment
is added (canvas path semantics); gradients are positioned in the user
space of the fill/stroke call. Works headless (the dummy registry keeps
upload pixels).

Surface: moveTo/lineTo/quadraticCurveTo/bezierCurveTo/arc/ellipse/
rect/closePath, fill/stroke (+fillRule evenodd), fillRect/strokeRect/
clearRect, save/restore, translate/rotate/scale/transform/setTransform,
linear/radial gradients (addColorStop), globalAlpha, fillText +
measureText (textAlign left/center/right, textBaseline top/middle/
alphabetic/bottom), clip (rect).

Deviations (explicit, Route B items stay out of the contract):
- fillText: the CTM translates the anchor only — no rotated/sheared
  text; a gradient fill style does not paint text (solid colors only).
- clip: the current path's bounding box (exact for rect paths — the
  supported clip shape).
- createRadialGradient: r0 > 0 collapses to a focal point at the inner
  circle's center.
- textAlign start/end map to left/right.

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
- `sub`/`sup`: 0.75em size, baseline shifted — sub drops 0.25em
  below the parent line's baseline, sup rises 0.35em above it.
- `mark`: text tinted with the selection color — no background runs.
- `background-gradient` (engine property, no CSS name): a full
  CSS-like gradient as its OWN ecss key instead of a
  `background-image` layer — `linear-gradient(135deg, #a, #b 60%)`,
  `radial-gradient(circle at 30% 20%, #a, #b)` with extent keywords.
  Multi-stop, any angle, `to`-directions, `at %` centers; hex colors
  only. Set on a class rule (state-scoped like `background`) or the
  exml `<box fill="linear-gradient(…)">`; wins over
  `background`/`background2` when present. Rendering: CPU raster is
  per-pixel exact; sokol paints linear gradients as exact stop-banded
  Gouraud and radial as concentric rings. Not transition-animated
  (a state switch snaps).
- `fieldset`: the legend rides the top border like the browser's —
  two stroke segments around the caption text (no fill gap behind
  the text; the frame's top side is simply not drawn under it).
  The frame is a flat 1px stroke; the browser's `groove` 3D style is
  not emulated.
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
| canvas (pixel) | ✅; Canvas2D Route A ✅ (contract §5) |
| audio | ✅ (system port + minaudio) |
| video | example-level (examples/video) — engine promotion ⏳ |
| svg, lottie, icons | ✅ |
| first frame (exml codegen) | ✅ Route A: `egui-gen` (scripts/egui_gen.cr) emits the literal Node tree; `Document.hybrid` picks live file (dev) → literals (release) |
| `@keyframes` | ✅ `animation:*` rule keys + `StyleSheet#keyframes` / ecss `@keyframes` blocks (deviations §5) |
| `position` | ✅ `relative`/`absolute`/`fixed` + `top/right/bottom/left` (px, `%` of the containing block, vw/vh/rem) on `Ui#box` / `ui.div`, from arguments, inline `style:` or ECSS class rules (see `Ui#box_positioning`); `sticky` ⏳ |
| Vue template syntax (exml `v-*` aliases) | ✅ contract §7 — parse-time desugar, one canonical tree |
| window chrome (frame + caption buttons) | ✅ exml `<window-frame>` (stock) / `<window-frame-custom>` (`<window-button type=…>` + caption content) → `Egui::WindowFrame`; drag/resize/maximize behavior stays in the binary |

## 7. Vue directive subset (exml aliases)

exml accepts the Vue **writing** of directives as parse-time aliases:
after desugar the tree is canonical, so the renderer, the linter
(`Exml.validate`), codegen (`egui-gen`) and hot reload never see an
alias. The formula: **Vue's form, our values** — a directive's value
is a bare slot/action/field name, never a JS expression
(`v-if="count > 0"` is a warned parse issue in `Exml.warnings`, not a
silent misrender). Canonical spellings stay valid forever; the aliases
are additive (plans/vue-aliases.md).

| Vue | canonical | Rule |
|---|---|---|
| `v-if="flag"` | `if="flag"` | bare slot (optionally `{slot}`) |
| `v-show="flag"` | `if="flag"` | rendering skipped, widget memory lives on by Id-path — Vue's display:none semantics, state kept |
| `v-model="name"` | `bind="name"` | modifiers below |
| `v-model.number="x"` | `bind="x" numeric="true"` | the input writes the FLOAT slot (`rt.floats`); unparseable text just doesn't write |
| `v-model.trim="x"` | `bind="x" trim="true"` | the write-back is stripped; `.number.trim` combines; `.lazy` warns + drops (on_change already fires on commit) |
| `v-text="name"` | `text="{name}"` | |
| `ref="name"` | `id="name"` | Vue's template-ref IS the ref registry (`renderer.ref(name)`); a real `id=` wins (warned) |
| `@click="save"` / `v-on:click="save"` | `on_click="save"` | bare action name; any event maps `on_<event>` |
| `@change="save"` / `v-on:change` | `on_change="save"` | |
| `@keyup.enter="save"` | `hotkey="enter" on_keyup="save"` | key events' dotted suffix is a KEY (`Hotkey` spelling: `enter`, `esc`, `ctrl+enter` via `@keyup.ctrl.enter`) — the key fires the action WINDOW-globally through the regular HotkeyMap, no focus needed; the binding lives while the node is visible and lapses with it |
| `v-bind:title="x"` / `:title="x"` | `title="{x}"` | value is a slot name; a literal (`:x="5"`) warns and applies as `x="5"` |
| `v-bind="settings"` (bare, no `:`-arg) | `props="settings"` | the DICT slot's fields (`rt.dicts["settings"]`, app-owned Hash, mutable in place) spread as component use-site props — values verbatim (app-formatted, like every other slot); explicit use-site attrs win over the spread (Vue 3 precedence); re-seeded live every frame; a component scope reads the parent store's dicts; a non-bare value warns |
| `v-for="item in items"` | synthesized `<repeat for="item" in="items">` | the wrapper takes the element's path; `:key`/`key` and `index` ride the wrapper |
| `v-for="(item, i) in items"` | …+ `index="i"` | `{i}` interpolates next to `{_i}` |
| `:key="item.id"` (inside v-for) | `key="id"` | `<var>.` prefix dropped; a bare value is a warned issue |
| `v-else` | `unless=`/`if=` mirrored from the previous sibling | the sibling's inverted condition |
| `<template v-if="flag">A B</template>` | A and B spliced in place, `if=` copied onto each | parse-time group wrapper, no node of its own; a child's own gate of the same kind wins (warned — the AND of two slots is an expression) |
| `<template v-for="d in list">A B</template>` | `<repeat>` wrapping BOTH children | the GROUP repeats; `:key`/`index` ride the wrapper, children keep their parse paths |

`v-if` on the same element as `v-for` applies **per row** (the child
keeps `if=` — Vue 2 semantics). Rewriting an EXISTING canonical
document into v-for syntax shifts paths one level (widget state
resets); a document born in v-for syntax is stable. `<template>`
splices keep every child's parsed path (namespaced under the
template), so siblings never shift and no id ever collides.

Markup hotkeys (`@keyup.<key>`) conflict with app `ctx.hotkeys`
bindings by ORDER: the markup binding lands during the render walk
(later than app setup), so markup wins while the node is visible and
the key is freed the frame the node hides; the app re-binds on its
own next frame. Firing is routed through the store action
(`rt.fire(name)`), namespaced `exml:<name>` on the HotkeyMap — an
app's own `HotkeyAction`s never collide.

NOT in the subset (warned parse issues, the absence is explicit):
`v-html` (no raw HTML), `v-else-if` (needs slot inversion; ONE
`v-else-if` after `v-if` could ride `if= unless=` — kept out until a
live port wants it), `v-once`/`v-memo`/`v-pre` (interpolation caching
already exists), `<script setup>` (logic is compiled Crystal — a
feature, not a gap), non-key event modifiers (`@click.stop` and
friends — a key NAME after `keyup`/`keydown` is the one accepted
modifier form), `v-model.lazy`. `v-slot`/`<slot>` IS in the subset
now — component templates only (§9 named slots). JS expression values
(space/operator/call syntax) are rejected everywhere — publish a store
slot and name it.

## 8. Flexbox (`ui.flex` / `display: flex`)

Full CSS flexbox (`src/egui/containers/flex.cr`), exact from the
FIRST frame — no one-frame settle: the container runs a measure pass
(`Context#measure` — paint discarded, `Context#interact` returning
dead verdicts), distributes, then lays the children out at computed
slots.

Two-pass contract: a child block runs TWICE per frame (measure +
real). Response-gated callbacks (`if resp.clicked? …`) fire exactly
once (the measure pass sees dead verdicts); widget state writes are
idempotent (same id, same inputs). Side effects NOT gated on a
Response must guard with `ui.measuring?`. In the html layer
(`div(style: "display:flex")`), where children are plain `ui.*`
calls intercepted via `Ui#flex_capture`, a flex child's Response is a
placeholder until the container block closes — consult it after the
div, not between (the placeholder absorbs the real verdicts, see
`Response#absorb`); the same applies to a nested container's return
rect.

Nesting cost (the exponential guard): a flex rendering inside an
ancestor's measure pass runs in MEASURE MODE — one pass over its
children (their real pass would be discarded paint anyway), reporting
its natural content extent upward; the real pass reuses a per-frame
measure memo (`Context#flex_measure`) when the available width
matches. Cost is linear in nesting depth, not 2^depth — a
depth-d leaf block runs ≈ d+1 times, not 2^d.

Supported (CSS spelling → `ui.flex` symbol):

| Property | Values |
| --- | --- |
| `flex-direction` | `row` `row-reverse` `column` `column-reverse` |
| `flex-wrap` | `nowrap` `wrap` `wrap-reverse` |
| `justify-content` | `flex-start` `center` `flex-end` `space-between` `space-around` `space-evenly` |
| `align-items` | `stretch` `flex-start` `center` `flex-end` `baseline` |
| `align-content` | the `align-items` set minus `baseline`, plus the `space-*` modes |
| `flex-grow` / `flex-shrink` | numbers (per child: `f.child(grow: …)` / EXML `<flex-item>`) |
| `flex-basis` | px, `%` (definite main axis only), `auto` |
| `order` | integer, stable |
| `gap` | one number (both axes) |

Entry points: `Ui#flex` (Crystal; every container mode also cascades
from the ECSS class chain — `flex-direction`, `flex-wrap`,
`justify-content`, `align-items`, `align-content`, `gap`), `<box
flex="true" …>` + `<flex-item grow="1" …>` (EXML), and
`div(style: "display:flex; …")` (NativeHTML — container modes; the
per-child factors are the Crystal/EXML API's). An explicit argument
beats the cascade. `box(width:/height:)` (px or `%` of the flow
region) makes a column container's main axis definite — in flow only
the width is, so grow/justify on an auto-height column are inert
(CSS `height: auto` semantics: the container grows with content).

Deviations (🔶):

- `align-items: baseline` is approximated as bottom-alignment (the
  label center-line already covers the common text-row case).
- Shrinking floors at 0, not min-content (no min-content pass).
- An `auto`-basis child never grows past its natural size (CSS caps
  content-based items at max-content — here natural IS max-content;
  `basis: 0` + grow gives the `flex: 1` behavior).
- In the html layer, `Grid`/`ScrollArea`-style `show` containers
  inside a flex div are not intercepted as items (widgets, `box` and
  `horizontal` are).

## 9. exml store contract (velour-components)

The reactive contract between markup, custom tags and the store. The
store is one `Exml::Runtime` (component scopes are `ScopedRuntime`
children — writes land locally, reads fall through to the parent).

### 9.1 Store lint (`Exml.validate`)

`validate(doc, known_custom, written:)` — `written` is the app's
declaration of the slot names it seeds/writes (nil = the store lint is
skipped; the vocabulary checks still run):

- **unknown `{name}`** (not a slot, not a repeat variable/field of an
  enclosing `<repeat>`, not a component prop) — **error**: not in
  scope and nobody writes it.
- **read nobody writes** — **warning**: a `bind=` key, a declared
  custom-tag slot attr (see `slot_attr` below), an `if=`/`unless=`
  name, an `:options=` list or a repeat `in=` rows slot with no
  writer — the binding reads an empty default. This is the
  «мёртвый тогл» shape: the write lands in a slot nobody declared
  and the silence looks like working logic.
- `Exml.slot_attr "ios-row", "switch"` — declares which attributes of
  a custom tag are slot names the handler reads/writes; they lint like
  `bind=`.
- Component classes register under their element name (`macro
  inherited`); a use site missing a REQUIRED prop (declared without a
  default) is an **error**: `<tag> requires prop "x"`.
- `Exml.validate_component(Comp)` — lints a component's own template
  against its declared props/states (+ `written:`).
- **Quote hygiene at parse**: an unbalanced quote cuts an attribute
  value short; the fragment with the quotes used to drop as junk
  SILENTLY. It is a parse-time error now — stderr + `Exml.warnings`
  (the parse stays lenient; a half-saved hot-reloaded file never
  crashes the frame loop).
- The last run's issues live in `Exml.last_issues` (the inspector's
  Store tab shows the lines mentioning a slot).

### 9.2 Component declarations (`prop` / `state` / `bindable`)

```crystal
class Counter < Egui::Exml::Component
  prop title, default: "Без имени"  # optional; seeded when the site omits it
  prop badge                        # REQUIRED — lint errors when missing
  state open, default: "0"          # a slot of the SITE scope, seeded at install
  bindable :value, :bool            # two-way prop, see 9.3
```

- **props are live**: re-seeded from the use site every frame (values
  interpolate against the enclosing store); a DECLARED default is
  seeded only while the scope lacks the key — the component's local
  write to its own slot wins.
- **state** is per-use-site by construction (the scope already
  namespaces it) — no manual key prefixes; `bind=`/`bind_*=` attrs are
  structural and never become props.

### 9.3 The `bind=` contract (modelValue/update:modelValue)

Use site: `<tag bind="parent_slot" on_change="act"/>`.

- **Component classes**: `bindable :value, :bool` — the parent slot
  seeds the scope's `value` prop (strings/floats/bools by the DECLARED
  flavor — the slot may not exist on the first frame, so there is
  nothing to detect from). A write from the component's own actions
  flows back to the parent slot at the end of the frame and fires
  `on_change=`. An external parent write re-seeds the scope (props
  down — the parent wins the frame); the scope's own pushed-back value
  persists otherwise. The first declared bindable maps to `bind=`,
  further ones ride `bind_<name>=`.
- **Handler tags** (`Renderer#on`): the handler runs against a
  `BoundRuntime` — the parent slot seeded as `"value"`
  (`rt.bool("value")`…), every write echoed into the parent store
  under the bound key (so the `strings["page"] = …` nav idiom keeps
  landing globally), and `on_change=` fires when the parent slot's
  VERSION moved during the handler. Fresh per frame; component-
  registered tags skip the wrap (their contract is Component-owned).

### 9.4 Auto-repaint on store writes

`Runtime#total_writes` counts CHANGED writes (strings/floats/bools —
a same-value write never bumps a version). `Renderer#render_routes`
captures the counter at frame start and calls `ctx.request_repaint`
when it moved — a write during the walk (handlers, bind write-back)
schedules the next frame ITSELF; the app never remembers the repaint
loop. Re-publishing identical rows/lists/values every frame does not
loop.

### 9.5 Computed slots

```crystal
rt.computed "wifi_label" do |s|
  s["wifi_on"] == "true" ? s["wifi_name"] : "Not connected"
end
```

Dependencies are NOT declared — the read-set of the first evaluation
(the `s[...]` tracker) is the dep list; a write to any dependency
re-computes lazily on the next read. String slots; resolvable through
`{name}` interpolation and `rt.lookup`. Self-reading resolves to the
stale value (no loop). There is still NO expression grammar in markup
— the ternary lives in Crystal. Computed names belong in the lint's
`written:` set (`rt.computed_names` lists them).

### 9.6 Named slots + scoped template classes

- `<slot name="x"/>` in a component template takes the use-site
  children carrying `slot="x"`; children without the attr fill the
  bare `<slot/>` (default). PARSE-TIME splicing with markers — after
  the splice the tree is plain nodes; spliced children re-path under
  the USE site (independent ids/scopes); a use-site slot name with no
  marker is dropped with a warn-once; an unmatched marker renders
  nothing (Vue semantics).
- Template classes are NAMESPACED with the element name (`card` →
  `counter__card`) — Vue-scoped semantics: a component's classes
  cannot collide with, or be matched by, the app's same-named global
  rules. `{…}` store-driven tokens are app-side names and stay
  unprefixed. Opt out with `scoped="false"` on the template root.

### 9.7 Page transitions (`Egui::Exml::Nav`)

`Nav.new(rt, slot: "page")` + `nav.update(ctx)` each frame: a slot
change seeds the spring (push: any value ≠ root; pop: back to root —
both configurable), `offsets(width)` gives the pixel slides of the
entering/leaving bodies, `transitioning?`/`settled?` tell the handler
which pages to draw. Response/damping are the spring's (the ECSS
`transition: spring(...)` vocabulary). The DEFAULT is no animation —
the transition exists only where an app constructs a Nav (spec:
spec/exml_nav_spec.cr).

### 9.8 Inspector Store tab

`ctx.inspector.store = rt` adds a Store tab: every slot with LIVE
editing (a write bumps the version — 9.4 redraws the next frame; the
«мёртвый тогл» debugger), computed slots read-only, and the first
`Exml.last_issues` line mentioning each slot (who reads/writes it,
per the 9.1 lint).
