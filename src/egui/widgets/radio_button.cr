# Port of egui_upstream/crates/egui/src/widgets/radio_button.rs.
#
# Like Checkbox but with a round icon: outer ring + inner dot when
# selected. Selection state lives in app state; a click reports through
# `Response#changed?`.

module Egui
  class RadioButton
    include Widget

    def initialize(@selected : Bool, @text : String)
    end

    def ui(ui : Ui) : Response
      style = ui.style
      sp = style.spacing
      font_size = style.font_size
      text_size = ui.ctx.fonts.measure(@text, font_size)

      icon = sp.icon_width
      height = {icon, text_size.y}.max
      total_width = icon + sp.icon_spacing + text_size.x
      rect = ui.allocate_at_least(Vec2.new(total_width, height))
      id = ui.next_widget_id
      response = ui.interact(rect, id, Sense.click)

      visuals = style.visuals
      center = Pos2.new(rect.left + icon / 2.0, rect.center.y)
      ui.painter.circle_stroke(center, icon / 2.0,
        visuals.button_fill(response.hovered?, response.active?), 1.0)

      if @selected
        ui.painter.circle_filled(center, sp.icon_width_inner / 2.0,
          visuals.text_color)
      end

      text_pos = Pos2.new(rect.left + icon + sp.icon_spacing, rect.center.y)
      ui.painter.text(text_pos, @text, font_size, visuals.text_color)

      response.mark_changed if response.clicked? && !@selected
      response
    end
  end
end
