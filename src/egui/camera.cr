# Camera capture seam (the SystemPorts `.use` pattern applied to a video
# source): device enumeration, permission, and a poll-based frame pump.
#
# The core only ever sees RGBA bytes — a Session hands out the latest
# frame between UI updates (`#poll` returns nil until a NEW frame has
# arrived, mirroring sokol's one-texture-update-per-frame rule) and the
# app pushes it into a stream texture (`TextureRegistry#create_stream` /
# `#update`, the pipeline the video player uses). Native capture lives
# behind an installable implementation: the sokol backend installs
# AVFoundation on macOS and camera2-NDK on Android; iOS keeps the
# default "not implemented" implementation below.

module Egui
  module Camera
    # A capturable device as reported by the platform. `id` is opaque and
    # must be passed back to `Camera.open` unchanged.
    struct Device
      getter id : String
      getter name : String
      # :front / :back on phones, :unknown on desktop webcams.
      getter facing : Symbol

      def initialize(@id : String, @name : String, @facing : Symbol = :unknown)
      end

      def to_s(io : IO) : Nil
        io << @name
      end
    end

    # An open capture stream. `#poll` returns the newest frame as RGBA
    # bytes (row-major, `width * height * 4`) or nil when nothing new
    # arrived since the last poll; the buffer is owned by the backend
    # and valid only until the next `#poll` / `#close`.
    class Session
      getter handle : UInt64
      property width : Int32
      property height : Int32

      def initialize(@handle : UInt64, @width : Int32 = 0, @height : Int32 = 0)
      end

      # New RGBA frame since the last poll, or nil. Updates #width/#height
      # to the ACTUAL capture dimensions (the open() size is a hint).
      def poll : Bytes?
        Camera.implementation.poll_frame(self)
      end

      def close : Nil
        Camera.implementation.close(self)
        @handle = 0_u64
      end

      def open? : Bool
        !@handle.zero?
      end
    end

    class_getter implementation : Implementation = Implementation.new

    # Install a platform implementation (called by the backend).
    def self.use(implementation : Implementation) : Nil
      @@implementation = implementation
    end

    # False when the platform has no capture backend compiled in — the UI
    # should show #unavailable_reason instead of the device picker.
    def self.available? : Bool
      implementation.available?
    end

    def self.unavailable_reason : String?
      implementation.unavailable_reason
    end

    # Runtime permission state (mobile). 3-state: true = capture away,
    # false = denied or not yet asked — call #request_permission! first;
    # the OS dialog answers asynchronously, so keep polling this between
    # frames. Desktop implementations return true unconditionally.
    def self.permission_granted? : Bool
      implementation.permission_granted?
    end

    def self.request_permission! : Nil
      implementation.request_permission!
    end

    def self.devices : Array(Device)
      implementation.devices
    end

    # Open a capture stream; `device_id` nil = the default device. The
    # size is a hint — the session reports its actual dimensions with the
    # first polled frame. Nil (and #last_error set) on failure.
    def self.open(device_id : String? = nil, width : Int32 = 1280,
                  height : Int32 = 720) : Session?
      implementation.open(device_id, width, height)
    end

    def self.last_error : String?
      implementation.last_error
    end

    # Platform seam; the default is the honest "not here" answer, which
    # is also what iOS ships with for now.
    class Implementation
      def available? : Bool
        false
      end

      def unavailable_reason : String?
        {% if flag?(:ios) %}
          "Camera capture is not implemented on iOS yet"
        {% else %}
          "Camera capture is not implemented on this platform yet"
        {% end %}
      end

      def permission_granted? : Bool
        false
      end

      def request_permission! : Nil
      end

      def devices : Array(Device)
        [] of Device
      end

      def open(device_id : String?, width : Int32, height : Int32) : Session?
        nil
      end

      def poll_frame(session : Session) : Bytes?
        nil
      end

      def close(session : Session) : Nil
      end

      def last_error : String?
        nil
      end
    end
  end
end
