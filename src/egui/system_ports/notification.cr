# System port Notification: desktop notifications.
#
# Linux/BSD uses `notify-send` (org.freedesktop.Notifications); macOS
# uses `display notification` through osascript; Windows shows a balloon
# through the WinForms `NotifyIcon` (System.Windows.Forms is part of the
# OS). Fire-and-forget; returns false when the backend is missing.
# Non-blocking — it returns as soon as the notification is dispatched.

module Egui
  module SystemPorts
    module Notification
      # Show a desktop notification. `summary` is the title, `body` the
      # optional second line.
      def self.show(summary : String, body : String = "") : Bool
        {% if flag?(:win32) %}
          # The balloon lives as long as the NotifyIcon; keep the
          # process around for a few seconds so it becomes visible
          # before Dispose, and run it detached so the caller never
          # waits for that.
          script = String.build do |s|
            s << "Add-Type -AssemblyName System.Windows.Forms\n"
            s << "Add-Type -AssemblyName System.Drawing\n"
            s << "$n = New-Object System.Windows.Forms.NotifyIcon\n"
            s << "$n.Icon = [System.Drawing.SystemIcons]::Information\n"
            s << "$n.Visible = $true\n"
            s << "$n.ShowBalloonTip(5000, " << Dialogs.ps_sq(summary) << ", " <<
              Dialogs.ps_sq(body) << ", [System.Windows.Forms.ToolTipIcon]::Info)\n"
            s << "Start-Sleep -Seconds 6\n"
            s << "$n.Dispose()\n"
          end
          Dialogs.spawn_powershell(script)
        {% elsif flag?(:darwin) %}
          script = %(display notification "#{Dialogs.as_quote(body)}" ) +
                   %(with title "#{Dialogs.as_quote(summary)}")
          Dialogs.run?("osascript", ["-e", script])
        {% else %}
          return false unless Dialogs.which("notify-send")
          args = [summary]
          args << body unless body.empty?
          Dialogs.run?("notify-send", args)
        {% end %}
      end
    end
  end
end
