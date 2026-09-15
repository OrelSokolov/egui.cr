# System port Screen: primary-monitor geometry — what windows position
# against. `size` is the monitor size in points, `dpi_scale` the
# pixels-per-point factor (sokol `sapp_dpi_scale`; 2.0 on retina).
#
# Native through sokol_app / backend/sokol_shim.c (XDisplayWidth, …).
# The default implementation is headless: nil size, scale 1.0; the
# backend installs the real one.

module Egui
  module SystemPorts
    module Screen
      class_getter implementation : Implementation = Implementation.new

      # Install a platform implementation (called by the backend).
      def self.use(implementation : Implementation) : Nil
        @@implementation = implementation
      end

      # Primary monitor size in points, or nil when headless.
      def self.size : Vec2?
        implementation.size
      end

      # Pixels per point (1.0 when headless).
      def self.dpi_scale : Float64
        implementation.dpi_scale
      end

      # Platform seam; the default is the headless answer.
      class Implementation
        def size : Vec2?
          nil
        end

        def dpi_scale : Float64
          1.0
        end
      end
    end
  end
end
