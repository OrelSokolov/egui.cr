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

      def self.fullscreen? : Bool
        implementation.fullscreen?
      end

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
      end
    end
  end
end
