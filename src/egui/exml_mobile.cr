# EXML mobile vocabulary — the mobile_widgets.md catalog as markup tags.
#
# `require "egui/exml_mobile"` registers GLOBAL custom-element handlers
# (the `widget` sugar — same extension path as `exml_formula`): unknown
# tag names already parse as `Kind::Custom`, custom dispatch runs before
# the builtins, so zero core parser edits. Mirrors the raw-Crystal Ui
# helpers one-to-one (see the per-widget files for the style classes):
#
#   <screen nav_height="80">          scaffold: fixed bars + scrolling body
#     <app-bar title="…" back="true" on_back="go_back">
#       <appbar-action icon="copy" on_click="open_sheet"/>
#     </app-bar>
#     <screen-body> …any flow content… </screen-body>
#     <bottom-nav bind="tab">
#       <nav-item icon="check" label="Controls"/>
#     </bottom-nav>
#     <fab icon="plus" margin_bottom="104" on_click="new_item"/>
#     <snackbar text="{toast}" action_text="{toast_action}"
#               visible="{toast?}" lift="88" on_action="toast_clear"/>
#   </screen>
#
#   <card id="…"> … </card>
#   <list-tile title="…" subtitle="…" leading_icon="wifi" on_click="tap">
#     <switch bind="wifi"/>        — children render into the trailing slot
#   </list-tile>
#
# Conventions (same as the builtins):
# * every `on_*` attr names an action registered in `rt.actions`;
# * `bind="key"` is the two-way float/bool/string slot (the slider/
#   checkbox contract — the widget writes the new value back);
# * booleans read "true"/"false" or a `{slot}` interpolation;
# * `id="name"` gives the widget its identity (stable Memory state per
#   markup site — `node.path`), NOT a `renderer#ref` (refs are a
#   builtin-dispatch feature; custom tags read state through slots).
#
# NOT in v1 (ctx-level presenters, they stay app-code — see Dialog /
# BottomSheet): <dialog>, <bottom-sheet>.

module Egui
  module ExmlMobile
    # ── attr readers (every value may be a `{slot}` template) ────────

    def self.attr_s(node : Exml::Node, rt : Exml::Runtime, key : String,
                    default : String? = nil) : String?
      raw = node.attrs[key]?
      raw ? rt.interpolate(raw) : default
    end

    def self.attr_f(node : Exml::Node, rt : Exml::Runtime, key : String,
                    default : Float64) : Float64
      attr_s(node, rt, key).try(&.to_f?) || default
    end

    def self.attr_b(node : Exml::Node, rt : Exml::Runtime, key : String,
                    default : Bool) : Bool
      case attr_s(node, rt, key)
      when "true", "1", "yes"  then true
      when "false", "0", "no"  then false
      else                          default
      end
    end

    def self.attr_i(node : Exml::Node, rt : Exml::Runtime, key : String,
                    default : Int32) : Int32
      attr_s(node, rt, key).try(&.to_i?) || default
    end

    # Warn-once for structural misuse (a child tag outside its parent).
    @@warned = Set(String).new

    def self.warn_once(key : String, message : String) : Nil
      unless @@warned.includes?(key)
        @@warned << key
        STDERR.puts "exml_mobile: #{message}"
      end
    end

    # Icon names are the closed `Icons::NAMES` set (no dynamic
    # String→Symbol in Crystal) — a name → symbol lookup with a
    # warn-once on a miss (the icon falls back like the Ui helpers).
    ICON_BY_NAME = {} of String => Symbol
    {% for icon in Egui::Icons::NAMES %}
      ICON_BY_NAME[{{ icon.id.stringify }}] = :{{ icon.id }}
    {% end %}

    def self.attr_icon(node : Exml::Node, rt : Exml::Runtime,
                       key : String, fallback : Symbol = :close) : Symbol
      name = attr_s(node, rt, key)
      return fallback unless name
      ICON_BY_NAME[name]? || begin
        warn_once("icon:#{name}",
          "unknown icon \"#{name}\" — Icons::NAMES has " \
          "#{ICON_BY_NAME.keys.join(", ")}")
        fallback
      end
    end

    def self.attr_icon?(node : Exml::Node, rt : Exml::Runtime,
                        key : String) : Symbol?
      attr_s(node, rt, key) ? attr_icon(node, rt, key) : nil
    end

    # The anchor symbol of the nine Overlay positions (unknown → the
    # bottom_right default — a FAB's home).
    def self.anchor_sym(node : Exml::Node, rt : Exml::Runtime) : Symbol
      case attr_s(node, rt, "corner")
      when "top_left"    then :top_left
      when "top_center"  then :top_center
      when "top_right"   then :top_right
      when "center"      then :center
      when "left_center" then :left_center
      when "right_center" then :right_center
      when "bottom_left" then :bottom_left
      when "bottom_center" then :bottom_center
      else                    :bottom_right
      end
    end
  end
end

# ── scaffold ─────────────────────────────────────────────────────────

# `<screen>` — the mobile screen scaffold (app bar / body / pinned
# bars). Children are grouped BY TAG, not by declaration order:
# every <app-bar> renders at the flow top, the first <screen-body>
# becomes the scrolling middle (its viewport is exactly the remainder
# minus the nav slot — the arithmetic the markup author must never do
# by hand), and the rest (bottom-nav / fab / snackbar) render after —
# they pin themselves to the region edges / overlay.
widget :screen do |node, ui, ctx, rt, r|
  nav_h = Egui::ExmlMobile.attr_f(node, rt, "nav_height", 80.0)

  body : Egui::Exml::Node? = nil
  rest = [] of Egui::Exml::Node
  node.children.each do |c|
    if c.name == "screen-body"
      body = c unless body
    elsif c.name != "app-bar"
      rest << c
    else
      r.render(c, ui, ctx, rt) # the fixed top bar(s)
    end
  end

  # The scrolling middle: exactly the remainder minus the nav slot —
  # then the floaters render AFTER (command order = paint order: the
  # pinned nav/FAB/toast must sit above the body content).
  if b = body
    body_h = {ui.available_height - nav_h, 1.0}.max
    ui.scroll_area(max_height: body_h) { |inner|
      r.render_each(b, inner, ctx, rt) }
  end
  rest.each { |c| r.render(c, ui, ctx, rt) }
end

# `<screen-body>` outside a `<screen>`: plain full-height scroll (the
# fragment linter has no nesting table for custom tags — the tag stays
# usable standalone).
widget "screen-body" do |node, ui, ctx, rt, r|
  ui.scroll_area { r.render_each(node, ui, ctx, rt) }
end

# ── bars and floaters ────────────────────────────────────────────────

# `<app-bar title="…" back="true" on_back="…">` with
# `<appbar-action icon on_click>` children (max 3 — the AppBar rule).
widget "app-bar" do |node, ui, ctx, rt, r|
  title = Egui::ExmlMobile.attr_s(node, rt, "title") || ""
  back = Egui::ExmlMobile.attr_b(node, rt, "back", false)
  on_back = Egui::ExmlMobile.attr_s(node, rt, "on_back")
  id = Egui::ExmlMobile.attr_s(node, rt, "id") || node.path
  ui.app_bar(title, back: back, id: id, on_back: (on_back ? ->{
    rt.fire(on_back.not_nil!)
  } : nil)) do |bar|
    node.children.each do |c|
      next unless c.name == "appbar-action"
      icon = Egui::ExmlMobile.attr_icon(c, rt, "icon")
      act = Egui::ExmlMobile.attr_s(c, rt, "on_click")
      bar.action(icon) { rt.fire(act.not_nil!) if act }
    end
  end
end

# `<appbar-action>` outside an `<app-bar>` — inert (actions are read by
# the bar, not rendered standalone); the mismatch says so, warn-once.
widget "appbar-action" do |node, ui, ctx, rt, r|
  Egui::ExmlMobile.warn_once("appbar-action",
    "<appbar-action> outside <app-bar> — ignored")
  ui.label("")
end

# `<bottom-nav bind="tab">` with `<nav-item icon label/>` children
# (3–5 — the BottomNav rule). `selected="{i}"` reads the index; `bind`
# (or `on_change`) writes the tapped one back.
widget "bottom-nav" do |node, ui, ctx, rt, r|
  items = node.children.select { |c| c.name == "nav-item" }.map do |c|
    Egui::BottomNav::Item.new(
      Egui::ExmlMobile.attr_icon(c, rt, "icon", fallback: :check),
      Egui::ExmlMobile.attr_s(c, rt, "label") || "")
  end
  selected = Egui::ExmlMobile.attr_i(node, rt, "selected", 0)
  key = Egui::ExmlMobile.attr_s(node, rt, "bind")
  on_act = Egui::ExmlMobile.attr_s(node, rt, "on_change")
  id = Egui::ExmlMobile.attr_s(node, rt, "id") || node.path
  ui.bottom_nav(items, selected, id: id) do |i|
    rt.floats[key] = i.to_f64 if key
    rt.fire(on_act.not_nil!) if on_act
  end
end

# `<nav-item>` outside a `<bottom-nav>` — inert for the same reason as
# appbar-action.
widget "nav-item" do |node, ui, ctx, rt, r|
  ui.label("")
end

# `<fab icon corner margin_bottom margin_right on_click/>` — the
# floating action button, self-pinned via an Overlay anchor (the
# pass_through/spot pattern of the raw gallery example).
widget :fab do |node, ui, ctx, rt, r|
  icon = Egui::ExmlMobile.attr_icon(node, rt, "icon", fallback: :plus)
  label = Egui::ExmlMobile.attr_s(node, rt, "label")
  margin = Egui::StyleBox.new(
    bottom: Egui::ExmlMobile.attr_f(node, rt, "margin_bottom", 16.0),
    right: Egui::ExmlMobile.attr_f(node, rt, "margin_right", 16.0))
  on_act = Egui::ExmlMobile.attr_s(node, rt, "on_click")
  id = Egui::ExmlMobile.attr_s(node, rt, "id") || node.path
  ui.overlay(Egui::ExmlMobile.anchor_sym(node, rt), margin: margin,
    id: "#{id}_spot", pass_through: true) do |o|
    o.fab(icon, label: label, id: id) { rt.fire(on_act.not_nil!) if on_act }
  end
end

# `<snackbar text action_text visible lift on_action/>` — the pinned
# toast; `visible="{b}"` gates it (false renders nothing, the helper's
# contract). Auto-hide is app-side — the markup clears the slots in its
# own action/timer, same as the raw example.
widget :snackbar do |node, ui, ctx, rt, r|
  text = Egui::ExmlMobile.attr_s(node, rt, "text") || ""
  visible = Egui::ExmlMobile.attr_b(node, rt, "visible", true)
  action_text = Egui::ExmlMobile.attr_s(node, rt, "action_text")
  lift = Egui::ExmlMobile.attr_f(node, rt, "lift", 0.0)
  on_act = Egui::ExmlMobile.attr_s(node, rt, "on_action")
  id = Egui::ExmlMobile.attr_s(node, rt, "id") || node.path
  ui.snackbar(id, text, visible, action_text: action_text, lift: lift) do
    rt.fire(on_act.not_nil!) if on_act
  end
end

# ── containers ───────────────────────────────────────────────────────

# `<card>` — the block container; children flow into its padded body.
widget :card do |node, ui, ctx, rt, r|
  id = Egui::ExmlMobile.attr_s(node, rt, "id") || node.path
  ui.card(id: id) { |c| r.render_each(node, c, ctx, rt) }
end

# `<list-tile title subtitle leading_icon on_click>` — children render
# into the right-aligned trailing slot (a switch, a badge…).
widget "list-tile" do |node, ui, ctx, rt, r|
  title = Egui::ExmlMobile.attr_s(node, rt, "title") || ""
  subtitle = Egui::ExmlMobile.attr_s(node, rt, "subtitle")
  leading = Egui::ExmlMobile.attr_icon?(node, rt, "leading_icon")
  on_act = Egui::ExmlMobile.attr_s(node, rt, "on_click")
  id = Egui::ExmlMobile.attr_s(node, rt, "id") || node.path
  resp = ui.list_tile(title, subtitle: subtitle, leading_icon: leading,
    id: id) { |row| r.render_each(node, row, ctx, rt) }
  rt.fire(on_act.not_nil!) if on_act && resp.clicked?
end

# ── input ────────────────────────────────────────────────────────────

# `<switch bind="b"/>` — the two-way bool slot (the checkbox contract).
widget "switch" do |node, ui, ctx, rt, r|
  key = Egui::ExmlMobile.attr_s(node, rt, "bind")
  checked = key ? rt.bool(key) :
             Egui::ExmlMobile.attr_b(node, rt, "checked", false)
  on_act = Egui::ExmlMobile.attr_s(node, rt, "on_change")
  id = Egui::ExmlMobile.attr_s(node, rt, "id") || node.path
  ui.switch(checked, id: id) do |v|
    rt.bools[key] = v if key
    rt.fire(on_act.not_nil!) if on_act
  end
end

# `<stepper bind="v" min max step/>` — the numeric stepper writing the
# new value into the float slot (the slider contract).
widget "stepper" do |node, ui, ctx, rt, r|
  key = Egui::ExmlMobile.attr_s(node, rt, "bind")
  value = key ? rt.float(key) : Egui::ExmlMobile.attr_f(node, rt, "value", 0.0)
  min = Egui::ExmlMobile.attr_f(node, rt, "min", 0.0)
  max = Egui::ExmlMobile.attr_f(node, rt, "max", 100.0)
  step = Egui::ExmlMobile.attr_f(node, rt, "step", 1.0)
  on_act = Egui::ExmlMobile.attr_s(node, rt, "on_change")
  id = Egui::ExmlMobile.attr_s(node, rt, "id") || node.path
  ui.stepper(value, range: (min..max), step: step, id: id) do |v|
    rt.floats[key] = v if key
    rt.fire(on_act.not_nil!) if on_act
  end
end

# `<rating-bar bind="v" count step/>` — the star bar writing the new
# rating into the float slot.
widget "rating-bar" do |node, ui, ctx, rt, r|
  key = Egui::ExmlMobile.attr_s(node, rt, "bind")
  value = key ? rt.float(key) : Egui::ExmlMobile.attr_f(node, rt, "value", 0.0)
  count = Egui::ExmlMobile.attr_i(node, rt, "count", 5)
  step = Egui::ExmlMobile.attr_f(node, rt, "step", 1.0)
  on_act = Egui::ExmlMobile.attr_s(node, rt, "on_change")
  id = Egui::ExmlMobile.attr_s(node, rt, "id") || node.path
  ui.rating_bar(value, count: count, step: step, id: id) do |v|
    rt.floats[key] = v if key
    rt.fire(on_act.not_nil!) if on_act
  end
end

# `<range-slider bind_lo bind_hi min max/>` — the two-thumb slider;
# the moved thumb's value lands in its slot (both fire on_change).
widget "range-slider" do |node, ui, ctx, rt, r|
  lo_key = Egui::ExmlMobile.attr_s(node, rt, "bind_lo")
  hi_key = Egui::ExmlMobile.attr_s(node, rt, "bind_hi")
  lo = lo_key ? rt.float(lo_key) : Egui::ExmlMobile.attr_f(node, rt, "lo", 0.0)
  hi = hi_key ? rt.float(hi_key) : Egui::ExmlMobile.attr_f(node, rt, "hi", 100.0)
  min = Egui::ExmlMobile.attr_f(node, rt, "min", 0.0)
  max = Egui::ExmlMobile.attr_f(node, rt, "max", 100.0)
  on_act = Egui::ExmlMobile.attr_s(node, rt, "on_change")
  id = Egui::ExmlMobile.attr_s(node, rt, "id") || node.path
  ui.range_slider(lo, hi, (min..max), id: id) do |nl, nh|
    rt.floats[lo_key] = nl if lo_key
    rt.floats[hi_key] = nh if hi_key
    rt.fire(on_act.not_nil!) if on_act
  end
end

# `<search-bar bind="q" hint/>` — the rounded search field; typing
# writes the buffer into the string slot (the input contract).
widget "search-bar" do |node, ui, ctx, rt, r|
  key = Egui::ExmlMobile.attr_s(node, rt, "bind")
  text = key ? rt.string(key) :
           Egui::ExmlMobile.attr_s(node, rt, "text") || ""
  hint = Egui::ExmlMobile.attr_s(node, rt, "hint") || "Search"
  on_act = Egui::ExmlMobile.attr_s(node, rt, "on_change")
  id = Egui::ExmlMobile.attr_s(node, rt, "id") || node.path
  ui.search_bar(text, hint, id: id) do |s|
    rt.strings[key] = s if key
    rt.fire(on_act.not_nil!) if on_act
  end
end

# `<pin-input bind="code" count on_filled/>` — the digit cells; typing
# writes the buffer into the string slot, completion fires on_filled.
widget "pin-input" do |node, ui, ctx, rt, r|
  key = Egui::ExmlMobile.attr_s(node, rt, "bind")
  text = key ? rt.string(key) :
           Egui::ExmlMobile.attr_s(node, rt, "text") || ""
  count = Egui::ExmlMobile.attr_i(node, rt, "count", 4)
  on_filled = Egui::ExmlMobile.attr_s(node, rt, "on_filled")
  on_act = Egui::ExmlMobile.attr_s(node, rt, "on_change")
  id = Egui::ExmlMobile.attr_s(node, rt, "id") || node.path
  ui.pin_input(text, count: count, id: id) do |t, filled|
    rt.strings[key] = t if key
    rt.fire(on_act.not_nil!) if on_act
    rt.fire(on_filled.not_nil!) if filled && on_filled
  end
end

# `<chip-row on_close>` — the filter chip strip; each `<chip label
# bind closable/>` child becomes one chip. `bind` makes it a FILTER
# chip (selected = the bool slot, the tap writes the flip back);
# without one it's a plain action chip (a static `selected` renders
# the tint but taps don't persist — objects rebuild per frame).
widget "chip-row" do |node, ui, ctx, rt, r|
  chip_nodes = node.children.select { |c| c.name == "chip" }
  chips = chip_nodes.map do |c|
    key = Egui::ExmlMobile.attr_s(c, rt, "bind")
    selected : Bool? =
      if key
        rt.bool(key)
      elsif c.attrs["selected"]?
        Egui::ExmlMobile.attr_b(c, rt, "selected", false)
      end
    Egui::Chip.new(
      Egui::ExmlMobile.attr_s(c, rt, "label") || "",
      icon: Egui::ExmlMobile.attr_icon?(c, rt, "icon"),
      selected: selected,
      closable: Egui::ExmlMobile.attr_b(c, rt, "closable", false),
      id: Egui::ExmlMobile.attr_s(c, rt, "id") || c.path)
  end
  on_close = Egui::ExmlMobile.attr_s(node, rt, "on_close")
  resps = ui.chip_row(chips) { |i| rt.fire(on_close.not_nil!) if on_close }
  # filter chips: `changed?` = the tap toggled — mirror the flip into
  # the bind slot (the Chip object is per-frame, the slot is the state)
  resps.each_with_index do |resp, i|
    next unless resp.changed?
    c = chip_nodes[i]?
    key = c ? Egui::ExmlMobile.attr_s(c, rt, "bind") : nil
    rt.bools[key] = !rt.bool(key) if key
    act = c ? Egui::ExmlMobile.attr_s(c, rt, "on_change") : nil
    rt.fire(act.not_nil!) if act
  end
end

# `<chip>` outside a `<chip-row>` — a single standalone chip.
widget "chip" do |node, ui, ctx, rt, r|
  key = Egui::ExmlMobile.attr_s(node, rt, "bind")
  selected : Bool? =
    if key
      rt.bool(key)
    elsif node.attrs["selected"]?
      Egui::ExmlMobile.attr_b(node, rt, "selected", false)
    end
  chip = Egui::Chip.new(
    Egui::ExmlMobile.attr_s(node, rt, "label") || "",
    icon: Egui::ExmlMobile.attr_icon?(node, rt, "icon"),
    selected: selected,
    closable: Egui::ExmlMobile.attr_b(node, rt, "closable", false),
    id: Egui::ExmlMobile.attr_s(node, rt, "id") || node.path)
  resp = ui.chip(chip)
  if resp.changed? && key
    rt.bools[key] = !rt.bool(key)
    act = Egui::ExmlMobile.attr_s(node, rt, "on_change")
    rt.fire(act.not_nil!) if act
  end
end

# ── gestures, indicators, misc ───────────────────────────────────────

# `<swipe-item on_dismiss>` with `<swipe-action label color on_tap/>`
# children; the rest of the children are the row content (a
# list-tile). `color` is `#rrggbb` (default #dc3c3c — the delete red).
widget "swipe-item" do |node, ui, ctx, rt, r|
  actions = node.children.select { |c| c.name == "swipe-action" }.map do |c|
    raw = Egui::Exml.parse_box_color(
      Egui::ExmlMobile.attr_s(c, rt, "color") || "#dc3c3c")
    color = raw.is_a?(Egui::Gradient) ?
              Egui::Color32.rgb(220, 60, 60) : raw ||
              Egui::Color32.rgb(220, 60, 60)
    act = Egui::ExmlMobile.attr_s(c, rt, "on_tap")
    Egui::SwipeItem::Action.new(
      Egui::ExmlMobile.attr_s(c, rt, "label") || "",
      color,
      act ? ->{ rt.fire(act.not_nil!) } : nil)
  end
  on_dismiss = Egui::ExmlMobile.attr_s(node, rt, "on_dismiss")
  id = Egui::ExmlMobile.attr_s(node, rt, "id") || node.path
  ui.swipe_item(id: id, actions: actions,
    on_dismiss: (on_dismiss ? ->{ rt.fire(on_dismiss.not_nil!) } : nil)) do |row|
    node.children.each { |c| r.render(c, row, ctx, rt) unless c.name == "swipe-action" }
  end
end

# `<swipe-action>` outside a `<swipe-item>` — inert (like appbar-action).
widget "swipe-action" do |node, ui, ctx, rt, r|
  Egui::ExmlMobile.warn_once("swipe-action",
    "<swipe-action> outside <swipe-item> — ignored")
  ui.label("")
end

# `<pager pages bind height on_change>` — the swipeable page strip;
# the children render into the VISIBLE page only (`{_i}` = its index —
# the repeat row-index convention). `bind` (or `on_change`) receives
# the settled page.
widget "pager" do |node, ui, ctx, rt, r|
  key = Egui::ExmlMobile.attr_s(node, rt, "bind")
  selected = key ? rt.float(key).to_i : Egui::ExmlMobile.attr_i(node, rt, "selected", 0)
  pages = Egui::ExmlMobile.attr_i(node, rt, "pages", 1)
  height = Egui::ExmlMobile.attr_f(node, rt, "height", 200.0)
  on_act = Egui::ExmlMobile.attr_s(node, rt, "on_change")
  id = Egui::ExmlMobile.attr_s(node, rt, "id") || node.path
  ui.pager(pages, selected, id: id, height: height,
    on_change: ->(i : Int32) {
      rt.floats[key] = i.to_f64 if key
      rt.fire(on_act.not_nil!) if on_act
    }) do |p, i|
    rt.strings["_i"] = i.to_s
    node.children.each { |c| r.render(c, p, ctx, rt) }
    rt.strings["_i"] = ""
  end
end

# `<page-indicator count bind/>` — the passive dots (index read from
# the slot or the `index` attr).
widget "page-indicator" do |node, ui, ctx, rt, r|
  key = Egui::ExmlMobile.attr_s(node, rt, "bind")
  index = key ? rt.float(key).to_i : Egui::ExmlMobile.attr_i(node, rt, "index", 0)
  count = Egui::ExmlMobile.attr_i(node, rt, "count", 1)
  id = Egui::ExmlMobile.attr_s(node, rt, "id") || node.path
  ui.page_indicator(count, index, id: id)
end

# `<pull-to-refresh refreshing="{b}" label/>` — the spinner strip
# shown while the (app-driven) refresh runs.
widget "pull-to-refresh" do |node, ui, ctx, rt, r|
  key = Egui::ExmlMobile.attr_s(node, rt, "bind")
  refreshing = key ? rt.bool(key) :
               Egui::ExmlMobile.attr_b(node, rt, "refreshing", false)
  label = Egui::ExmlMobile.attr_s(node, rt, "label")
  id = Egui::ExmlMobile.attr_s(node, rt, "id") || node.path
  ui.pull_to_refresh(refreshing, id: id, label: label)
end

# `<avatar name size/>` — the initials circle.
widget "avatar" do |node, ui, ctx, rt, r|
  name = Egui::ExmlMobile.attr_s(node, rt, "name") || "?"
  size = Egui::ExmlMobile.attr_f(node, rt, "size", 40.0)
  id = Egui::ExmlMobile.attr_s(node, rt, "id") || node.path
  ui.avatar(name, size: size, id: id)
end

# `<badge count/>` — the counter bubble, standalone (the `on:`-anchored
# paint-over mode needs a builtin ref — custom tags don't register
# refs — so anchoring is not available in markup v1).
widget "badge" do |node, ui, ctx, rt, r|
  count = Egui::ExmlMobile.attr_i(node, rt, "count", 0)
  id = Egui::ExmlMobile.attr_s(node, rt, "id") || node.path
  ui.badge(count, id: id)
end

# `<skeleton rows height/>` — the loading placeholder column.
widget "skeleton" do |node, ui, ctx, rt, r|
  rows = Egui::ExmlMobile.attr_i(node, rt, "rows", 3)
  height = node.attrs["height"]? ?
             Egui::ExmlMobile.attr_f(node, rt, "height", 64.0) : nil
  id = Egui::ExmlMobile.attr_s(node, rt, "id") || node.path
  ui.skeleton_list(rows, height: height, id: id)
end

# `<circular-progress value text/>` — the ring gauge (value 0..1).
widget "circular-progress" do |node, ui, ctx, rt, r|
  value = Egui::ExmlMobile.attr_f(node, rt, "value", 0.0).clamp(0.0, 1.0)
  text = Egui::ExmlMobile.attr_s(node, rt, "text")
  id = Egui::ExmlMobile.attr_s(node, rt, "id") || node.path
  ui.circular_progress(value, text: text, id: id)
end

# `<safe-area top bottom left right>` — the inset-padded container.
widget "safe-area" do |node, ui, ctx, rt, r|
  id = Egui::ExmlMobile.attr_s(node, rt, "id") || node.path
  ui.safe_area(
    top: Egui::ExmlMobile.attr_f(node, rt, "top", 0.0),
    bottom: Egui::ExmlMobile.attr_f(node, rt, "bottom", 0.0),
    left: Egui::ExmlMobile.attr_f(node, rt, "left", 0.0),
    right: Egui::ExmlMobile.attr_f(node, rt, "right", 0.0),
    id: id) { |sa| r.render_each(node, sa, ctx, rt) }
end
