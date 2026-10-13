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
#     "background" => Egui::Color32.rgb(0, 122, 204),
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
# Media conditions (CSS `@media (min-width: 600px)`): rules declared
# with a `media:` condition live in a parallel list evaluated against
# the viewport width (`#viewport_width=`, set from `screen_rect` by
# `Context#begin_frame`). Matching media rules merge BETWEEN the class
# and state layers — a media rule beats the class defaults, but a
# pseudo-class rule still beats a media class rule (CSS: media queries
# gate rules, they don't add specificity). `px` = logical point.
#
# Style scopes (`Ui#with_style_scope`) chain a widget's base class with
# a scoped path — a Button inside scope "sidebar" reads BOTH "button"
# and "sidebar.button" through `#resolve_chain` (class layers first,
# state layers on top, so `button:hover` still beats
# `sidebar.button`). See `Widget#class_paths` for how the chain is
# derived.
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
  alias StyleValue = Color32 | Float64 | Int32 | Bool | String | StyleLength

  # A length with a unit (CSS-like responsive sizing): `50%`, `10vw`,
  # `4vmin`, `1.5rem`. A plain `Float64` in a `StyleVars` bag stays a
  # point value (`px`), so pre-unit themes keep working untouched.
  #
  # Resolution (`#resolve`) happens against the widget's containing
  # `Ui` — immediate mode needs no widget tree:
  #   %    — the Ui's `max_rect` side (minus one `item_spacing` on the
  #          flow axis of horizontal rows, so a pair of 50% widgets
  #          splits the row exactly); vertical percents resolve to nil
  #          in unbounded top-down regions (frames/scroll contents
  #          grow downward with content — there is no definite height
  #          to be a percent OF, the caller's fallback applies);
  #   vw/vh/vmin/vmax — the Context's `screen_rect`;
  #   rem  — the root `Style#font_size` (logical points).
  struct StyleLength
    getter value : Float64
    getter unit : Symbol

    def initialize(@value : Float64, @unit : Symbol)
    end

    # "50%" / "10vw" / "1.5rem" / "12px" — nil when the string is not
    # a number with a known unit suffix. No suffix is a suffix of
    # another, so iteration order never matters. The bare `env(top)`
    # forms carry an implicit 1.0 multiplier.
    UNITS = {"%" => :percent, "vmin" => :vmin, "vmax" => :vmax,
             "rem" => :rem, "vw" => :vw, "vh" => :vh, "px" => :px,
             "env(safe-area-inset-top)" => :safe_top,
             "env(safe-area-inset-right)" => :safe_right,
             "env(safe-area-inset-bottom)" => :safe_bottom,
             "env(safe-area-inset-left)" => :safe_left}

    def self.parse?(s : String) : StyleLength?
      UNITS.each do |suffix, unit|
        next unless s.ends_with?(suffix)
        num_s = s[0...s.size - suffix.size]
        # `env(top)` alone = the full inset; `0.5env(top)` scales it.
        num = num_s.empty? ? 1.0 : num_s.to_f64?
        return num ? new(num, unit) : nil
      end
      nil
    end

    def resolve(ui : Ui, axis : Symbol = :x) : Float64?
      case @unit
      when :px   then @value
      when :rem  then @value * ui.ctx.style.font_size * ui.ctx.font_scale
      when :vw   then @value / 100.0 * ui.ctx.input.screen_rect.width
      when :vh   then @value / 100.0 * ui.ctx.input.screen_rect.height
      when :vmin
        r = ui.ctx.input.screen_rect
        @value / 100.0 * {r.width, r.height}.min
      when :vmax
        r = ui.ctx.input.screen_rect
        @value / 100.0 * {r.width, r.height}.max
      when :safe_top    then @value * ui.ctx.safe_area.top
      when :safe_right  then @value * ui.ctx.safe_area.right
      when :safe_bottom then @value * ui.ctx.safe_area.bottom
      when :safe_left   then @value * ui.ctx.safe_area.left
      when :percent
        base = axis == :x ? percent_base_x(ui) : percent_base_y(ui)
        base ? @value / 100.0 * base : nil
      else nil
      end
    end

    def to_s(io : IO) : Nil
      # Whole numbers print without the trailing ".0" — the spelling
      # files are hand-written with ("50%", not "50.0%"). The bare
      # `env()` form round-trips as `1env(...)` — equivalent.
      io << (@value % 1 == 0 ? @value.to_i64.to_s : @value.to_s) << suffix
    end

    private def suffix : String
      case @unit
      when :percent     then "%"
      when :safe_top    then "env(safe-area-inset-top)"
      when :safe_right  then "env(safe-area-inset-right)"
      when :safe_bottom then "env(safe-area-inset-bottom)"
      when :safe_left   then "env(safe-area-inset-left)"
      else @unit.to_s
      end
    end

    # The horizontal containing-block width. In a horizontal row one
    # `item_spacing` is subtracted: two `50%` widgets then split the
    # row exactly (each (W−s)/2, the second's remaining space is the
    # same number — see plans/responsive-mobile.md Этап 1).
    private def percent_base_x(ui : Ui) : Float64
      base = ui.max_rect.width
      base -= ui.style.spacing.item_spacing.x if ui.layout.horizontal?
      {base, 0.0}.max
    end

    # The vertical base — nil in unbounded regions (a definite height
    # is what a percent needs to be a percent OF). Frames and scroll
    # contents hand out ~1e6-high inner rects; 1e5 separates them from
    # any real panel/viewport height.
    private def percent_base_y(ui : Ui) : Float64?
      h = ui.max_rect.height
      h < 1e5 ? h : nil
    end
  end

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

  # A resolved CSS `box-shadow`: `color` plus geometry. Built from flat
  # `shadow.*` style keys by `StyleVars#shadow?` (see there).
  struct BoxShadowSpec
    getter color : Color32
    getter blur : Float64
    getter spread : Float64
    getter offset : Vec2
    getter? inset : Bool

    def initialize(@color : Color32, @blur : Float64 = 0.0,
                   @spread : Float64 = 0.0, @offset : Vec2 = Vec2.new(0.0, 0.0),
                   @inset : Bool = false)
    end
  end

  # A stylable property declaration: the `StyleVars` key a widget
  # actually reads, plus how to edit it. Widgets declare their own
  # lists (`Widget#style_properties`) — the inspector is generic and
  # builds its editors purely from these declarations.
  struct StyleProp
    getter key : String
    # :color | :number | :box | :bool | :string | :weight | :enum —
    # picks the inspector editor (:enum renders a SelectBox over
    # #options, "не в списке" values still display).
    getter kind : Symbol
    getter label : String
    # True when the key also makes sense as a `:hover`/`:active` state
    # overlay (button fills, bevels, shadows) — the inspector then
    # offers the base/hover/active switch for it.
    getter? states : Bool
    # The widget's own hardcoded default for the key (what #ui passes
    # to `vars.f64(key, …)` when neither class rules nor theme define
    # it) — the inspector shows it as the value while unset, instead
    # of a bogus 0.
    getter fallback : StyleValue?
    # Lower bound for :number keys the value makes no sense below
    # (font_size, rounding, blur…): the inspector's number editor
    # clamps edits to it. nil = unclamped (offsets, spreads —
    # negatives are legitimate CSS there).
    getter min : Float64?
    # The pick list for :enum keys (the editor's SelectBox options).
    # nil for every other kind.
    getter options : Array(String)?

    def initialize(@key : String, @kind : Symbol, label : String? = nil,
                   @states : Bool = false, @fallback : StyleValue? = nil,
                   @min : Float64? = nil,
                   @options : Array(String)? = nil)
      @label = label || @key
    end
  end

  # Ready-made declaration sets shared by several widgets (widgets
  # return their OWN array — treat the results as read-only).
  module StyleProps
    # Text-carrying widgets: color + size + weight + family. `font_size`
    # floors at 0 — a negative size is meaningless (the inspector
    # clamps); `font_weight` is the CSS 100..900 ladder edited from a
    # list (>= 600 synthesizes bold — see `Style#font_weight`).
    def self.textlike : Array(StyleProp)
      [StyleProp.new("text_color", :color),
       StyleProp.new("font_size", :number, min: 0.0),
       StyleProp.new("font_weight", :weight),
       StyleProp.new("font_family", :string)]
    end

    # Widgets painted as a filled box (buttons & friends). ONE CSS-like
    # `background` key — per-state values come from state rules
    # (`button:hover { … }`) and are resolved automatically from the
    # widget's live interaction state (see `Widget#background_color`).
    def self.buttonlike : Array(StyleProp)
      textlike + [
        StyleProp.new("background", :color, states: true),
        StyleProp.new("stroke", :color, states: true),
      ]
    end

    # Responsive sizing keys every widget understands (applied by
    # `Widget#styled_size`): `width`/`min_width`/`max_width` and the
    # height trio, values in points or responsive units (`%`, `vw`,
    # `vh`, `vmin`, `vmax`, `rem` — see `StyleLength`). `transition`
    # (ms) animates size keys towards new targets (per-key
    # `transition.width` beats the shorthand).
    def self.sizable : Array(StyleProp)
      props = [%w[width min_width max_width],
               %w[height min_height max_height]].flat_map do |keys|
        keys.map { |k| StyleProp.new(k, :number, min: 0.0) }
      end
      props + [StyleProp.new("transition", :number, label: "transition (ms)",
        min: 0.0)]
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

    # A length key resolved to logical points against the widget's
    # containing `Ui` (see `StyleLength#resolve`): plain numbers pass
    # through (Int32 coerces), `%`/`vw`/`vh`/`vmin`/`vmax`/`rem`
    # resolve per their unit. nil when the key is unset, holds a
    # non-length value, or the unit's base is undefined (percent
    # height in an unbounded region) — callers apply their fallback.
    # The allocation max-size rule clamps the result to the region,
    # so an oversized percent can never push past the parent.
    def length_px?(key : String, ui : Ui, axis : Symbol = :x) : Float64?
      case v = self[key]?
      when Float64    then v
      when Int32      then v.to_f64
      when StyleLength then v.resolve(ui, axis)
      else nil
      end
    end

    def length_px(key : String, ui : Ui, fallback : Float64,
                  axis : Symbol = :x) : Float64
      length_px?(key, ui, axis) || fallback
    end

    # String values (font families, class names…).
    def str?(key : String) : String?
      self[key]?.as?(String)
    end

    # The four-sided box under `prefix` ("padding", "margin", …):
    # `prefix.top/left/right/bottom`, each side falling back to the
    # scalar `prefix` shorthand (CSS `padding: 12px` sets all sides),
    # missing sides to 0. Negative sides clamp to 0 — this layout
    # engine has no notion of "padding pulling content outside the
    # widget", so a negative value only made text overflow its rect.
    def box(prefix : String) : StyleBox
      all = f64?(prefix)
      side = ->(k : String) { {(f64?(k) || all || 0.0), 0.0}.max }
      StyleBox.new(
        side.call("#{prefix}.top"),
        side.call("#{prefix}.right"),
        side.call("#{prefix}.bottom"),
        side.call("#{prefix}.left"))
    end

    # Same, but nil when no box key is set at all (callers fall back to
    # their own default, e.g. `Spacing#button_padding`).
    def box?(prefix : String) : StyleBox?
      return nil unless has_key?(prefix) ||
                       has_key?("#{prefix}.top") || has_key?("#{prefix}.right") ||
                       has_key?("#{prefix}.bottom") || has_key?("#{prefix}.left")
      box(prefix)
    end

    # The CSS `box-shadow` under `prefix` ("shadow" by default):
    # requires `shadow.color` (a shadow without a color is nothing),
    # everything else defaults — blur/spread/offset 0, outset. Flat
    # scalar keys like #box?, so the mergeable-bag cascade works per
    # key: a `button:active` rule may flip only `shadow.inset` and the
    # class defaults fill in the rest.
    def shadow?(prefix : String = "shadow") : BoxShadowSpec?
      return nil unless (color = color?("#{prefix}.color"))
      BoxShadowSpec.new(color,
        f64("#{prefix}.blur", 0.0),
        f64("#{prefix}.spread", 0.0),
        Vec2.new(f64("#{prefix}.x", 0.0), f64("#{prefix}.y", 0.0)),
        bool("#{prefix}.inset", false))
    end

    def bool?(key : String) : Bool?
      self[key]?.as?(Bool)
    end

    def bool(key : String, fallback : Bool) : Bool
      # An explicit `false` must not fall through (`false || fallback`
      # and `if (v = bool?(key))` both drop it).
      v = bool?(key)
      v.nil? ? fallback : v
    end

    # Apply this bag onto a copy of `base` (the same key vocabulary
    # `WidgetStyle#merge_over` uses), mapping keys onto their `Style`
    # slots. `background` is deliberately NOT mapped here: it is
    # state-scoped, so state-painted widgets read it from the
    # state-merged bag through `Widget#background_color` instead of a
    # flat Style slot. Skips cloning for empty bags.
    def apply_over(base : Style) : Style
      return base if empty?
      merged = base.clone
      v = merged.visuals
      if (c = color?("text_color"))
        v.text_color = c
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
        # Floor at 0: a negative size is meaningless in every consumer
        # (layout, rasterization) no matter how it got in — inspector,
        # .ecss file or a code-side rule.
        merged.font_size = {f, 0.0}.max
      end
      if (f = f64?("font_weight"))
        # Clamp to the CSS ladder 100..900 (see `Style#font_weight`).
        merged.font_weight = f.clamp(100.0, 900.0)
      end
      if (f = str?("font_family"))
        merged.font_family = f
      end
      merged
    end
  end

  # A CSS media condition: width/height bounds, orientation and the
  # pointer type — `(min-width: 600px) and (orientation: portrait)`,
  # `(pointer: coarse)`, `(hover: none)`, … Media types (`screen`,
  # `all`) are accepted and ignored. Bounds are inclusive, like CSS.
  # `(pointer: none)` (no pointing device at all) matches nothing —
  # every backend egui.cr runs on has at least one pointer.
  struct MediaCond
    getter min_width : Float64?
    getter max_width : Float64?
    getter min_height : Float64?
    getter max_height : Float64?
    getter orientation : Symbol?  # :portrait | :landscape
    getter pointer : Symbol?      # :coarse | :fine | :none
    getter hover : Symbol?        # :hover | :none

    def initialize(@min_width : Float64? = nil, @max_width : Float64? = nil,
                   @min_height : Float64? = nil,
                   @max_height : Float64? = nil,
                   @orientation : Symbol? = nil, @pointer : Symbol? = nil,
                   @hover : Symbol? = nil)
    end

    # Parse "(min-width: 600px)", "(orientation: portrait)",
    # "(pointer: coarse) and (max-height: 500px)", … — nil when
    # nothing supported is there; the caller decides whether to warn
    # and drop the rule. Strict units: a bare number or `Npx`
    # (logical points); `600em`-style garbage no longer silently
    # parses as 600.
    def self.parse(text : String) : MediaCond?
      min_width = max_width = min_height = max_height = nil
      orientation = pointer = hover = nil
      seen = false
      text.strip.split(/\s+and\s+/i).each do |part|
        p = part.strip.downcase
        next if p.empty? || p == "screen" || p == "all" || p == "only screen"
        p = p[1...-1] if p.starts_with?('(') && p.ends_with?(')')
        key, _, val = p.partition(':')
        v = val.strip
        case key.strip
        when "min-width", "max-width", "min-height", "max-height"
          num = v.ends_with?("px") ? v[0...-2].to_f64? : v.to_f64?
          return nil if num.nil?
          case key.strip
          when "min-width"  then min_width = num
          when "max-width"  then max_width = num
          when "min-height" then min_height = num
          else                   max_height = num
          end
          seen = true
        when "orientation"
          return nil unless {"portrait", "landscape"}.includes?(v)
          orientation = v == "portrait" ? :portrait : :landscape
          seen = true
        when "pointer"
          return nil unless {"coarse", "fine", "none"}.includes?(v)
          pointer = v == "coarse" ? :coarse : (v == "fine" ? :fine : :none)
          seen = true
        when "hover"
          return nil unless {"hover", "none"}.includes?(v)
          hover = v == "hover" ? :hover : :none
          seen = true
        else
          return nil # print/aspect-ratio/… — not supported
        end
      end
      seen ? new(min_width, max_width, min_height, max_height,
        orientation, pointer, hover) : nil
    end

    def matches?(width : Float64?, height : Float64? = nil,
                 pointer_coarse : Bool = false) : Bool
      ok = true
      if (mn = @min_width)
        return false if width.nil?
        ok &= width >= mn
      end
      if (mx = @max_width)
        return false if width.nil?
        ok &= width <= mx
      end
      if (mn = @min_height)
        return false if height.nil?
        ok &= height >= mn
      end
      if (mx = @max_height)
        return false if height.nil?
        ok &= height <= mx
      end
      if (o = @orientation)
        return false if width.nil? || height.nil?
        ok &= (o == :landscape) == (width >= height)
      end
      if (p = @pointer)
        # One coarse flag for every backend (touch screens); a mouse
        # (or trackpad) is `fine`. `none` never matches — see the
        # struct comment.
        ok &= (pointer_coarse ? :coarse : :fine) == p
      end
      if (h = @hover)
        ok &= (pointer_coarse ? :none : :hover) == h
      end
      ok
    end

    def to_s(io : IO) : Nil
      parts = [] of String
      if (mn = @min_width)
        parts << "(min-width: #{fmt(mn)}px)"
      end
      if (mx = @max_width)
        parts << "(max-width: #{fmt(mx)}px)"
      end
      if (mn = @min_height)
        parts << "(min-height: #{fmt(mn)}px)"
      end
      if (mx = @max_height)
        parts << "(max-height: #{fmt(mx)}px)"
      end
      parts << "(orientation: #{@orientation})" if @orientation
      parts << "(pointer: #{@pointer})" if @pointer
      parts << "(hover: #{@hover})" if @hover
      io << parts.join(" and ")
    end

    # Whole numbers print without the trailing ".0" — the same spelling
    # files are hand-written with ("600px", not "600.0px").
    private def fmt(w : Float64) : String
      w % 1 == 0 ? w.to_i64.to_s : w.to_s
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
    # One media-gated rule entry: the condition plus the selector it
    # was declared with (path + optional state) and its vars. Kept in
    # declaration order — CSS source order decides between two active
    # media rules touching the same key.
    struct MediaRuleEntry
      getter cond : MediaCond
      getter path : String
      getter state : String?
      getter vars : StyleVars

      def initialize(@cond, @path, @state, @vars)
      end
    end

    def initialize
      @classes = {} of String => StyleClass
      @resolved = {} of {String, String?} => StyleVars
      @media_rules = [] of MediaRuleEntry
      # The viewport width the media conditions match against, in
      # logical points — set by `Context#begin_frame` from
      # `screen_rect` (headless tests set it directly).
      @viewport_width = nil
      @viewport_height = nil
      # True when the input device is touch-first (a phone/tablet):
      # `(pointer: coarse)` and `(hover: none)` conditions match.
      # Backends flip this through `Context#pointer_coarse=`.
      @pointer_coarse = false
      # The per-rule match bits at the last viewport update — a flip
      # (a condition boundary crossed) drops the resolve cache.
      @media_bits = [] of Bool
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
    # the resolve cache. With `media` ("(min-width: 600px)") the rule
    # lands in the media-gated list instead — applied only while the
    # viewport matches (see `#viewport_width=`).
    def rule(selector : String,
             vars : Hash(String, StyleValue), media : String? = nil) : self
      path, state = split_selector(selector)
      if media
        if (cond = MediaCond.parse(media))
          @media_rules << MediaRuleEntry.new(cond, path, state,
            StyleVars.new.merge!(vars))
          refresh_media_matches
        else
          STDERR.puts "stylesheet: unsupported media condition " \
                      "#{media.inspect} — rule #{selector.inspect} ignored"
        end
      else
        cls = self[path]
        state ? cls.set(state, vars) : cls.set(vars)
      end
      @resolved.clear
      self
    end

    # The class+state vars, merged in two cascade layers and cached:
    # the returned bag is the same object frame after frame until a
    # `rule` changes something — read it, do not mutate it.
    #
    #   1. class layer (defaults): ancestor vars root→leaf — the more
    #      specific class wins per key;
    #   2. media class layer: every matching media condition's class
    #      rules, declaration order (see `#viewport_width=`);
    #   3. state layer: every matching state overlay root→leaf, merged
    #      on top — states ALWAYS override class defaults, and the leaf
    #      state wins among states (CSS: classes are defaults,
    #      pseudo-class rules beat them — even media-gated ones);
    #   4. media state layer: matching media conditions' state rules.
    def resolve(path : String, state : String? = nil) : StyleVars
      key = {path, state}
      if (cached = @resolved[key]?)
        Egui::Bench.count("style.resolve.hit")
        return cached
      end
      Egui::Bench.count("style.resolve.miss")

      bag = StyleVars.new
      chain = ancestors(path)
      chain.each do |ancestor|
        bag.merge!(@classes[ancestor].vars) if (cls = @classes[ancestor]?)
      end
      merge_media_class(bag, path)
      if state
        chain.each do |ancestor|
          if (cls = @classes[ancestor]?) && (overlay = cls.states[state]?)
            bag.merge!(overlay)
          end
        end
        merge_media_state(bag, path, state)
      end
      @resolved[key] = bag
      bag
    end

    # The class-chain counterpart of #resolve: merges every path's
    # resolved bag in CSS cascade order — later paths are more
    # specific and win per key (`.sidebar .button` beats `button`), but
    # the STATE layer of ANY path beats the class layer of ANY path
    # (`button:hover` still wins over `sidebar.button`). Cached like
    # #resolve (the joined paths form the cache key), so chains resolve
    # once and the bag is shared across frames until a rule changes.
    def resolve_chain(paths : Array(String), state : String? = nil) : StyleVars
      return resolve(paths.first, state) if paths.size == 1
      key = paths.join('\u0000')
      if (cached = @resolved[{key, state}]?)
        Egui::Bench.count("style.resolve.hit")
        return cached
      end
      Egui::Bench.count("style.resolve.miss")
      bag = StyleVars.new
      # 1. class layer (defaults), least specific first
      paths.each { |path| bag.merge!(resolve(path)) }
      # 2. state layer on top — always beats class values
      if state
        paths.each { |path| bag.merge!(resolve_state_layer(path, state)) }
      end
      @resolved[{key, state}] = bag
      bag
    end

    # The state layer of #resolve alone: every matching ancestor's
    # `state` overlay merged root→leaf, with NO class values — what
    # resolve_chain needs to keep a pseudo-class rule above the class
    # layer of a more specific chain path. Includes the media state
    # entries on top (media gating never trumps pseudo-class rules).
    def resolve_state_layer(path : String, state : String) : StyleVars
      bag = StyleVars.new
      ancestors(path).each do |ancestor|
        if (cls = @classes[ancestor]?) && (overlay = cls.states[state]?)
          bag.merge!(overlay)
        end
      end
      merge_media_state(bag, path, state)
      bag
    end

    # The raw (unmerged) state overlay defined for one class+state —
    # the state layer of the cascade, applied on top of the class
    # layer but under widget `#style` overrides.
    def state_vars(path : String, state : String) : StyleVars?
      @classes[path]?.try &.states[state]?
    end

    # Remove one key from a class/state rule (the inspector's "reset"):
    # the slot goes back to inheriting the theme. Unset keys and
    # unknown selectors are no-ops. With `media` the key is removed
    # from that media rule instead (same spelling as `#rule`).
    def unset(selector : String, key : String, media : String? = nil) : self
      path, state = split_selector(selector)
      if media
        if (cond = MediaCond.parse(media))
          @media_rules.each do |entry|
            next unless entry.cond == cond && entry.path == path &&
                        entry.state == state
            entry.vars.delete(key)
          end
          @media_rules.reject! { |entry| entry.vars.empty? }
          refresh_media_matches
        end
      elsif (cls = @classes[path]?)
        if state
          cls.states[state]?.try &.delete(key)
        else
          cls.vars.delete(key)
        end
      end
      @resolved.clear
      self
    end

    # Drop the cached merges manually (after mutating a StyleClass
    # directly through `[]`; `rule` does this itself).
    def touch : self
      @resolved.clear
      self
    end

    # The viewport width the media conditions match against, in
    # logical points — set by `Context#begin_frame` from
    # `screen_rect` (headless tests set it directly). A width change
    # only drops the resolve cache when it flips some condition's
    # match state; mere resizes inside a breakpoint band keep the
    # cache.
    def viewport_width=(width : Float64?) : Nil
      return if width == @viewport_width
      @viewport_width = width
      refresh_media_matches
    end

    def viewport_width : Float64?
      @viewport_width
    end

    # The viewport height for `(min-height:…)`/`(orientation:…)`
    # conditions — set alongside the width by `Context#begin_frame`.
    def viewport_height=(height : Float64?) : Nil
      return if height == @viewport_height
      @viewport_height = height
      refresh_media_matches
    end

    def viewport_height : Float64?
      @viewport_height
    end

    # Touch-first input (phone/tablet): flips `(pointer: coarse)` /
    # `(hover: none)` rules. Sticky — a desktop pointer after a touch
    # does not un-coarse the device.
    def pointer_coarse=(coarse : Bool) : Nil
      return if coarse == @pointer_coarse
      @pointer_coarse = coarse
      refresh_media_matches
    end

    def pointer_coarse? : Bool
      @pointer_coarse
    end

    # Recompute the per-rule match bits; a flip (a condition crossed)
    # invalidates every cached merge.
    private def refresh_media_matches : Nil
      bits = @media_rules.map do |entry|
        entry.cond.matches?(@viewport_width, @viewport_height, @pointer_coarse)
      end
      @resolved.clear if bits != @media_bits
      @media_bits = bits
    end

    # Media class rules for `path` (entry.path ∈ ancestors-or-self),
    # matching conditions only, declaration order.
    private def merge_media_class(bag : StyleVars, path : String) : Nil
      @media_rules.each do |entry|
        next if entry.state
        next unless entry.cond.matches?(@viewport_width, @viewport_height,
          @pointer_coarse)
        bag.merge!(entry.vars) if applies_to?(entry.path, path)
      end
    end

    # Media state rules on top of the state layer.
    private def merge_media_state(bag : StyleVars, path : String,
                                  state : String) : Nil
      @media_rules.each do |entry|
        next unless entry.state == state
        next unless entry.cond.matches?(@viewport_width, @viewport_height,
          @pointer_coarse)
        bag.merge!(entry.vars) if applies_to?(entry.path, path)
      end
    end

    # "button" applies to "button" and "sidebar.button"; the reverse
    # does not hold.
    private def applies_to?(entry_path : String, path : String) : Bool
      path == entry_path || path.starts_with?("#{entry_path}.")
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
