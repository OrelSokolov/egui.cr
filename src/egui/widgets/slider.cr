# Port of egui_upstream/crates/egui/src/widgets/slider.rs (horizontal,
# pointer-driven part; keyboard stepping lands with phase 3).
#
# Stateless on purpose: while dragging, the value is derived directly
# from the pointer position mapped through the rail (upstream does the
# same), refined by SmartAim so slow drags land on round numbers.

module Egui
  class Slider
    include Widget

    def initialize(@value : Float64, @range : Range(Float64, Float64),
                   @text : String? = nil, id : String? = nil)
      @id_name = id
    end

    def style_properties : Array(StyleProp)
      StyleProps.textlike + [
        StyleProp.new("selection_fill", :color, label: "fill (handle)"),
        StyleProp.new("stroke", :color, label: "rail stroke"),
      ]
    end

    def inspector_label : String?
      @text
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      style = effective_style(ui, id)
      sp = style.spacing
      thickness = sp.interact_size.y

      # The label is part of the widget: allocate rail + label together,
      # so min_rect (and any auto-sizing parent) stays within the
      # available width. Painting the label OUTSIDE the allocated rect
      # made every containing window grow a little each frame.
      fonts, face_family, face_bold = ui.ctx.fonts_for_weight(
        style.font_family, style.font_weight, false)
      label_w = label_width(ui, style, fonts)
      width = {sp.slider_width, ui.available_width - label_w}.max
      outer = ui.allocate_at_least(Vec2.new(width + label_w, thickness))
      rect = Rect.from_min_size(outer.min, Vec2.new(width, thickness))
      response = ui.interact(rect, id, Sense.drag | Sense::Focusable)

      new_value = @value
      if response.dragged? && (pos = ui.ctx.input.pointer_pos)
        new_value = value_at(ui, rect, pos.x)
      end

      # Paint: rail + handle circle at the value position.
      visuals = style.visuals
      rail_y = rect.center.y
      rail = Rect.from_min_size(
        Pos2.new(rect.left, rail_y - sp.slider_rail_width / 2.0),
        Vec2.new(rect.width, sp.slider_rail_width))
      # The rail is a groove, not a button: upstream fills it with the
      # noninteractive background, but light themes set button_weak ≈
      # panel_fill (macOS #FFF on #FFF) — the stroke color keeps the
      # rail visible in every preset.
      ui.painter.rect(rail, rail.height / 2.0, visuals.button_stroke)

      handle_r = 6.0
      t = normalized(new_value)
      handle_x = rect.left + handle_r + t * (rect.width - 2 * handle_r)
      handle_color = visuals.selection_fill
      handle_color = visuals.fade_color(handle_color, 0.85) if response.hovered?
      ui.painter.circle_filled(Pos2.new(handle_x, rail_y), handle_r,
        handle_color)

      response.paint_focus_ring(9.0)

      if text = @text
        label = "#{text}: #{format_value(new_value)}"
        label_size = fonts.measure(label, style.font_size)
        label_pos = Pos2.new(rect.right + sp.icon_spacing, rect.center.y)
        ui.painter.text(label_pos, label, style.font_size,
          visuals.text_color, family: face_family,
          bold: face_bold)
        ui.min_rect = ui.min_rect.union(
          Rect.from_min_size(label_pos, label_size))
      end

      response.widget_value = new_value
      response.mark_changed if new_value != @value
      response
    end

    private def label_width(ui : Ui, style : Style, fonts : Fonts) : Float64
      return 0.0 unless text = @text
      fonts.measure("#{text}: #{format_value(@value)}",
        style.font_size).x + style.spacing.icon_spacing
    end

    private def normalized(value : Float64) : Float64
      lo, hi = @range.begin, @range.end
      ((value - lo) / (hi - lo)).clamp(0.0, 1.0)
    end

    # The inverse map, with SmartAim refinement around the pointer
    # (upstream `Slider::slider_ui` + `best_in_range_f64`).
    private def value_at(ui : Ui, rect : Rect, pointer_x : Float64) : Float64
      lo, hi = @range.begin, @range.end
      handle_r = 6.0
      span = rect.width - 2 * handle_r
      return lo if span <= 0.0

      from_x = ->(x : Float64) : Float64 do
        t = ((x - (rect.left + handle_r)) / span).clamp(0.0, 1.0)
        lo + t * (hi - lo)
      end

      aim = ui.ctx.input.aim_radius
      SmartAim.best_in_range_f64(
        from_x.call(pointer_x - aim), from_x.call(pointer_x + aim))
    end

    def self.format_value(v : Float64) : String
      v.round(3).to_s
    end

    private def format_value(v : Float64) : String
      Slider.format_value(v)
    end
  end
end
