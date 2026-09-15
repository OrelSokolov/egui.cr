# System port MessageBox: native alert/confirm dialogs.
#
# Windows calls `MessageBoxW` (user32) directly — instant, native, no
# subprocess. Linux/BSD shells out to zenity (--info/--warning/--error/
# --question) or kdialog (--msgbox/--sorry/--error/--yesno), whichever
# is on PATH. macOS uses `display dialog` through osascript (icon
# note/caution/stop/question). Like the file dialogs, the call blocks
# (modal): the frame loop freezes until the user dismisses the box.

module Egui
  module SystemPorts
    module MessageBox
      {% if flag?(:win32) %}
        @[Link("user32")]
        lib LibUser32
          # hwnd, text, caption, type → clicked button id (1=OK, 6=YES).
          fun MessageBoxW(hwnd : Void*, text : UInt16*, caption : UInt16*, u_type : UInt32) : Int32
        end

        MB_ICONERROR   = 0x0000_0010_u32
        MB_ICONWARNING = 0x0000_0030_u32
        MB_ICONINFO    = 0x0000_0040_u32
        MB_YESNO       = 0x0000_0004_u32
        IDYES          = 6

        private def self.win32_box(message : String, title : String, icon : UInt32) : Nil
          LibUser32.MessageBoxW(nil, message.to_utf16, title.to_utf16, icon)
          nil
        end
      {% end %}

      # Informational box with an OK button.
      def self.info(message : String, title : String = "Information") : Nil
        {% if flag?(:win32) %}
          win32_box(message, title, MB_ICONINFO)
        {% elsif flag?(:darwin) %}
          Dialogs.mac_display_dialog(message, title, "note", false)
        {% else %}
          case Dialogs.tool
          when "zenity"  then Dialogs.run?("zenity", ["--info", "--title=#{title}", "--text=#{message}"])
          when "kdialog" then Dialogs.run?("kdialog", ["--msgbox", message, "--title", title])
          end
        {% end %}
        nil
      end

      # Warning box (non-fatal problem) with an OK button.
      def self.warning(message : String, title : String = "Warning") : Nil
        {% if flag?(:win32) %}
          win32_box(message, title, MB_ICONWARNING)
        {% elsif flag?(:darwin) %}
          Dialogs.mac_display_dialog(message, title, "caution", false)
        {% else %}
          case Dialogs.tool
          when "zenity"  then Dialogs.run?("zenity", ["--warning", "--title=#{title}", "--text=#{message}"])
          when "kdialog" then Dialogs.run?("kdialog", ["--sorry", message, "--title", title])
          end
        {% end %}
        nil
      end

      # Error box with an OK button.
      def self.error(message : String, title : String = "Error") : Nil
        {% if flag?(:win32) %}
          win32_box(message, title, MB_ICONERROR)
        {% elsif flag?(:darwin) %}
          Dialogs.mac_display_dialog(message, title, "stop", false)
        {% else %}
          case Dialogs.tool
          when "zenity"  then Dialogs.run?("zenity", ["--error", "--title=#{title}", "--text=#{message}"])
          when "kdialog" then Dialogs.run?("kdialog", ["--error", message, "--title", title])
          end
        {% end %}
        nil
      end

      # Yes/no question; true only when the user confirms. False on
      # cancel or when no dialog tool is available.
      def self.confirm(message : String, title : String = "Confirm") : Bool
        {% if flag?(:win32) %}
          LibUser32.MessageBoxW(nil, message.to_utf16, title.to_utf16, MB_YESNO) == IDYES
        {% elsif flag?(:darwin) %}
          Dialogs.mac_display_dialog(message, title, "question", true)
        {% else %}
          case Dialogs.tool
          when "zenity"  then Dialogs.run?("zenity", ["--question", "--title=#{title}", "--text=#{message}"])
          when "kdialog" then Dialogs.run?("kdialog", ["--yesno", message, "--title", title])
          else                false
          end
        {% end %}
      end
    end
  end
end
