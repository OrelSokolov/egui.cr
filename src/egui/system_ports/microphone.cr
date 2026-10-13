# System port Microphone: capture. The port API stays headless — the
# native capture lives in the minaudio shard (ma_device + a C ring
# buffer; the audio-thread callback never enters Crystal) and is
# installed as a runner by `require "egui/backend/audio"`.
#
# Pull model: call #read once per frame from `update` — the ring drops
# the newest frames when the app reads slower than the mic delivers,
# it never grows unbounded and never blocks the frame loop:
#
#   mic = Egui::SystemPorts::Microphone.open  # nil when refused
#   if mic
#     n = mic.read(@buf)                      # f32 interleaved frames
#   end
#   mic.close
#
# On Android/iOS the runner requests the platform permission before
# opening; a refusal surfaces as Nil + `Microphone.last_error`, never
# as a crash. Without a runner `open` is Nil (headless builds, specs).

module Egui
  module SystemPorts
    module Microphone
      # Native capture runner installed by backend/audio.cr.
      @@runner : Runner?

      @@last_error : String?

      def self.last_error : String?
        @@last_error
      end

      # Runner-internal: record/clear the failure reason ("permission
      # denied", "no capture device", ...).
      def self.last_error=(message : String?) : Nil
        @@last_error = message
      end

      # The port's native surface: open returns a capture id (0 =
      # refused/unsupported); frames flow through the runner's ring
      # until close. All methods default to "unsupported" so spec fakes
      # stay small.
      module Runner
        def open(sample_rate : Int32, channels : Int32,
                 ring_frames : Int32) : Int32
          0
        end

        def read(id : Int32, buf : Bytes) : Int32
          0
        end

        def available_frames(id : Int32) : UInt64
          0
        end

        def start(id : Int32) : Nil
        end

        def stop(id : Int32) : Nil
        end

        def close(id : Int32) : Nil
        end
      end

      def self.use(runner : Runner) : Nil
        @@runner = runner
      end

      # Drop the installed runner (spec hygiene).
      def self.use : Nil
        @@runner = nil
      end

      def self.supported? : Bool
        !!@@runner
      end

      # Open the default capture device: mono 48 kHz with a ~0.34s ring
      # by default. Returns Nil when no runner is installed, there is no
      # microphone, or the platform permission was refused (reason in
      # `last_error`). Capture starts immediately.
      def self.open(sample_rate : Int32 = 48_000, channels : Int32 = 1,
                    ring_frames : Int32 = 16_384) : Mic?
        runner = @@runner
        return nil unless runner
        id = runner.open(sample_rate, channels, ring_frames)
        id > 0 ? Mic.new(id, channels) : nil
      end

      # A live capture session. Reuse one buffer and call #read from the
      # frame loop; the ring keeps at most `ring_frames` frames.
      class Mic
        getter id : Int32
        getter channels : Int32

        # Internal: built by Microphone.open.
        def initialize(@id : Int32, @channels : Int32)
        end

        # Frames of f32-interleaved PCM waiting in the ring.
        def available_frames : UInt64
          runner.try(&.available_frames(@id)) || 0u64
        end

        # Pull up to buf.size / (channels * 4) frames into buf; returns
        # the frame count actually read (0 = nothing captured yet).
        def read(buf : Bytes) : Int32
          runner.try(&.read(@id, buf)) || 0
        end

        def stop : Nil
          runner.try(&.stop(@id))
        end

        def start : Nil
          runner.try(&.start(@id))
        end

        # Stop capturing and release the device. Idempotent; the handle
        # is dead afterwards (reads return 0).
        def close : Nil
          runner.try(&.close(@id))
          @id = 0
        end

        private def runner : Runner?
          Microphone.runner_for(@id)
        end
      end

      # Internal: the live runner for handle delegation.
      def self.runner_for(id : Int32) : Runner?
        return nil if id <= 0
        @@runner
      end
    end
  end
end
