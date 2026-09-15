# System port Window: cross-platform window management — title, size,
# position, minimize/maximize/restore, fullscreen.
#
# Title and fullscreen delegate to sokol_app directly; resize/move/
# minimize/maximize go through backend/sokol_shim.c (X11 core protocol
# + _NET_WM_STATE, Win32). The default implementation is a headless
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
      end
    end
  end
end
