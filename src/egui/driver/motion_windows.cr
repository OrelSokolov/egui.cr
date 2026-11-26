# Windows Motion port (plans/animations.md Ур.2): reads the system
# "Show animations in Windows" accessibility switch —
# SystemParametersInfo(SPI_GETCLIENTAREAANIMATION). Windows frames the
# setting as the inverse of the other platforms' "reduce motion"
# switch: animations ON = normal, OFF = reduced motion. Polled once
# per frame by the driver, so flipping the switch in Settings takes
# effect on the next frame.
{% if flag?(:win32) %}
  module Egui
    module Driver
      # No @[Link("user32")] — driver/tray_windows.cr already puts
      # user32 on the linker line for win32 programs (both files are
      # required together by driver/sokol.cr); a repeat would only
      # draw an ld "duplicate libraries" warning.
      lib LibMotionUser32
        fun system_parameters_info_w = SystemParametersInfoW(action : UInt32,
          ui_param : UInt32, pv_param : Void*, win_ini : UInt32) : Int32
      end

      class WindowsMotion < SystemPorts::Motion::Implementation
        SPI_GETCLIENTAREAANIMATION = 0x1042u32

        def reduced? : Bool
          enabled = 0u32
          LibMotionUser32.system_parameters_info_w(SPI_GETCLIENTAREAANIMATION,
            0, pointerof(enabled), 0)
          enabled == 0 # animations disabled = reduced motion
        end
      end
    end
  end
{% end %}
