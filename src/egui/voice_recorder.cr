# Microphone capture seam (the Camera `.use` pattern applied to audio):
# device enumeration, permission and a poll-based PCM pump. Like the
# camera, the core only ever sees bytes — s16le PCM chunks that arrived
# since the previous poll (`#poll` returns nil until NEW samples show
# up); the app accumulates them and computes its own level (RMS).
# Playback of a recording goes through SystemPorts::Audio via Wav.encode.
#
# Native capture lives behind an installable implementation
# (backend/voice_recorder.cr, miniaudio capture on top of the permission
# shim in backend/sokol_shim.c); the default below is the honest
# "not here" answer, which is also what iOS ships with for now.

module Egui
  module VoiceRecorder
    # A microphone as reported by the platform. `id` is an opaque blob
    # (a backend-dependent device id) that must be passed back to
    # `VoiceRecorder.start` unchanged.
    struct Device
      getter id : Bytes
      getter name : String

      def initialize(@id : Bytes, @name : String)
      end

      def to_s(io : IO) : Nil
        io << @name
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

    # Runtime permission state (mobile). 3-state like the camera: true =
    # record away, false = denied or not yet asked — call
    # #request_permission! first; the OS dialog answers asynchronously, so
    # keep polling this between frames. Desktop implementations return
    # true unconditionally.
    def self.permission_granted? : Bool
      implementation.permission_granted?
    end

    def self.request_permission! : Nil
      implementation.request_permission!
    end

    # Microphones on this machine (empty when none / no permission yet —
    # on Android the list fills only after the RECORD_AUDIO grant).
    def self.devices : Array(Device)
      implementation.devices
    end

    # Begin recording. `device_id` nil or omitted = the default
    # microphone; otherwise an opaque Device#id blob. Returns false (and
    # sets #last_error) on failure — permission refused, no device.
    def self.start(device_id : Bytes? = nil, sample_rate : Int32 = 16000,
                   channels : Int32 = 1) : Bool
      implementation.start(device_id, sample_rate, channels)
    end

    def self.recording? : Bool
      implementation.recording?
    end

    # New s16le PCM since the last poll, or nil when nothing arrived.
    # Never blocks — safe on the frame thread. The buffer is owned by the
    # caller (copy out immediately if kept).
    def self.poll : Bytes?
      implementation.poll
    end

    def self.stop : Nil
      implementation.stop
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
          "Microphone capture is not implemented on iOS yet"
        {% else %}
          "Microphone capture is not implemented on this platform yet"
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

      def start(device_id : Bytes?, sample_rate : Int32, channels : Int32) : Bool
        false
      end

      def recording? : Bool
        false
      end

      def poll : Bytes?
        nil
      end

      def stop : Nil
      end

      def last_error : String?
        nil
      end
    end

    # Minimal WAV writer: a 44-byte canonical header around s16le PCM.
    # Enough to hand a recording to SystemPorts::Audio.play (miniaudio
    # decodes it) without pulling in an encoding dependency (the shard
    # compiles miniaudio with MA_NO_ENCODING).
    module Wav
      # `pcm` is interleaved s16le samples recorded at `sample_rate` with
      # `channels` channels.
      def self.encode(pcm : Bytes, sample_rate : Int32,
                      channels : Int32) : Bytes
        le = IO::ByteFormat::LittleEndian
        wav = Bytes.new(44 + pcm.size)
        "RIFF".each_char_with_index { |c, i| wav[i] = c.ord.to_u8 }
        le.encode((36 + pcm.size).to_u32!, wav[4, 4])
        "WAVE".each_char_with_index { |c, i| wav[8 + i] = c.ord.to_u8 }
        "fmt ".each_char_with_index { |c, i| wav[12 + i] = c.ord.to_u8 }
        le.encode(16u16, wav[16, 2])                    # fmt chunk size
        le.encode(1u16, wav[20, 2])                     # PCM
        le.encode(channels.to_u16!, wav[22, 2])
        le.encode(sample_rate.to_u32!, wav[24, 4])
        le.encode((sample_rate * channels * 2).to_u32!, wav[28, 4])
        le.encode((channels * 2).to_u16!, wav[32, 2])   # block align
        le.encode(16u16, wav[34, 2])                    # bits per sample
        "data".each_char_with_index { |c, i| wav[36 + i] = c.ord.to_u8 }
        le.encode(pcm.size.to_u32!, wav[40, 4])
        pcm.copy_to(wav[44, pcm.size])
        wav
      end
    end
  end
end
