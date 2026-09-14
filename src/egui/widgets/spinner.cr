# Port of egui_upstream/crates/egui/src/widgets/spinner.rs.
#
# A spinning arc: the rotation angle comes from input time (3 turns/s,
# like upstream), so it keeps animating — request_repaint each frame.

module Egui
  class Spinner
    include Widget

    def initialize(@size : Float64? = nil)
    end

    def ui(ui : Ui) : Response
      size = @size || ui.style.spacing.interact_size.y
      rect = ui.allocate_at_least(Vec2.new(size, size))
      id = ui.next_widget_id

      ui.ctx.request_repaint

      tau = 2.0 * Math::PI
      angle = (ui.ctx.input.time * tau / 3.0) % tau
      center = rect.center
      radius = size / 2.0 - 1.5
      ui.painter.arc(center, radius, angle, angle + tau * 0.3, 2.0,
        ui.style.visuals.text_color)

      ui.interact(rect, id, Sense.none)
    end
  end
end
