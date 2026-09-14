# Port of egui_upstream/crates/egui/src/widgets/separator.rs.
#
# A hairline rule: horizontal in vertical layouts, vertical in
# horizontal ones (fills the remaining cross extent, like upstream
# reads `ui.available_size`).

module Egui
  class Separator
    include Widget

    def ui(ui : Ui) : Response
      style = ui.style
      width = 1.0
      size = if ui.layout.horizontal?
               Vec2.new(width, ui.available_height)
             else
               Vec2.new(ui.available_width, width)
             end

      rect = ui.allocate_at_least(size)
      center = rect.center
      if ui.layout.horizontal?
        p1 = Pos2.new(center.x, rect.top)
        p2 = Pos2.new(center.x, rect.bottom)
      else
        p1 = Pos2.new(rect.left, center.y)
        p2 = Pos2.new(rect.right, center.y)
      end
      ui.painter.line(p1, p2, width, style.visuals.separator_color)

      ui.interact(rect, ui.next_widget_id, Sense.none)
    end
  end
end
