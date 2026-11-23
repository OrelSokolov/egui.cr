# Mobile Avatar (Material 3 avatar, phase 3 of
# plans/todo/mobile_widgets.md): a circle showing WHO is on screen.
#
# Two sources, one shape:
#   * initials — the first letters of the name's first two words,
#     uppercase, centered on a tinted disc (`Avatar.initials` is the
#     public rule so apps and the paint can't drift);
#   * texture — when `texture_id` is non-zero a loaded image is drawn
#     over the disc (tint + initials become the failed-load fallback,
#     mirroring `Image`'s zero-texture placeholder behavior).
#
# v1 honesty (documented limitation): the painter has no circular
# clip, so a texture renders as the square rect INSIDE the circle's
# bounding box, not masked to the disc. Initials avatars — the default
# — are true circles. A round-image clip needs backend support and is
# deliberately out of this phase.
#
# Styling — the `avatar` class:
#   size        (number, default 40 — the disc's diameter; the
#               constructor's `size:` argument beats the class)
#   background  (color, default visuals.selection_fill — the tint)
#   text_color  (color, default white)
#   font_size   (number, default size * 0.36 — two letters in a disc)

module Egui
  class Avatar
    include Widget

    def initialize(@name : String, @size : Float64 = 40.0,
                   @texture_id : UInt64 = 0, id : String? = nil)
      @id_name = id
    end

    def style_class : String?
      "avatar"
    end

    def style_properties : Array(StyleProp)
      [StyleProp.new("size", :number, fallback: 40.0, min: 0.0),
       StyleProp.new("background", :color),
       StyleProp.new("text_color", :color),
       StyleProp.new("font_size", :number, min: 0.0)]
    end

    def inspector_label : String?
      @name
    end

    # The initials rule: first letter of the first two words,
    # uppercased ("Гриша Иванов" → "ГИ", "cher" → "C"). Spaces split;
    # an empty name gives empty initials (the bare disc shows).
    def self.initials(name : String) : String
      parts = name.split(" ", remove_empty: true)
      letters = parts.first(2).compact_map do |p|
        p.empty? ? nil : p.chars[0].upcase.to_s
      end
      letters.join
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      vars = style_vars(ui, id)
      style = effective_style(ui, id, vars)
      visuals = style.visuals

      # The class `size` key beats the constructor's default (the
      # constructor value IS the fallback slot).
      size = vars.f64?("size") || @size
      rect = ui.allocate_at_least(Vec2.new(size, size))

      tint = vars.color("background", visuals.selection_fill)
      if !@texture_id.zero?
        ui.painter.image(rect, @texture_id)
      else
        ui.painter.circle_filled(rect.center, size / 2.0, tint)
        text = self.class.initials(@name)
        unless text.empty?
          font_size = vars.f64("font_size", size * 0.36)
          fonts = ui.ctx.fonts_for(style.font_family)
          tw = fonts.measure(text, font_size).x
          ui.painter.text(
            Pos2.new(rect.center.x - tw / 2.0, rect.center.y), text,
            font_size, vars.color("text_color",
              Color32.rgb(255, 255, 255)), family: style.font_family)
        end
      end

      ui.interact(rect, id, Sense.none)
    end
  end
end

# Ui sugar for the mobile widget set (see widgets/switch.cr — the
# class is reopened per phase file, `ui.cr` stays untouched).
class Egui::Ui
  # `ui.avatar("Гриша Иванов")` — initials on a tinted disc;
  # `ui.avatar("…", size: 48, texture_id: tex)` — a loaded image
  # (square inside the circle in v1 — see the class comment).
  def avatar(name : String, size : Float64 = 40.0,
             texture_id : UInt64 = 0, id : String? = nil) : Response
    add(Avatar.new(name, size, texture_id, id: id))
  end
end
