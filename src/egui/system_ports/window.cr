# System port Window: cross-platform window management — title, size,
# position, minimize/maximize/restore, fullscreen, icon.
#
# Title and fullscreen delegate to sokol_app directly; resize/move/
# minimize/maximize/icon go through backend/sokol_shim.c (X11 core
# protocol + _NET_WM_STATE, Win32; the icon is Win32-only there —
# elsewhere it is a no-op). The default implementation is a headless
# no-op; the backend installs the real one.

module Egui
  module SystemPorts
    module Window
      class_getter implementation : Implementation = Implementation.new

      # Install a platform implementation (called by the backend).
      def self.use(implementation : Implementation) : Nil
        @@implementation = implementation
      end

      def self.set_title(title : String) : Nil
        implementation.set_title(title)
      end

      def self.set_size(width : Int32, height : Int32) : Nil
        implementation.set_size(width, height)
      end

      def self.set_position(x : Int32, y : Int32) : Nil
        implementation.set_position(x, y)
      end

      def self.minimize : Nil
        implementation.minimize
      end

      def self.maximize : Nil
        implementation.maximize
      end

      def self.restore : Nil
        implementation.restore
      end

      def self.toggle_fullscreen : Nil
        implementation.toggle_fullscreen
      end

      # Enter/exit fullscreen EXPLICITLY (video-player idiom): no-op when
      # the window already sits in the requested mode, so a stream of
      # `set_fullscreen(true)` calls toggles exactly once. The default
      # implementation forwards to #toggle_fullscreen when the mode
      # differs.
      def self.set_fullscreen(fullscreen : Bool) : Nil
        implementation.set_fullscreen(fullscreen)
      end

      # The window mode STATE — fullscreen or windowed (the app-facing
      # half of the fullscreen contract). Like
      # SystemPorts::Screen.orientation, the recorded report wins over
      # the implementation's live answer; the backend keeps it current
      # every frame (native toggles — Esc, a WM hotkey, the title-bar
      # button — bypass the port entirely, so polling the live value is
      # the only way to stay truthful). Before the first report the
      # live implementation answers.
      def self.fullscreen? : Bool
        # The recorded report WINS — including a recorded `false`:
        # `@@fullscreen || …` reads a windowed report as "no report"
        # and falls through to the live query on every call, and on
        # the detached loops that query is a blocking roundtrip to the
        # render thread's next command drain (~a vsync tick each — the
        # video app polls twice per update, which cost ~33 ms/frame
        # and capped playback at ~18 fps). The backend refreshes the
        # record every frame (#sync_fullscreen), so it is never stale
        # by more than a tick.
        if (fs = @@fullscreen).nil?
          implementation.fullscreen?
        else
          fs
        end
      end

      # Record a fullscreen report (called by the backend: the sokol
      # driver's per-frame sync). Reports carrying the recorded value
      # are the "nothing changed" case — the driver filters them and
      # raises Events::FullscreenChanged itself.
      def self.fullscreen=(fullscreen : Bool) : Nil
        @@fullscreen = fullscreen
      end

      @@fullscreen : Bool? = nil

      # Set the window icon from straight (non-premultiplied) RGBA8
      # pixels, row-major, `width`×`height`. Win32 only today — the
      # default (and other platforms') implementation is a no-op.
      def self.set_icon(rgba : Bytes, width : Int32, height : Int32) : Nil
        implementation.set_icon(rgba, width, height)
      end

      # Toggle the system window chrome (title bar + borders) at
      # runtime. `false` gives a borderless window — the app then draws
      # its own title bar and drives close/minimize/move/resize through
      # this port (the eframe `decorations: false` setup). The default
      # (headless) implementation is a no-op.
      def self.set_decorations(decorated : Bool) : Nil
        implementation.set_decorations(decorated)
      end

      # Current window position — top-left corner in screen coordinates,
      # physical pixels (the units #set_position expects). Nil when the
      # platform (or headless default) cannot report it.
      def self.position : Egui::Vec2?
        implementation.position
      end

      # Hand an in-progress title-bar drag to the platform's native
      # window-move loop (WM/compositor tracks the pointer — jitter-free,
      # unlike a client-side loop measured in window-local coordinates,
      # which feeds back on its own moves). Call once, on drag start,
      # while the button is held. The native loop consumes the button
      # release; the backend injects a synthetic one so egui does not
      # keep the button pressed. The default (headless) implementation
      # is a no-op.
      def self.start_drag : Nil
        implementation.start_drag
      end

      # The resize counterpart of #start_drag: `edge` is one of
      # :top_left, :top, :top_right, :right, :bottom_right, :bottom,
      # :bottom_left, :left. Call once, on drag start, while the button
      # is held. The default (headless) implementation is a no-op.
      def self.start_resize(edge : Symbol) : Nil
        implementation.start_resize(edge)
      end

      # Shape the window from an 8-bit alpha mask (255 = pixel belongs
      # to the window, 0 = hole) — the splash-screen primitive: the
      # GL swap chain loses framebuffer alpha before the compositor on
      # several X11 stacks, so a server-side binary shape (X11 XShape,
      # Win32 SetWindowRgn) is the deterministic cross-platform way to
      # get a non-rectangular window. It clips input as well. macOS is
      # a no-op — its native per-pixel alpha already composites. Call
      # once per shape change, after the window exists. The default
      # (headless) implementation is a no-op.
      def self.set_shape(mask : Bytes, width : Int32, height : Int32) : Nil
        implementation.set_shape(mask, width, height)
      end

      # Uniform runtime opacity for the WHOLE window — chrome and
      # content together — the terminal-emulator idiom. `alpha` is
      # 0.0..1.0; 1.0 restores a fully opaque window. Goes through the
      # platform's own window-opacity channel (X11
      # _NET_WM_WINDOW_OPACITY — needs a running compositor; Win32
      # layered windows; macOS NSWindow.alphaValue), so it works both
      # ways at runtime, any number of times. The default (headless)
      # implementation is a no-op.
      def self.set_opacity(alpha : Float64) : Nil
        implementation.set_opacity(alpha)
      end

      # Platform seam; the default is a headless no-op.
      class Implementation
        def set_title(title : String) : Nil
        end

        def set_size(width : Int32, height : Int32) : Nil
        end

        def set_position(x : Int32, y : Int32) : Nil
        end

        def minimize : Nil
        end

        def maximize : Nil
        end

        def restore : Nil
        end

        def toggle_fullscreen : Nil
        end

        def set_fullscreen(fullscreen : Bool) : Nil
          toggle_fullscreen unless fullscreen == fullscreen?
        end

        def fullscreen? : Bool
          false
        end

        def set_icon(rgba : Bytes, width : Int32, height : Int32) : Nil
        end

        def set_decorations(decorated : Bool) : Nil
        end

        def position : Egui::Vec2?
          nil
        end

        def start_drag : Nil
        end

        def start_resize(edge : Symbol) : Nil
        end

        def set_shape(mask : Bytes, width : Int32, height : Int32) : Nil
        end

        def set_opacity(alpha : Float64) : Nil
        end
      end
    end
  end
end
