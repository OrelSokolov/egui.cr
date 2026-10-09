# Port of egui_upstream/crates/egui/src/widgets/spinner.rs.
#
# A spinning arc: the rotation angle comes from input time (3 turns/s,
# like upstream), so it keeps animating — request_repaint each frame.

module Egui
  class Spinner
    include Widget

    def initialize(@size : Float64? = nil, id : String? = nil)
      @id_name = id
    end

    # Styled through the `spinner` class: `color`, `size`, `thickness`,
    # `arc_percent` keys (unset keys keep the defaults — the theme's
    # text color, the spacing's `interact_size.y`, the upstream stroke
    # 2.0, and the upstream 30%-of-circle arc span).
    def style_class : String?
      "spinner"
    end

    def style_properties : Array(StyleProp)
      [StyleProp.new("color", :color),
       StyleProp.new("size", :number, fallback: 18.0),
       StyleProp.new("thickness", :number, fallback: 2.0),
       StyleProp.new("arc_percent", :number, fallback: 30.0)]
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      style = effective_style(ui, id)
      vars = style_vars(ui, id)
      size = @size || vars.f64("size", style.spacing.interact_size.y)
      rect = ui.allocate_at_least(Vec2.new(size, size))

      ui.ctx.request_repaint

      tau = 2.0 * Math::PI
      angle = (ui.ctx.input.time * tau / 3.0) % tau
      center = rect.center
      radius = size / 2.0 - 1.5
      # Arc span as a percent of the circle, silently clamped to
      # 10..90 — a full 100 would look like a static ring, ~0 invisible.
      percent = vars.f64("arc_percent", 30.0).clamp(10.0, 90.0)
      ui.painter.arc(center, radius, angle, angle + tau * percent / 100.0,
        vars.f64("thickness", 2.0),
        vars.color("color", style.visuals.text_color))

      ui.interact(rect, id, Sense.none)
    end
  end
end
