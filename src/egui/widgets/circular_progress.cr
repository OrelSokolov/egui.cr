# Circular progress ring (Material `CircularProgressIndicator` in its
# DETERMINATE mode) — plans/todo/mobile_widgets.md #21.
#
# A fraction 0..1 painted as an arc over a full-circle track: exactly
# `Spinner`'s arc machinery, minus the rotation — the start angle is
# pinned to 12 o'clock (-90°) and the span IS the value. That is the
# whole point of a separate widget: a spinner spins (indeterminate,
# repaints forever), this ring is static (determinate — repaints only
# when the frame does; no `request_repaint` here, per the spinner's
# visibility contract inverted).
#
# An optional caption paints dead-center (`text:` — "42%" and the
# like); the widget reserves nothing for it: the ring is the widget's
# whole footprint, the caller sizes the ring so the caption fits.
#
# Reporting: `Response#widget_value` = the CLAMPED fraction
# (0..1 — an app bug feeding 1.5 paints a full ring AND reads back a
# legal value instead of the out-of-domain one). No `changed?` — there
# is nothing to interact with (Sense.none, like the spinner).
#
# Styling — the `circular_progress` class: `size` (32),
# `thickness` (4), `color` (the arc; default selection_fill),
# `track_color` (default: the arc faded to 35%).

module Egui
  class CircularProgress
    include Widget

    def initialize(@fraction : Float64, @text : String? = nil,
                   id : String? = nil)
      @id_name = id
    end

    def style_class : String?
      "circular_progress"
    end

    def style_properties : Array(StyleProp)
      [
        StyleProp.new("size", :number, fallback: 32.0, min: 0.0),
        StyleProp.new("thickness", :number, fallback: 4.0, min: 0.0),
        StyleProp.new("color", :color),
        StyleProp.new("track_color", :color),
      ]
    end

    def inspector_label : String?
      @text || @fraction.to_s
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      class_vars = style_vars(ui, id)
      style = effective_style(ui, id, class_vars)
      visuals = style.visuals

      size = styled_size(Vec2.new(class_vars.f64("size", 32.0),
        class_vars.f64("size", 32.0)), class_vars, ui, id)
      rect = ui.allocate_at_least(size)
      response = ui.interact(rect, id, Sense.none)

      fraction = @fraction.clamp(0.0, 1.0)
      tau = 2.0 * Math::PI
      center = rect.center
      thickness = class_vars.f64("thickness", 4.0)
      radius = (size.x - thickness) / 2.0 - 1.0
      color = class_vars.color("color", visuals.selection_fill)
      track_color = class_vars.color("track_color",
        visuals.fade_color(color, 0.35))

      # Track first (a full circle), the value arc on top from 12
      # o'clock clockwise. A zero fraction paints no arc — the track
      # alone IS the zero state.
      ui.painter.circle_stroke(center, radius, track_color, thickness)
      if fraction > 0.0
        ui.painter.arc(center, radius, -Math::PI / 2.0,
          -Math::PI / 2.0 + tau * fraction, thickness, color)
      end

      if text = @text
        fonts, family, bold = ui.ctx.fonts_for_weight(
          style.font_family, style.font_weight, false)
        font_size = style.font_size * 0.7
        m = fonts.measure(text, font_size)
        # Painter#text anchors the LEFT-CENTER of the text box, so the
        # dead-center anchor is (center.x - width/2, center.y).
        ui.painter.text(
          Pos2.new(center.x - m.x / 2.0, center.y),
          text, font_size, class_vars.color("text_color", visuals.text_color),
          family: family, bold: bold)
      end

      response.widget_value = fraction
      response
    end
  end
end

# Ui sugar for the mobile widget set. Each phase file appends its own
# helpers here (the class is reopened per file — the shared `ui.cr`
# stays untouched by the mobile plan).
class Egui::Ui
  # `ui.circular_progress(fraction, text: "42%")` — static ring; the
  # app repaints on its own when the fraction changes (the widget never
  # requests frames).
  def circular_progress(fraction : Float64, text : String? = nil,
                        id : String? = nil) : Response
    add(CircularProgress.new(fraction, text: text, id: id))
  end
end
