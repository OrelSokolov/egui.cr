# Port of egui_upstream/crates/egui/src/context.rs.
#
# The Context owns the system state (Memory: data/areas/focus/
# animations/popups), the frame's input and painter, and drives the
# immediate-mode loop:
#
#   ctx.begin_frame(raw)   # derive InputState, rotate Memory geometry
#   app.update(ctx)        # widgets run top-to-bottom, push commands
#   ctx.end_frame          # → paint list for the backend (layer order)
#
# Containers: #window is the Area+Frame+Collapsed composite from
# upstream — movable via its title bar (drag through Areas state),
# stacked in the Middle layer; #popup rides the Foreground layer and
# closes on outside click; #bottom_panel pins to the screen bottom.

module Egui
  class Context
    getter memory : Memory
    getter input : InputState
    getter painter : Painter
    # The active global theme. Widgets read its #style every frame, so
    # assigning a new theme (`ctx.theme = Theme.light`) restyles the
    # entire UI on the very next frame — an instant swap.
    getter theme : Theme
    property fonts : Fonts
    property textures : TextureRegistry

    getter fps : Float64

    # The cursor the frame asked the integration to show (upstream
    # `PlatformOutput::cursor_icon`): reset to Default each
    # begin_frame, set by widgets via #set_cursor_icon / hover.
    getter cursor_icon : CursorIcon

    # egui `Context::available_rect`: screen area not yet claimed by
    # panels. Reset each begin_frame; every panel takes a bite; the
    # central panel takes what's left (panels must be added first —
    # the upstream ordering rule).
    getter available_rect : Rect

    @prev_time : Float64?
    @repaint_outstanding : Int32
    @frame_cache : Hash(String, IdTypeMap::Cell)

    def initialize
      @memory = Memory.new
      @input = InputState.new(Rect.zero, nil, false, false, false,
        Vec2.zero, 0.0, 0.016)
      @painter = Painter.new
      @theme = Theme.dark
      @cursor_icon = CursorIcon::Default
      @fonts = MonospaceFonts.new
      @textures = DummyTextureRegistry.new
      @prev_time = nil
      @fps = 0.0
      @repaint_outstanding = 0
      @frame_cache = {} of String => IdTypeMap::Cell
      @available_rect = Rect.zero
      @texture_cache = {} of String => UInt64
    end

    def begin_frame(raw : RawInput) : Nil
      @input = InputState.build(raw, @input, @prev_time)
      @prev_time = raw.time
      @available_rect = raw.screen_rect
      @cursor_icon = CursorIcon::Default

      # Smoothed FPS (EMA) — read by apps to show in a bottom panel.
      if @input.dt > 0.0
        instantaneous = 1.0 / @input.dt
        @fps = @fps < 1.0 ? instantaneous : @fps * 0.9 + instantaneous * 0.1
      end

      @repaint_outstanding -= 1 if @repaint_outstanding > 0
      @frame_cache.clear

      @memory.begin_frame(@input)
      @painter.clear
    end

    # Instant theme swap (see #theme) — takes effect next frame.
    def theme=(theme : Theme) : Theme
      @theme = theme
      request_repaint
      theme
    end

    # The active theme's style — what every un-overridden widget reads.
    def style : Style
      @theme.style
    end

    # The active theme's CSS-like class styles (see `StyleSheet`).
    def stylesheet : StyleSheet
      @theme.sheet
    end

    def end_frame : Array(PaintCmd)
      @memory.end_frame
      @painter.commands_in_layer_order
    end

    # egui `Context::set_cursor_icon`: a widget requests the cursor
    # while hovered/dragged; the backend reads #cursor_icon after
    # end_frame.
    def set_cursor_icon(icon : CursorIcon) : Nil
      @cursor_icon = icon
    end

    def interact(id : Id, rect : Rect, sense : Sense,
                 layer : LayerId = LayerId.background,
                 clip : Rect = Rect.infinite) : Response
      v = @memory.interact(id, rect, sense, layer, clip)
      response = Response.new(self, id, rect, sense, v.hovered?, v.clicked?,
        v.click_count, v.pressed?, v.active?, v.dragged?, v.drag_started?,
        v.drag_stopped?, v.drag_delta)
      # CSS `cursor: pointer` style (upstream `Visuals::interact_cursor`,
      # applied per-widget there — one hook here covers every clickable).
      if response.hovered? && sense.click? &&
         (icon = @theme.style.visuals.interact_cursor)
        @cursor_icon = icon
      end
      response
    end

    # --- animation / cache / repaint seams --------------------------------

    # egui `Context::animate_value_with_time`: smoothly move `value`
    # towards its new target; state keyed by widget id.
    def animate_value_with_time(id : Id, value : Float64,
                                duration : Float64 = 0.15) : Float64
      @memory.animations.animate(id, value, duration, @input.time)
    end

    # egui CacheStorage-lite: memoize an expensive computation for the
    # current frame only (cleared in begin_frame).
    def frame_cache(key : String, &block : -> IdTypeMap::Cell) : IdTypeMap::Cell
      if (hit = @frame_cache[key]?)
        hit
      else
        value = block.call
        @frame_cache[key] = value
        value
      end
    end

    # egui `Context::load_texture`: decode an image file and cache it
    # per path; 0 means "couldn't load".
    def load_image(path : String) : UInt64
      @texture_cache[path] ||= @textures.load(path)
    end

    # egui repaint scheduling: an immediate request buys two repaints so
    # frame-delayed responses settle. The sokol backend runs continuous
    # vsync today and ignores this; keep the API 1:1 for on-demand mode.
    def request_repaint : Nil
      @repaint_outstanding = 2
    end

    def needs_repaint? : Bool
      @repaint_outstanding > 0
    end

    # --- containers --------------------------------------------------------

    # A titled, movable, resizable window. egui order preserved:
    # reserve the background slot, interact with the title bar (drag →
    # Areas state moves the window; click/hover → bring to top), build
    # contents, back-fill the frame, title.
    WINDOW_MIN_SIZE = Vec2.new(120.0, 80.0)
    def window(title : String, default_pos : Pos2 = Pos2.new(24.0, 24.0),
               width : Float64 = 380.0, &block : Ui ->) : Nil
      win_id = Id.from("window/#{title}")
      layer = LayerId.new(Order::Middle, win_id)
      pad = style.spacing.window_padding
      title_size = style.font_size * 1.25
      title_h = title_size + pad.y

      pos = @memory.areas.pos_for(win_id, default_pos)
      size = @memory.layer_sizes[win_id]? || Vec2.new(width, 160.0)

      @painter.layer = Order::Middle
      bg_index = @painter.add_noop

      # Title bar: drag moves the window, interaction brings it to top.
      title_rect = Rect.from_min_size(pos, Vec2.new(size.x, title_h))
      title_id = win_id.child(0_u64)
      title_resp = interact(title_id, title_rect, Sense.click_and_drag, layer)
      if title_resp.dragged?
        @memory.areas.move_by(win_id, title_resp.drag_delta)
        pos = @memory.areas.pos_for(win_id, default_pos)
      end
      if title_resp.hovered? || title_resp.pressed? || title_resp.dragged?
        @memory.areas.bring_to_top(layer)
      end

      @painter.clip = Rect.from_min_size(pos, Vec2.new(size.x, 1e6))
      content_min = pos + Vec2.new(pad.x, title_h + pad.y)
      ui = Ui.new(self, win_id,
        Rect.from_min_size(content_min, Vec2.new(size.x - 2 * pad.x, 1e6)))
      ui.layer = layer
      # Interaction stays inside the window's horizontal extent; the
      # height grows with the content, hence the 1e6 tall strip.
      ui.clip = Rect.from_min_size(pos, Vec2.new(size.x, 1e6))
      yield ui

      outer = Rect.new(
        pos,
        Pos2.new({ui.min_rect.right + pad.x, pos.x + size.x}.max,
          ui.min_rect.bottom + pad.y))

      # Resize grip: drag the bottom-right corner (upstream `Resize`
      # wired into `Window`); size persists in Memory#layer_sizes.
      grip_size = 12.0
      grip = Rect.from_min_size(
        Pos2.new(outer.max.x - grip_size, outer.max.y - grip_size),
        Vec2.new(grip_size, grip_size))
      grip_id = Id.from("window/#{title}/resize_grip")
      grip_resp = interact(grip_id, grip, Sense.drag, layer)
      grip_resp.on_hover_and_drag_cursor(CursorIcon::NwseResize)
      if grip_resp.dragged?
        size = size + grip_resp.drag_delta
        size = Vec2.new({size.x, WINDOW_MIN_SIZE.x}.max,
          {size.y, WINDOW_MIN_SIZE.y}.max)
        outer = Rect.new(outer.min, outer.min + size)
      end
      @memory.layer_sizes[win_id] = outer.size

      @painter.clip = outer
      @painter.set(bg_index,
        RectCmd.new(outer, outer, 6.0, style.visuals.window_fill,
          style.visuals.window_stroke, 1.0))
      @painter.text(Pos2.new(pos.x + pad.x, pos.y + title_h / 2.0),
        title, title_size, style.visuals.title_color)
      # Grip: two small diagonal marks.
      (1..2).each do |i|
        o = grip_size - 4.0 * i
        @painter.line(
          Pos2.new(grip.max.x - o, grip.max.y - 4.0),
          Pos2.new(grip.max.x - 4.0, grip.max.y - o),
          2.0, style.visuals.separator_color)
      end
      @painter.layer = Order::Background
      @painter.clip = Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))
    end

    # egui `Area` (containers/area.rs) — an explicit positioned region
    # in its own Middle layer: the building block window/popup are made
    # of, exposed for custom floating content. Position persists in
    # Areas (bring-to-top on interaction, like a window without chrome).
    def area(id : String, default_pos : Pos2 = Pos2.zero,
             width : Float64 = 300.0, &block : Ui ->) : Nil
      area_id = Id.from("area/#{id}")
      layer = LayerId.new(Order::Middle, area_id)
      pos = @memory.areas.pos_for(area_id, default_pos)

      probe = Rect.from_min_size(pos, Vec2.new(width, 1.0))
      probe_resp = interact(area_id.child(0_u64), probe, Sense.click, layer)
      @memory.areas.bring_to_top(layer) if probe_resp.hovered? || probe_resp.pressed?

      @painter.layer = Order::Middle
      @painter.clip = Rect.from_min_size(pos, Vec2.new(width, 1e6))
      ui = Ui.new(self, area_id,
        Rect.from_min_size(pos, Vec2.new(width, 1e6)))
      ui.layer = layer
      yield ui

      @painter.layer = Order::Background
      @painter.clip = Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))
    end

    # egui popup (containers/popup.rs): rides the Foreground layer,
    # closes when a click lands outside it (Memory#end_frame). `pad`
    # overrides the frame's inner padding (menus pass a zero vertical
    # pad so the frame hugs the first/last item).
    def popup(id : String, anchor : Pos2, width : Float64 = 220.0,
              pad : Vec2? = nil, &block : Ui ->) : Nil
      pop_id = Id.from("popup/#{id}")
      return unless @memory.open_popups.includes?(pop_id)

      # Snap to last frame's measured size (like #modal): menus size
      # themselves from their items' natural widths (via Ui#min_rect),
      # so frame one opens at `width`, later frames hug the content.
      width = @memory.layer_sizes[pop_id]?.try(&.x) || width

      layer = LayerId.new(Order::Foreground, pop_id)
      pad ||= style.spacing.window_padding

      @painter.layer = Order::Foreground
      bg_index = @painter.add_noop
      @painter.clip = Rect.from_min_size(anchor, Vec2.new(width, 1e6))
      ui = Ui.new(self, pop_id,
        Rect.from_min_size(anchor + Vec2.new(pad.x, pad.y),
          Vec2.new(width - 2 * pad.x, 1e6)))
      ui.layer = layer
      yield ui

      outer = Rect.new(
        anchor,
        Pos2.new(ui.min_rect.right + pad.x, ui.min_rect.bottom + pad.y))
      @memory.layer_sizes[pop_id] = outer.size
      @memory.popup_rects[pop_id] = outer
      @painter.clip = outer
      @painter.set(bg_index,
        RectCmd.new(outer, outer, 4.0, style.visuals.window_fill,
          style.visuals.window_stroke, 1.0))
      @painter.layer = Order::Background
      @painter.clip = Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))
    end

    def popup_open?(id : String) : Bool
      @memory.open_popups.includes?(Id.from("popup/#{id}"))
    end

    def open_popup(id : String) : Nil
      @memory.open_popup(Id.from("popup/#{id}"))
      request_repaint
    end

    def close_popup(id : String) : Nil
      @memory.close_popup(Id.from("popup/#{id}"))
      request_repaint
    end

    # egui modal (containers/modal.rs): dims the screen and blocks all
    # interaction below the Foreground layer (Memory#mark_modal). The
    # dialog is centered using its last-frame size (stored per id) —
    # the first frame it appears at an approximate position, then
    # snaps. Closing is the caller's business (a Close button calling
    # nothing — just stop calling #modal).
    def modal(id : String = "modal", width : Float64 = 340.0,
              &block : Ui ->) : Nil
      @memory.mark_modal
      modal_id = Id.from("modal/#{id}")
      layer = LayerId.new(Order::Foreground, modal_id)
      screen = @input.screen_rect
      pad = style.spacing.window_padding

      # Dim everything below (theme-driven scrim — `Visuals#modal_dim`).
      @painter.layer = Order::Foreground
      @painter.clip = screen
      @painter.rect(screen, 0.0, style.visuals.modal_dim)

      # Center using last frame's size.
      prev_size = @memory.layer_sizes[modal_id]? || Vec2.new(width, 120.0)
      pos = Pos2.new(screen.center.x - prev_size.x / 2.0,
        screen.center.y - prev_size.y / 2.0)

      bg_index = @painter.add_noop
      @painter.clip = Rect.from_min_size(pos, Vec2.new(width, 1e6))
      content_min = pos + Vec2.new(pad.x, pad.y)
      ui = Ui.new(self, modal_id,
        Rect.from_min_size(content_min, Vec2.new(width - 2 * pad.x, 1e6)))
      ui.layer = layer
      yield ui

      outer = Rect.new(pos,
        Pos2.new({ui.min_rect.right + pad.x, pos.x + width}.max,
          ui.min_rect.bottom + pad.y))
      @memory.layer_sizes[modal_id] = outer.size
      @painter.clip = outer
      @painter.set(bg_index,
        RectCmd.new(outer, outer, 8.0, style.visuals.window_fill,
          style.visuals.window_stroke, 1.0))
      @painter.layer = Order::Background
      @painter.clip = Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))
    end

    # --- panels (egui containers/panel.rs) --------------------------------
    #
    # egui `TopBottomPanel`/`SidePanel`/`CentralPanel`: each panel takes
    # a bite out of #available_rect in the order it is added; the
    # central panel takes what's left. Panels MUST be added before
    # #central_panel (upstream ordering rule) — this replaces the old
    # "contents drawn before bottom_panel don't shift" simplification.

    def top_panel(id : String = "top_panel", &block : Ui ->) : Rect
      line_h = style.font_size * Fonts::LINE_H_FACTOR
      pad = style.spacing.window_padding
      height = line_h + 2 * pad.y
      rect = Rect.from_min_size(@available_rect.min,
        Vec2.new(@available_rect.width, height))
      @available_rect = Rect.new(
        Pos2.new(rect.left, rect.bottom),
        @available_rect.max)
      panel_ui(id, rect, Layout.left_to_right) { |ui| yield ui }
      rect
    end

    def bottom_panel(id : String = "bottom_panel", &block : Ui ->) : Rect
      line_h = style.font_size * Fonts::LINE_H_FACTOR
      pad = style.spacing.window_padding
      height = line_h + 2 * pad.y
      rect = Rect.from_min_size(
        Pos2.new(@available_rect.min.x, @available_rect.max.y - height),
        Vec2.new(@available_rect.width, height))
      @available_rect = Rect.new(@available_rect.min,
        Pos2.new(rect.right, rect.top))
      panel_ui(id, rect, Layout.left_to_right) { |ui| yield ui }
      rect
    end

    def side_panel(side : Symbol, id : String = "side_panel",
                   width : Float64 = 200.0, &block : Ui ->) : Rect
      w = {width, @available_rect.width}.min
      rect = if side == :right
        Rect.from_min_size(
          Pos2.new(@available_rect.max.x - w, @available_rect.min.y),
          Vec2.new(w, @available_rect.height))
      else
        Rect.from_min_size(@available_rect.min,
          Vec2.new(w, @available_rect.height))
      end
      @available_rect = if side == :right
        Rect.new(@available_rect.min,
          Pos2.new(rect.left, @available_rect.max.y))
      else
        Rect.new(Pos2.new(rect.right, @available_rect.min.y),
          @available_rect.max)
      end
      panel_ui(id, rect, Layout.top_down) { |ui| yield ui }
      rect
    end

    # egui `CentralPanel::show` — the remainder. Returns its rect.
    def central_panel(id : String = "central_panel", &block : Ui ->) : Rect
      rect = @available_rect
      panel_ui(id, rect, Layout.top_down) { |ui| yield ui }
      rect
    end

    private def panel_ui(id : String, rect : Rect, layout : Layout,
                         &block : Ui ->) : Nil
      pad = style.spacing.window_padding

      @painter.layer = Order::Background
      bg_index = @painter.add_noop
      @painter.clip = rect
      @painter.set(bg_index,
        RectCmd.new(rect, rect, 0.0, style.visuals.panel_fill,
          style.visuals.window_stroke, 1.0))

      ui = Ui.new(self, Id.from("panel/#{id}"),
        rect.shrink(pad.x), layout)
      ui.clip = rect
      yield ui

      @painter.clip = Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))
    end
  end
end
