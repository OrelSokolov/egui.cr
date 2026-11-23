# macOS Motion port (plans/animations.md Ур.2): reads the system
# "Reduce motion" accessibility switch —
# NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion —
# through the minimal ObjC runtime layer (driver/objc.cr). Polled once
# per frame by the driver (two objc_msgSends — no observer wiring), so
# flipping the switch in System Settings takes effect on the next frame.
{% if flag?(:darwin) && !flag?(:ios) %}
  require "./objc"

  module Egui
    module Driver
      class DarwinMotion < SystemPorts::Motion::Implementation
        def initialize
          @workspace = ObjC.send0(ObjC.cls("NSWorkspace"),
            ObjC.sel("sharedWorkspace"))
        end

        def reduced? : Bool
          ObjC.send0_b(@workspace,
            ObjC.sel("accessibilityDisplayShouldReduceMotion"))
        end
      end
    end
  end
{% end %}
