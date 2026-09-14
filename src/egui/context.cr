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
    getter style : Style
    property fonts : Fonts

    getter fps : Float64

    @prev_time : Float64?
    @repaint_outstanding : Int32
    @frame_cache : Hash(String, IdTypeMap::Cell)

    def initialize
      @memory = Memory.new
      @input = InputState.new(Rect.zero, nil, false, false, false,
        Vec2.zero, 0.0, 0.016)
      @painter = Painter.new
      @style = Style.new
      @fonts = MonospaceFonts.new
      @prev_time = nil
      @fps = 0.0
      @repaint_outstanding = 0
      @frame_cache = {} of String => IdTypeMap::Cell
    end

    def begin_frame(raw : RawInput) : Nil
      @input = InputState.build(raw, @input, @prev_time)
      @prev_time = raw.time

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

    def end_frame : Array(PaintCmd)
      @memory.end_frame
      @painter.commands_in_layer_order
    end

    def interact(id : Id, rect : Rect, sense : Sense,
                 layer : LayerId = LayerId.background) : Response
      v = @memory.interact(id, rect, sense, layer)
      Response.new(self, id, rect, sense, v.hovered?, v.clicked?,
        v.click_count, v.pressed?, v.active?, v.dragged?, v.drag_started?,
        v.drag_stopped?, v.drag_delta)
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

    # A titled, movable window. egui order preserved: reserve the
    # background slot, interact with the title bar (drag → Areas state
    # moves the window; click/hover → bring to top), build contents,
    # back-fill the frame, title.
    def window(title : String, default_pos : Pos2 = Pos2.new(24.0, 24.0),
               width : Float64 = 380.0, &block : Ui ->) : Nil
      win_id = Id.from("window/#{title}")
      layer = LayerId.new(Order::Middle, win_id)
      pad = style.spacing.window_padding
      title_size = style.font_size * 1.25
      title_h = title_size + pad.y

      pos = @memory.areas.pos_for(win_id, default_pos)

      @painter.layer = Order::Middle
      bg_index = @painter.add_noop

      # Title bar: drag moves the window, interaction brings it to top.
      title_rect = Rect.from_min_size(pos, Vec2.new(width, title_h))
      title_id = win_id.child(0_u64)
      title_resp = interact(title_id, title_rect, Sense.click_and_drag, layer)
      if title_resp.dragged?
        @memory.areas.move_by(win_id, title_resp.drag_delta)
        pos = @memory.areas.pos_for(win_id, default_pos)
      end
      if title_resp.hovered? || title_resp.pressed? || title_resp.dragged?
        @memory.areas.bring_to_top(layer)
      end

      @painter.clip = Rect.from_min_size(pos, Vec2.new(width, 1e6))
      content_min = pos + Vec2.new(pad.x, title_h + pad.y)
      ui = Ui.new(self, win_id,
        Rect.from_min_size(content_min, Vec2.new(width - 2 * pad.x, 1e6)))
      ui.layer = layer
      yield ui

      outer = Rect.new(
        pos,
        Pos2.new({ui.min_rect.right + pad.x, pos.x + width}.max,
          ui.min_rect.bottom + pad.y))
      @painter.clip = outer
      @painter.set(bg_index,
        RectCmd.new(outer, outer, 6.0, style.visuals.window_fill,
          style.visuals.window_stroke, 1.0))
      @painter.text(Pos2.new(pos.x + pad.x, pos.y + title_h / 2.0),
        title, title_size, style.visuals.title_color)
      @painter.layer = Order::Background
      @painter.clip = Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))
    end

    # egui popup (containers/popup.rs): rides the Foreground layer,
    # closes when a click lands outside it (Memory#end_frame).
    def popup(id : String, anchor : Pos2, width : Float64 = 220.0,
              &block : Ui ->) : Nil
      pop_id = Id.from("popup/#{id}")
      return unless @memory.open_popups.includes?(pop_id)

      layer = LayerId.new(Order::Foreground, pop_id)
      pad = style.spacing.window_padding

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
        Pos2.new({ui.min_rect.right + pad.x, anchor.x + width}.max,
          ui.min_rect.bottom + pad.y))
      @painter.clip = outer
      @painter.set(bg_index,
        RectCmd.new(outer, outer, 4.0, style.visuals.window_fill,
          style.visuals.window_stroke, 1.0))
      @painter.layer = Order::Background
      @painter.clip = Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))
    end

    def open_popup(id : String) : Nil
      @memory.open_popup(Id.from("popup/#{id}"))
      request_repaint
    end

    def close_popup(id : String) : Nil
      @memory.close_popup(Id.from("popup/#{id}"))
      request_repaint
    end

    # egui `TopBottomPanel::bottom(id).show(ctx, …)` — a strip pinned to
    # the bottom of the screen. Same reserve/back-fill trick as #window.
    # NOTE: unlike upstream, contents laid out *before* the panel do not
    # get pushed up (no retained layout yet) — don't overlap it.
    def bottom_panel(id : String = "bottom_panel", &block : Ui ->) : Nil
      screen = @input.screen_rect
      pad = style.spacing.window_padding
      line_h = style.font_size * Fonts::LINE_H_FACTOR

      @painter.layer = Order::Background
      bg_index = @painter.add_noop

      content_min = Pos2.new(screen.min.x + pad.x,
        screen.max.y - pad.y - line_h)
      @painter.clip = screen
      ui = Ui.new(self, Id.from("panel/#{id}"),
        Rect.new(content_min, Pos2.new(screen.max.x - pad.x, screen.max.y - pad.y)),
        Layout.left_to_right)
      yield ui

      outer = Rect.new(
        Pos2.new(screen.min.x, ui.min_rect.min.y - pad.y),
        Pos2.new(screen.max.x, ui.min_rect.max.y + pad.y))
      @painter.clip = outer
      @painter.set(bg_index,
        RectCmd.new(outer, outer, 0.0, style.visuals.panel_fill,
          style.visuals.window_stroke, 1.0))
      @painter.clip = Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))
    end
  end
end
