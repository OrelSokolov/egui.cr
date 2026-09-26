# Action-driven global hotkeys (no upstream equivalent — egui.cr's
# own layer, see docs/ANALYSIS.md §12).
#
# Three types:
#   Hotkey       a key combo (modifiers + KeyCode) — parses from and
#                formats back to "Ctrl+Shift+Z" strings
#   HotkeyAction the semantic event a hotkey fires ("app.new_tab")
#   HotkeyMap    the app-global hotkey → action bindings (one hotkey
#                per action, one action per hotkey)
#
# The flow is action-driven end to end: `ctx.hotkeys.bind("Ctrl+N",
# ACTION_NEW)` binds a key; a key press fires the action in
# `Context#begin_frame` (see `#consume_action`); `Ui#menu_item` takes
# an action — not a shortcut string — and displays whatever hotkey is
# bound to it, so rebinding in a `HotkeyEdit` updates every menu the
# next frame.

module Egui
  # The semantic event a hotkey (or a menu click) fires. Apps define
  # their actions as constants and poll them with
  # `Context#consume_action` — one place handles the action no matter
  # whether it came from a key press or a menu.
  struct HotkeyAction
    getter name : String

    def initialize(@name : String)
    end

    def to_s : String
      @name
    end

    def ==(other : HotkeyAction) : Bool
      @name == other.name
    end

    def hash(hasher)
      @name.hash(hasher)
    end
  end

  # A key combo: modifiers plus a `KeyCode`. Canonical string form is
  # "Ctrl+Alt+Shift+Super+<Key>" (only the pressed parts shown), key
  # names matching the `KeyCode` members ("Ctrl+N", "F5",
  # "Ctrl+Shift+Z", "Ctrl+Space").
  struct Hotkey
    getter key : KeyCode
    getter ctrl : Bool
    getter shift : Bool
    getter alt : Bool
    getter super_key : Bool

    def initialize(@key : KeyCode, ctrl : Bool = false, shift : Bool = false,
                   alt : Bool = false, super_key : Bool = false)
      @ctrl = ctrl
      @shift = shift
      @alt = alt
      @super_key = super_key
    end

    # From live modifier state (e.g. what `HotkeyEdit` captured).
    def initialize(@key : KeyCode, modifiers : Modifiers)
      @ctrl = modifiers.ctrl
      @shift = modifiers.shift
      @alt = modifiers.alt
      @super_key = modifiers.super_key
    end

    # Parse-friendly aliases for named keys ("Esc" → Escape…).
    KEY_ALIASES = {
      "esc"        => "escape",
      "return"     => "enter",
      "bksp"       => "backspace",
      "ins"        => "insert",
      "del"        => "delete",
      "pgup"       => "pageup",
      "pgdn"       => "pagedown",
      "pgdown"     => "pagedown",
      "arrowleft"  => "left",
      "arrowright" => "right",
      "arrowup"    => "up",
      "arrowdown"  => "down",
    }

    # Modifier tokens (case-insensitive); "super" also parses under
    # the cmd/win/meta spellings.
    def self.parse?(str : String) : Hotkey?
      ctrl = shift = alt = sup = false
      key : KeyCode? = nil
      str.split('+').each do |raw|
        token = raw.strip.downcase
        case token
        when "ctrl", "control"  then ctrl = true
        when "shift"            then shift = true
        when "alt"              then alt = true
        when "super", "cmd", "command", "meta", "win"
          sup = true
        else
          return nil if key # two non-modifier tokens — not a hotkey
          key = parse_key?(token)
          return nil unless key
        end
      end
      return nil unless key
      new(key.not_nil!, ctrl: ctrl, shift: shift, alt: alt, super_key: sup)
    end

    # Strict parse — raises ArgumentError on an unknown key or combo
    # (a typo'd default binding should fail loudly at startup).
    def self.parse(str : String) : Hotkey
      parse?(str) || raise ArgumentError.new("invalid hotkey: #{str}")
    end

    private def self.parse_key?(token : String) : KeyCode?
      if token.size == 1
        ch = token[0]
        if ch.ascii_letter?
          KeyCode.from_value?(ch.upcase.ord)
        elsif ch.number?
          KeyCode.from_value?(ch.ord)
        end
      else
        KeyCode.parse?(KEY_ALIASES[token]? || token)
      end
    end

    # "Ctrl+N", "Ctrl+Shift+Z", "F5" — the display form menus use.
    def to_s : String
      parts = [] of String
      parts << "Ctrl" if @ctrl
      parts << "Alt" if @alt
      parts << "Shift" if @shift
      parts << "Super" if @super_key
      parts << Hotkey.key_name(@key)
      parts.join('+')
    end

    # Display name of a bare key: digits render as the digit, named
    # keys as the enum member ("Space", "F5", "Escape").
    def self.key_name(key : KeyCode) : String
      key.digit? ? key.value.chr.to_s : key.to_s
    end

    # This hotkey was pressed this frame (key press + exact modifier
    # state — "Ctrl+N" does not match Ctrl+Shift+N).
    def matches?(input : InputState) : Bool
      input.key_pressed?(@key) && modifiers_match?(input.modifiers)
    end

    def modifiers_match?(m : Modifiers) : Bool
      m.ctrl == @ctrl && m.shift == @shift &&
        m.alt == @alt && m.super_key == @super_key
    end

    def ==(other : Hotkey) : Bool
      @key == other.key && @ctrl == other.ctrl && @shift == other.shift &&
        @alt == other.alt && @super_key == other.super_key
    end

    def hash(hasher)
      hasher = @key.value.hash(hasher)
      hasher = @ctrl.hash(hasher)
      hasher = @shift.hash(hasher)
      hasher = @alt.hash(hasher)
      @super_key.hash(hasher)
    end
  end

  # The app-global hotkey → action bindings, owned by the Context
  # (`ctx.hotkeys`). One hotkey per action and one action per hotkey:
  # rebinding an action moves it (the old hotkey is freed); binding a
  # hotkey that is taken replaces the previous binding.
  class HotkeyMap
    @hotkeys = {} of Hotkey => HotkeyAction
    @by_action = {} of HotkeyAction => Hotkey

    def bind(hotkey : Hotkey, action : HotkeyAction) : Nil
      unbind(hotkey)
      unbind_action(action)
      @hotkeys[hotkey] = action
      @by_action[action] = hotkey
    end

    def bind(hotkey : String, action : HotkeyAction) : Nil
      bind(Hotkey.parse(hotkey), action)
    end

    def bind(hotkey : String, action : String) : Nil
      bind(Hotkey.parse(hotkey), HotkeyAction.new(action))
    end

    def unbind(hotkey : Hotkey) : Nil
      return unless @hotkeys.has_key?(hotkey)
      action = @hotkeys.delete(hotkey)
      @by_action.delete(action) if @by_action.has_key?(action)
    end

    # Remove whatever hotkey `action` is bound to (HotkeyEdit's
    # Backspace/Delete "clear" gesture).
    def unbind_action(action : HotkeyAction) : Nil
      return unless @by_action.has_key?(action)
      hotkey = @by_action.delete(action)
      @hotkeys.delete(hotkey) if @hotkeys.has_key?(hotkey)
    end

    def hotkey_for(action : HotkeyAction) : Hotkey?
      @by_action[action]?
    end

    def action_for(hotkey : Hotkey) : HotkeyAction?
      @hotkeys[hotkey]?
    end

    def size : Int32
      @hotkeys.size
    end

    def each(&block : {Hotkey, HotkeyAction} ->) : Nil
      @hotkeys.each { |hotkey, action| yield({hotkey, action}) }
    end

    # Global dispatch (Context#begin_frame): fire every action whose
    # hotkey was pressed this frame and claim the key so widgets don't
    # also react to it. Modifier-press-only frames never match (the
    # backend emits no key events for bare modifiers).
    def dispatch(input : InputState) : Array(HotkeyAction)
      fired = [] of HotkeyAction
      @hotkeys.each do |hotkey, action|
        if hotkey.matches?(input)
          input.consume_key(hotkey.key)
          fired << action
        end
      end
      fired
    end
  end
end
