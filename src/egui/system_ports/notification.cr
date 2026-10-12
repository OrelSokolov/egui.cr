# System port Notification: desktop notifications.
#
# Linux/BSD uses `notify-send` (org.freedesktop.Notifications); macOS
# uses `display notification` through osascript; Windows shows a balloon
# through the WinForms `NotifyIcon` (System.Windows.Forms is part of the
# OS). iOS goes through a native runner installed by the backend
# (UNUserNotificationCenter local notifications — no subprocess tools
# exist there). Android posts through the sysport JNI bridge
# (NotificationManager; on API 33+ the first call triggers the
# POST_NOTIFICATIONS request — until granted the system silently drops
# the notification). Fire-and-forget; returns false when the backend is
# missing. Non-blocking — it returns as soon as the notification is
# dispatched.

module Egui
  module SystemPorts
    module Notification
      # Native notification runner installed by the backend when the
      # platform has a system API (iOS UNUserNotificationCenter via the
      # sokol shim). Takes precedence over the subprocess tools.
      @@native : ((String, String) -> Bool)?

      def self.use_native(&runner : String, String -> Bool) : Nil
        @@native = runner
      end

      # Drop an installed native runner — the subprocess fallback takes
      # over again. Spec hygiene.
      def self.use_native : Nil
        @@native = nil
      end

      # Show a desktop notification. `summary` is the title, `body` the
      # optional second line.
      def self.show(summary : String, body : String = "") : Bool
        {% if flag?(:ios) %}
          # iOS: native runner (UNUserNotificationCenter); headless
          # builds fail fast — no osascript/notify-send exists there.
          if (runner = @@native)
            runner.call(summary, body)
          else
            false
          end
        {% elsif flag?(:win32) %}
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
        {% elsif flag?(:android) %}
          Android.notify(summary, body)
          true
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
