# Mobile Badge (Material 3 badge / iOS app-badge, phase 3 of
# plans/todo/mobile_widgets.md): a small filled circle carrying a
# count, glued onto another widget's corner or standing alone.
#
# NOT the system badge of the app icon (system_ports/badge.cr) — this
# is the in-app element. The count caps at 99: anything larger renders
# as "99+" (Material's MAX_COUNT convention) so the dot never has to
# grow a pill tail for a runaway number — `Badge.label_for` is the
# single source of that rule (public, so apps/tests agree with the
# paint).
#
# Two placement modes share one paint path:
#   * standalone — a Widget in the flow (`ui.add(Badge.new(3))` /
#     `ui.badge(3)`), a `size`-side square;
#   * anchored — `ui.badge(3, on: icon_response.rect)` paints over the
#     anchor rect's corner (top-right by default, `align:` flips it)
#     WITHOUT touching the flow: no allocation, the parent's cursor
#     never advances. The dot is centered ON the corner, so it
#     overlaps the anchor like a Material notification dot.
# count <= 0 renders nothing in either mode (an empty badge is not a
# badge), still returning a dead response.
#
# v1 honesty: the anchored dot does not claim a hit target (it's a
# paint-over, taps pass through to the anchor widget) — badge counters
# are never tappable in this phase.
#
# Styling — the `badge` class:
#   size        (number, default 18 — the dot's diameter)
#   background  (color, default visuals.selection_fill — the accent dot)
#   text_color  (color, default white)
#   font_size   (number, default size * 0.5)

module Egui
  class Badge
    include Widget

    MAX_COUNT = 99

    def initialize(@count : Int32, id : String? = nil)
      @id_name = id
    end

    def style_class : String?
      "badge"
    end

    def style_properties : Array(StyleProp)
      [StyleProp.new("size", :number, fallback: 18.0, min: 0.0),
       StyleProp.new("background", :color),
       StyleProp.new("text_color", :color),
       StyleProp.new("font_size", :number, min: 0.0)]
    end

    def inspector_label : String?
      self.class.label_for(@count)
    end

    # The displayed count text: the 99+ cap (see the class comment).
    def self.label_for(count : Int32) : String
      count > MAX_COUNT ? "#{MAX_COUNT}+" : count.to_s
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      vars = style_vars(ui, id)
      return Response.container(ui.ctx, id, Rect.zero) if @count <= 0

      size = vars.f64("size", 18.0)
      rect = ui.allocate_at_least(Vec2.new(size, size))
      paint_dot(ui, rect, vars, id)
      Response.container(ui.ctx, id, rect)
    end

    # Anchored mode: paint over `anchor`'s corner (no allocation, no
    # interaction — see the class comment). Returns a dead container
    # response spanning the dot.
    def paint_at(ui : Ui, anchor : Rect, align : Symbol = :top_right) : Response
      id = resolve_id(ui)
      vars = style_vars(ui, id)
      return Response.container(ui.ctx, id, Rect.zero) if @count <= 0

      size = vars.f64("size", 18.0)
      cx = align.to_s.includes?("left") ? anchor.left : anchor.right
      cy = align.to_s.starts_with?("bottom") ? anchor.bottom : anchor.top
      rect = Rect.from_min_size(
        Pos2.new(cx - size / 2.0, cy - size / 2.0), Vec2.new(size, size))
      paint_dot(ui, rect, vars, id)
      Response.container(ui.ctx, id, rect)
    end

    # The dot itself: filled circle + centered count text.
    private def paint_dot(ui : Ui, rect : Rect, vars : StyleVars,
                          id : Id) : Nil
      style = effective_style(ui, id, vars)
      visuals = style.visuals
      size = rect.width
      font_size = vars.f64("font_size", size * 0.5)
      text = self.class.label_for(@count)
      fonts = ui.ctx.fonts_for(style.font_family)
      tw = fonts.measure(text, font_size).x

      ui.painter.circle_filled(rect.center, size / 2.0,
        vars.color("background", visuals.selection_fill))
      ui.painter.text(
        Pos2.new(rect.center.x - tw / 2.0, rect.center.y), text,
        font_size, vars.color("text_color", Color32.rgb(255, 255, 255)),
        family: style.font_family)
    end
  end
end

# Ui sugar for the mobile widget set (see widgets/switch.cr — the
# class is reopened per phase file, `ui.cr` stays untouched).
class Egui::Ui
  # `ui.badge(3)` — a standalone count dot in the flow;
  # `ui.badge(3, on: icon.rect)` — a dot glued onto that rect's
  # `align:` corner (:top_right default, also :top_left/:bottom_left/
  # :bottom_right), the flow untouched. count <= 0 draws nothing.
  def badge(count : Int32, on : Rect? = nil,
            align : Symbol = :top_right, id : String? = nil) : Response
    b = Badge.new(count, id: id)
    on ? b.paint_at(self, on, align) : add(b)
  end
end
