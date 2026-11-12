# A color swatch button — the NSColorWell look: a small rounded
# rectangle filled with the color, hairline border, click-reporting
# like any button. The editor itself is not baked in — `ui.color_edit32`
# is the inline SV/hue editor; a host can open one (or an overlay) from
# the clicked response.
#
#   if ui.add(Egui::ColorButton.new(@color)).clicked?
#     open_color_editor
#   end
#
# Restyled under the `color_well` class: `rounding`, `stroke` and the
# responsive sizing keys — the fill IS the color, so there is no fill
# key to fight it. macOS metrics (the native 44×23 well) live in
# `MacOsTheme`, the defaults stay a modest generic swatch.

module Egui
  class ColorButton
    include Widget

    def initialize(color : Color32, id : String? = nil)
      @color = color
      @id_name = id
    end

    def style_class : String?
      "color_well"
    end

    def style_properties : Array(StyleProp)
      [StyleProp.new("rounding", :number, fallback: 4.0, min: 0.0),
       StyleProp.new("stroke", :color)] + StyleProps.sizable
    end

    def inspector_label : String?
      "color well"
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      vars = style_vars(ui, id)
      size = styled_size(Vec2.new(24.0, 16.0), vars, ui, id)
      rect = ui.allocate_at_least(size)
      ui.painter.rect(rect, vars.f64?("rounding") || 4.0, @color,
        vars.color?("stroke") || ui.style.visuals.button_stroke, 1.0)
      ui.interact(rect, id, Sense.click)
    end
  end
end
