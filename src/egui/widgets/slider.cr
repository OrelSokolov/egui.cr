# Port of egui_upstream/crates/egui/src/widgets/slider.rs (horizontal,
# pointer-driven part; keyboard stepping lands with phase 3).
#
# Stateless on purpose: while dragging, the value is derived directly
# from the pointer position mapped through the rail (upstream does the
# same), refined by SmartAim so slow drags land on round numbers.
#
# Two macOS-style extras beyond the plain port:
#   * `tips` — a {left, right} pair of captions painted under the rail,
#     flush to its ends (NSSlider tick labels). Each caption is its own
#     stylable sub-widget (class `slider.tip`, see TipPart): class rules
#     and per-element inspector edits reach it like any real widget;
#   * `quantized: true` + `values` — the value is restricted to that
#     list: the pointer maps to the NEAREST entry and the handle snaps
#     to discrete positions (index-spaced across the rail);
#   * `ticks:` — macOS-style tick marks: short vertical strokes
#     pointing at the quants. `true`/`:down` under the rail, `:up`
#     above it, `:up_down` on both sides at once. Stylable the same
#     way through the `slider.tick` class (TickPart). Requires
#     `values:`;
#   * `handle:` — the handle shape: `:circle` (default), `:rect`, or a
#     pentagon pointing at the tips row: `:pentagon_up` /
#     `:pentagon_down`.

module Egui
  class Slider
    include Widget

    # Element class of the tip captions (see TipPart): stylesheet rules
    # and inspector edits address them as `slider.tip` —
    #   ctx.stylesheet.rule("slider.tip", StyleVars{
    #     "text_color" => Color32.rgb(120, 120, 120), …})
    TIP_CLASS = "slider.tip"

    # The StyledPart behind one tip caption (see widgets/styled_part.cr):
    # carries the inspector meta for the caption's interact and declares
    # the `slider.tip` keys. Without it the tips are plain painter text —
    # unpickable and invisible to the class editor. Vars resolve per tip
    # id, so class rules AND per-element inspector edits both land.
    class TipPart < StyledPart
      def initialize(label : String)
        super("SliderTip", TIP_CLASS, StyleProps.textlike, label)
      end
    end

    # Element class of the tick-mark row (see TickPart): stylesheet
    # rules and inspector edits address it as `slider.tick` —
    #   ctx.stylesheet.rule("slider.tick", StyleVars{
    #     "stroke" => Color32.rgb(150, 150, 150), "height" => 6.0})
    TICK_CLASS = "slider.tick"

    # The StyledPart behind the tick-mark row: one part covers the whole
    # row (the strokes are decorative, there is nothing to pick per
    # stroke) — it records the inspector meta for the row's interact
    # and declares the `slider.tick` keys.
    class TickPart < StyledPart
      def initialize
        super("SliderTick", TICK_CLASS, [
          StyleProp.new("stroke", :color),
          StyleProp.new("height", :number, min: 0.0),
        ])
      end
    end

    # Handle shapes `handle:` accepts (`:pentagon_up` points at the
    # tips row below, `:pentagon_down` at a row above the rail).
    HANDLE_SHAPES = [:circle, :rect, :pentagon_up, :pentagon_down]

    def initialize(@value : Float64, @range : Range(Float64, Float64),
                   @text : String? = nil, id : String? = nil,
                   @tips : {String, String}? = nil,
                   @quantized : Bool = false,
                   @values : Array(Float64)? = nil,
                   ticks : Bool | Symbol = false,
                   @handle : Symbol = :circle)
      @id_name = id
      unless HANDLE_SHAPES.includes?(@handle)
        raise ArgumentError.new(
          "Slider handle: #{@handle} (expected one of " +
          HANDLE_SHAPES.map(&.to_s).join(", ") + ")")
      end
      # `true` reads as :down (the pre-`:up` behavior); the symbols
      # pick which side of the rail the strokes point from, :up_down
      # both at once.
      @ticks = case ticks
        when false          then nil
        when true           then :down
        when :down, :up, :up_down then ticks
        else
          raise ArgumentError.new(
            "Slider ticks: #{ticks} (expected true/false/:up/:down/:up_down)")
      end
      if @quantized
        # The flag requires the list — nothing to snap to otherwise.
        if (list = @values).nil? || list.empty?
          raise ArgumentError.new(
            "Slider quantized: true requires a non-empty values list")
        end
        # Snap the incoming value so the handle starts on a legal spot.
        @value = list[nearest_index(list, @value)]
      end
      if @ticks && ((list = @values).nil? || list.empty?)
        # Strokes point AT the quants — no list, nowhere to point.
        raise ArgumentError.new(
          "Slider ticks requires a non-empty values list")
      end
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

      # The label is part of the widget: it sits on its own line ABOVE
      # the rail (not beside it) — stacked sliders then read as
      # separate blocks, the label line doubling as a separator. Its
      # height is reserved up front so min_rect (and any auto-sizing
      # parent) covers what we paint.
      fonts, face_family, face_bold = ui.ctx.fonts_for_weight(
        style.font_family, style.font_weight, false)
      label = @text ? "#{@text}: #{format_value(@value)}" : nil
      label_size = label ? fonts.measure(label.not_nil!, style.font_size) : Vec2.zero
      label_h = label ? label_size.y + TIP_GAP : 0.0

      # Everything the rail does not cover — tips and the tick rows
      # (below, and now above for :up/:up_down) — is reserved up front
      # so the allocated rect covers what we paint. Tips resolve their
      # cascade first, the tick row its own (font size/family/weight
      # and the styled tick height influence the measurement, so this
      # runs before the allocate).
      tips = @tips ? {
        prepare_tip(ui, id.child(1), @tips.not_nil![0], style),
        prepare_tip(ui, id.child(2), @tips.not_nil![1], style),
      } : nil
      tick = @ticks ? prepare_tick(ui, id.child(3)) : nil
      both = @ticks == :up_down
      above_h = (tick && (both || @ticks == :up)) ? TIP_GAP + tick.height : 0.0
      tick_h = (tick && (both || @ticks == :down)) ? TIP_GAP + tick.height : 0.0
      tips_h = tips ? TIP_GAP + {tips[0].height, tips[1].height}.max : 0.0

      width = {sp.slider_width, ui.available_width}.max
      outer = ui.allocate_at_least(
        Vec2.new(width, above_h + label_h + thickness + tick_h + tips_h))
      # The rail row sits under the label line and the up-tick band, at
      # the same offset from the outer rect's top every frame.
      rect = Rect.from_min_size(
        Pos2.new(outer.min.x, outer.min.y + above_h + label_h),
        Vec2.new(width, thickness))
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

      handle_r = HANDLE_R
      t = normalized(new_value)
      handle_x = rect.left + handle_r + t * (rect.width - 2 * handle_r)
      handle_color = visuals.selection_fill
      handle_color = visuals.fade_color(handle_color, 0.85) if response.hovered?
      paint_handle(ui.painter, @handle,
        Pos2.new(handle_x, rail_y), handle_r, handle_color)

      response.paint_focus_ring(9.0)

      # macOS stacking under the rail: tick strokes first (pointing at
      # the quants), tip captions below them.
      if t = tick
        paint_ticks(ui, t, rect, visuals)
      end
      if tips
        base_y = rect.bottom + tick_h
        tip_y = base_y + TIP_GAP + {tips[0].height, tips[1].height}.max / 2.0
        paint_tip(ui, tips[0], Pos2.new(rect.left, tip_y), visuals)
        paint_tip(ui, tips[1], Pos2.new(rect.right - tips[1].width, tip_y), visuals)
      end

      if text = @text
        # Above the rail, flush to its left edge (left-center anchor).
        # The painted string carries `new_value` — the live figure
        # during a drag — while the reserved height was measured from
        # the frame's start value (same digit count, no reflow).
        live = "#{text}: #{format_value(new_value)}"
        label_pos = Pos2.new(rect.left, rect.top - TIP_GAP - label_size.y / 2.0)
        ui.painter.text(label_pos, live, style.font_size,
          visuals.text_color, family: face_family,
          bold: face_bold)
        ui.min_rect = ui.min_rect.union(Rect.from_min_size(
          Pos2.new(rect.left, rect.top - TIP_GAP - label_size.y),
          label_size))
      end

      response.widget_value = new_value
      response.mark_changed if new_value != @value
      response
    end

    # Gap between the rail row and the rows under it (ticks, tips).
    TIP_GAP = 3.0
    # Default tick-mark length (the `slider.tick` `height` key overrides).
    TICK_LEN = 5.0
    # Handle radius (half the rect edge / the pentagon's circumradius).
    HANDLE_R = 6.0

    # The tick-mark row, resolved for painting: its part (inspector
    # meta + `slider.tick` cascade) and the cascade-read stroke length.
    private struct TickRender
      getter part : TickPart
      getter id : Id
      getter vars : StyleVars
      getter height : Float64

      def initialize(@part, @id, @vars, @height)
      end
    end

    # Resolve the tick row through its `slider.tick` cascade: a set
    # `height` beats the TICK_LEN default (measured here so the
    # allocate reserves the styled length, not the default one).
    private def prepare_tick(ui : Ui, tick_id : Id) : TickRender
      part = TickPart.new
      vars = part.vars(ui, tick_id)
      TickRender.new(part, tick_id, vars, vars.f64("height", TICK_LEN))
    end

    # Paint one vertical stroke per quant, at the handle's own spot for
    # that entry (index-spaced when quantized, numeric otherwise), and
    # register the rows' bounding rect as a pickable sub-widget — one
    # interact for the whole band (Sense::none: decorative, but the
    # inspector can pick it and edit `slider.tick` per element).
    # :down strokes hang under the rail, :up stand above it, :up_down
    # paints both.
    private def paint_ticks(ui : Ui, tick : TickRender, rail : Rect,
                            visuals : Visuals) : Nil
      list = @values.not_nil!
      handle_r = HANDLE_R
      span = rail.width - 2 * handle_r
      color = tick.vars.color("stroke", visuals.button_stroke)

      top = rail.top - (@ticks == :up || @ticks == :up_down ? TIP_GAP + tick.height : 0.0)
      bottom = rail.bottom + (@ticks == :down || @ticks == :up_down ? TIP_GAP + tick.height : 0.0)
      row = Rect.from_min_size(
        Pos2.new(rail.left, top), Vec2.new(rail.width, bottom - top))
      ui.ctx.with_inspector_widget(tick.part) do
        ui.interact(row, tick.id, Sense.none)
      end

      list.each_with_index do |v, i|
        t = tick_t(list, i, v)
        x = rail.left + handle_r + t * span
        if @ticks == :up || @ticks == :up_down
          y = rail.top - TIP_GAP
          ui.painter.line(Pos2.new(x, y), Pos2.new(x, y - tick.height),
            1.0, color)
        end
        if @ticks == :down || @ticks == :up_down
          y = rail.bottom + TIP_GAP
          ui.painter.line(Pos2.new(x, y), Pos2.new(x, y + tick.height),
            1.0, color)
        end
      end
    end

    # Where the tick for entry `i` sits along the rail: index-spaced
    # when quantized (same spots the handle snaps to), else the
    # entry's numeric spot in the range.
    private def tick_t(list : Array(Float64), i : Int32, v : Float64) : Float64
      if @quantized
        list.size == 1 ? 0.0 : i.to_f64 / (list.size - 1)
      else
        normalized(v)
      end
    end

    # The handle glyph: a filled disc (:circle, the upstream look), a
    # rounded square (:rect), or a house pentagon (:pentagon_up roof on
    # top / :pentagon_down roof below) — a 2r×r body rect plus one
    # roof triangle, the bounding box matching the other shapes'.
    private def paint_handle(painter : Painter, shape : Symbol,
                             center : Pos2, r : Float64,
                             color : Color32) : Nil
      case shape
      when :rect
        painter.rect(
          Rect.from_min_size(Pos2.new(center.x - r, center.y - r),
            Vec2.new(2 * r, 2 * r)),
          2.0, color)
      when :pentagon_up, :pentagon_down
        # Body: the half away from the roof; roof: one triangle with
        # its apex on the pointing side, base flush at the seam.
        body = shape == :pentagon_up ?
          Rect.from_min_size(Pos2.new(center.x - r, center.y),
            Vec2.new(2 * r, r)) :
          Rect.from_min_size(Pos2.new(center.x - r, center.y - r),
            Vec2.new(2 * r, r))
        painter.rect(body, 0.0, color)
        seam = shape == :pentagon_up ? body.top : body.bottom
        apex = shape == :pentagon_up ?
          Pos2.new(center.x, center.y - r) :
          Pos2.new(center.x, center.y + r)
        painter.triangle(Pos2.new(center.x - r, seam),
          Pos2.new(center.x + r, seam), apex, color)
      else # :circle
        painter.circle_filled(center, r, color)
      end
    end


    # One tip caption, resolved for painting: its part (inspector meta
    # + `slider.tip` cascade), the cascade-read fonts/size it measures
    # and paints with, and the measured extent.
    private struct TipRender
      getter part : TipPart
      getter id : Id
      getter vars : StyleVars
      getter text : String
      getter size : Float64
      getter width : Float64
      getter height : Float64
      getter face_family : String?
      getter face_bold : Bool

      def initialize(@part, @id, @vars, @text, @size,
                     @width, @height, @face_family, @face_bold)
      end
    end

    # Resolve one tip caption through its `slider.tip` cascade (class
    # rules + the per-element inspector override, `StyledPart#vars`):
    # a set font_size/family/weight beats the slider's own, and the
    # measurement runs through the SAME stack the paint will use.
    private def prepare_tip(ui : Ui, tip_id : Id, text : String,
                            style : Style) : TipRender
      part = TipPart.new(text)
      vars = part.vars(ui, tip_id)
      size = vars.f64("font_size", style.font_size)
      family = vars.str?("font_family") || style.font_family
      weight = vars.f64?("font_weight") || style.font_weight
      tip_fonts, face_family, face_bold = ui.ctx.fonts_for_weight(
        family, weight, false)
      m = tip_fonts.measure(text, size)
      TipRender.new(part, tip_id, vars, text, size, m.x, m.y,
        face_family, face_bold)
    end

    # Paint one caption at `pos` (left-center of its text) and register
    # its rect as a pickable sub-widget: Sense::none — no interaction,
    # but the inspector records the meta (wrapped around the interact)
    # so both the pick and per-element edits address this tip alone.
    private def paint_tip(ui : Ui, tip : TipRender, pos : Pos2,
                          visuals : Visuals) : Nil
      rect = Rect.from_min_size(
        Pos2.new(pos.x, pos.y - tip.height / 2.0),
        Vec2.new(tip.width, tip.height))
      ui.ctx.with_inspector_widget(tip.part) do
        ui.interact(rect, tip.id, Sense.none)
      end
      color = tip.vars.color("text_color",
        visuals.fade_color(visuals.text_color, 0.6))
      ui.painter.text(pos, tip.text, tip.size, color,
        family: tip.face_family, bold: tip.face_bold)
    end

    private def normalized(value : Float64) : Float64
      # Quantized: the handle sits at discrete index positions, not at
      # the value's spot in the numeric range.
      if @quantized && (list = @values)
        return 0.0 if list.size == 1
        return nearest_index(list, value).to_f64 / (list.size - 1)
      end
      lo, hi = @range.begin, @range.end
      ((value - lo) / (hi - lo)).clamp(0.0, 1.0)
    end

    # Index of the list entry closest to `value`.
    private def nearest_index(list : Array(Float64), value : Float64) : Int32
      best = 0
      best_d = (list[0] - value).abs
      list.each_with_index do |v, i|
        d = (v - value).abs
        if d < best_d
          best = i
          best_d = d
        end
      end
      best
    end

    # The inverse map, with SmartAim refinement around the pointer
    # (upstream `Slider::slider_ui` + `best_in_range_f64`).
    private def value_at(ui : Ui, rect : Rect, pointer_x : Float64) : Float64
      handle_r = HANDLE_R
      span = rect.width - 2 * handle_r

      if @quantized && (list = @values)
        # Discrete: map the pointer to the continuous t, then snap to
        # the nearest index — no SmartAim, every landing is legal.
        return list[0] if span <= 0.0 || list.size == 1
        t = ((pointer_x - (rect.left + handle_r)) / span).clamp(0.0, 1.0)
        idx = (t * (list.size - 1)).round.to_i32.clamp(0, list.size - 1)
        return list[idx]
      end

      lo, hi = @range.begin, @range.end
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
