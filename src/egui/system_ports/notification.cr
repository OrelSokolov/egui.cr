# System port Notification: desktop notifications (Linux `notify-send`,
# org.freedesktop.Notifications). Fire-and-forget; returns false when
# the tool is missing. Non-blocking — notify-send returns as soon as the
# notification is dispatched.

module Egui
  module SystemPorts
    module Notification
      # Show a desktop notification. `summary` is the title, `body` the
      # optional second line.
      def self.show(summary : String, body : String = "") : Bool
        return false unless {{ flag?(:unix) }}
        return false unless Dialogs.which("notify-send")
        args = [summary]
        args << body unless body.empty?
        Dialogs.run?("notify-send", args)
      end
    end
  end
end
