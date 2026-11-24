# System port Screen: primary-monitor geometry — what windows position
# against. `size` is the monitor size in points, `dpi_scale` the
# pixels-per-point factor (sokol `sapp_dpi_scale`; 2.0 on retina).
#
# `orientation` is the window/device orientation STATE (portrait /
# landscape) — the fact `Events::RotationChanged` only signals. The
# backend keeps it current: the sokol driver derives it from the
# window aspect (and re-derives on every RESIZED), mobile bridges
# record the OS's exact report (Events::RotationChanged carries it).
# The default implementation is headless: nil size, scale 1.0,
# orientation unknown; the backend installs the real one.

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

      # The window/device orientation, or nil when nothing has
      # reported it yet (headless / before the first frame). The
      # recorded report wins over the implementation's answer —
      # mobile bridges know the OS's value before the surface
      # actually resizes.
      def self.orientation : Orientation?
        @@orientation || implementation.orientation
      end

      # Record an orientation report (called by the backend: the
      # sokol driver on every RESIZED, mobile bridges on the OS's
      # configuration change).
      def self.orientation=(orientation : Orientation) : Nil
        @@orientation = orientation
      end

      @@orientation : Orientation? = nil

      # Platform seam; the default is the headless answer.
      class Implementation
        def size : Vec2?
          nil
        end

        def dpi_scale : Float64
          1.0
        end

        # The device orientation straight from the OS, or nil when
        # the platform can't tell.
        def orientation : Orientation?
          nil
        end
      end
    end
  end
end
