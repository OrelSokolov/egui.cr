# Mobile range slider (Material 3 `RangeSlider`) — plans/todo/mobile_widgets.md #18.
#
# Two thumbs on ONE rail. The single-thumb `Slider` is stateless on
# purpose (the pointer maps through the rail each drag frame); a range
# cannot be fully stateless because a drag has to remember WHICH thumb
# it is moving — otherwise the thumb nearest the pointer would grab the
# drag mid-stroke and the values would swap as the thumbs cross. The
# active thumb (0 = lo, 1 = hi) is therefore a per-id memory cell set
# on drag start (nearest thumb wins) and cleared on drag stop.
#
# The lo <= hi invariant is enforced at the VALUE level: dragging the
# lo thumb clamps to the current hi and vice versa, so no pointer path
# can ever produce an inverted range — the thumbs visually collide at
# the crossing point and stop (a swap/carry variant is deliberately
# NOT done: the app-side pair would jump discontinuously).
#
# Styling mirrors `slider.cr` (the same raw keys read from the class
# bag, same fallback slots): `stroke` (rail), `selection_fill` (handles;
# the `slider` class spells the handle color that way), `fill` (the
# span BETWEEN the thumbs — falls back to the selection color, which is
# what makes a range slider read as a range at all), `handle_size`
# (handle radius). Geometry follows the slider rail: height =
# `interact_size.y`, width = `slider_width`, plus the shared
# `styled_size` pass for the `width`/`height` cascade keys.
#
# Value reporting: `Response#widget_value` is a single Float64 slot, so
# the PAIR cannot ride it — the moved thumb's new value goes there
# (hi when no thumb moved, matching the single-slider contract), the
# full pair travels through the `ui.range_slider` block
# (`|new_lo, new_hi|`) and through `RangeSlider`'s `last_lo`/`last_hi`
# getters for sugar-free callers. `Response#changed?` fires on any move.

module Egui
  class RangeSlider
    include Widget

    # Memory-cell seed for the active-thumb cell (0 = lo, 1 = hi,
    # -1 = none). An arbitrary but stable salt keeps the cell off the
    # auto-id namespace.
    ACTIVE_SEED = 0xA71E_u64

    HANDLE_R = 6.0

    def initialize(@lo : Float64, @hi : Float64,
                   @range : Range(Float64, Float64), id : String? = nil)
      @id_name = id
      @last_lo = @lo
      @last_hi = @hi
      # Normalize on the way in so a widget NEVER sees an inverted range
      # (the invariant is a property of the widget, not only of drags).
      if @lo > @hi
        @lo, @hi = @hi, @lo
        @last_lo, @last_hi = @lo, @hi
      end
    end

    # The pair as of the last #ui run (the incoming values when no drag
    # happened) — the block-free way to read the range back.
    getter last_lo : Float64
    getter last_hi : Float64

    def style_class : String?
      "range_slider"
    end

    def style_properties : Array(StyleProp)
      [
        StyleProp.new("selection_fill", :color, label: "fill (handles)"),
        StyleProp.new("stroke", :color, label: "rail stroke"),
        StyleProp.new("fill", :color, label: "fill (span)"),
        StyleProp.new("handle_size", :number, label: "handle radius",
          min: 0.0),
      ]
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      class_vars = style_vars(ui, id)
      style = effective_style(ui, id, class_vars)
      sp = style.spacing
      thickness = sp.interact_size.y
      width = {sp.slider_width, ui.available_width}.max
      size = styled_size(Vec2.new(width, thickness), class_vars, ui, id)
      rect = ui.allocate_at_least(size)
      response = ui.interact(rect, id, Sense.drag | Sense::Focusable)

      lo, hi = @lo, @hi
      moved = false

      # Active-thumb cell: like every state cell it must be marked used
      # each frame or end-frame pruning drops it mid-drag.
      active_id = id.child(ACTIVE_SEED)
      ui.ctx.memory.use_id(active_id)
      active = ui.ctx.memory.data.get_int(active_id, -1)
      if (pointer = ui.ctx.input.pointer_pos)
        if response.drag_started? || (response.dragged? && active == -1)
          # Nearest thumb at press time owns the whole stroke.
          lo_x, hi_x = thumb_x(rect, lo, hi)
          d_lo = (pointer.x - lo_x).abs
          d_hi = (pointer.x - hi_x).abs
          active = d_lo <= d_hi ? 0 : 1
          ui.ctx.memory.data.set_int(active_id, active)
        elsif response.drag_stopped?
          ui.ctx.memory.data.set_int(active_id, -1)
          active = -1
        end

        if response.dragged? && active >= 0
          v = value_at(rect, pointer.x)
          if active == 0
            lo = {v, hi}.min # invariant: lo may kiss hi, never pass it
          else
            hi = {v, lo}.max
          end
          moved = true
        end
      end
      @last_lo = lo
      @last_hi = hi

      # Paint: rail, accent span between the thumbs, two handles — the
      # slider's geometry, doubled.
      visuals = style.visuals
      rail_y = rect.center.y
      rail = Rect.from_min_size(
        Pos2.new(rect.left, rail_y - sp.slider_rail_width / 2.0),
        Vec2.new(rect.width, sp.slider_rail_width))
      rail_color = class_vars.color?("stroke") || visuals.button_stroke
      ui.painter.rect(rail, rail.height / 2.0, rail_color)

      handle_r = class_vars.f64("handle_size", HANDLE_R)
      span = rect.width - 2 * handle_r
      lo_x = rect.left + handle_r + normalized(lo) * span
      hi_x = rect.left + handle_r + normalized(hi) * span
      span_color = class_vars.color?("fill") || visuals.selection_fill
      fill_w = (hi_x - lo_x).clamp(0.0, rail.width)
      if fill_w > 0.0
        ui.painter.rect(
          Rect.from_min_size(Pos2.new(lo_x, rail.min.y),
            Vec2.new(fill_w, rail.height)),
          rail.height / 2.0, span_color)
      end

      handle_color = class_vars.color?("selection_fill") ||
                     visuals.selection_fill
      handle_color = visuals.fade_color(handle_color, 0.85) if response.hovered?
      ui.painter.circle_filled(Pos2.new(lo_x, rail_y), handle_r, handle_color)
      ui.painter.circle_filled(Pos2.new(hi_x, rail_y), handle_r, handle_color)

      # Capsule focus ring (the slider's `border-radius: 9999px` idiom).
      response.paint_focus_ring(9999.0)

      response.widget_value = active == 0 && moved ? lo : hi
      response.mark_changed if moved
      response
    end

    private def normalized(value : Float64) : Float64
      lo, hi = @range.begin, @range.end
      ((value - lo) / (hi - lo)).clamp(0.0, 1.0)
    end

    private def thumb_x(rect : Rect, lo : Float64, hi : Float64) : {Float64, Float64}
      span = rect.width - 2 * HANDLE_R
      {rect.left + HANDLE_R + normalized(lo) * span,
       rect.left + HANDLE_R + normalized(hi) * span}
    end

    # Pointer → range value through the rail (the slider's inverse map,
    # without SmartAim — a range drag snaps smartly for ONE thumb only
    # at the cost of the pair feeling uneven; plain linear mapping keeps
    # both thumbs honest).
    private def value_at(rect : Rect, pointer_x : Float64) : Float64
      lo, hi = @range.begin, @range.end
      span = rect.width - 2 * HANDLE_R
      return lo if span <= 0.0
      t = ((pointer_x - (rect.left + HANDLE_R)) / span).clamp(0.0, 1.0)
      lo + t * (hi - lo)
    end
  end
end

# Ui sugar for the mobile widget set. Each phase file appends its own
# helpers here (the class is reopened per file — the shared `ui.cr`
# stays untouched by the mobile plan).
class Egui::Ui
  # `ui.range_slider(lo, hi, range) { |new_lo, new_hi| … }` — the block
  # fires with the NEW pair while a thumb moves; `Response#changed?`
  # reports the same. The lo <= hi invariant holds for whatever the
  # block receives.
  def range_slider(lo : Float64, hi : Float64,
                   range : Range(Float64, Float64), id : String? = nil,
                   &on_change : (Float64, Float64) ->) : Response
    w = RangeSlider.new(lo, hi, range, id: id)
    response = add(w)
    on_change.call(w.last_lo, w.last_hi) if response.changed?
    response
  end

  def range_slider(lo : Float64, hi : Float64,
                   range : Range(Float64, Float64),
                   id : String? = nil) : Response
    add(RangeSlider.new(lo, hi, range, id: id))
  end
end
