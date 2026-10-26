# backend/voice_recorder.cr — installs the VoiceRecorder implementation
# on top of the minaudio shard (capture) and the permission gate in
# backend/sokol_shim.c (`egui_cr_mic_*`). Opt-in: `require
# "egui/backend/voice_recorder"` — apps without it keep the headless
# "not implemented" port and link no audio-capture code. iOS keeps the
# core default answer (AVAudioSession wiring is a separate step, see
# plans/voice-recording.md Phase 6).

require "minaudio"

module Egui
  module Backend
    {% unless flag?(:ios) %}
      @[Link("egui_cr_sokol")]
      lib LibEguiMic
        # 1 granted / 0 not asked / -1 denied
        fun perm = egui_cr_mic_perm : Int32
        fun perm_request = egui_cr_mic_perm_request : Void
      end

      class NativeVoiceRecorder < VoiceRecorder::Implementation
        @capture : MinAudio::CaptureDevice?
        @last_error : String?

        def initialize
        end

        def available? : Bool
          true
        end

        def permission_granted? : Bool
          LibEguiMic.perm == 1
        end

        def request_permission! : Nil
          LibEguiMic.perm_request
        end

        def devices : Array(VoiceRecorder::Device)
          MinAudio::Context.devices[:capture].map do |d|
            VoiceRecorder::Device.new(d.id, d.name)
          end
        rescue ex : MinAudio::Error
          @last_error = ex.message.to_s
          [] of VoiceRecorder::Device
        end

        def start(device_id : Bytes?, sample_rate : Int32,
                  channels : Int32) : Bool
          stop
          perm = LibEguiMic.perm
          unless perm == 1
            if perm == 0
              # Not asked yet — pop the dialog; the retry after a grant
              # succeeds (the app keeps polling permission_granted?).
              LibEguiMic.perm_request
              @last_error = "microphone permission requested — allow it, then Record again"
            else
              @last_error = "microphone permission denied (System Settings > Privacy & Security > Microphone)"
            end
            return false
          end
          {% if flag?(:android) %}
            # Capture mirror of the playback pin: AAudio first (stable for
            # capture since 8.0), OpenSL ES the fallback — the reverse of
            # backend/audio.cr, where vendor AAudio delivers silence.
            candidates = [
              [LibMinAudio::BACKEND_AAUDIO] of Int32,
              [LibMinAudio::BACKEND_OPENSL] of Int32,
            ]
          {% else %}
            candidates = [nil] of Array(Int32)?
          {% end %}
          candidates.each_with_index do |backends, i|
            begin
              dev = MinAudio::CaptureDevice.new(device_id, sample_rate,
                channels, backends)
              dev.start
              @capture = dev
              @last_error = nil
              puts "[mic] capture up: #{dev.sample_rate}Hz " \
                   "#{dev.channels}ch#{backends ? " (#{backends.inspect})" : ""}"
              return true
            rescue ex : MinAudio::Error
              @last_error = ex.message.to_s
              next if i < candidates.size - 1 # try the fallback backend
              puts "[mic] capture init failed: #{ex.message}"
            end
          end
          false
        end

        def recording? : Bool
          !!@capture
        end

        def poll : Bytes?
          dev = @capture
          return nil unless dev
          chunk = dev.drain
          chunk.empty? ? nil : chunk
        end

        def stop : Nil
          if (dev = @capture)
            @capture = nil
            dev.close rescue nil
          end
        end

        def last_error : String?
          @last_error
        end
      end

      # Installed at require time; the device itself opens lazily on
      # first start.
      VoiceRecorder.use(NativeVoiceRecorder.new)
    {% end %}
  end
end
