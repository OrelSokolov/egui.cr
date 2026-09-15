# System port MessageBox: native alert/confirm dialogs — zenity
# (--info/--warning/--error/--question) or kdialog (--msgbox/--sorry/
# --error/--yesno), whichever is on PATH. Like the file dialogs, the
# call blocks (modal): the frame loop freezes until the user dismisses
# the box.

module Egui
  module SystemPorts
    module MessageBox
      # Informational box with an OK button.
      def self.info(message : String, title : String = "Information") : Nil
        case Dialogs.tool
        when "zenity"  then Dialogs.run?("zenity", ["--info", "--title=#{title}", "--text=#{message}"])
        when "kdialog" then Dialogs.run?("kdialog", ["--msgbox", message, "--title", title])
        end
        nil
      end

      # Warning box (non-fatal problem) with an OK button.
      def self.warning(message : String, title : String = "Warning") : Nil
        case Dialogs.tool
        when "zenity"  then Dialogs.run?("zenity", ["--warning", "--title=#{title}", "--text=#{message}"])
        when "kdialog" then Dialogs.run?("kdialog", ["--sorry", message, "--title", title])
        end
        nil
      end

      # Error box with an OK button.
      def self.error(message : String, title : String = "Error") : Nil
        case Dialogs.tool
        when "zenity"  then Dialogs.run?("zenity", ["--error", "--title=#{title}", "--text=#{message}"])
        when "kdialog" then Dialogs.run?("kdialog", ["--error", message, "--title", title])
        end
        nil
      end

      # Yes/no question; true only when the user confirms. False on
      # cancel or when no dialog tool is available.
      def self.confirm(message : String, title : String = "Confirm") : Bool
        case Dialogs.tool
        when "zenity"  then Dialogs.run?("zenity", ["--question", "--title=#{title}", "--text=#{message}"])
        when "kdialog" then Dialogs.run?("kdialog", ["--yesno", message, "--title", title])
        else                false
        end
      end
    end
  end
end
