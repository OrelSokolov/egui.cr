# Port of egui `Widget` trait (egui_upstream/crates/egui/src/ui.rs:
# `pub trait Widget { fn ui(self, ui: &mut Ui) -> Response; }`).
#
# In Crystal this is a module with an abstract method; `Ui#add`
# (`ui.add(widget)` upstream) dispatches through it.
#
# The module also carries the styling and identity plumbing shared by
# every widget:
#
# * identity — an optional explicit id (`Button.new("OK", id: "save")`
#   or `.with_id("save")`), claimed per frame (a duplicate raises
#   `Egui::DuplicateWidgetIdError`); without one the widget keeps its
#   stable hierarchy-derived auto id (displayed as a random-looking
#   6-char name, `Id#short_label` — every widget HAS an id, so the
#   inspector can address any of them);
# * style — `#style` collects a `WidgetStyle` (nilable fields — nil =
#   inherit the theme), `effective_style` runs the full cascade
#   theme → class rules → inline `#style` → per-element inspector
#   override, and `#background_color` resolves the state-scoped
#   `background` key (element → inline → class → theme slots);
# * introspection — `#style_properties` declares which `StyleVars`
#   keys the widget actually reads; the inspector (and nothing else)
#   builds its editors from these declarations. An empty list means
#   "this widget reads no style keys".

module Egui
  module Widget
    abstract def ui(ui : Ui) : Response

    @style_override : WidgetStyle?
    @id_name : String?
    @part_name : String?

    # Give the widget an explicit id (builder form of the `id:`
    # constructor parameter). Explicit ids are claimed once per frame —
    # a second widget claiming the same name raises.
    def with_id(name : String) : self
      @id_name = name
      self
    end

    # The explicit id name, if the widget was given one (nil = auto id).
    def id_name : String?
      @id_name
    end

    # CSS-like class this widget styles under in the global
    # `StyleSheet` (nil = not registered yet). Widgets adopt the class
    # system gradually; see `Button` and `containers/sidebar.cr` for
    # the reference wiring (base + state overlays).
    def style_class : String?
      nil
    end

    # The stylable properties of THIS widget kind: the `StyleVars`
    # keys its `#ui` actually reads, declared here — not hardcoded in
    # the inspector. `StyleProps.textlike` / `.buttonlike` provide the
    # common sets. An empty list (the default) means the widget reads
    # no style keys and the inspector shows it as non-stylable.
    def style_properties : Array(StyleProp)
      [] of StyleProp
    end

    # Short human label for the inspector (the button's text, a
    # label's text…); nil = no meaningful label.
    def inspector_label : String?
      nil
    end

    # The kind name shown in the inspector («Button», «Tab»…) — the
    # class name by default; `StyledPart` stand-ins override it with
    # their site-specific kind.
    def inspector_kind : String
      {{ @type.name.split("::").last }}
    end

    # Customize this widget's style; nil fields keep the theme value:
    #
    #   Button.new("OK").style { |s| s.fill = Color32.rgb(180, 40, 40) }
    def style(& : WidgetStyle ->) : self
      ws = (@style_override ||= WidgetStyle.new)
      yield ws
      self
    end

    # Name this widget's slot inside its container's style scope (see
    # `Ui#with_style_scope`): inside scope "sidebar" a
    # `Button.new("✕").part("close")` styles under BOTH "button" and
    # "sidebar.close" (a nameless widget uses its base class name:
    # "sidebar.button"). The scoped path is more specific and wins
    # per key.
    def part(name : String) : self
      @part_name = name
      self
    end

    # The widget's id for this frame: the explicit one (claimed — a
    # duplicate raises) or the stable auto id. Widgets call this
    # instead of `ui.next_widget_id` directly.
    protected def resolve_id(ui : Ui) : Id
      if (name = @id_name)
        id = Id.from(name)
        ui.ctx.claim_widget_id(id, name, self.class.name)
        id
      else
        ui.next_widget_id
      end
    end

    # The class paths this widget styles under, least specific first:
    # the base `style_class` plus — inside a style scope
    # (`Ui#with_style_scope`) — the scoped path "{scope}.{part}"
    # ("button" → ["button", "sidebar.button"]). `#part` names the
    # scope segment explicitly; nil uses the base class name. Empty
    # when the widget has no class at all.
    protected def class_paths(scope : String?) : Array(String)
      base = style_class
      part = @part_name || base
      paths = [] of String
      paths << base if base
      if scope && !scope.empty? && part
        scoped = "#{scope}.#{part}"
        paths << scoped unless paths.includes?(scoped)
      end
      paths
    end

    # The widget's live class chain (base + scoped path) for the
    # inspector meta — reads the Context's scope mirror because
    # paint-in-place parts have no Ui at record time (the mirror is
    # kept equal to the Ui's scope by `Ui#with_style_scope`).
    def style_classes(ctx : Context) : Array(String)
      class_paths(ctx.current_style_scope)
    end

    # The merged raw-key vars of this widget's class chain (#
    # class_paths) with the optional state overlay and the per-element
    # inspector override merged ON TOP (into a copy — the sheet's
    # resolved bags are shared caches, read-only; the element layer is
    # state-keyed, base keys under the state overlay). Without an
    # override the cached shared bag comes back as-is, so widgets pay
    # nothing extra until the inspector actually touches them. Widgets
    # read their raw keys (`padding`, `rounding`, `shadow.*`, …)
    # through here — the chain (base class + style scope) is derived,
    # never hardcoded at the call site.
    protected def style_vars(ui : Ui, id : Id, state : String? = nil) : StyleVars
      vars_for(ui, id, class_paths(ui.style_scope), state)
    end

    # Explicit-path variant for sites that resolve one known class
    # path (a container's own root keys) — same per-element layer on
    # top as #style_vars.
    protected def style_vars_for(ui : Ui, id : Id, class_path : String?,
                                 state : String? = nil) : StyleVars
      vars_for(ui, id, class_path ? [class_path] : [] of String, state)
    end

    private def vars_for(ui : Ui, id : Id, paths : Array(String),
                         state : String?) : StyleVars
      # Touch devices have no hover (Этап 6 of
      # plans/responsive-mobile.md): `:hover` overlays read as the
      # base state, so a finger tap leaves no stuck highlight.
      state = nil if state == "hover" && ui.ctx.pointer_coarse?
      bag = case paths.size
            when 0 then StyleVars.new
            when 1 then ui.ctx.stylesheet.resolve(paths.first, state)
            else        ui.ctx.stylesheet.resolve_chain(paths, state)
            end
      if (ov = ui.ctx.id_style_state_vars(id, state))
        merged = StyleVars.new
        merged.merge!(bag)
        merged.merge!(ov)
        merged
      else
        bag
      end
    end

    # Style-driven sizing (plans/responsive-mobile.md Этап 2): apply
    # the cascade's `width`/`min_width`/`max_width` (and the height
    # trio) to the widget's natural size. `width` overrides the axis
    # (content still centers inside), `min_*` floors, `max_*` caps;
    # values resolve through `StyleVars#length_px` — plain numbers are
    # points, `%` is the containing Ui, `vw/vh/vmin/vmax` the viewport,
    # `rem` the root font. Returns `natural` unchanged when no size
    # key is set; percent heights in unbounded regions stay unset (the
    # natural size applies). The allocation max-size rule clamps the
    # result to the region, so an oversized percent can never push
    # past the parent.
    protected def styled_size(natural : Vec2, vars : StyleVars,
                              ui : Ui, id : Id? = nil) : Vec2
      Vec2.new(
        styled_axis(natural.x, vars, ui, :x, id),
        styled_axis(natural.y, vars, ui, :y, id))
    end

    private def styled_axis(natural : Float64, vars : StyleVars, ui : Ui,
                            axis : Symbol, id : Id?) : Float64
      key = axis == :x ? "width" : "height"
      if (target = vars.length_px?(key, ui, axis))
        # An EXPLICIT size key: animate towards the new target when a
        # `transition` is declared (natural-size changes never
        # animate — CSS semantics; only declared properties do).
        v = id ? transition_scalar(key, target, vars, ui, id) : target
      else
        v = natural
      end
      if (mn = vars.length_px?("min_#{key}", ui, axis))
        v = {v, mn}.max
      end
      if (mx = vars.length_px?("max_#{key}", ui, axis))
        v = {v, mx}.min
      end
      v
    end

    # The class vars of this widget (class chain + element override),
    # sized with #styled_size — the one-liner first-wave widgets call
    # right before allocating.
    protected def styled_size(natural : Vec2, ui : Ui, id : Id) : Vec2
      styled_size(natural, style_vars(ui, id), ui, id)
    end

    # --- cascade transitions (plans/animations.md Ур.1) --------------
    #
    # `transition.<key>: <ms>` (or the `transition: <ms>` shorthand
    # for every key) animates a style value towards its new cascade
    # target. Duration in milliseconds; absent/0 = snap.

    # The declared transition duration for `key` in milliseconds
    # (0.0 = not transitioned). Per-key beats the shorthand.
    protected def transition_ms?(key : String, vars : StyleVars) : Float64
      (vars.f64?("transition.#{key}") || vars.f64?("transition") ||
       0.0).clamp(0.0, 10_000.0)
    end

    # The named easing curve for `key` (`easing.<key>` beats the
    # `easing` shorthand; nil = smoothstep). Values are quoted
    # strings: `easing.background: "ease-out"`.
    protected def transition_easing?(key : String, vars : StyleVars) : String?
      vars.str?("easing.#{key}") || vars.str?("easing")
    end

    protected def transition_color(key : String, target : Color32,
                                   vars : StyleVars, ui : Ui,
                                   id : Id) : Color32
      ui.ctx.animate_style_color(id, key, target, transition_ms?(key, vars),
        transition_easing?(key, vars))
    end

    protected def transition_scalar(key : String, target : Float64,
                                     vars : StyleVars, ui : Ui,
                                     id : Id) : Float64
      ui.ctx.animate_style_scalar(id, key, target, transition_ms?(key, vars),
        transition_easing?(key, vars))
    end

    # The CSS-like `background` of a state-painted widget, resolved
    # from its live interaction `state` ("active"/"hover"/nil) through
    # the cascade — one key, no per-state duplicates:
    #
    #   1. per-element inspector override (state value over base);
    #   2. the inline `#style` background (flat — inline-style
    #      semantics, CSS `style="background: …"`);
    #   3. the class chain's rules (`StyleSheet#resolve_chain`) — a
    #      `:hover`/`:active` rule beats the class base value, a
    #      scoped path beats the base class;
    #   4. the theme's state slots (`Visuals#button_fill`) — the
    #      user-agent default with built-in per-state colors.
    protected def background_color(ui : Ui, id : Id, state : String?,
                                   hovered : Bool, active : Bool) : Color32
      paths = class_paths(ui.style_scope)
      c = if (oc = ui.ctx.id_style_state_vars(id, state).try(&.color?("background")))
        oc
      elsif (ic = @style_override.try(&.background))
        ic
      elsif !paths.empty? &&
           (cc = ui.ctx.stylesheet.resolve_chain(paths, state).color?("background"))
        cc
      else
        nil
      end
      target = c || ui.style.visuals.button_fill(hovered, active)
      # `transition`/`transition.background` animates the fill towards
      # its new cascade target (duration in ms; absent = snap). The
      # duration rides the same state-aware bags the value came from.
      if c && !paths.empty?
        vars = ui.ctx.stylesheet.resolve_chain(paths, state)
        if (ov = ui.ctx.id_style_state_vars(id, state))
          merged = StyleVars.new
          merged.merge!(vars)
          merged.merge!(ov)
          vars = merged
        end
        return transition_color("background", target, vars, ui, id)
      end
      target
    end

    # The effective Style with the full cascade applied:
    # theme → class rules (`class_vars`) → this widget's `#style`
    # overrides → the inspector's per-element override (`id`,
    # `Context#id_style_overrides` — base keys only here; the
    # state-scoped `background` goes through #background_color).
    # Every layer is a copy — the theme is never mutated; widgets
    # without any layer share the theme object itself, no per-widget
    # copying.
    protected def effective_style(ui : Ui, id : Id? = nil,
                                  class_vars : StyleVars? = nil) : Style
      base = ui.style
      if class_vars && !class_vars.empty?
        base = class_vars.apply_over(base)
      end
      if (ws = @style_override)
        base = ws.merge_over(base)
      end
      if id && (ov = ui.ctx.id_style_state_vars(id, nil))
        base = ov.apply_over(base)
      else
        base
      end
    end
  end
end
