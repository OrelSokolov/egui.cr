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
#   theme → class rules → state overlay → inline `#style` →
#   per-element inspector override;
# * introspection — `#style_properties` declares which `StyleVars`
#   keys the widget actually reads; the inspector (and nothing else)
#   builds its editors from these declarations. An empty list means
#   "this widget reads no style keys".

module Egui
  module Widget
    abstract def ui(ui : Ui) : Response

    @style_override : WidgetStyle?
    @id_name : String?

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

    # Customize this widget's style; nil fields keep the theme value:
    #
    #   Button.new("OK").style { |s| s.fill = Color32.rgb(180, 40, 40) }
    def style(& : WidgetStyle ->) : self
      ws = (@style_override ||= WidgetStyle.new)
      yield ws
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

    # The merged raw-key vars for `class_path` (+ optional state
    # overlay): `StyleSheet#resolve` with this widget's per-element
    # inspector override merged ON TOP (into a copy — the sheet's
    # resolved bags are shared caches, read-only). Without an override
    # this is the shared cache itself, so widgets pay nothing extra
    # until the inspector actually touches them. Widgets read their
    # raw keys (`padding`, `rounding`, `shadow.*`, …) through here —
    # reading `resolve` directly would hide the per-element layer.
    protected def style_vars(ui : Ui, id : Id, class_path : String?,
                             state : String? = nil) : StyleVars
      return StyleVars.new unless class_path
      vars = ui.ctx.stylesheet.resolve(class_path, state)
      if (ov = ui.ctx.id_style_overrides[id]?)
        merged = StyleVars.new
        merged.merge!(vars)
        merged.merge!(ov)
        merged
      else
        vars
      end
    end

    # The effective Style with the full cascade applied:
    # theme → class rules (`class_vars`) → class state overlay
    # (`state`, resolved through #style_class) → this widget's `#style`
    # overrides → the inspector's per-element override (`id`,
    # `Context#id_style_overrides`). Every layer is a copy — the theme
    # is never mutated; widgets without any layer share the theme
    # object itself, no per-widget copying.
    #
    # The per-element layer sits ABOVE inline `#style` on purpose: a
    # debug tool must see its own edits even on widgets whose code
    # sets overrides. It maps with `state: nil` (CSS inline-style
    # semantics — `fill` lands on the base slot, pseudo-classes keep
    # their own `fill_hovered`/`fill_active` keys).
    protected def effective_style(ui : Ui, id : Id? = nil,
                                  class_vars : StyleVars? = nil,
                                  state : String? = nil) : Style
      base = ui.style
      if class_vars && !class_vars.empty?
        base = class_vars.apply_over(base)
      end
      if state && (path = style_class) &&
         (overlay = ui.ctx.stylesheet.state_vars(path, state)) &&
         !overlay.empty?
        base = overlay.apply_over(base, state)
      end
      if (ws = @style_override)
        base = ws.merge_over(base)
      end
      if id && (ov = ui.ctx.id_style_overrides[id]?)
        base = ov.apply_over(base)
      else
        base
      end
    end
  end
end
