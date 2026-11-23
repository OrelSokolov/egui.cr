# Skeleton placeholder (Material shimmer / iOS redacted rows) —
# plans/todo/mobile_widgets.md #22.
#
# A gray rounded bar or circle that stands in for content still
# loading. Two shapes: `:bar` (the default — a capsule bar, radius
# clamped to height/2 by painter.rect) and `:circle` (avatars). Both
# take ONE fill color and, when `shimmer: true` (default), a highlight
# that breathes toward it — the highlight rides
# `Context#animate_value_with_time` as a slow 0→1→0 triangle wave
# (target flips every second, one second to travel), so the animation
# machinery keeps repainting only for as long as the ease is running.
#
# Repaint contract — the SPINNER's, mirrored exactly: an animated
# skeleton calls `request_repaint` each frame its rect meets the Ui's
# clip, and NEVER when it is culled — a scrolled-away skeleton must not
# pin the loop at full frames or the idle path (re-emit the last
# commands, skip the walk) would never engage. Scrolling back is an
# event, so frames resume. With `shimmer: false` nothing animates and
# nothing repaints — a static placeholder.
#
# `ui.skeleton_list(rows)` produces a column of placeholder bars with
# slightly ragged widths (the classic redacted-text look) — one widget
# per row so the paint cache and the inspector see real widgets.
#
# Styling — the `skeleton` class: `height` (12; the circle's diameter),
# `color` (default separator_color), `highlight_color` (default: the
# base color faded to 30% — lighter on light themes, darker on dark),
# `rounding` (default: height/2, the capsule).

module Egui
  class Skeleton
    include Widget

    # Seconds per shimmer leg (base → highlight → base); the triangle
    # wave period is twice this.
    SHIMMER_LEG = 1.0
    # Natural bar size when the caller gives no width/height (a bare
    # `Skeleton.new` in a flow region reads as one text line).
    BAR_W = 160.0
    BAR_H = 12.0

    SHAPES = [:bar, :circle]

    def initialize(@shape : Symbol = :bar, @width : Float64? = nil,
                   @height : Float64? = nil, @shimmer : Bool = true,
                   id : String? = nil)
      @id_name = id
      unless SHAPES.includes?(@shape)
        raise ArgumentError.new(
          "Skeleton shape: #{@shape} (expected one of " +
          SHAPES.map(&.to_s).join(", ") + ")")
      end
    end

    def style_class : String?
      "skeleton"
    end

    def style_properties : Array(StyleProp)
      [
        StyleProp.new("height", :number, fallback: BAR_H, min: 0.0),
        StyleProp.new("color", :color),
        StyleProp.new("highlight_color", :color),
        StyleProp.new("rounding", :number, min: 0.0),
      ]
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      class_vars = style_vars(ui, id)
      style = effective_style(ui, id, class_vars)
      visuals = style.visuals

      h = @height || class_vars.f64("height", BAR_H)
      w = @shape == :circle ? h : (@width || BAR_W)
      size = styled_size(Vec2.new(w, h), class_vars, ui, id)
      rect = ui.allocate_at_least(size)
      response = ui.interact(rect, id, Sense.none)

      # Shimmer value: a slow triangle wave through the ctx animation
      # machinery (which requests the repaints the ease itself needs).
      # The VISIBILITY half of the contract is ours: keep frames coming
      # only while the rect can actually paint (see the header).
      value = 0.0
      if @shimmer
        ui.ctx.request_repaint if rect.intersects?(ui.clip)
        leg = ((ui.ctx.input.time / SHIMMER_LEG) % 2.0) < 1.0 ? 1.0 : 0.0
        value = ui.ctx.animate_value_with_time(id, leg, SHIMMER_LEG)
      end

      color = class_vars.color("color", visuals.separator_color)
      highlight = class_vars.color("highlight_color",
        visuals.fade_color(color, 0.3))
      fill = color.lerp(highlight, value)
      if @shape == :circle
        d = {size.x, size.y}.min
        ui.painter.circle_filled(
          Pos2.new(rect.left + d / 2.0, rect.top + d / 2.0), d / 2.0, fill)
      else
        ui.painter.rect(rect,
          class_vars.f64("rounding", size.y / 2.0), fill)
      end

      response
    end
  end
end

# Ui sugar for the mobile widget set. Each phase file appends its own
# helpers here (the class is reopened per file — the shared `ui.cr`
# stays untouched by the mobile plan).
class Egui::Ui
  # `ui.skeleton_list(rows)` — a column of placeholder bars with
  # ragged widths (1.0 / 0.85 / 0.92 of the available width, cycling),
  # one Skeleton widget per row.
  def skeleton_list(rows : Int32, height : Float64? = nil,
                    shimmer : Bool = true, id : String? = "skeleton_list") : Nil
    fractions = [1.0, 0.85, 0.92]
    rows.times do |i|
      w = available_width * fractions[i % fractions.size]
      h = height || 12.0
      add_sized(Vec2.new(w, h), Skeleton.new(:bar, width: w, height: h,
        shimmer: shimmer, id: "#{id}/row#{i}"))
    end
  end
end
