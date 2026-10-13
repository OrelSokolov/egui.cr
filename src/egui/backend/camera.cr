# Native camera implementations for the sokol backend: AVFoundation on
# macOS, camera2 NDK on Android (backend/sokol_shim.c, camera capture
# section). The two stacks share one C API, so one implementation class
# covers both; iOS keeps the core default "not implemented" answer, and
# this file compiles to nothing there — as it does on Windows/Linux.

module Egui
  module Backend
    {% if (flag?(:darwin) && !flag?(:ios)) || flag?(:android) %}
      @[Link("egui_cr_sokol")]
      {% if flag?(:darwin) %}
        @[Link(framework: "AVFoundation")]
        @[Link(framework: "CoreMedia")]
      {% end %}
      {% if flag?(:android) %}
        @[Link("camera2ndk")]
        @[Link("mediandk")]
      {% end %}
      lib LibEguiCam
        # 1 granted / 0 not asked / -1 denied
        fun perm = egui_cr_cam_perm : Int32
        fun perm_request = egui_cr_cam_perm_request : Void
        # Refresh the device list; returns the count (max 8).
        fun devices = egui_cr_cam_devices : Int32
        fun dev_id = egui_cr_cam_dev_id(index : Int32) : UInt8*
        fun dev_name = egui_cr_cam_dev_name(index : Int32) : UInt8*
        # 0 unknown / 1 front / 2 back
        fun dev_facing = egui_cr_cam_dev_facing(index : Int32) : Int32
        # Returns the session pointer (NULL = failure, see last_error).
        fun cam_open = egui_cr_cam_open(devid : UInt8*, w : Int32, h : Int32) : Void*
        # 1 when a NEW frame arrived; *data then points at backend-owned
        # RGBA pixels (w*h*4) valid until the next call.
        fun cam_frame = egui_cr_cam_frame(sess : Void*, data : UInt8**,
                                          w : Int32*, h : Int32*) : Int32
        fun cam_close = egui_cr_cam_close(sess : Void*) : Void
        fun cam_set_rotation = egui_cr_cam_set_rotation(sess : Void*,
                                                        deg : Int32) : Void
        fun last_error = egui_cr_cam_last_error : UInt8*
      end

      # The shared implementation over the shim's uniform camera C API.
      class NativeCam < Camera::Implementation
        def available? : Bool
          true
        end

        def permission_granted? : Bool
          LibEguiCam.perm == 1
        end

        def request_permission! : Nil
          LibEguiCam.perm_request
        end

        def devices : Array(Camera::Device)
          count = LibEguiCam.devices
          (0...count).map do |i|
            facing = case LibEguiCam.dev_facing(i)
                     when 1 then :front
                     when 2 then :back
                     else        :unknown
                     end
            Camera::Device.new(String.new(LibEguiCam.dev_id(i)),
              String.new(LibEguiCam.dev_name(i)), facing)
          end
        end

        def open(device_id : String?, width : Int32, height : Int32) : Camera::Session?
          ptr = device_id ? device_id.to_unsafe : Pointer(UInt8).null
          handle = LibEguiCam.cam_open(ptr, width, height)
          handle.null? ? nil : Camera::Session.new(handle.address)
        end

        def poll_frame(session : Camera::Session) : Bytes?
          data = Pointer(UInt8).null
          w, h = 0, 0
          if LibEguiCam.cam_frame(Pointer(Void).new(session.handle),
                                  pointerof(data), pointerof(w), pointerof(h)) == 1
            session.width = w
            session.height = h
            Slice.new(data, w * h * 4, read_only: true)
          end
        end

        def close(session : Camera::Session) : Nil
          LibEguiCam.cam_close(Pointer(Void).new(session.handle))
        end

        def set_rotation(session : Camera::Session, degrees : Int32) : Nil
          LibEguiCam.cam_set_rotation(Pointer(Void).new(session.handle), degrees)
        end

        def last_error : String?
          ptr = LibEguiCam.last_error
          (ptr.null? || ptr[0] == 0) ? nil : String.new(ptr)
        end
      end
    {% end %}
  end
end
