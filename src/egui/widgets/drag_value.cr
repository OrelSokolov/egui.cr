# Port of egui_upstream/crates/egui/src/widgets/drag_value.rs
# (pointer-drag part; keyboard typing lands with phase 3).
#
# Drag horizontally (or vertically) to change the value by
# `speed` per point. Displays the value as a label.

module Egui
  class DragValue
    include Widget

    def initialize(@value : Float64, @speed : Float64 = 1.0,
                   @prefix : String = "", @suffix : String = "")
    end

    def ui(ui : Ui) : Response
      style = ui.style
      font_size = style.font_size
      text = "#{@prefix}#{Slider.format_value(@value)}#{@suffix}"
      text_size = ui.ctx.fonts.measure(text, font_size)

      size = Vec2.new(
        {text_size.x, style.spacing.interact_size.x}.max,
        {text_size.y, style.spacing.interact_size.y}.max)
      rect = ui.allocate_at_least(size)
      id = ui.next_widget_id
      response = ui.interact(rect, id, Sense.click_and_drag)

      new_value = @value
      if response.dragged?
        new_value += (response.drag_delta.x - response.drag_delta.y) * @speed
      end

      visuals = style.visuals
      bg = if response.dragged?
        visuals.button_active
      elsif response.hovered?
        visuals.button_hovered
      else
        nil # plain label look until touched (upstream shows a weak bg too)
      end
      ui.painter.rect(rect, 3.0, bg, visuals.button_stroke, 1.0) if bg

      ui.painter.text(rect.left_center, text, font_size, visuals.text_color)

      response.widget_value = new_value
      response.mark_changed if new_value != @value
      response
    end
  end
end
