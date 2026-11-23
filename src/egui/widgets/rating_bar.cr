# Mobile rating bar (Material `RatingBar`) — plans/todo/mobile_widgets.md #20.
#
# A row of `count` five-point stars drawn DIRECTLY through the painter
# as a triangle fan (center → star outline vertices): `icons.cr` has no
# star glyph and none is invented — the geometry IS the widget. The
# fan paints filled stars; unfilled ones paint in the muted base color,
# a half-value paints only the angular left half of the fan (the
# triangles whose span sits between 90° and 270° screen angle — an
# exact left half for the default geometry since the top point lies on
# the vertical axis).
#
# Interaction: tap a star to rate. `step: 1.0` (default) rates the
# tapped star; `step: 0.5` taps the LEFT half of a star for the half
# value, the right half for the full one. Anything else is rejected at
# construction — half-star painting is built for the 0.5 grid and
# pretending otherwise would silently lie. Hover is not previewed in
# v1 (the rating is the app's state; a preview would need either a
# transient memory cell or app-side hover plumbing — deliberately
# deferred).
#
# Reporting: `Response#changed?` + `Response#widget_value` = the new
# rating (the `ui.rating_bar` block receives it the same way).
#
# Styling — the `rating_bar` class: `star_size` (28), `gap` (4),
# `fill_color` (rated stars; default selection_fill), `base_color`
# (unrated; the fill faded to 40%).

module Egui
  class RatingBar
    include Widget

    HANDLE_GAP = 4.0
    STAR_SIZE  = 28.0
    # Inner radius of the star's concave vertices, as a fraction of the
    # outer radius (the classic pentagram ratio range; 0.45 reads as a
    # friendly Material star at 28pt).
    INNER_RATIO = 0.45

    def initialize(@value : Float64, @count : Int32 = 5,
                   @step : Float64 = 1.0, id : String? = nil)
      @id_name = id
      unless @step == 1.0 || @step == 0.5
        raise ArgumentError.new(
          "RatingBar step: #{@step} (only 1.0 and 0.5 are supported — " +
          "the half-star paint is built for that grid)")
      end
      @value = @value.clamp(0.0, @count.to_f64)
    end

    def style_class : String?
      "rating_bar"
    end

    def style_properties : Array(StyleProp)
      [
        StyleProp.new("star_size", :number, min: 0.0),
        StyleProp.new("gap", :number, min: 0.0),
        StyleProp.new("fill_color", :color),
        StyleProp.new("base_color", :color),
      ]
    end

    def inspector_label : String?
      @value.to_s
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      class_vars = style_vars(ui, id)
      style = effective_style(ui, id, class_vars)
      visuals = style.visuals

      star = class_vars.f64("star_size", STAR_SIZE)
      gap = class_vars.f64("gap", HANDLE_GAP)
      natural = Vec2.new(@count * star + (@count - 1) * gap, star)
      size = styled_size(natural, class_vars, ui, id)
      rect = ui.allocate_at_least(size)
      response = ui.interact(rect, id, Sense.click)

      # Tap → rating: the tapped star's index, then the in-star half
      # when stepping by 0.5.
      value = @value
      if response.clicked? && (pointer = ui.ctx.input.pointer_pos)
        i = ((pointer.x - rect.left) / (star + gap)).to_i32.clamp(0, @count - 1)
        if @step == 0.5
          star_left = rect.left + i * (star + gap)
          value = i.to_f64 + (pointer.x - star_left >= star / 2.0 ? 1.0 : 0.5)
        else
          value = i.to_f64 + 1.0
        end
        value = value.clamp(0.0, @count.to_f64)
      end

      fill_color = class_vars.color("fill_color", visuals.selection_fill)
      base_color = class_vars.color("base_color",
        visuals.fade_color(fill_color, 0.4))
      scale = size.x / natural.x
      r = star * scale / 2.0
      cell_step = (star + gap) * scale
      @count.times do |i|
        center = Pos2.new(
          rect.left + i * cell_step + star * scale / 2.0, rect.center.y)
        amount = (value - i).clamp(0.0, 1.0)
        paint_star(ui.painter, center, r, base_color)
        if amount >= 1.0
          paint_star(ui.painter, center, r, fill_color)
        elsif amount > 0.0
          paint_star(ui.painter, center, r, fill_color, half: true)
        end
      end

      response.widget_value = value
      response.mark_changed if value != @value
      response
    end

    # One five-point star as a triangle fan: 10 outline vertices
    # alternating outer/inner every 36°, starting at the top (-90°).
    # `half` keeps only the triangles whose angular midpoint lies in
    # the left half (90°..270° screen angle) — the 0.5-step paint.
    private def paint_star(painter : Painter, center : Pos2, r : Float64,
                           color : Color32, half : Bool = false) : Nil
      tau = 2.0 * Math::PI
      verts = StaticArray(Pos2, 10).new do |k|
        a = -Math::PI / 2.0 + k * tau / 10.0
        rad = k.even? ? r : r * INNER_RATIO
        Pos2.new(center.x + Math.cos(a) * rad, center.y + Math.sin(a) * rad)
      end
      10.times do |k|
        if half
          mid = (-Math::PI / 2.0 + (k + 0.5) * tau / 10.0) % tau
          next unless mid >= Math::PI / 2.0 && mid <= 1.5 * Math::PI
        end
        painter.triangle(center, verts[k], verts[(k + 1) % 10], color)
      end
    end
  end
end

# Ui sugar for the mobile widget set. Each phase file appends its own
# helpers here (the class is reopened per file — the shared `ui.cr`
# stays untouched by the mobile plan).
class Egui::Ui
  # `ui.rating_bar(value, count: 5, step: 1.0) { |new_value| … }` — the
  # block fires with the new rating on tap; `Response#changed?` reports
  # the same and `Response#widget_value` carries it.
  def rating_bar(value : Float64, count : Int32 = 5, step : Float64 = 1.0,
                 id : String? = nil, &on_change : Float64 ->) : Response
    response = add(RatingBar.new(value, count: count, step: step, id: id))
    if response.changed? && (v = response.widget_value)
      on_change.call(v)
    end
    response
  end

  def rating_bar(value : Float64, count : Int32 = 5, step : Float64 = 1.0,
                 id : String? = nil) : Response
    add(RatingBar.new(value, count: count, step: step, id: id))
  end
end
