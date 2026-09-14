# Port of egui_upstream/crates/egui/src/data/input.rs + input_state.rs.
#
# `RawInput` is what a backend feeds into `Context#begin_frame`
# (events collected since the previous frame + viewport geometry).
# `InputState` is the derived, widget-facing view built from it.

module Egui
  enum PointerButton
    Primary
    Secondary
    Middle
  end

  struct Event
    enum Type
      PointerMoved
      PointerButtonPressed
      PointerButtonReleased
      Scroll
      WindowResized
    end

    getter type : Type
    getter pos : Pos2?
    getter button : PointerButton
    getter scroll : Vec2

    def initialize(@type : Type, @pos : Pos2? = nil,
                   @button : PointerButton = :primary,
                   @scroll : Vec2 = Vec2.zero)
    end

    def self.pointer_moved(pos : Pos2) : Event
      new(:pointer_moved, pos: pos)
    end

    def self.pointer_pressed(pos : Pos2, button : PointerButton = :primary) : Event
      new(:pointer_button_pressed, pos: pos, button: button)
    end

    def self.pointer_released(pos : Pos2, button : PointerButton = :primary) : Event
      new(:pointer_button_released, pos: pos, button: button)
    end

    def self.scroll(delta : Vec2) : Event
      new(:scroll, scroll: delta)
    end
  end

  class RawInput
    property events : Array(Event)
    property screen_rect : Rect
    property time : Float64

    def initialize(@screen_rect : Rect = Rect.zero,
                   @events : Array(Event) = [] of Event,
                   @time : Float64 = 0.0)
    end
  end

  class InputState
    getter screen_rect : Rect
    getter pointer_pos : Pos2?
    getter pointer_delta : Vec2
    getter pointer_velocity : Vec2
    getter? pointer_down : Bool
    getter? pointer_pressed : Bool
    getter? pointer_released : Bool
    getter scroll : Vec2
    getter time : Float64
    getter dt : Float64

    def initialize(@screen_rect : Rect, @pointer_pos : Pos2?, @pointer_down : Bool,
                   @pointer_pressed : Bool, @pointer_released : Bool, @scroll : Vec2,
                   @time : Float64, @dt : Float64,
                   @pointer_delta : Vec2 = Vec2.zero,
                   @pointer_velocity : Vec2 = Vec2.zero)
    end

    # Derive this frame's input from RawInput **carried over the previous
    # frame's InputState** (upstream `PointerState` persistence): pointer
    # position and button state survive frames without move/press events.
    # Without this, hover/active flicker on eventless frames.
    def self.build(raw : RawInput, prev : InputState?, prev_time : Float64?) : InputState
      pos : Pos2? = prev.try &.pointer_pos
      down = prev.try(&.pointer_down?) || false
      pressed = released = false
      scroll = Vec2.zero

      raw.events.each do |e|
        case e.type
        in .pointer_moved?
          pos = e.pos unless e.pos.nil?
        in .pointer_button_pressed?
          if e.button.primary?
            down = true
            pressed = true
            pos = e.pos unless e.pos.nil?
          end
        in .pointer_button_released?
          if e.button.primary?
            down = false
            released = true
            pos = e.pos unless e.pos.nil?
          end
        in .scroll?
          scroll = scroll + e.scroll
        in .window_resized?
          # handled via screen_rect
        end
      end

      # Per-frame motion delta and smoothed velocity (egui PointerState:
      # drag deltas, kinetic scrolling, momentum all read these).
      dt = prev_time ? (raw.time - prev_time).clamp(0.0, 1.0) : 0.016
      prev_pos = prev.try &.pointer_pos
      delta = (pos && prev_pos) ? pos.not_nil! - prev_pos : Vec2.zero
      velocity = Vec2.zero
      if prev && dt > 0.0
        v_inst = delta / dt
        velocity = prev.pointer_velocity * 0.8 + v_inst * 0.2
      end

      new(raw.screen_rect, pos, down, pressed, released, scroll, raw.time, dt,
        delta, velocity)
    end
  end
end
