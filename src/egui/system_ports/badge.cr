# System port Badge: the app icon's notification count — the dock tile
# number on macOS, the home-screen icon number on iOS. Windows and
# Linux have no equivalent surface (the taskbar overlay needs
# ITaskbarList3 + an icon handle; launcher badges are OEM-specific),
# and Android's launcher badges are driven by notification channels,
# not apps — those platforms report unsupported and are a no-op.
#
# The macOS/iOS native side lives in the sokol shim (egui_cr_badge_set
# / egui_cr_ios_badge_set); installed as a runner by backend/sokol.cr.

module Egui
  module SystemPorts
    module Badge
      @@runner : Proc(Int32, Nil)?

      # Native runner installed by the backend: sets the count (0
      # clears). Nil = unsupported platform.
      def self.use_runner(&runner : Int32 -> Nil) : Nil
        @@runner = runner
      end

      # Drop the installed runner (spec hygiene).
      def self.use_runner : Nil
        @@runner = nil
      end

      # Whether this platform shows a badge at all — for UI that wants
      # to hide the option.
      def self.supported? : Bool
        {% if flag?(:android) %}
          false
        {% else %}
          !!@@runner
        {% end %}
      end

      # Show `count` on the app icon; 0 or #clear removes it. Returns
      # false on unsupported platforms.
      def self.set(count : Int32) : Bool
        return false unless supported?
        runner = @@runner
        return false unless runner
        runner.call(count.clamp(0, 99_999))
        true
      end

      # Remove the badge (Badge.set(0)).
      def self.clear : Nil
        set(0)
      end
    end
  end
end
