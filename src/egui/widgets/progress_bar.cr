# Port of egui_upstream/crates/egui/src/widgets/progress_bar.rs.
#
# Fills the available width with a rounded track + a fraction fill.
# With `animate` on, the fill eases towards the target via
# `Context#animate_value_with_time` (upstream animates on decrease).

module Egui
  class ProgressBar
    include Widget

    def initialize(@fraction : Float64, @text : String? = nil,
                   @animate : Bool = false, id : String? = nil)
      @id_name = id
    end

    def style_class : String?
      "progressbar"
    end

    def style_properties : Array(StyleProp)
      StyleProps.textlike + StyleProps.sizable + [
        StyleProp.new("selection_fill", :color, label: "fill"),
        StyleProp.new("stroke", :color, label: "track stroke"),
        # Corner rounding of the track (and the fill, capped by the
        # fill's own height); "capsule" (via ecss) is the macOS shape —
        # semicircle ends, whatever the bar's width.
        StyleProp.new("rounding", :number, fallback: 4.0, min: 0.0),
      ]
    end

    def inspector_label : String?
      @text
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      # Class rules through the full cascade: textlike keys (`text_color`
      # for the bar text, `font_*`) land in the effective Style; the box
      # keys (`selection_fill`, `stroke`, `rounding`) are read raw below.
      vars = style_vars(ui, id)
      style = effective_style(ui, id, vars)
      height = {style.spacing.interact_size.y * 1.25,
                style.font_size * 1.5}.max
      size = Vec2.new(ui.available_width, height)
      size = styled_size(size, vars, ui, id)
      rect = ui.allocate_at_least(size)

      fraction = @fraction.clamp(0.0, 1.0)
      fraction = ui.ctx.animate_value_with_time(id, fraction, 0.3) if @animate

      visuals = style.visuals
      track_rounding = vars.rounding_px("rounding", rect, 4.0)
      track_corners = vars.rounding_corners?("rounding", rect)
      stroke = vars.color?("stroke")
      if stroke
        ui.painter.rect(rect, track_rounding, visuals.button_weak, stroke, 1.0,
          corners: track_corners)
      else
        ui.painter.rect(rect, track_rounding, visuals.button_weak,
          visuals.button_stroke, 1.0, corners: track_corners)
      end
      if fraction > 0.0
        fill_rect = Rect.from_min_size(rect.min,
          Vec2.new(fraction * rect.width, rect.height))
        # The fill rounds with the track, capped by its own height so
        # a narrow capsule fill keeps its semicircle ends (the backends
        # clamp to min(w,h)/2 anyway — this just names it).
        fill_rounding = {track_rounding, fill_rect.height / 2.0}.min
        ui.painter.rect(fill_rect, fill_rounding, visuals.selection_fill)
      end

      if text = @text
        fonts, face_family, face_bold = ui.ctx.fonts_for_weight(
          style.font_family, style.font_weight, false)
        text_size = fonts.measure(text, style.font_size)
        text_pos = Pos2.new(rect.center.x - text_size.x / 2.0, rect.center.y)
        ui.painter.text(text_pos, text, style.font_size, visuals.text_color,
          family: face_family, bold: face_bold)
      end

      ui.interact(rect, id, Sense.none)
    end
  end
end
