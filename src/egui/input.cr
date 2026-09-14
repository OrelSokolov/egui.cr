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

  # Keyboard codes — values match `sapp_keycode` exactly (USB HID:
  # letters 65..90, digits 48..57, function keys from 256) so the
  # backend passes them through untranslated.
  enum KeyCode
    Zero       =  48
    One        =  49
    Two        =  50
    Three      =  51
    Four       =  52
    Five       =  53
    Six        =  54
    Seven      =  55
    Eight      =  56
    Nine       =  57
    A          =  65
    B          =  66
    C          =  67
    D          =  68
    E          =  69
    F          =  70
    G          =  71
    H          =  72
    I          =  73
    J          =  74
    K          =  75
    L          =  76
    M          =  77
    N          =  78
    O          =  79
    P          =  80
    Q          =  81
    R          =  82
    S          =  83
    T          =  84
    U          =  85
    V          =  86
    W          =  87
    X          =  88
    Y          =  89
    Z          =  90
    Escape     = 256
    Enter      = 257
    Tab        = 258
    Backspace  = 259
    Delete     = 261
    Right      = 262
    Left       = 263
    Down       = 264
    Up         = 265
    PageUp     = 266
    PageDown   = 267
    Home       = 268
    End        = 269

    def digit? : Bool
      value >= 48 && value <= 57
    end
  end

  # egui `Modifiers` — keyboard modifier state for an event/frame.
  struct Modifiers
    getter ctrl : Bool
    getter shift : Bool
    getter alt : Bool
    getter super_key : Bool

    def initialize(@ctrl = false, @shift = false, @alt = false,
                   @super_key = false)
    end

    # From the sapp modifier bitmask (SHIFT=0x1 CTRL=0x2 ALT=0x4 SUPER=0x8).
    def self.from_mask(mask : UInt32) : Modifiers
      Modifiers.new(
        ctrl: mask & 0x2 > 0,
        shift: mask & 0x1 > 0,
        alt: mask & 0x4 > 0,
        super_key: mask & 0x8 > 0)
    end
  end

  struct Event
    enum Type
      PointerMoved
      PointerButtonPressed
      PointerButtonReleased
      Scroll
      WindowResized
      KeyPressed
      KeyReleased
      TextInput
    end

    getter type : Type
    getter pos : Pos2?
    getter button : PointerButton
    getter scroll : Vec2
    getter key : KeyCode
    getter text : String
    getter modifiers : Modifiers

    def initialize(@type : Type, @pos : Pos2? = nil,
                   @button : PointerButton = :primary,
                   @scroll : Vec2 = Vec2.zero,
                   @key : KeyCode = :escape,
                   @text : String = "",
                   @modifiers : Modifiers = Modifiers.new)
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

    def self.key_pressed(key : KeyCode,
                         modifiers : Modifiers = Modifiers.new) : Event
      new(:key_pressed, key: key, modifiers: modifiers)
    end

    def self.key_released(key : KeyCode,
                          modifiers : Modifiers = Modifiers.new) : Event
      new(:key_released, key: key, modifiers: modifiers)
    end

    def self.text_input(text : String) : Event
      new(:text_input, text: text)
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
    # Keyboard: currently-held keys, this frame's press/release sets,
    # keys already eaten by a widget (`consume_key`), concatenated text
    # input, and the last-seen modifier state (egui InputState).
    getter keys_down : Set(KeyCode)
    getter keys_pressed : Set(KeyCode)
    getter keys_released : Set(KeyCode)
    getter consumed_keys : Set(KeyCode)
    getter text : String
    getter modifiers : Modifiers

    def initialize(@screen_rect : Rect, @pointer_pos : Pos2?, @pointer_down : Bool,
                   @pointer_pressed : Bool, @pointer_released : Bool, @scroll : Vec2,
                   @time : Float64, @dt : Float64,
                   @pointer_delta : Vec2 = Vec2.zero,
                   @pointer_velocity : Vec2 = Vec2.zero,
                   @keys_down : Set(KeyCode) = Set(KeyCode).new,
                   @keys_pressed : Set(KeyCode) = Set(KeyCode).new,
                   @keys_released : Set(KeyCode) = Set(KeyCode).new,
                   @text : String = "",
                   @modifiers : Modifiers = Modifiers.new)
      @consumed_keys = Set(KeyCode).new
    end

    def key_pressed?(key : KeyCode) : Bool
      @keys_pressed.includes?(key) && !@consumed_keys.includes?(key)
    end

    def key_down?(key : KeyCode) : Bool
      @keys_down.includes?(key)
    end

    def key_released?(key : KeyCode) : Bool
      @keys_released.includes?(key)
    end

    # egui `InputState::consume_key`: a widget claims a pressed key;
    # subsequent widgets (and navigation) no longer see it.
    def consume_key(key : KeyCode) : Bool
      return false unless key_pressed?(key)
      @consumed_keys.add(key)
      true
    end

    def any_modifier_down? : Bool
      @modifiers.ctrl || @modifiers.shift || @modifiers.alt || @modifiers.super_key
    end

    # egui `InputState::aim_radius` — how coarse the pointer aims (in
    # points); sliders pass ± this around the pointer position to
    # smart_aim. Upstream uses the physical pixel size; we use 2 points.
    def aim_radius : Float64
      2.0
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

      keys_down = prev.try(&.keys_down) || Set(KeyCode).new
      keys_down = keys_down.dup
      keys_pressed = Set(KeyCode).new
      keys_released = Set(KeyCode).new
      text = ""
      modifiers = prev.try(&.modifiers) || Modifiers.new

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
        in .key_pressed?
          modifiers = e.modifiers
          keys_pressed.add(e.key)
          keys_down.add(e.key)
        in .key_released?
          modifiers = e.modifiers
          keys_released.add(e.key)
          keys_down.delete(e.key)
        in .text_input?
          text += e.text
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
        delta, velocity, keys_down, keys_pressed, keys_released, text, modifiers)
    end
  end
end
