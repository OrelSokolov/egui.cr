# Port of egui_upstream/crates/egui/src/containers/collapsing_header.rs.
#
# The canonical demonstration of system state: the open/closed flag
# lives in `Memory#data` (IdTypeMap) keyed by the header's id — so it
# survives frames where the collapsed body (and even the whole header)
# is not created, and the app never holds it.

module Egui
  class CollapsingHeader
    def initialize(@text : String, @default_open : Bool = false)
    end

    def show(ui : Ui, &block : Ui ->) : Response
      id = ui.next_widget_id
      open = ui.ctx.memory.data.get_bool(id, @default_open)

      line_h = ui.style.font_size * Fonts::LINE_H_FACTOR
      rect = ui.allocate_at_least(Vec2.new(ui.max_rect.width, line_h))
      response = ui.interact(rect, id, Sense.click)

      v = ui.style.visuals
      arrow = open ? "▾" : "▸"
      ui.painter.text(Pos2.new(rect.min.x + 2.0, rect.center.y),
        arrow, ui.style.font_size, v.text_color)
      ui.painter.text(Pos2.new(rect.min.x + 20.0, rect.center.y),
        @text, ui.style.font_size, v.text_color)
      ui.painter.rect(
        Rect.from_min_size(Pos2.new(rect.min.x, rect.max.y - 1.0),
          Vec2.new(rect.width, 1.0)),
        fill: v.border_color)

      if response.clicked?
        open = !open
        ui.ctx.memory.data.set_bool(id, open)
        ui.ctx.request_repaint
      end

      if open
        indent = ui.style.spacing.indent
        origin = ui.cursor + Vec2.new(indent, 0.0)
        body = ui.child_ui(
          Rect.from_min_size(origin,
            Vec2.new(ui.max_rect.width - indent, 1e6)),
          id.child(0xFFFF_u64))
        yield body
        ui.min_rect = ui.min_rect.union(body.min_rect)
        ui.cursor = Pos2.new(ui.max_rect.min.x,
          body.min_rect.bottom + ui.style.spacing.item_spacing.y)
      end

      response
    end
  end
end
