# Port of egui_upstream/crates/egui/src/widgets/checkbox.rs.
#
# A toggle backed by app state: the widget reads `checked`, paints icon
# + label, and reports the toggle through `Response#changed?` (the Ui#
# checkbox block form hands the new value back).

module Egui
  class Checkbox
    include Widget

    def initialize(@checked : Bool, @text : String)
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
      response = ui.interact(rect, id, Sense.click | Sense::Focusable)

      visuals = style.visuals
      icon_rect = Rect.from_min_size(
        Pos2.new(rect.left, rect.center.y - icon / 2.0),
        Vec2.new(icon, icon))
      ui.painter.rect(icon_rect, 3.0,
        visuals.button_fill(response.hovered?, response.active?),
        visuals.button_stroke, 1.0)

      if @checked
        # A two-segment checkmark (upstream draws a font glyph; we use
        # the phase-0 line primitive).
        c = icon_rect.min
        w = icon_rect.width
        h = icon_rect.height
        corner = Pos2.new(c.x + 0.26 * w, c.y + 0.52 * h)
        elbow = Pos2.new(c.x + 0.45 * w, c.y + 0.72 * h)
        tip = Pos2.new(c.x + 0.78 * w, c.y + 0.26 * h)
        ui.painter.line(corner, elbow, 2.0, visuals.text_color)
        ui.painter.line(elbow, tip, 2.0, visuals.text_color)
      end

      text_pos = Pos2.new(icon_rect.right + sp.icon_spacing, rect.center.y)
      ui.painter.text(text_pos, @text, font_size, visuals.text_color)

      response.paint_focus_ring(9.0)
      response.mark_changed if response.clicked?
      response
    end
  end
end
