# CSS-like class styling for egui.cr (no upstream counterpart — the
# closest analogues upstream are `Style` + per-widget `WidgetStyle`).
#
# A `StyleSheet` is a global tree of style classes addressed by dotted
# paths ("sidebar.tab"), each holding a bag of style variables
# (`StyleVars` — a Hash subclass, mergeable per key) for the base state
# plus overlays for interaction states (`:hover`, `:selected`, …):
#
#   ctx.stylesheet.rule("sidebar.tab", StyleVars{
#     "padding"    => Egui::Vec2.new(12.0, 6.0),
#     "text_color" => Egui::Color32.rgb(235, 235, 235),
#   })
#   ctx.stylesheet.rule("sidebar.tab:selected", StyleVars{
#     "fill" => Egui::Color32.rgb(0, 122, 204),
#   })
#
# Resolution (`#resolve`) works in two layers, like the CSS cascade:
# first every matching class rule root→leaf (classes are *defaults*,
# more specific classes win), then every matching state rule root→leaf
# on top — a state always overrides any class value, and within the
# state layer the leaf (`sidebar.tab:hover`) beats the ancestor
# (`sidebar:hover`). Merged bags are cached and shared across frames —
# nothing is rebuilt per frame; defining or tweaking a rule drops the
# cache.
#
# Introspection: `#classes` / `#selectors` list what is defined, and
# `#dump(io)` (or `puts ctx.stylesheet`) prints the whole tree with
# every key per class/state — for logs or a runtime style editor.
#
# The sheet lives on the `Theme` (`Theme#sheet`, so `ctx.theme = …`
# swaps class styles together with the palette); the complete default
# theme — palette AND element class rules — is defined in
# `default_theme.cr` (`DefaultTheme`).

module Egui
  # The closed vocabulary of stylable values (keeps `StyleVars` a plain
  # mergeable hash while still type-safe at the getter level).
  alias StyleValue = Color32 | Float64 | Int32 | Bool | String

  # CSS box model for paddings/margins/any four-sided spacing: every
  # side is its own key (`padding.top/left/right/bottom`), with the
  # scalar shorthand (`padding` → all sides) as fallback per side.
  struct StyleBox
    getter top : Float64
    getter right : Float64
    getter bottom : Float64
    getter left : Float64

    def initialize(@top = 0.0, @right = 0.0, @bottom = 0.0, @left = 0.0)
    end

    def vertical : Float64
      top + bottom
    end

    def horizontal : Float64
      left + right
    end

    def to_s(io : IO) : Nil
      io << "(" << top << ", " << right << ", " << bottom << ", " << left << ")"
    end
  end

  # A mergeable bag of style variables: `Hash(String, StyleValue)` with
  # typed getters (untyped keys simply stay invisible to a getter, so
  # typos degrade to "unset", never to a crash). Bags produced by
  # `StyleSheet#resolve` are shared caches — treat them as read-only.
  class StyleVars < Hash(String, StyleValue)
    def color?(key : String) : Color32?
      self[key]?.as?(Color32)
    end

    def color(key : String, fallback : Color32) : Color32
      color?(key) || fallback
    end

    # Integers coerce (CSS vibes: `{"height" => 24}` reads as 24.0).
    def f64?(key : String) : Float64?
      case v = self[key]?
      when Float64 then v
      when Int32   then v.to_f64
      else              nil
      end
    end

    def f64(key : String, fallback : Float64) : Float64
      f64?(key) || fallback
    end

    # The four-sided box under `prefix` ("padding", "margin", …):
    # `prefix.top/left/right/bottom`, each side falling back to the
    # scalar `prefix` shorthand (CSS `padding: 12px` sets all sides),
    # missing sides to 0.
    def box(prefix : String) : StyleBox
      all = f64?(prefix)
      StyleBox.new(
        f64?("#{prefix}.top") || all || 0.0,
        f64?("#{prefix}.right") || all || 0.0,
        f64?("#{prefix}.bottom") || all || 0.0,
        f64?("#{prefix}.left") || all || 0.0)
    end

    # Same, but nil when no box key is set at all (callers fall back to
    # their own default, e.g. `Spacing#button_padding`).
    def box?(prefix : String) : StyleBox?
      return nil unless has_key?(prefix) ||
                       has_key?("#{prefix}.top") || has_key?("#{prefix}.right") ||
                       has_key?("#{prefix}.bottom") || has_key?("#{prefix}.left")
      box(prefix)
    end

    def bool?(key : String) : Bool?
      self[key]?.as?(Bool)
    end

    def bool(key : String, fallback : Bool) : Bool
      bool?(key) || fallback
    end

    # The class layer of the cascade: apply this bag onto a copy of
    # `base` (the same key vocabulary `WidgetStyle#merge_over` uses).
    # `state` maps the `fill` key onto the matching Visuals slot
    # ("hover" → button_hovered, "active" → button_active), so a
    # state overlay lands on its state's color. Skips cloning for
    # empty bags.
    def apply_over(base : Style, state : String? = nil) : Style
      return base if empty?
      merged = base.clone
      v = merged.visuals
      if (c = color?("text_color"))
        v.text_color = c
      end
      if (c = color?("fill"))
        case state
        when "hover"  then v.button_hovered = c
        when "active" then v.button_active = c
        else               v.button_weak = c
        end
      end
      if (c = color?("fill_hovered"))
        v.button_hovered = c
      end
      if (c = color?("fill_active"))
        v.button_active = c
      end
      if (c = color?("stroke"))
        v.button_stroke = c
      end
      if (c = color?("selection_fill"))
        v.selection_fill = c
      end
      if (c = color?("separator_color"))
        v.separator_color = c
      end
      if (c = color?("hyperlink_color"))
        v.hyperlink_color = c
      end
      if (f = f64?("font_size"))
        merged.font_size = f
      end
      merged
    end
  end

  # One class in the tree: base-state vars plus per-state overlays.
  class StyleClass
    getter path : String
    property vars : StyleVars
    getter states : Hash(String, StyleVars)

    def initialize(@path)
      @vars = StyleVars.new
      @states = {} of String => StyleVars
    end

    # Merge `vars` into the base state (per-key override).
    def set(vars : Hash(String, StyleValue)) : self
      @vars.merge!(vars)
      self
    end

    # Merge `vars` into the given state overlay (:hover, :selected…).
    def set(state : String, vars : Hash(String, StyleValue)) : self
      (@states[state] ||= StyleVars.new).merge!(vars)
      self
    end
  end

  class StyleSheet
    def initialize
      @classes = {} of String => StyleClass
      @resolved = {} of {String, String?} => StyleVars
    end

    # The class for `path`, created on first touch (defining a child
    # never requires defining its ancestors first).
    def [](path : String) : StyleClass
      @classes[path] ||= StyleClass.new(path)
    end

    def []?(path : String) : StyleClass?
      @classes[path]?
    end

    # Define/extend a rule CSS-style: `rule("sidebar.tab:selected", …)`
    # splits into class "sidebar.tab" + state "selected". Merges into
    # whatever the selector already holds (per-key override) and drops
    # the resolve cache.
    def rule(selector : String,
             vars : Hash(String, StyleValue)) : self
      path, state = split_selector(selector)
      cls = self[path]
      state ? cls.set(state, vars) : cls.set(vars)
      @resolved.clear
      self
    end

    # The class+state vars, merged in two cascade layers and cached:
    # the returned bag is the same object frame after frame until a
    # `rule` changes something — read it, do not mutate it.
    #
    #   1. class layer (defaults): ancestor vars root→leaf — the more
    #      specific class wins per key;
    #   2. state layer: every matching state overlay root→leaf, merged
    #      on top — states ALWAYS override class defaults, and the leaf
    #      state wins among states (CSS: classes are defaults,
    #      pseudo-class rules beat them).
    def resolve(path : String, state : String? = nil) : StyleVars
      key = {path, state}
      if (cached = @resolved[key]?)
        return cached
      end

      bag = StyleVars.new
      chain = ancestors(path)
      chain.each do |ancestor|
        bag.merge!(@classes[ancestor].vars) if (cls = @classes[ancestor]?)
      end
      if state
        chain.each do |ancestor|
          if (cls = @classes[ancestor]?) && (overlay = cls.states[state]?)
            bag.merge!(overlay)
          end
        end
      end
      @resolved[key] = bag
      bag
    end

    # The raw (unmerged) state overlay defined for one class+state —
    # the state layer of the cascade, applied on top of the class
    # layer but under widget `#style` overrides.
    def state_vars(path : String, state : String) : StyleVars?
      @classes[path]?.try &.states[state]?
    end

    # Drop the cached merges manually (after mutating a StyleClass
    # directly through `[]`; `rule` does this itself).
    def touch : self
      @resolved.clear
      self
    end

    # Introspection: every defined class path, tree order.
    def classes : Array(String)
      @classes.keys.sort
    end

    # Introspection: every defined selector — "class" and "class:state".
    def selectors : Array(String)
      out = [] of String
      @classes.each do |path, cls|
        out << path
        cls.states.each_key { |state| out << "#{path}:#{state}" }
      end
      out.sort
    end

    # Introspection: print the whole tree (classes → states → keys with
    # values) — `puts ctx.stylesheet` or log it to see every key.
    def dump(io : IO) : Nil
      classes.each do |path|
        cls = @classes[path]
        indent = "  " * (path.split('.').size - 1)
        io << indent << path.split('.').last << '\n'
        dump_vars(io, cls.vars, indent + "  ")
        cls.states.each do |state, vars|
          io << indent << "  :" << state << '\n'
          dump_vars(io, vars, indent + "    ")
        end
      end
    end

    def to_s(io : IO) : Nil
      dump(io)
    end

    # The "user-agent stylesheet" lives in `default_theme.cr`
    # (`DefaultTheme`) — the complete default theme (base palette +
    # element class rules) is defined there.

    private def dump_vars(io : IO, vars : StyleVars, indent : String) : Nil
      vars.keys.sort.each do |key|
        io << indent << key << ": " << format_value(vars[key]) << '\n'
      end
    end

    private def format_value(v : StyleValue) : String
      case v
      when Color32
        sprintf("#%02x%02x%02x%02x", v.r.to_i, v.g.to_i, v.b.to_i, v.a.to_i)
      else
        v.to_s
      end
    end

    # "sidebar.tab" → ["sidebar", "sidebar.tab"].
    private def ancestors(path : String) : Array(String)
      parts = path.split('.')
      parts.each_with_index.map { |_, i| parts[0..i].join('.') }.to_a
    end

    # "sidebar.tab:hover" → {"sidebar.tab", "hover"}.
    private def split_selector(selector : String) : {String, String?}
      if (i = selector.rindex(':'))
        {selector[0...i], selector[(i + 1)..]}
      else
        {selector, nil}
      end
    end
  end
end
