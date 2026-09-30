# `StyledPart` — a meta-only Widget stand-in for UI painted in place
# (menu rows, title-bar tab cards): code that calls `ctx.interact` /
# `ui.interact` directly with painter calls instead of living through
# `Ui#add`. Without a Widget instance the inspector records NO meta for
# those interacts — the widget is unpickable and shows nothing to edit.
#
# A StyledPart carries exactly what the inspector needs (kind, style
# class, property declarations, label) plus public cascade readers so
# the site reads its keys through the SAME layers real widgets use
# (class rules + per-element inspector overrides — `Widget#style_vars`
# is protected, so the readers live here on the part itself):
#
#   part = TabPart.new(title)
#   ctx.with_inspector_widget(part) { ctx.interact(id, rect, Sense.click) }
#   vars = part.vars(ctx, id)              # class + per-id override
#   hover = part.vars(ctx, id, "hover")    # … with the state overlay
module Egui
  class StyledPart
    include Widget

    def initialize(@kind : String, @style_class : String?,
                   @props : Array(StyleProp), @label : String? = nil)
    end

    # StyledParts never run through `Ui#add` — they only describe a
    # paint-in-place site. Hitting this is a wiring bug.
    def ui(ui : Ui) : Response
      raise "#{@kind} is a paint-in-place part — no #ui"
    end

    def style_class : String?
      @style_class
    end

    def style_properties : Array(StyleProp)
      @props
    end

    def inspector_kind : String
      @kind
    end

    def inspector_label : String?
      @label
    end

    # The merged vars for this part's class (+ optional state overlay)
    # with the per-element inspector override on top — the public face
    # of `Widget#style_vars` for paint-in-place sites.
    def vars(ctx : Context, id : Id, state : String? = nil) : StyleVars
      class_vars = @style_class ?
        ctx.stylesheet.resolve(@style_class.not_nil!, state) : StyleVars.new
      if (ov = ctx.id_style_state_vars(id, state))
        merged = StyleVars.new
        merged.merge!(class_vars)
        merged.merge!(ov)
        merged
      else
        class_vars
      end
    end

    def vars(ui : Ui, id : Id, state : String? = nil) : StyleVars
      vars(ui.ctx, id, state)
    end
  end
end
