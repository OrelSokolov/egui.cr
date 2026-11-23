# Mobile Stepper (iOS `UIStepper` / the Material quantity picker,
# phase 3 of plans/todo/mobile_widgets.md): a minus button, the value
# between them, a plus button. min/max/step, the classic cheap value
# widget — stateless like Slider: the app owns the value and passes it
# in every frame; a click reports the new value through
# `Response#changed?` + `Response#widget_value` (the same channel the
# Slider/NumberInput block helpers read), so `ui.stepper(v, …) { |new|
# … }` and the reactive `ui.stepper(sig)` both fall out of the one
# implementation.
#
# The three zones are separate interacts over the one allocated rect —
# no child Uis, no composition: the label zone carries Sense.none (a
# painted caption, never a click target), the buttons Sense.click.
# Hitting a bound disables that button honestly: the icon fades and
# the click falls through (no changed, no repaint ping).
#
# Styling — the `stepper` class:
#   button_size   (number, default 28 — each end button's square)
#   height        (number, default 32)
#   rounding      (number, default 8)
#   background    (color, states: true — the whole pill's fill)
#   stroke        (color)
#   text_color    (color, default visuals.text_color)
#   font_size     (number, default the Ui font size)

module Egui
  class Stepper
    include Widget

    MINUS_SALT = 1_u64
    PLUS_SALT  = 2_u64

    def initialize(@value : Float64, @min : Float64 = 0.0,
                   @max : Float64 = 100.0, @step : Float64 = 1.0,
                   id : String? = nil)
      @id_name = id
    end

    def style_class : String?
      "stepper"
    end

    def style_properties : Array(StyleProp)
      StyleProps.textlike + [
        StyleProp.new("button_size", :number, fallback: 28.0, min: 0.0),
        StyleProp.new("height", :number, fallback: 32.0, min: 0.0),
        StyleProp.new("rounding", :number, fallback: 8.0, min: 0.0),
        StyleProp.new("background", :color, states: true),
        StyleProp.new("stroke", :color),
      ]
    end

    def inspector_label : String?
      format_value(@value)
    end

    # The two end buttons' rects from the last ui() run — the nested
    # hit targets (tests click these; the value zone is inert).
    getter minus_rect : Rect?
    getter plus_rect : Rect?

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      vars = style_vars(ui, id)
      style = effective_style(ui, id, vars)
      visuals = style.visuals
      font_size = vars.f64?("font_size") || style.font_size
      fonts = ui.ctx.fonts_for(style.font_family)

      btn = vars.f64("button_size", 28.0)
      height = vars.f64("height", 32.0)
      gap = 2.0
      text = format_value(@value)
      text_w = fonts.measure(text, font_size).x
      width = btn * 2.0 + gap * 2.0 + {text_w, btn}.max
      rect = ui.allocate_at_least(Vec2.new(width, height))

      minus = Rect.from_min_size(Pos2.new(rect.left, rect.top),
        Vec2.new(btn, height))
      label = Rect.from_min_size(
        Pos2.new(minus.right + gap, rect.top),
        Vec2.new(rect.width - btn * 2.0 - gap * 2.0, height))
      plus = Rect.from_min_size(Pos2.new(label.right + gap, rect.top),
        Vec2.new(btn, height))
      @minus_rect = minus
      @plus_rect = plus

      # Whole-rect response is the base verdict; a button click
      # rewrites it below (the returned Response always carries the
      # fresh value through widget_value).
      response = ui.interact(rect, id, Sense.none)

      fill = vars.color?("background")
      stroke = vars.color?("stroke")
      rounding = vars.rounding_px("rounding", rect, 8.0)
      if fill || stroke
        ui.painter.rect(rect, rounding, fill, stroke)
      end

      can_down = @value - @step >= @min - 1e-9
      can_up = @value + @step <= @max + 1e-9

      result = response
      minus_resp = ui.interact(minus, id.child(MINUS_SALT), Sense.click)
      plus_resp = ui.interact(plus, id.child(PLUS_SALT), Sense.click)
      text_color = vars.color("text_color", visuals.text_color)

      # Icons: full-strength while their direction can move, faded at
      # the bound (the honest disabled look — see the class comment).
      # The glyph sits in a centered half-size square of its button.
      glyph = btn * 0.5
      base_color = vars.color("text_color", visuals.text_color)
      Icons.draw(ui.painter, :minus, Rect.from_min_size(
        Pos2.new(minus.center.x - glyph / 2.0,
          minus.center.y - glyph / 2.0), Vec2.new(glyph, glyph)),
        can_down ? base_color : visuals.fade_color(base_color))
      ui.painter.text(Pos2.new(label.center.x - text_w / 2.0,
        rect.center.y), text, font_size, text_color,
        family: style.font_family)
      Icons.draw(ui.painter, :plus, Rect.from_min_size(
        Pos2.new(plus.center.x - glyph / 2.0,
          plus.center.y - glyph / 2.0), Vec2.new(glyph, glyph)),
        can_up ? base_color : visuals.fade_color(base_color))

      if minus_resp.clicked? && can_down
        response.widget_value = (@value - @step).clamp(@min, @max)
        response.mark_changed
        result = response
        ui.ctx.request_repaint
      elsif plus_resp.clicked? && can_up
        response.widget_value = (@value + @step).clamp(@min, @max)
        response.mark_changed
        result = response
        ui.ctx.request_repaint
      end
      result
    end

    # Integer-looking values print without the tail (3 not 3.0);
    # fractional ones round the float noise away (2.5 + 0.1 steps).
    private def format_value(v : Float64) : String
      v = v.round(6)
      v == v.trunc ? v.to_i64.to_s : v.to_s
    end
  end
end

# Ui sugar for the mobile widget set (see widgets/switch.cr — the
# class is reopened per phase file, `ui.cr` stays untouched).
class Egui::Ui
  # `ui.stepper(value, range: 0.0..100.0, step: 1.0) { |new_v| … }` —
  # the block fires with the NEW value when a button clicked this
  # frame; `Response#changed?` + `#widget_value` report the same.
  def stepper(value : Float64,
              range : Range(Float64, Float64) = (0.0..100.0),
              step : Float64 = 1.0, id : String? = nil,
              &on_change : Float64 ->) : Response
    response = add(Stepper.new(value, range.begin, range.end, step,
      id: id))
    if response.changed? && (v = response.widget_value)
      on_change.call(v)
    end
    response
  end

  # Reactive form: `ui.stepper(sig, range: …)` — the write lands in
  # the signal directly (see ui.cr's signal-form widgets).
  def stepper(sig : Signal(Float64),
              range : Range(Float64, Float64) = (0.0..100.0),
              step : Float64 = 1.0, id : String? = nil) : Response
    signal_form add(Stepper.new(sig.value, range.begin, range.end, step,
      id: id)) do
      sig.value = response.widget_value.not_nil!
    end
  end
end
