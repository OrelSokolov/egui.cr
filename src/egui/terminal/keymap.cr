# Keyboard → byte stream encoding (the xterm rules every console app
# expects): plain text passes through, Ctrl+letter becomes its C0
# byte, Alt prefixes ESC, and special keys emit CSI/SS3 sequences that
# follow the child's DEC modes (application cursor keys, keypad).

module Egui
  module Terminal
    module Keymap
      # Bytes to write for one key event, or nil when the combination
      # means nothing to a terminal. `text` is the frame's text input
      # for printable characters.
      def self.encode(term : Terminal, key : KeyCode?,
                      mods : Modifiers, text : String?) : Bytes?
        # Printable characters: text beats key codes (layout-correct),
        # unless a real shortcut modifier is held; Alt still forwards
        # the char with an ESC prefix (the xterm Meta convention).
        if text && !text.empty? && !mods.ctrl && !mods.super_key
          clean = text.gsub(/\r\n|\r|\n/, "\r")
          return esc_prefix(clean.to_slice, mods)
        end

        return nil if key.nil?

        # Ctrl+letter → C0 byte (1..26). Ctrl+Space → NUL,
        # Ctrl+Backspace → BS.
        if mods.ctrl && !mods.shift && !mods.alt
          if key.value >= 65 && key.value <= 90 # A..Z
            return Bytes[(key.value - 64)]
          end
          case key
          when .space? then return Bytes[0]
          when .backspace? then return Bytes[0x08]
          end
        end

        special(term, key, mods)
      end

      private def self.esc_prefix(bytes : Bytes, mods : Modifiers) : Bytes
        return bytes unless mods.alt
        Bytes[0x1b] + bytes
      end

      # xterm modifier parameter: 1 + (shift 1, alt 2, ctrl 4).
      private def self.mod_param(mods : Modifiers) : Int32
        1 + (mods.shift ? 1 : 0) + (mods.alt ? 2 : 0) + (mods.ctrl ? 4 : 0)
      end

      private def self.csi(body : String) : Bytes
        "\e[#{body}".to_slice
      end

      # Cursor arrows: SS3 when application cursor keys are on, CSI
      # otherwise; any modifier switches to the CSI 1;m form.
      private def self.arrow(term : Terminal, final : Char, mods : Modifiers) : Bytes
        modified(term, final, mods) do
          "\eO#{final}".to_slice
        end
      end

      # Bare form when unmodified; the 1;m param form with any modifier
      # (or in CSI mode for Home/End).
      private def self.modified(term : Terminal, final : Char, mods : Modifiers, &bare)
        if mods.shift || mods.ctrl || mods.alt
          csi("1;#{mod_param(mods)}#{final}")
        elsif term.app_cursor_keys?
          yield
        else
          csi(final.to_s)
        end
      end

      private def self.tilde(key : KeyCode, code : Int32, mods : Modifiers) : Bytes
        if mods.shift || mods.ctrl || mods.alt
          csi("#{code};#{mod_param(mods)}~")
        else
          csi("#{code}~")
        end
      end

      private def self.special(term : Terminal, key : KeyCode,
                               mods : Modifiers) : Bytes?
        base = case key
               when .up?     then arrow(term, 'A', mods)
               when .down?   then arrow(term, 'B', mods)
               when .right?  then arrow(term, 'C', mods)
               when .left?   then arrow(term, 'D', mods)
               when .home?   then home_end(term, 'H', mods)
               when .end?    then home_end(term, 'F', mods)
               when .insert? then tilde(key, 2, mods)
               when .delete? then tilde(key, 3, mods)
               when .page_up?   then tilde(key, 5, mods)
               when .page_down? then tilde(key, 6, mods)
               when .f1?  then fn_ss3('P', 1, mods)
               when .f2?  then fn_ss3('Q', 1, mods)
               when .f3?  then fn_ss3('R', 1, mods)
               when .f4?  then fn_ss3('S', 1, mods)
               when .f5?  then tilde(key, 15, mods)
               when .f6?  then tilde(key, 17, mods)
               when .f7?  then tilde(key, 18, mods)
               when .f8?  then tilde(key, 19, mods)
               when .f9?  then tilde(key, 20, mods)
               when .f10? then tilde(key, 21, mods)
               when .f11? then tilde(key, 23, mods)
               when .f12? then tilde(key, 24, mods)
               when .enter?     then "\r".to_slice
               when .tab?       then mods.shift ? csi("Z") : Bytes[0x09]
               when .backspace? then Bytes[0x7f]
               when .escape?    then Bytes[0x1b]
               else                 nil
               end
        base
      end

      private def self.home_end(term : Terminal, final : Char,
                                mods : Modifiers) : Bytes
        modified(term, final, mods) do
          "\eO#{final}".to_slice
        end
      end

      # F1-F4 use SS3 (bare) or CSI 1;m + SS3-final with modifiers.
      private def self.fn_ss3(final : Char, _code : Int32,
                              mods : Modifiers) : Bytes
        if mods.shift || mods.ctrl || mods.alt
          csi("1;#{mod_param(mods)}#{final}")
        else
          "\eO#{final}".to_slice
        end
      end
    end
  end
end
