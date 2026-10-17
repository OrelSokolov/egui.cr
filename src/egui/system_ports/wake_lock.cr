# System port WakeLock: keep the display from sleeping while the app
# is in a "watching" state (video playback, a timer running).
#
# acquire is idempotent (one slot — a second acquire while held keeps
# the existing assertion); release is safe when not held. macOS holds
# an IOPMAssertion, Windows arms SetThreadExecutionState, Android
# sets FLAG_KEEP_SCREEN_ON (via the sysport JNI bridge), iOS disables
# the idle timer. Linux/BSD has no portable single call: the port
# tries the org.freedesktop.ScreenSaver D-Bus inhibition through
# gdbus/busctl when present and reports false otherwise.

module Egui
  module SystemPorts
    module WakeLock
      # Desktop native runner installed by backend/sokol.cr (the shim's
      # egui_cr_wakelock_* — macOS IOPMAssertion / Windows execution
      # state). Nil on Linux and headless builds.
      @@runner : {acquire: Proc(String, Bool), release: Proc(Nil)}?

      # Linux D-Bus inhibition cookie (nil = none held), set by the
      # gdbus/busctl fallback path.
      @@dbus_cookie : String?

      def self.use_runner(acquire : Proc(String, Bool),
                          release : Proc(Nil)) : Nil
        @@runner = {acquire: acquire, release: release}
      end

      # Drop the installed runner (spec hygiene).
      def self.use_runner : Nil
        @@runner = nil
      end

      # Ask the OS to keep the display awake. `reason` shows up in
      # pmset assertions / power reports. Returns false when the
      # platform refuses (or has no mechanism at all).
      def self.acquire(reason : String = "app in use") : Bool
        {% if flag?(:android) %}
          LibAndroidWake.keep_screen_on(1)
          true
        {% elsif flag?(:ios) %}
          LibIosWake.idle_timer(1)
          true
        {% else %}
          if (runner = @@runner)
            return runner[:acquire].call(reason)
          end
          {% if flag?(:linux) && !flag?(:android) %}
            dbus_acquire(reason)
          {% else %}
            false
          {% end %}
        {% end %}
      end

      # Let the display sleep again. Always safe to call.
      def self.release : Nil
        {% if flag?(:android) %}
          LibAndroidWake.keep_screen_on(0)
        {% elsif flag?(:ios) %}
          LibIosWake.idle_timer(0)
        {% else %}
          if (runner = @@runner)
            runner[:release].call
            return
          end
          {% if flag?(:linux) && !flag?(:android) %}
            dbus_release
          {% end %}
        {% end %}
      end

      # True while a wake lock is held on this port's bookkeeping.
      def self.held? : Bool
        !!(@@runner || @@dbus_cookie)
      end

      {% if flag?(:android) %}
        lib LibAndroidWake
          fun keep_screen_on = egui_cr_android_keep_screen_on(
            on : Int32) : Void
        end
      {% end %}

      {% if flag?(:ios) %}
        lib LibIosWake
          fun idle_timer = egui_cr_ios_idle_timer(on : Int32) : Void
        end
      {% end %}

      # ---- Linux fallback ------------------------------------------------

      # Session-bus ScreenSaver inhibition; works on GNOME/KDE session
      # daemons. The cookie string comes back from the D-Bus reply.
      {% if flag?(:linux) && !flag?(:android) %}
        private def self.dbus_acquire(reason : String) : Bool
          reply = Dialogs.run("gdbus", [
            "call", "--session",
            "--dest", "org.freedesktop.ScreenSaver",
            "--object-path", "/org/freedesktop/ScreenSaver",
            "--method", "org.freedesktop.ScreenSaver.Inhibit",
            "egui-cr", reason,
          ])
          return false unless reply
          # Reply: (uint32 N,) — keep the whole string as the cookie;
          # UnInhibit takes the number back out of it.
          @@dbus_cookie = reply
          true
        end

        private def self.dbus_release : Nil
          cookie = @@dbus_cookie
          return unless cookie
          @@dbus_cookie = nil
          number = cookie.scan(/\d+/).first?.try(&.[0]) || ""
          Dialogs.spawn("gdbus", [
            "call", "--session",
            "--dest", "org.freedesktop.ScreenSaver",
            "--object-path", "/org/freedesktop/ScreenSaver",
            "--method", "org.freedesktop.ScreenSaver.UnInhibit",
            number,
          ])
        end
      {% end %}
    end
  end
end
