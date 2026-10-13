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

    def style_class : String?
      "separator"
    end

    def style_properties : Array(StyleProp)
      [StyleProp.new("separator_color", :color),
       StyleProp.new("stroke_width", :number, fallback: 1.0, min: 0.0)] +
        StyleProps.sizable
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      style = effective_style(ui, id)
      vars = style_vars(ui, id, nil)
      # The hairline's THICKNESS is `stroke_width` (the old `width`
      # spelling still reads through as a plain number — a unit length
      # there cannot, since `width` now means the layout width).
      width = vars.f64?("stroke_width") || vars.f64?("width") || 1.0
      size = if ui.layout.horizontal?
               Vec2.new(width, ui.available_height)
             else
               Vec2.new(ui.available_width, width)
             end
      # The layout axes go through the responsive size keys (`width`/
      # `min_width`/… — `%` of the region, vw/vh, rem): a vertical
      # separator stretches across the row, a horizontal one no
      # longer has to span the full panel.
      size = styled_size(size, vars, ui, id)

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
