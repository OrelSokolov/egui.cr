# System port MessageBox: native alert/confirm dialogs.
#
# Windows calls `MessageBoxW` (user32) directly — instant, native, no
# subprocess. Linux/BSD shells out to zenity (--info/--warning/--error/
# --question) or kdialog (--msgbox/--sorry/--error/--yesno), whichever
# is on PATH. macOS uses `display dialog` through osascript (icon
# note/caution/stop/question). Android shows an AlertDialog through the
# sysport JNI bridge: info/warning/error are fire-and-forget, and the
# confirm answer — delivered by the OS on its UI thread — can only
# return through the callback overload of #confirm (use it on Android;
# the blocking #confirm there shows the dialog but returns false).
# Like the file dialogs, the call blocks (modal): the frame loop
# freezes until the user dismisses the box.

module Egui
  module SystemPorts
    module MessageBox
      {% if flag?(:win32) %}
        @[Link("user32")]
        lib LibUser32
          # hwnd, text, caption, type → clicked button id (1=OK, 6=YES).
          fun MessageBoxW(hwnd : Void*, text : UInt16*, caption : UInt16*, u_type : UInt32) : Int32
          # The calling thread's active window — the sokol window while
          # an app.update runs — gives the box a proper owner.
          fun GetActiveWindow : Void*
        end

        MB_ICONERROR   = 0x0000_0010_u32
        MB_ICONWARNING = 0x0000_0030_u32
        MB_ICONINFO    = 0x0000_0040_u32
        MB_YESNO       = 0x0000_0004_u32
        IDYES          = 6

        private def self.win32_box(message : String, title : String, icon : UInt32) : Nil
          LibUser32.MessageBoxW(LibUser32.GetActiveWindow,
            message.to_utf16, title.to_utf16, icon)
          nil
        end
      {% end %}

      # Informational box with an OK button.
      def self.info(message : String, title : String = "Information") : Nil
        {% if flag?(:win32) %}
          win32_box(message, title, MB_ICONINFO)
        {% elsif flag?(:darwin) %}
          Dialogs.mac_display_dialog(message, title, "note", false)
        {% elsif flag?(:android) %}
          Android.msgbox(Android::MSG_INFO, title, message)
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
        {% elsif flag?(:android) %}
          Android.msgbox(Android::MSG_WARNING, title, message)
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
        {% elsif flag?(:android) %}
          Android.msgbox(Android::MSG_ERROR, title, message)
        {% else %}
          case Dialogs.tool
          when "zenity"  then Dialogs.run?("zenity", ["--error", "--title=#{title}", "--text=#{message}"])
          when "kdialog" then Dialogs.run?("kdialog", ["--error", message, "--title", title])
          end
        {% end %}
        nil
      end

      # Yes/no question; true only when the user confirms. False on
      # cancel or when no dialog tool is available. On Android this only
      # SHOWS the dialog — the answer cannot return synchronously (the
      # OS delivers it on the UI thread; blocking the frame loop would
      # stall input dispatch → ANR); use the callback overload below.
      def self.confirm(message : String, title : String = "Confirm") : Bool
        {% if flag?(:win32) %}
          LibUser32.MessageBoxW(LibUser32.GetActiveWindow,
            message.to_utf16, title.to_utf16, MB_YESNO) == IDYES
        {% elsif flag?(:darwin) %}
          Dialogs.mac_display_dialog(message, title, "question", true)
        {% elsif flag?(:android) %}
          Android.confirm_box(title, message)
          false
        {% else %}
          case Dialogs.tool
          when "zenity"  then Dialogs.run?("zenity", ["--question", "--title=#{title}", "--text=#{message}"])
          when "kdialog" then Dialogs.run?("kdialog", ["--yesno", message, "--title", title])
          else                false
          end
        {% end %}
      end

      # Non-blocking confirm: `on_result` fires with the answer. On
      # Android the native dialog is asynchronous by nature — the
      # callback lands between frames via the sysport ring; on the
      # desktop platforms this wraps the blocking #confirm and calls
      # back immediately. (Two defs, not an {% if %} inside one: block
      # arguments don't resolve through in-method macro branches.)
      {% if flag?(:android) %}
        def self.confirm(message : String, title : String = "Confirm",
                         &on_result : Bool ->) : Nil
          Android.confirm_async(title, message) { |ok| on_result.call(ok) }
        end
      {% else %}
        def self.confirm(message : String, title : String = "Confirm",
                         &on_result : Bool ->) : Nil
          on_result.call(confirm(message, title))
        end
      {% end %}
    end
  end
end
