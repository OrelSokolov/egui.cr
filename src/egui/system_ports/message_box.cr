# System port MessageBox: native alert/confirm dialogs — zenity
# (--info/--warning/--error/--question) or kdialog (--msgbox/--sorry/
# --error/--yesno) on Linux/BSD, `display dialog` through osascript
# (icon note/caution/stop/question) on macOS. Like the file dialogs,
# the call blocks (modal): the frame loop freezes until the user
# dismisses the box.

module Egui
  module SystemPorts
    module MessageBox
      # Informational box with an OK button.
      def self.info(message : String, title : String = "Information") : Nil
        if {{ flag?(:darwin) }}
          Dialogs.mac_display_dialog(message, title, "note", false)
        else
          case Dialogs.tool
          when "zenity"  then Dialogs.run?("zenity", ["--info", "--title=#{title}", "--text=#{message}"])
          when "kdialog" then Dialogs.run?("kdialog", ["--msgbox", message, "--title", title])
          end
        end
        nil
      end

      # Warning box (non-fatal problem) with an OK button.
      def self.warning(message : String, title : String = "Warning") : Nil
        if {{ flag?(:darwin) }}
          Dialogs.mac_display_dialog(message, title, "caution", false)
        else
          case Dialogs.tool
          when "zenity"  then Dialogs.run?("zenity", ["--warning", "--title=#{title}", "--text=#{message}"])
          when "kdialog" then Dialogs.run?("kdialog", ["--sorry", message, "--title", title])
          end
        end
        nil
      end

      # Error box with an OK button.
      def self.error(message : String, title : String = "Error") : Nil
        if {{ flag?(:darwin) }}
          Dialogs.mac_display_dialog(message, title, "stop", false)
        else
          case Dialogs.tool
          when "zenity"  then Dialogs.run?("zenity", ["--error", "--title=#{title}", "--text=#{message}"])
          when "kdialog" then Dialogs.run?("kdialog", ["--error", message, "--title", title])
          end
        end
        nil
      end

      # Yes/no question; true only when the user confirms. False on
      # cancel or when no dialog tool is available.
      def self.confirm(message : String, title : String = "Confirm") : Bool
        if {{ flag?(:darwin) }}
          Dialogs.mac_display_dialog(message, title, "question", true)
        else
          case Dialogs.tool
          when "zenity"  then Dialogs.run?("zenity", ["--question", "--title=#{title}", "--text=#{message}"])
          when "kdialog" then Dialogs.run?("kdialog", ["--yesno", message, "--title", title])
          else                false
          end
        end
      end
    end
  end
end
