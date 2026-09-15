# Port of egui_upstream/crates/egui/src/containers/scroll_area.rs
# (vertical-only stage: wheel scrolling, offset state, clipping,
# scrollbar painting + thumb dragging; kinetic scrolling follows later).
#
# State (upstream ScrollState): scroll offset + content size, stored
# per-id in IdTypeMap. The viewport registers itself with Memory for
# scroll arbitration — only the top-most viewport under the pointer
# consumes `input.scroll`.

module Egui
  class ScrollArea
    def initialize(@max_height : Float64? = nil)
    end

    def show(ui : Ui, &block : Ui ->) : Rect
      style = ui.style
      fonts = ui.ctx.fonts
      memory = ui.ctx.memory
      id = ui.next_widget_id

      height = {@max_height || ui.available_height, ui.available_height}.min
      viewport = Rect.from_min_size(ui.cursor,
        Vec2.new(ui.available_width, height))

      offset = memory.data.get_vec2(id, Vec2.zero)
      prev_content = memory.data.get_vec2(id.child(0), Vec2.new(0.0, height))

      # Wheel scroll — only if this viewport owns the delta.
      if memory.active_scroll_area? == id
        delta = ui.ctx.input.scroll
        offset += Vec2.new(0.0, delta.y) unless delta.y.zero?
      end

      memory.register_scroll_area(id, viewport, ui.layer)

      # Lay the content out inside the viewport shifted by the offset;
      # clip painting to the viewport (intersected with the ambient clip).
      outer_clip = ui.painter.clip
      clip_min = Pos2.new({outer_clip.min.x, viewport.min.x}.max,
        {outer_clip.min.y, viewport.min.y}.max)
      clip_max = Pos2.new({outer_clip.max.x, viewport.max.x}.min,
        {outer_clip.max.y, viewport.max.y}.min)
      ui.painter.clip = Rect.new(clip_min, clip_max)

      inner = ui.child_ui(
        Rect.from_min_size(viewport.min + Vec2.new(0.0, -offset.y),
          Vec2.new(viewport.width, 1e6)),
        id: id.child(1))
      inner.layer = ui.layer
      inner.clip = Rect.new(clip_min, clip_max)
      yield inner

      content_size = inner.min_rect.size
      max_offset = {content_size.y - viewport.height, 0.0}.max
      offset = Vec2.new(0.0, offset.y.clamp(0.0, max_offset))
      memory.data.set_vec2(id, offset)
      memory.data.set_vec2(id.child(0), content_size)

      ui.painter.clip = outer_clip

      # Scrollbar when the content overflows vertically. The whole bar
      # senses click+drag (upstream scroll_area.rs: `ui.interact(
      # max_bar_rect, interact_id, Sense::CLICK | Sense::DRAG)`); while
      # pressed or dragged the thumb is positioned absolutely under the
      # pointer — grabbing the thumb keeps the grab point, pressing the
      # track centers the thumb on the pointer.
      if content_size.y > viewport.height && viewport.height > 0.0
        bar_w = 8.0
        track = Rect.from_min_size(
          Pos2.new(viewport.right - bar_w, viewport.top),
          Vec2.new(bar_w, viewport.height))
        bar_id = id.child(2)
        response = ui.interact(track, bar_id, Sense.click_and_drag)

        thumb_h = (viewport.height * viewport.height / content_size.y)
          .clamp(12.0, viewport.height)
        scrollable = viewport.height - thumb_h
        thumb_y = ->(off : Float64) : Float64 do
          max_offset > 0.0 ? viewport.top + scrollable * off / max_offset
                            : viewport.top
        end

        # Upstream `scroll_start_offset_from_top_left`: where inside the
        # thumb the pointer grabbed, latched at interaction start and
        # cleared when the pointer leaves (NaN = no grab in progress).
        if (response.pressed? || response.dragged?) &&
           (pointer = ui.ctx.input.pointer_pos)
          grab = memory.data.get_f64(bar_id, Float64::NAN)
          if grab.nan?
            thumb_now = Rect.from_min_size(
              Pos2.new(track.left, thumb_y.call(offset.y)),
              Vec2.new(bar_w, thumb_h))
            grab = thumb_now.contains?(pointer) ? pointer.y - thumb_now.top
                                                : thumb_h / 2.0
            memory.data.set_f64(bar_id, grab)
          end
          if scrollable > 0.0
            offset = Vec2.new(0.0,
              ((pointer.y - grab - track.top) * max_offset / scrollable)
                .clamp(0.0, max_offset))
            memory.data.set_vec2(id, offset)
          end
        else
          memory.data.set_f64(bar_id, Float64::NAN)
        end

        visuals = style.visuals
        ui.painter.rect(track, 4.0, visuals.button_weak)

        thumb = Rect.from_min_size(
          Pos2.new(track.left + 1.0, thumb_y.call(offset.y) + 1.0),
          Vec2.new(bar_w - 2.0, {thumb_h - 2.0, 4.0}.max))
        thumb_color = visuals.button_hovered
        if response.pressed? || response.dragged? || response.hovered?
          thumb_color = visuals.selection_fill
        end
        ui.painter.rect(thumb, 3.0, thumb_color)
      end

      ui.min_rect = ui.min_rect.union(viewport)
      ui.cursor = ui.cursor + Vec2.new(0.0, height + style.spacing.item_spacing.y)
      viewport
    end
  end
end
