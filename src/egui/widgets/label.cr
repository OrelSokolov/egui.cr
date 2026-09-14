# Port of egui_upstream/crates/egui/src/widgets/label.rs.
#
# A Label reserves its text size, paints the text left-center, and
# returns a (non-clickable) Response — upstream `Sense::hover()`.

module Egui
  class Label
    include Widget

    getter text : String
    getter size : Float64?

    def initialize(@text : String, @size : Float64? = nil)
    end

    def ui(ui : Ui) : Response
      size = @size || ui.style.font_size
      text_size = ui.ctx.fonts.measure(@text, size)

      rect = ui.allocate_at_least(text_size)
      id = ui.next_widget_id
      ui.painter.text(rect.left_center, @text, size,
        ui.style.visuals.text_color)

      ui.interact(rect, id, Sense.none)
    end
  end
end
