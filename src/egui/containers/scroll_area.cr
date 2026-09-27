# Port of egui_upstream/crates/egui/src/containers/scroll_area.rs
# (vertical-only stage: wheel scrolling, offset state, clipping,
# scrollbar painting + thumb dragging; kinetic scrolling follows later).
#
# State (upstream ScrollState): scroll offset + content size, stored
# per-id in IdTypeMap. The viewport registers itself with Memory as a
# scroll sink — only the top-most sink under the pointer (scroll area,
# textarea, plot…) consumes `input.scroll`.
#
# Two scrollbar flavors: `:overlay` (default) paints a thin bar over
# the content's right edge; `:classic` reserves a separate 16px column
# beside the content, Win95/XP style — square arrow buttons above and
# below the track, a draggable thumb, and track clicks that page
# toward the pointer.

module Egui
  class ScrollArea
    # Overlay bar width (px), pinned over the content's right edge.
    BAR_W = 8.0
    # Classic bar: width of the reserved column and of each square
    # arrow button (px).
    CLASSIC_W = 16.0
    # Classic arrows: one line per click, and a hold repeats at
    # LINE_RATE lines per second.
    LINE = 20.0
    LINE_RATE = 10.0
    # Classic track click: the page is a fraction of the viewport
    # (Win95 pages a little less than a full page so context stays
    # visible at the jump).
    PAGE = 0.8

    def initialize(@max_height : Float64? = nil,
                   @scrollbar : Symbol = :overlay)
    end

    def classic? : Bool
      @scrollbar == :classic
    end

    def show(ui : Ui, &block : Ui ->) : Rect
      style = ui.style
      memory = ui.ctx.memory
      id = ui.next_widget_id

      height = {@max_height || ui.available_height, ui.available_height}.min
      # The classic column is reserved up front, so the viewport (and
      # thus the content width) is stable whether or not the bar is
      # currently scrollable.
      bar_w = classic? ? CLASSIC_W : 0.0
      viewport = Rect.from_min_size(ui.cursor,
        Vec2.new({ui.available_width - bar_w, 0.0}.max, height))

      offset = memory.data.get_vec2(id, Vec2.zero)
      prev_content = memory.data.get_vec2(id.child(0), Vec2.new(0.0, height))
      kin_id = id.child(3)
      memory.use_id(kin_id)

      # Kinetic scrolling: the offset's History estimates a release
      # velocity while direct input drives the offset (wheel below,
      # thumb later); once input stops the offset glides on by that
      # velocity, decaying (see KineticScroller).
      max_offset_prev = {prev_content.y - height, 0.0}.max
      kin = KineticScroller.new(offset.y,
        memory.data.get_f64(kin_id, 0.0), memory.scroll_history(id))

      # Wheel scroll — only if this viewport owns the delta. The raw
      # delta is in wheel notches (±1.0 per click from the backend);
      # `style.scroll_speed` scales it to pixels.
      if memory.active_scroll_area? == id && !ui.ctx.input.scroll.y.zero?
        kin.input(ui.ctx.input.scroll.y * style.scroll_speed,
          ui.ctx.input.time, max_offset_prev)
      else
        kin.glide(ui.ctx.input.dt, max_offset_prev, ui.ctx)
      end
      offset = Vec2.new(0.0, kin.offset)

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
      kin_velocity = kin.velocity
      memory.data.set_vec2(id, offset)
      memory.data.set_vec2(id.child(0), content_size)

      ui.painter.clip = outer_clip

      # Scrollbar when the content overflows vertically. Both flavors
      # report whether the user directly drove the offset this frame
      # (thumb drag / arrows / paging) — direct control kills inertia.
      covering = viewport
      direct = false
      if content_size.y > viewport.height && viewport.height > 0.0
        if classic?
          bar, direct = classic_bar(ui, id, viewport, content_size.y,
            max_offset, offset, kin)
          covering = viewport.union(bar)
        else
          direct = overlay_bar(ui, id, viewport, content_size.y,
            max_offset, offset, kin)
        end
      elsif classic?
        # Nothing to scroll: the column stays (stable layout) with a
        # disabled look — groove + dimmed arrows, no thumb, no clicks.
        bar, up_r, down_r = classic_geometry(viewport)
        visuals = style.visuals
        ui.painter.rect(bar, fill: visuals.button_weak)
        Icons.arrow_button(ui.painter, :up, up_r, visuals.button_weak,
          visuals.separator_color, pressed: false)
        Icons.arrow_button(ui.painter, :down, down_r, visuals.button_weak,
          visuals.separator_color, pressed: false)
        covering = viewport.union(bar)
      end
      kin_velocity = 0.0 if direct

      memory.data.set_f64(kin_id, kin_velocity)
      ui.min_rect = ui.min_rect.union(covering)
      ui.cursor = ui.cursor + Vec2.new(0.0, height + style.spacing.item_spacing.y)
      viewport
    end

    # --- overlay bar (default) ------------------------------------------
    #
    # The whole bar senses click+drag (upstream scroll_area.rs:
    # `ui.interact(max_bar_rect, interact_id, Sense::CLICK | Sense::DRAG)`);
    # while pressed or dragged the thumb is positioned absolutely under
    # the pointer — grabbing the thumb keeps the grab point, pressing
    # the track centers the thumb on the pointer. Returns whether the
    # user directly drove the offset this frame.
    private def overlay_bar(ui : Ui, id : Id, viewport : Rect,
                            content_h : Float64, max_offset : Float64,
                            offset : Vec2, kin : KineticScroller) : Bool
      memory = ui.ctx.memory
      track = Rect.from_min_size(
        Pos2.new(viewport.right - BAR_W, viewport.top),
        Vec2.new(BAR_W, viewport.height))
      bar_id = id.child(2)
      response = ui.interact(track, bar_id, Sense.click_and_drag)

      thumb_h = (viewport.height * viewport.height / content_h)
        .clamp(12.0, viewport.height)
      scrollable = viewport.height - thumb_h
      thumb_y = ->(off : Float64) : Float64 do
        max_offset > 0.0 ? viewport.top + scrollable * off / max_offset
                          : viewport.top
      end

      # Upstream `scroll_start_offset_from_top_left`: where inside the
      # thumb the pointer grabbed, latched at interaction start and
      # cleared when the pointer leaves (NaN = no grab in progress).
      direct = false
      if (response.pressed? || response.dragged?) &&
         (pointer = ui.ctx.input.pointer_pos)
        kin.takeover # direct control: no inertia after a thumb drag
        direct = true
        grab = memory.data.get_f64(bar_id, Float64::NAN)
        if grab.nan?
          thumb_now = Rect.from_min_size(
            Pos2.new(track.left, thumb_y.call(offset.y)),
            Vec2.new(BAR_W, thumb_h))
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

      visuals = ui.style.visuals
      ui.painter.rect(track, 4.0, visuals.button_weak)

      thumb = Rect.from_min_size(
        Pos2.new(track.left + 1.0, thumb_y.call(offset.y) + 1.0),
        Vec2.new(BAR_W - 2.0, {thumb_h - 2.0, 4.0}.max)
      )
      # Classic thumb: face-colored with a stroke border — the border is
      # what keeps it visible when the face matches the track (light
      # system themes set weak = track = face, e.g. XP #ECE9D8). The
      # interaction states use the button states, never the selection
      # accent — no OS tints its scrollbar thumb accent-blue.
      thumb_color = visuals.button_hovered if response.hovered?
      thumb_color = visuals.button_active if response.pressed? || response.dragged?
      thumb_color ||= visuals.button_weak
      ui.painter.rect(thumb, 3.0, thumb_color, visuals.button_stroke, 1.0)
      direct
    end

    # --- classic bar (Win95/XP) -----------------------------------------
    #
    # Column geometry shared by the live and disabled branches:
    # {bar, up button, down button} (the track spans between them).
    private def classic_geometry(viewport : Rect)
      bar = Rect.from_min_size(Pos2.new(viewport.right, viewport.top),
        Vec2.new(CLASSIC_W, viewport.height))
      up_r = Rect.from_min_size(bar.min, Vec2.new(CLASSIC_W, CLASSIC_W))
      down_r = Rect.from_min_size(
        Pos2.new(bar.left, bar.bottom - CLASSIC_W),
        Vec2.new(CLASSIC_W, CLASSIC_W))
      {bar, up_r, down_r}
    end

    # Returns {bar rect, direct-control flag}. `offset` in/out goes
    # through Memory (`memory.data`), same as the overlay bar.
    private def classic_bar(ui : Ui, id : Id, viewport : Rect,
                            content_h : Float64, max_offset : Float64,
                            offset : Vec2, kin : KineticScroller)
      memory = ui.ctx.memory
      bar, up_r, down_r = classic_geometry(viewport)
      track = Rect.from_min_size(
        Pos2.new(bar.left, bar.top + CLASSIC_W),
        Vec2.new(CLASSIC_W, {bar.height - CLASSIC_W * 2.0, 0.0}.max))

      bar_id = id.child(2)
      up = ui.interact(up_r, id.child(4), Sense.click)
      down = ui.interact(down_r, id.child(5), Sense.click)
      track_resp = ui.interact(track, bar_id, Sense.click_and_drag)

      # Thumb: sized by the viewport/content ratio inside the track
      # (not the viewport), positioned by the offset.
      thumb_h = track.height.positive? ?
        (track.height * viewport.height / content_h).clamp(12.0, track.height) : 0.0
      scrollable = track.height - thumb_h
      thumb = ->(off : Float64) : Rect do
        top = max_offset > 0.0 && scrollable > 0.0 ?
          track.top + scrollable * off / max_offset : track.top
        Rect.from_min_size(Pos2.new(track.left + 1.0, top + 1.0),
          Vec2.new(CLASSIC_W - 2.0, {thumb_h - 2.0, 4.0}.max))
      end

      # Helper: drive the offset directly (clamp + store + no inertia).
      direct_ctrl = false
      set_offset = ->(y : Float64) do
        kin.takeover
        direct_ctrl = true
        offset = Vec2.new(0.0, y.clamp(0.0, max_offset))
        memory.data.set_vec2(id, offset)
      end

      # Arrow buttons: one line per click, hold repeats. The repeat
      # runs on the interaction itself, so keep frames coming.
      if up.pressed?
        ui.ctx.request_repaint
        set_offset.call(offset.y - LINE * LINE_RATE * ui.ctx.input.dt)
      end
      if up.clicked?
        set_offset.call(offset.y - LINE)
      end
      if down.pressed?
        ui.ctx.request_repaint
        set_offset.call(offset.y + LINE * LINE_RATE * ui.ctx.input.dt)
      end
      if down.clicked?
        set_offset.call(offset.y + LINE)
      end
      offset = memory.data.get_vec2(id, offset)

      # Track: press on the thumb grabs it (grab point kept, absolute
      # positioning like the overlay bar); a plain click on the track
      # pages toward the pointer (Win95 paging).
      pointer = ui.ctx.input.pointer_pos
      if track_resp.pressed? || track_resp.dragged?
        grab = memory.data.get_f64(bar_id, Float64::NAN)
        if grab.nan? && (ptr = pointer) && thumb.call(offset.y).contains?(ptr)
          grab = ptr.y - thumb.call(offset.y).top
          memory.data.set_f64(bar_id, grab)
        end
        if !grab.nan? && scrollable > 0.0 && (ptr = pointer)
          set_offset.call((ptr.y - grab - track.top) * max_offset / scrollable)
          offset = memory.data.get_vec2(id, offset)
        end
      else
        memory.data.set_f64(bar_id, Float64::NAN)
        if track_resp.clicked? && (ptr = pointer) &&
           !thumb.call(offset.y).contains?(ptr)
          page = viewport.height * PAGE
          set_offset.call(offset.y +
            (ptr.y > thumb.call(offset.y).center.y ? page : -page))
          offset = memory.data.get_vec2(id, offset)
        end
      end

      # Paint: groove under everything, beveled buttons + thumb, line
      # arrows from the built-in icon set.
      visuals = ui.style.visuals
      painter = ui.painter
      painter.rect(bar, fill: visuals.button_weak)

      Icons.arrow_button(painter, :up, up_r,
        visuals.button_fill(up.hovered?, up.pressed?),
        visuals.text_color, pressed: up.pressed?)
      Icons.arrow_button(painter, :down, down_r,
        visuals.button_fill(down.hovered?, down.pressed?),
        visuals.text_color, pressed: down.pressed?)

      if track.height.positive?
        dragging = track_resp.pressed? || track_resp.dragged?
        thumb_hover = false
        if track_resp.hovered? && (ptr = pointer)
          thumb_hover = thumb.call(offset.y).contains?(ptr)
        end
        Icons.bevel(painter, thumb.call(offset.y),
          visuals.button_fill(thumb_hover, dragging), dragging)
      end

      {bar, direct_ctrl}
    end
  end
end
