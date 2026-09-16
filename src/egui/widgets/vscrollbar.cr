# egui.cr-native standalone vertical scrollbar (upstream has no
# in-tree widget — ScrollArea paints its own; this one is for custom
# views where the app owns the scroll offset). Same math as the
# ScrollArea bar: thumb size from the viewport/content ratio, dragging
# with a latched grab point, pressing the track centers the thumb on
# the pointer.
#
# The app passes the current offset in and receives the new one back
# through the `Ui#vscrollbar` block when it changed this frame
# (Checkbox pattern); the offset itself is NOT stored — the app owns
# it. Only the drag grab point lives in IdTypeMap.

module Egui
  class VScrollBar
    include Widget

    BAR_WIDTH = 8.0

    def initialize(@offset : Float64, @content_height : Float64,
                   @viewport_height : Float64, @height : Float64? = nil)
    end

    def ui(ui : Ui) : Response
      style = effective_style(ui)
      visuals = style.visuals
      memory = ui.ctx.memory
      id = ui.next_widget_id

      height = @height || ui.available_height
      rect = ui.allocate_at_least(Vec2.new(BAR_WIDTH, height))

      # No overflow → no scrollbar (the bar reserves its width so the
      # layout doesn't reflow when content grows past the viewport).
      max_offset = @content_height - @viewport_height
      if max_offset <= 0.0 || height <= 0.0
        return ui.interact(rect, id, Sense.none)
      end

      response = ui.interact(rect, id, Sense.click_and_drag)

      thumb_h = (height * @viewport_height / @content_height)
        .clamp(12.0, height)
      scrollable = height - thumb_h
      thumb_y = ->(off : Float64) : Float64 do
        rect.top + scrollable * off / max_offset
      end

      # Where inside the thumb the pointer grabbed (upstream
      # `scroll_start_offset_from_top_left`): latched at interaction
      # start, NaN = no grab in progress.
      offset = @offset.clamp(0.0, max_offset)
      if (response.pressed? || response.dragged?) &&
         (pointer = ui.ctx.input.pointer_pos)
        grab = memory.data.get_f64(id.child(0), Float64::NAN)
        if grab.nan?
          thumb_now = Rect.from_min_size(
            Pos2.new(rect.left, thumb_y.call(offset)),
            Vec2.new(BAR_WIDTH, thumb_h))
          grab = thumb_now.contains?(pointer) ? pointer.y - thumb_now.top
                                              : thumb_h / 2.0
          memory.data.set_f64(id.child(0), grab)
        end
        if scrollable > 0.0
          offset = ((pointer.y - grab - rect.top) * max_offset / scrollable)
            .clamp(0.0, max_offset)
        end
      else
        memory.data.set_f64(id.child(0), Float64::NAN)
      end

      ui.painter.rect(rect, 4.0, visuals.button_weak)

      thumb = Rect.from_min_size(
        Pos2.new(rect.left + 1.0, thumb_y.call(offset) + 1.0),
        Vec2.new(BAR_WIDTH - 2.0, {thumb_h - 2.0, 4.0}.max))
      thumb_color = visuals.button_hovered
      if response.pressed? || response.dragged? || response.hovered?
        thumb_color = visuals.selection_fill
      end
      ui.painter.rect(thumb, 3.0, thumb_color)

      if offset != @offset
        response.widget_value = offset
        response.mark_changed
      end
      response
    end
  end

  class Ui
    # `ui.vscrollbar(offset, content_height, viewport_height) { |off| … }`
    # — shows a standalone VScrollBar and hands back the new offset
    # when it changed this frame (drag / track press).
    def vscrollbar(offset : Float64, content_height : Float64,
                   viewport_height : Float64, height : Float64? = nil,
                   &on_change : Float64 ->) : Response
      response = add(VScrollBar.new(offset, content_height,
        viewport_height, height))
      if response.changed? && (v = response.widget_value)
        on_change.call(v)
      end
      response
    end
  end
end
