# Port of egui_upstream/crates/egui/src/widgets/button.rs.
#
# Upstream `Button::ui` in five moves, kept in the same order here:
#   1. sense = Sense::click()
#   2. size = text size + 2 * button_padding
#   3. (rect, response) = ui.allocate_at_least(size)
#   4. re-interact: ui.interact(rect, id, sense)
#   5. paint: bg rect (state-colored) + centered text; return response

module Egui
  class Button
    include Widget

    getter text : String

    def initialize(@text : String)
    end

    def ui(ui : Ui) : Response
      sense = Sense.click

      size = ui.ctx.fonts.measure(@text, ui.style.font_size) +
             ui.style.spacing.button_padding * 2.0

      rect = ui.allocate_at_least(size)
      id = ui.next_widget_id
      response = ui.interact(rect, id, sense)

      fill = ui.style.visuals.button_fill(response.hovered?, response.active?)
      ui.painter.rect(rect, rounding: 4.0, fill: fill,
        stroke_color: ui.style.visuals.button_stroke, stroke_width: 1.0)

      text_size = ui.ctx.fonts.measure(@text, ui.style.font_size)
      pad_x = ui.style.spacing.button_padding.x
      pos = Pos2.new(rect.left + pad_x +
                     ((rect.width - 2 * pad_x - text_size.x).clamp(0.0, Float64::MAX)) / 2.0,
        rect.center.y)
      ui.painter.text(pos, @text, ui.style.font_size,
        ui.style.visuals.text_color)

      response
    end
  end
end
