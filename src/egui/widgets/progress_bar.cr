# Port of egui_upstream/crates/egui/src/widgets/progress_bar.rs.
#
# Fills the available width with a rounded track + a fraction fill.
# With `animate` on, the fill eases towards the target via
# `Context#animate_value_with_time` (upstream animates on decrease).

module Egui
  class ProgressBar
    include Widget

    def initialize(@fraction : Float64, @text : String? = nil,
                   @animate : Bool = false)
    end

    def ui(ui : Ui) : Response
      style = effective_style(ui)
      # Not tied to interact_size (that floor is for buttons/controls
      # and grew in the GTK-proportioned defaults) — a slim bar at
      # 1.5 text lines, like the pre-bump sizing.
      height = style.font_size * 1.5
      size = Vec2.new(ui.available_width, height)
      rect = ui.allocate_at_least(size)
      id = ui.next_widget_id

      fraction = @fraction.clamp(0.0, 1.0)
      fraction = ui.ctx.animate_value_with_time(id, fraction, 0.3) if @animate

      visuals = style.visuals
      ui.painter.rect(rect, 4.0, visuals.button_weak,
        visuals.border_color, 1.0)
      if fraction > 0.0
        fill_rect = Rect.from_min_size(rect.min,
          Vec2.new(fraction * rect.width, rect.height))
        ui.painter.rect(fill_rect, 4.0, visuals.selection_fill)
      end

      if text = @text
        text_size = ui.ctx.fonts.measure(text, style.font_size)
        text_pos = Pos2.new(rect.center.x - text_size.x / 2.0, rect.center.y)
        ui.painter.text(text_pos, text, style.font_size, visuals.text_color)
      end

      ui.interact(rect, id, Sense.none)
    end
  end
end
