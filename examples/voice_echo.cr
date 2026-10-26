# egui-cr voice echo demo — a separate binary (bin/voice_echo).
#
# Framework side: the VoiceRecorder seam (src/egui/voice_recorder.cr,
# minaudio capture behind it) + SystemPorts::Audio for playback. Device
# picker over VoiceRecorder.devices (several microphones are the norm on
# a desktop), runtime permission (mobile/macOS TCC), record/stop, a
# live RMS level meter, and Play → Wav.encode → Audio.play of what was
# just recorded — the echo test.

require "../src/egui/backend_selector"
require "../src/egui/backend/audio"
require "../src/egui/backend/voice_recorder"

class VoiceEchoApp < Egui::App
  SAMPLE_RATE = 16000
  CHANNELS    = 1

  @devices = [] of Egui::VoiceRecorder::Device
  @names = [] of String          # "Default microphone" + device names
  @selected = 0                  # 0 = default device (nil id)
  @pcm = Bytes.new(0)
  @recording_start = Time.instant
  @seconds = 0.0f32
  @level = 0.0f32                # RMS of the last chunk, decaying
  @status = ""
  @listed = false
  @perm_requested = false
  @wav_path : String? = nil

  def initialize
    super()
  end

  private def refresh_devices : Nil
    @devices = Egui::VoiceRecorder.devices
    @names = ["Default microphone"] + @devices.map(&.to_s)
    @selected = 0
  end

  private def selected_id : Bytes?
    # index 0 is the "Default microphone" entry
    return nil if @selected == 0
    @devices[@selected - 1]?.try &.id
  end

  private def start_recording : Nil
    @pcm = Bytes.new(0)
    @seconds = 0.0f32
    @level = 0.0f32
    if Egui::VoiceRecorder.start(selected_id, SAMPLE_RATE, CHANNELS)
      @recording_start = Time.instant
      @status = "Recording…"
    else
      @status = "Record failed: #{Egui::VoiceRecorder.last_error || "unknown error"}"
    end
  end

  private def stop_recording : Nil
    Egui::VoiceRecorder.stop
    @seconds = (Time.instant - @recording_start).total_seconds.to_f32!
    if @pcm.empty?
      @status = "Nothing recorded (silence?)"
      return
    end
    @wav_path.try { |p| File.delete(p) rescue nil }
    @wav_path = nil
    @status = "#{@pcm.size // (SAMPLE_RATE * CHANNELS * 2)} s captured — press Play"
  end

  private def play_recording : Nil
    path = @wav_path
    if path.nil? || !File.exists?(path)
      # (re)write the WAV once per take: encode → tempfile → Audio.play
      wav = Egui::VoiceRecorder::Wav.encode(@pcm, SAMPLE_RATE, CHANNELS)
      path = File.tempname("voice_echo", ".wav")
      File.write(path, wav)
      @wav_path = path
    end
    if Egui::SystemPorts::Audio.play(path)
      @status = "Playing…"
    else
      @status = "Playback failed: #{Egui::SystemPorts::Audio.last_error || "unknown error"}"
    end
  end

  def update(ctx : Egui::Context) : Nil
    # Device list + permission state, lazily on the first update.
    unless @listed
      @listed = true
      refresh_devices if Egui::VoiceRecorder.available?
    end

    # The permission dialog answers asynchronously — keep repainting (and
    # refresh the device list once granted; on Android it fills only
    # then).
    granted = Egui::VoiceRecorder.available? && Egui::VoiceRecorder.permission_granted?
    if granted
      @perm_requested = false
      refresh_devices if @devices.empty?
    elsif @perm_requested
      ctx.request_repaint
    end

    # PCM pump: accumulate new chunks, update the level meter and clock.
    if Egui::VoiceRecorder.recording?
      if (chunk = Egui::VoiceRecorder.poll)
        grown = Bytes.new(@pcm.size + chunk.size)
        @pcm.copy_to(grown)
        chunk.copy_to(grown + @pcm.size)
        @pcm = grown
        @level = rms(chunk)
      else
        @level *= 0.92f32 # decay between chunks so the bar "breathes"
      end
      @seconds = (Time.instant - @recording_start).total_seconds.to_f32!
      ctx.request_repaint # capture = continuous stream, never idle-skip
    else
      @level *= 0.9f32 if @level > 0.001
    end

    ctx.bottom_panel(height: 140) do |ui|
      ui.horizontal do |row|
        unless Egui::VoiceRecorder.available?
          row.label(Egui::VoiceRecorder.unavailable_reason || "Microphone unavailable")
          next
        end
        unless granted
          if row.button("Allow microphone access").clicked?
            Egui::VoiceRecorder.request_permission!
            if (err = Egui::VoiceRecorder.last_error)
              @status = err
            else
              @perm_requested = true
              @status = "Waiting for permission — answer the system dialog…"
            end
          end
          row.label("Recording needs microphone permission.")
          next
        end
        if @names.size <= 1
          row.label("No microphones found")
        else
          row.select_box("mic_device", @names[@selected]? || "", @names) do |opt|
            idx = @names.index(opt) || 0
            # A live device switch restarts the take.
            @selected = idx
            start_recording if Egui::VoiceRecorder.recording?
          end
        end
        recording = Egui::VoiceRecorder.recording?
        if row.button(recording ? "Stop" : @pcm.empty? ? "Record" : "Record again").clicked?
          recording ? stop_recording : start_recording
        end
        if !recording && !@pcm.empty? && row.button("Play").clicked?
          play_recording
        end
      end
      # Level meter: RMS of the newest chunk (0..1 of full scale).
      ui.progress_bar(@level.clamp(0.0f32, 1.0f32).to_f64,
        text: Egui::VoiceRecorder.recording? ? "level %.0f%%" % {@level * 100} : "")
      ui.label(@status.empty? ? "Ready." : @status)
    end

    ctx.central_panel do |ui|
      ui.heading("egui-cr voice echo")
      if Egui::VoiceRecorder.available?
        ui.label("Record from the microphone (picker above), then Play — " \
                 "the take goes through Wav.encode → SystemPorts::Audio.")
        ui.separator
        ui.label("Recorded: %.1f s · %d KB (s16le, #{SAMPLE_RATE} Hz, " \
                 "#{CHANNELS == 1 ? "mono" : "stereo"})" %
                 {@seconds, @pcm.size // 1024})
        if (dev = @names[@selected]?)
          ui.label("Microphone: #{dev}")
        end
      else
        ui.label(Egui::VoiceRecorder.unavailable_reason || "Microphone unavailable")
      end
    end
  end

  # Root-mean-square of an s16le chunk, normalized to 0..1 — the cheap
  # "how loud is it right now" the level bar shows.
  private def rms(chunk : Bytes) : Float32
    return 0.0f32 if chunk.size < 2
    samples = chunk.size // 2
    sum = 0.0f64
    samples.times do |i|
      s = (chunk.to_unsafe.as(Int16*)[i]).to_f64!
      sum += s * s
    end
    Math.sqrt(sum / samples).to_f32! / 32768.0f32 * 4.0f32 # *4: speech RMS ≈ 25%
  end
end

Egui.run(VoiceEchoApp.new,
  title: "egui.cr — voice echo", width: 720, height: 480, inspector: :hidden)
