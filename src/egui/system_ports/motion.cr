# System port Motion: the OS accessibility motion setting —
# `prefers-reduced-motion` (plans/animations.md Ур.2). When it reports
# true, Context#reduced_motion= snaps every cascade transition, appear
# run and popup exit — the "all durations → 0" accessibility rule.
#
# The core stays headless: the default implementation answers false;
# the backend installs the platform reader (macOS:
# NSWorkspace's accessibilityDisplayShouldReduceMotion — driver/
# motion_darwin.cr). The driver polls it once per frame and syncs
# Context#reduced_motion, so a mid-run OS toggle takes effect without
# an app restart.

module Egui
  module SystemPorts
    module Motion
      class_getter implementation : Implementation = Implementation.new

      # Install a platform implementation (called by the backend).
      def self.use(implementation : Implementation) : Nil
        @@implementation = implementation
      end

      # True when the OS asks for reduced motion.
      def self.reduced? : Bool
        implementation.reduced?
      end

      # Platform seam; the default is a headless no-op.
      class Implementation
        def reduced? : Bool
          false
        end
      end
    end
  end
end
