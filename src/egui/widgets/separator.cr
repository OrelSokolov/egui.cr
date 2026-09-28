# Port of egui_upstream/crates/egui/src/widgets/separator.rs.
#
# A hairline rule: horizontal in vertical layouts, vertical in
# horizontal ones (fills the remaining cross extent, like upstream
# reads `ui.available_size`).

module Egui
  class Separator
    include Widget

    def initialize(id : String? = nil)
      @id_name = id
    end

    def style_properties : Array(StyleProp)
      [StyleProp.new("separator_color", :color),
       StyleProp.new("width", :number)]
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      style = effective_style(ui, id)
      vars = style_vars(ui, id, nil)
      width = vars.f64("width", 1.0)
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
      ui.painter.line(p1, p2, width,
        vars.color("separator_color", style.visuals.separator_color))

      ui.interact(rect, id, Sense.none)
    end
  end
end
