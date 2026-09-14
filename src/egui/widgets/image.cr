# Port of egui_upstream/crates/egui/src/widgets/image.rs.
#
# An `Image` shows a texture (from Context#load_image or
# TextureRegistry#register_rgba) fitted into a rect, optionally tinted.

module Egui
  class Image
    include Widget

    def initialize(@texture_id : UInt64, @size : Vec2,
                   @tint : Color32 = Color32.new(255, 255, 255, 255))
    end

    def ui(ui : Ui) : Response
      rect = ui.allocate_at_least(@size)
      id = ui.next_widget_id

      unless @texture_id.zero?
        ui.painter.image(rect, @texture_id, tint: @tint)
      else
        # failed load: placeholder checker
        visuals = ui.style.visuals
        ui.painter.rect(rect, 3.0, visuals.button_weak)
      end

      ui.interact(rect, id, Sense.none)
    end
  end
end
