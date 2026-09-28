# Port of egui_upstream/crates/egui/src/containers/scroll_area.rs
# (vertical-first stage: wheel scrolling, offset state, clipping,
# scrollbar painting + thumb dragging; kinetic scrolling follows later).
#
# State (upstream ScrollState): scroll offset + content size, stored
# per-id in IdTypeMap. The viewport registers itself with Memory as a
# scroll sink — only the top-most sink under the pointer (scroll area,
# textarea, plot…) consumes `input.scroll`.
#
# Two scrollbar flavors: `:overlay` (default) paints a thin bar over
# the content's edge; `:classic` reserves a separate 16px strip
# beside the content, Win95/XP style — square arrow buttons on both
# ends, a draggable thumb, and track clicks that page toward the
# pointer.
#
# Bar PLACEMENT is per axis and per side:
#   vbar: :right (default) | :left   — the vertical scrollbar's side
#   hbar: nil (default) | :bottom | :top — horizontal scrolling, off
#        unless a side is given (nil keeps the inner Ui viewport-wide,
#        which is what fill-width content like the Sidebar wants)
# Shift+wheel drives the horizontal axis when one exists (upstream
# convention); otherwise each axis takes its own wheel delta.

module Egui
  class ScrollArea
    # Overlay bar thickness (px), pinned over the content's edge.
    BAR_W = 8.0
    # Classic bar: width of the reserved strip and of each square
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
                   @scrollbar : Symbol = :overlay,
                   @vbar : Symbol = :right,
                   @hbar : Symbol? = nil)
    end

    def classic? : Bool
      @scrollbar == :classic
    end

    def show(ui : Ui, &block : Ui ->) : Rect
      style = ui.style
      memory = ui.ctx.memory
      input = ui.ctx.input
      id = ui.next_widget_id

      height = {@max_height || ui.available_height, ui.available_height}.min
      # The classic strips are reserved up front, so the viewport (and
      # thus the content size) is stable whether or not the bars are
      # currently scrollable. A left/top classic bar shifts the
      # viewport in; a right/bottom one is carved out of its far edge.
      vbar_w = classic? ? CLASSIC_W : 0.0
      hbar_h = classic? && @hbar ? CLASSIC_W : 0.0
      viewport = Rect.from_min_size(
        Pos2.new(ui.cursor.x + (classic? && vbar_left? ? CLASSIC_W : 0.0),
          ui.cursor.y + (classic? && hbar_top? ? CLASSIC_W : 0.0)),
        Vec2.new({ui.available_width - vbar_w, 0.0}.max,
          {height - hbar_h, 0.0}.max))

      offset = memory.data.get_vec2(id, Vec2.zero)
      prev_content = memory.data.get_vec2(id.child(0), Vec2.new(0.0, height))
      kin_id = id.child(3)
      h_kin_id = id.child(6)
      memory.use_id(kin_id)
      memory.use_id(h_kin_id) if @hbar

      # Kinetic scrolling (both axes run their own scroller): the
      # offset's History estimates a release velocity while direct
      # input drives the offset (wheel below, thumb later); once input
      # stops the offset glides on by that velocity, decaying (see
      # KineticScroller).
      max_v_prev = {prev_content.y - viewport.height, 0.0}.max
      max_h_prev = {prev_content.x - viewport.width, 0.0}.max
      v_kin = KineticScroller.new(offset.y,
        memory.data.get_f64(kin_id, 0.0), memory.scroll_history(id))
      h_kin = @hbar ? KineticScroller.new(offset.x,
        memory.data.get_f64(h_kin_id, 0.0), memory.scroll_history(h_kin_id)) : nil

      # Wheel scroll — only if this viewport owns the delta. The raw
      # delta is in wheel notches (±1.0 per click from the backend);
      # `style.scroll_speed` scales it to pixels. Shift+wheel goes to
      # the horizontal axis when one exists (upstream convention).
      active = memory.active_scroll_area? == id
      to_h = @hbar && input.modifiers.shift && !input.scroll.y.zero?
      if active && !input.scroll.y.zero? && !to_h
        v_kin.input(input.scroll.y * style.scroll_speed,
          input.time, max_v_prev)
      else
        v_kin.glide(input.dt, max_v_prev, ui.ctx)
      end
      if (hk = h_kin)
        dx = input.scroll.x
        dx = input.scroll.y if dx.zero? && to_h
        if active && !dx.zero?
          hk.input(dx * style.scroll_speed, input.time, max_h_prev)
        else
          hk.glide(input.dt, max_h_prev, ui.ctx)
        end
      end
      offset = Vec2.new(h_kin.try(&.offset) || 0.0, v_kin.offset)

      memory.register_scroll_area(id, viewport, ui.layer)

      # Lay the content out inside the viewport shifted by the offset;
      # clip painting to the viewport (intersected with the ambient
      # clip). With horizontal scrolling the inner Ui is unbounded in
      # width; otherwise it stays viewport-wide so fill-width content
      # (the Sidebar tabs) keeps its extent.
      outer_clip = ui.painter.clip
      clip_min = Pos2.new({outer_clip.min.x, viewport.min.x}.max,
        {outer_clip.min.y, viewport.min.y}.max)
      clip_max = Pos2.new({outer_clip.max.x, viewport.max.x}.min,
        {outer_clip.max.y, viewport.max.y}.min)
      ui.painter.clip = Rect.new(clip_min, clip_max)

      inner = ui.child_ui(
        Rect.from_min_size(viewport.min - offset,
          Vec2.new(@hbar ? 1e6 : viewport.width, 1e6)),
        id: id.child(1))
      inner.layer = ui.layer
      inner.clip = Rect.new(clip_min, clip_max)
      yield inner

      content_size = inner.min_rect.size
      max_v = {content_size.y - viewport.height, 0.0}.max
      max_h = {content_size.x - viewport.width, 0.0}.max
      offset = Vec2.new(offset.x.clamp(0.0, max_h), offset.y.clamp(0.0, max_v))
      memory.data.set_vec2(id, offset)
      memory.data.set_vec2(id.child(0), content_size)

      ui.painter.clip = outer_clip

      # Scrollbars when the content overflows. Both flavors report
      # whether the user directly drove the offset this frame (thumb
      # drag / arrows / paging) — direct control kills inertia.
      covering = viewport
      v_direct = false
      if content_size.y > viewport.height && viewport.height > 0.0
        if classic?
          bar, v_direct = classic_vbar(ui, id, viewport, content_size.y,
            max_v, offset, v_kin)
          covering = covering.union(bar)
        else
          v_direct = overlay_vbar(ui, id, viewport, content_size.y,
            max_v, offset, v_kin)
        end
      elsif classic?
        # Nothing to scroll: the column stays (stable layout) with a
        # disabled look — groove + dimmed arrows, no thumb, no clicks.
        classic_vbar_disabled(ui, viewport)
        covering = covering.union(classic_vbar_rect(viewport))
      end
      h_direct = false
      if (hk = h_kin)
        if content_size.x > viewport.width && viewport.width > 0.0
          if classic?
            bar, h_direct = classic_hbar(ui, id, viewport, content_size.x,
              max_h, offset, hk)
            covering = covering.union(bar)
          else
            h_direct = overlay_hbar(ui, id, viewport, content_size.x,
              max_h, offset, hk)
          end
        elsif classic?
          classic_hbar_disabled(ui, viewport)
          covering = covering.union(classic_hbar_rect(viewport))
        end
      end

      memory.data.set_f64(kin_id, v_direct ? 0.0 : v_kin.velocity)
      memory.data.set_f64(h_kin_id, h_direct ? 0.0 : hk.try(&.velocity) || 0.0) if @hbar
      ui.min_rect = ui.min_rect.union(covering)
      ui.cursor = ui.cursor + Vec2.new(0.0, height + style.spacing.item_spacing.y)
      viewport
    end

    private def vbar_left? : Bool
      @vbar == :left
    end

    private def hbar_top? : Bool
      @hbar == :top
    end

    # Classic strip rects: the reserved column/row at the configured
    # side of the viewport (outside it — the viewport was shrunk/shift
    # ed up front to make room).
    private def classic_vbar_rect(viewport : Rect) : Rect
      x = vbar_left? ? viewport.left - CLASSIC_W : viewport.right
      Rect.from_min_size(Pos2.new(x, viewport.top),
        Vec2.new(CLASSIC_W, viewport.height))
    end

    private def classic_hbar_rect(viewport : Rect) : Rect
      y = hbar_top? ? viewport.top - CLASSIC_W : viewport.bottom
      Rect.from_min_size(Pos2.new(viewport.left, y),
        Vec2.new(viewport.width, CLASSIC_W))
    end

    # --- overlay bars (default) -----------------------------------------
    #
    # The whole track senses click+drag (upstream scroll_area.rs:
    # `ui.interact(max_bar_rect, interact_id, Sense::CLICK | Sense::DRAG)`);
    # while pressed or dragged the thumb is positioned absolutely under
    # the pointer — grabbing the thumb keeps the grab point, pressing
    # the track centers the thumb on the pointer. Returns whether the
    # user directly drove the offset this frame.
    private def overlay_vbar(ui : Ui, id : Id, viewport : Rect,
                             content_h : Float64, max_offset : Float64,
                             offset : Vec2, kin : KineticScroller) : Bool
      memory = ui.ctx.memory
      track = Rect.from_min_size(
        Pos2.new(vbar_left? ? viewport.left : viewport.right - BAR_W,
          viewport.top),
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
          off = ((pointer.y - grab - track.top) * max_offset / scrollable)
            .clamp(0.0, max_offset)
          memory.data.set_vec2(id, Vec2.new(offset.x, off))
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

    # Horizontal twin of `overlay_vbar` (thumb drag on the x axis).
    private def overlay_hbar(ui : Ui, id : Id, viewport : Rect,
                             content_w : Float64, max_offset : Float64,
                             offset : Vec2, kin : KineticScroller) : Bool
      memory = ui.ctx.memory
      track = Rect.from_min_size(
        Pos2.new(viewport.left,
          hbar_top? ? viewport.top : viewport.bottom - BAR_W),
        Vec2.new(viewport.width, BAR_W))
      bar_id = id.child(7)
      response = ui.interact(track, bar_id, Sense.click_and_drag)

      thumb_w = (viewport.width * viewport.width / content_w)
        .clamp(12.0, viewport.width)
      scrollable = viewport.width - thumb_w
      thumb_x = ->(off : Float64) : Float64 do
        max_offset > 0.0 ? viewport.left + scrollable * off / max_offset
                          : viewport.left
      end

      direct = false
      if (response.pressed? || response.dragged?) &&
         (pointer = ui.ctx.input.pointer_pos)
        kin.takeover
        direct = true
        grab = memory.data.get_f64(bar_id, Float64::NAN)
        if grab.nan?
          thumb_now = Rect.from_min_size(
            Pos2.new(thumb_x.call(offset.x), track.top),
            Vec2.new(thumb_w, BAR_W))
          grab = thumb_now.contains?(pointer) ? pointer.x - thumb_now.left
                                              : thumb_w / 2.0
          memory.data.set_f64(bar_id, grab)
        end
        if scrollable > 0.0
          off = ((pointer.x - grab - track.left) * max_offset / scrollable)
            .clamp(0.0, max_offset)
          memory.data.set_vec2(id, Vec2.new(off, offset.y))
        end
      else
        memory.data.set_f64(bar_id, Float64::NAN)
      end

      visuals = ui.style.visuals
      ui.painter.rect(track, 4.0, visuals.button_weak)

      thumb = Rect.from_min_size(
        Pos2.new(thumb_x.call(offset.x) + 1.0, track.top + 1.0),
        Vec2.new({thumb_w - 2.0, 4.0}.max, BAR_W - 2.0)
      )
      thumb_color = visuals.button_hovered if response.hovered?
      thumb_color = visuals.button_active if response.pressed? || response.dragged?
      thumb_color ||= visuals.button_weak
      ui.painter.rect(thumb, 3.0, thumb_color, visuals.button_stroke, 1.0)
      direct
    end

    # --- classic bars (Win95/XP) ----------------------------------------
    #
    # Vertical geometry shared by the live and disabled branches:
    # {bar, up button, down button} (the track spans between them).
    private def classic_v_geometry(viewport : Rect)
      bar = classic_vbar_rect(viewport)
      up_r = Rect.from_min_size(bar.min, Vec2.new(CLASSIC_W, CLASSIC_W))
      down_r = Rect.from_min_size(
        Pos2.new(bar.left, bar.bottom - CLASSIC_W),
        Vec2.new(CLASSIC_W, CLASSIC_W))
      {bar, up_r, down_r}
    end

    # Horizontal geometry: {bar, left button, right button}.
    private def classic_h_geometry(viewport : Rect)
      bar = classic_hbar_rect(viewport)
      left_r = Rect.from_min_size(bar.min, Vec2.new(CLASSIC_W, CLASSIC_W))
      right_r = Rect.from_min_size(
        Pos2.new(bar.right - CLASSIC_W, bar.top),
        Vec2.new(CLASSIC_W, CLASSIC_W))
      {bar, left_r, right_r}
    end

    # Returns {bar rect, direct-control flag}. `offset` in/out goes
    # through Memory (`memory.data`), same as the overlay bar.
    private def classic_vbar(ui : Ui, id : Id, viewport : Rect,
                             content_h : Float64, max_offset : Float64,
                             offset : Vec2, kin : KineticScroller)
      memory = ui.ctx.memory
      bar, up_r, down_r = classic_v_geometry(viewport)
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
        offset = Vec2.new(offset.x, y.clamp(0.0, max_offset))
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

    # Horizontal twin of `classic_vbar` (left/right arrows, paging on
    # the x axis).
    private def classic_hbar(ui : Ui, id : Id, viewport : Rect,
                             content_w : Float64, max_offset : Float64,
                             offset : Vec2, kin : KineticScroller)
      memory = ui.ctx.memory
      bar, left_r, right_r = classic_h_geometry(viewport)
      track = Rect.from_min_size(
        Pos2.new(bar.left + CLASSIC_W, bar.top),
        Vec2.new({bar.width - CLASSIC_W * 2.0, 0.0}.max, CLASSIC_W))

      bar_id = id.child(7)
      left = ui.interact(left_r, id.child(8), Sense.click)
      right = ui.interact(right_r, id.child(9), Sense.click)
      track_resp = ui.interact(track, bar_id, Sense.click_and_drag)

      thumb_w = track.width.positive? ?
        (track.width * viewport.width / content_w).clamp(12.0, track.width) : 0.0
      scrollable = track.width - thumb_w
      thumb = ->(off : Float64) : Rect do
        x = max_offset > 0.0 && scrollable > 0.0 ?
          track.left + scrollable * off / max_offset : track.left
        Rect.from_min_size(Pos2.new(x + 1.0, track.top + 1.0),
          Vec2.new({thumb_w - 2.0, 4.0}.max, CLASSIC_W - 2.0))
      end

      direct_ctrl = false
      set_offset = ->(x : Float64) do
        kin.takeover
        direct_ctrl = true
        offset = Vec2.new(x.clamp(0.0, max_offset), offset.y)
        memory.data.set_vec2(id, offset)
      end

      if left.pressed?
        ui.ctx.request_repaint
        set_offset.call(offset.x - LINE * LINE_RATE * ui.ctx.input.dt)
      end
      if left.clicked?
        set_offset.call(offset.x - LINE)
      end
      if right.pressed?
        ui.ctx.request_repaint
        set_offset.call(offset.x + LINE * LINE_RATE * ui.ctx.input.dt)
      end
      if right.clicked?
        set_offset.call(offset.x + LINE)
      end
      offset = memory.data.get_vec2(id, offset)

      pointer = ui.ctx.input.pointer_pos
      if track_resp.pressed? || track_resp.dragged?
        grab = memory.data.get_f64(bar_id, Float64::NAN)
        if grab.nan? && (ptr = pointer) && thumb.call(offset.x).contains?(ptr)
          grab = ptr.x - thumb.call(offset.x).left
          memory.data.set_f64(bar_id, grab)
        end
        if !grab.nan? && scrollable > 0.0 && (ptr = pointer)
          set_offset.call((ptr.x - grab - track.left) * max_offset / scrollable)
          offset = memory.data.get_vec2(id, offset)
        end
      else
        memory.data.set_f64(bar_id, Float64::NAN)
        if track_resp.clicked? && (ptr = pointer) &&
           !thumb.call(offset.x).contains?(ptr)
          page = viewport.width * PAGE
          set_offset.call(offset.x +
            (ptr.x > thumb.call(offset.x).center.x ? page : -page))
          offset = memory.data.get_vec2(id, offset)
        end
      end

      visuals = ui.style.visuals
      painter = ui.painter
      painter.rect(bar, fill: visuals.button_weak)

      Icons.arrow_button(painter, :left, left_r,
        visuals.button_fill(left.hovered?, left.pressed?),
        visuals.text_color, pressed: left.pressed?)
      Icons.arrow_button(painter, :right, right_r,
        visuals.button_fill(right.hovered?, right.pressed?),
        visuals.text_color, pressed: right.pressed?)

      if track.width.positive?
        dragging = track_resp.pressed? || track_resp.dragged?
        thumb_hover = false
        if track_resp.hovered? && (ptr = pointer)
          thumb_hover = thumb.call(offset.x).contains?(ptr)
        end
        Icons.bevel(painter, thumb.call(offset.x),
          visuals.button_fill(thumb_hover, dragging), dragging)
      end

      {bar, direct_ctrl}
    end

    # Disabled looks for the classic strips (nothing to scroll): the
    # strip stays for stable layout — groove + dimmed arrows, no
    # thumb, no clicks.
    private def classic_vbar_disabled(ui : Ui, viewport : Rect) : Nil
      bar, up_r, down_r = classic_v_geometry(viewport)
      visuals = ui.style.visuals
      ui.painter.rect(bar, fill: visuals.button_weak)
      Icons.arrow_button(ui.painter, :up, up_r, visuals.button_weak,
        visuals.separator_color, pressed: false)
      Icons.arrow_button(ui.painter, :down, down_r, visuals.button_weak,
        visuals.separator_color, pressed: false)
    end

    private def classic_hbar_disabled(ui : Ui, viewport : Rect) : Nil
      bar, left_r, right_r = classic_h_geometry(viewport)
      visuals = ui.style.visuals
      ui.painter.rect(bar, fill: visuals.button_weak)
      Icons.arrow_button(ui.painter, :left, left_r, visuals.button_weak,
        visuals.separator_color, pressed: false)
      Icons.arrow_button(ui.painter, :right, right_r, visuals.button_weak,
        visuals.separator_color, pressed: false)
    end
  end
end
