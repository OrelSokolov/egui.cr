# System port Haptics: vibration / tap feedback. Android goes through
# the sysport JNI bridge (Vibrator service; the VIBRATE permission in
# the manifest is a normal one — no runtime dialog), iOS drives
# UIFeedbackGenerator from the sokol shim. Desktops and headless
# builds are a silent no-op: UI code calls the port unconditionally
# and simply gets nothing where no hardware exists.
#
# Fire-and-forget, never blocks, never raises.

module Egui
  module SystemPorts
    module Haptics
      # Tap styles (Android: amplitude/duration presets; iOS:
      # UIImpactFeedbackStyle). :selection is the discreet tick for
      # picker/value changes (UISelectionFeedbackGenerator).
      STYLE_LIGHT = 0
      STYLE_MEDIUM = 1
      STYLE_HEAVY = 2
      STYLE_SELECTION = 3

      {% if flag?(:android) %}
        # JNI bridge (mirrors the Notification port's path through
        # backend/sokol_shim.c → EguiCrActivity.vibrate).
        lib LibAndroidHaptics
          fun vibrate = egui_cr_android_vibrate(style : Int32,
                                                ms : Int32) : Void
        end

        def self.supported? : Bool
          true
        end

        # One vibration of `ms` milliseconds (a plain timed buzz).
        def self.vibrate(ms : Int32 = 30) : Nil
          LibAndroidHaptics.vibrate(STYLE_MEDIUM, ms)
        rescue
        end

        # A style preset — the idiomatic call for touch feedback.
        def self.tap(style : Int32 = STYLE_LIGHT) : Nil
          LibAndroidHaptics.vibrate(style, 0)
        rescue
        end

      {% elsif flag?(:ios) %}
        lib LibIosHaptics
          fun haptic = egui_cr_ios_haptic(style : Int32) : Void
        end

        def self.supported? : Bool
          true
        end

        def self.vibrate(ms : Int32 = 30) : Nil
          # iOS has no timed buzz; approximate with a medium impact.
          LibIosHaptics.haptic(STYLE_MEDIUM)
        rescue
        end

        def self.tap(style : Int32 = STYLE_LIGHT) : Nil
          LibIosHaptics.haptic(style)
        rescue
        end

      {% else %}
        def self.supported? : Bool
          false
        end

        def self.vibrate(ms : Int32 = 30) : Nil
        end

        def self.tap(style : Int32 = STYLE_LIGHT) : Nil
        end
      {% end %}
    end
  end
end
