# egui-cr audio demo — the full SystemPorts::Audio v2 surface and the
# Microphone port in one window:
#
#   • samples: a click decoded once (from a generated WAV on disk and
#     from in-memory Bytes — the embedded-asset path), overlaid replays
#   • streaming: a generated music-like loop with live volume / pause /
#     fade-out / seek, played through a named bus
#   • bus mixer: per-bus volume sliders + master
#   • microphone: pull-model capture with a level meter (RMS)
#
# All sounds are generated at startup — no binary assets ship with the
# example. Everything degrades honestly: on a headless/no-device box
# the labels say so instead of crashing the frame loop.

require "../src/egui/backend_selector"
require "../src/egui/backend/audio"

class AudioApp < Egui::App
  @wav_path : String = ""
  @music_path : String = ""
  @click : Egui::SystemPorts::Audio::Sample?
  @embedded : Egui::SystemPorts::Audio::Sample?
  @music : Egui::SystemPorts::Audio::Sound?
  @music_vol = 0.6_f64
  @sfx_vol = 0.8_f64
  @ui_vol = 0.5_f64
  @master = 0.9_f64
  @mic : Egui::SystemPorts::Microphone::Mic?
  @mic_buf = Bytes.new(4800 * 4) # 100 ms of mono f32 @ 48 kHz
  @mic_level = 0.0f32
  @status : String = ""
  # Echo test: the running recording and its live waveform view.
  @rec = [] of Float32
  @recording = false
  @rec_peak = 0.0f32 # loudest incoming sample of the current recording
  @echo : Egui::SystemPorts::Audio::Sample?
  # The currently playing echo voice + its position in seconds (drives
  # the playback cursor line on the wave). The raw `Sound#cursor` from
  # minaudio advances in ~0.2 s mixer-block steps, so the displayed
  # position is wall-clock interpolated from an anchor and re-anchored
  # when it drifts from the true cursor.
  @echo_voice : Egui::SystemPorts::Audio::Sound?
  @play_pos : Float32?
  @play_anchor : Float32?  # true cursor value at the anchor moment
  @play_t0 : Float64?      # play-clock seconds at the anchor moment
  @wave = Egui::Canvas.new("audio_wave", 430, 110,
    Egui::Color32.new(28, 30, 36))
  # The floating window length in seconds: the wave keeps a FIXED time
  # scale (frames-per-bar constant) anchored to the end of the buffer —
  # it fills left→right, then scrolls with the live edge on the right.
  @wave_seconds = 5

  def initialize
    super
    begin
      generate_assets
    rescue ex
      puts "[audio] asset generation failed: #{ex.message}"
    end
    draw_wave # empty frame so the canvas never shows as blank white
  end

  private def tmp_path(name : String) : String
    dir = tmp_dir
    File.join(dir, name)
  rescue
    "/tmp/#{name}"
  end

  private def tmp_dir : String
    {% if flag?(:android) %}
      Egui::SystemPorts::Android.dir(Egui::SystemPorts::Android::DIR_CACHE) || Dir.tempdir
    {% else %}
      Dir.tempdir
    {% end %}
  rescue
    "."
  end

  # Two generated sounds: a short click (16-bit mono) and a longer
  # music-ish loop (a quiet chord arpeggio). WAV-writing helpers — the
  # same format code as examples/device_api.cr.
  def generate_assets : Nil
    le = IO::ByteFormat::LittleEndian
    rate = 44_100

    write_wav = ->(frames : Array(Int16), channels : Int32, path : String) do
      data_bytes = frames.size * 2
      wav = Bytes.new(44 + data_bytes)
      "RIFF".each_char_with_index { |c, i| wav[i] = c.ord.to_u8 }
      le.encode((36 + data_bytes).to_u32, wav[4, 4])
      "WAVE".each_char_with_index { |c, i| wav[8 + i] = c.ord.to_u8 }
      "fmt ".each_char_with_index { |c, i| wav[12 + i] = c.ord.to_u8 }
      le.encode(16u16, wav[16, 2]); le.encode(1u16, wav[20, 2])
      le.encode(channels.to_u16!, wav[22, 2])
      le.encode(rate.to_u32!, wav[24, 4])
      le.encode((rate * channels * 2).to_u32, wav[28, 4])
      le.encode((channels * 2).to_u16!, wav[32, 2])
      le.encode(16u16, wav[34, 2])
      "data".each_char_with_index { |c, i| wav[36 + i] = c.ord.to_u8 }
      le.encode(data_bytes.to_u32, wav[40, 4])
      frames.each_with_index { |s, i| le.encode(s, wav[44 + i * 2, 2]) }
      File.write(path, wav)
      wav
    end

    # Click: 160 ms two-tone blip (660→880 Hz, ~43% full scale, fading
    # tail) — the device_api chime recipe: short enough to read as a
    # click, loud/long enough to survive laptop speakers.
    click_frames = Array(Int16).new(rate * 160 // 1000) do |f|
      t = f.to_f64 / rate
      dur = 0.16
      freq = t < 0.08 ? 660.0 : 880.0
      (Math.sin(t * freq * 2 * Math::PI) * 14000 * (1.0 - t / dur)).to_i16!
    end
    @wav_path = tmp_path("egui_audio_click.wav")
    write_wav.call(click_frames, 1, @wav_path)

    # Music: 6 s arpeggio over a base drone — long enough to make the
    # streamed/decoded difference visible in memory terms.
    music_frames = Array(Int16).new(rate * 6) do |f|
      t = f.to_f64 / rate
      step = (t * 4).to_i % 4 # 4 notes/s
      freq = {220.0, 277.18, 329.63, 440.0}[step]
      tone = Math.sin(t * freq * 2 * Math::PI) * 5000
      drone = Math.sin(t * 110 * 2 * Math::PI) * 3000
      (tone + drone).to_i16!
    end
    @music_path = tmp_path("egui_audio_music.wav")
    write_wav.call(music_frames, 1, @music_path)

    # Samples: from the file path and from the in-memory image (the
    # embedded-asset path — bytes could come from build_resource).
    @click = Egui::SystemPorts::Audio.sample(@wav_path)
    @embedded = Egui::SystemPorts::Audio.sample(
      File.read(@wav_path).to_slice)
    if @click.nil? && @embedded.nil?
      @status = "сэмплы: #{Egui::SystemPorts::Audio.last_error || "недоступно"}"
    end
  end

  def update(ctx : Egui::Context) : Nil
    # Microphone pull: read whatever the ring buffered since the last
    # frame; RMS over what arrived feeds the level readout, the frames
    # accumulate into the recording and scroll the waveform. The wave
    # canvas itself drives the frame loop while it keeps changing
    # (Canvas includes AutoRepaint — no manual repaint bookkeeping).
    if (mic = @mic)
      got = mic.read(@mic_buf)
      if got > 0
        sum = 0.0f32
        ptr = @mic_buf.to_unsafe.as(Float32*)
        got.times do |i|
          v = ptr[i]
          sum += v * v
          @rec << v if @recording
          a = v.abs
          @rec_peak = a if a > @rec_peak
        end
        @mic_level = Math.sqrt(sum / got)
        draw_wave
      end
    else
      @mic_level *= 0.9f32 # decay to zero after close
      # Echo playback cursor: redraw the wave with the position line
      # while the voice runs; one last redraw when it finishes.
      if (v = @echo_voice)
        if v.playing?
          @play_pos = interpolate_play_pos(v)
          draw_wave
        else
          @echo_voice = nil
          @play_pos = nil
          @play_anchor = nil
          @play_t0 = nil
          draw_wave
        end
      end
    end

    ctx.window("Audio", Egui::Pos2.new(40.0, 40.0), width: 470.0) do |ui|
      # The panel is taller than a small window can be — scroll the whole
      # body (wheel/kinetic/scrollbar) instead of clamping the layout.
      ui.scroll_area do |scroll|
        scroll.heading("Аудио-слой")
        scroll.label("Движок — #{Egui::SystemPorts::Audio.supported? ? "minaudio" : "нет (headless)"}")
        scroll.label(@status) unless @status.empty?

        scroll.separator
        scroll.label("Сэмплы (клики) — декод once, реплеи дёшевы")
        scroll.horizontal do |h|
          if h.button("Клик (из файла)").clicked?
            play_click(@click)
          end
          if h.button("Клик (из Bytes)").clicked?
            play_click(@embedded)
          end
          if h.button("×3 наложением").clicked?
            3.times { play_click(@click) }
          end
        end
        changed = false
        scroll.slider(@sfx_vol, 0.0..1.0, "Громкость шины sfx") do |v|
          @sfx_vol = v
          changed = true
        end
        Egui::SystemPorts::Audio.bus("sfx").volume = @sfx_vol.to_f32! if changed

        scroll.separator
        scroll.label("Стриминг (музыка)")
        music = @music
        if music.nil?
          if scroll.button("Играть музыку (loop, шина music)").clicked?
            @music = Egui::SystemPorts::Audio.play_stream(@music_path,
              volume: @music_vol.to_f32!, loop: true, bus: "music")
            if @music.nil?
              @status = "музыка: #{Egui::SystemPorts::Audio.last_error || "недоступно"}"
            end
          end
        else
          if scroll.button("Стоп (с фейдом 400 мс)").clicked?
            music.fade_out_and_stop(400)
            @music = nil
          end
          if scroll.button(music.playing? ? "Пауза" : "Продолжить").clicked?
            music.paused = music.playing?
          end
          scroll.label("Позиция: #{music.cursor.round(1)} / #{music.length.round(1)} с")
        end
        changed = false
        scroll.slider(@music_vol, 0.0..1.0, "Громкость музыки") do |v|
          @music_vol = v
          changed = true
        end
        if changed
          Egui::SystemPorts::Audio.bus("music").volume = @music_vol.to_f32!
          @music.try(&.volume = @music_vol.to_f32!)
        end

        scroll.separator
        scroll.label("Микшер")
        scroll.slider(@ui_vol, 0.0..1.0, "Шина ui") do |v|
          @ui_vol = v
          Egui::SystemPorts::Audio.bus("ui").volume = @ui_vol.to_f32!
        end
        scroll.slider(@master, 0.0..1.0, "Мастер") do |v|
          @master = v
          Egui::SystemPorts::Audio.master_volume = @master.to_f32!
        end
        scroll.horizontal do |h|
          if h.button("Пауза всего").clicked?
            Egui::SystemPorts::Audio.pause_all
          end
          if h.button("Продолжить всё").clicked?
            Egui::SystemPorts::Audio.resume_all
          end
          if h.button("Стоп все звуки").clicked?
            Egui::SystemPorts::Audio.stop_all
            @music = nil
          end
        end

        scroll.separator
        scroll.label("Эхо-тест — #{Egui::SystemPorts::Microphone.supported? ? "запись с волной, затем проигрывание" : "микрофона нет (headless)"}")
        mic = @mic
        if mic.nil?
          if scroll.button(@echo ? "Перезаписать" : "Записать с микрофона").clicked?
            if (old = @echo)
              old.close
              @echo = nil
            end
            @rec.clear
            @rec_peak = 0.0f32
            @recording = true
            @mic = Egui::SystemPorts::Microphone.open
            @status = @mic ? "запись…" :
              "микрофон: #{Egui::SystemPorts::Microphone.last_error || "отказ"}"
            draw_wave
          end
        elsif scroll.button("Остановить запись").clicked?
          mic.close
          @mic = nil
          @recording = false
          @mic_level = 0.0f32
          make_echo
          draw_wave
          if @rec.size > 4800 && @rec_peak == 0.0f32
            # Frames flow but every sample is exactly zero: macOS/Android
            # deliver digital silence when the process lacks mic
            # permission (unbundled binaries get no prompt — grant the
            # Terminal/app the microphone, then re-record).
            @status = "микрофон отдаёт тишину — нет разрешения " \
                      "(macOS: Конфиденциальность → Микрофон)"
          else
            @status = @echo ? "записано #{@rec.size // 48_000} c" : "запись пуста"
          end
        end
        # The live waveform: fixed-scale floating window over the buffer.
        scroll.horizontal do |h|
          h.label("Окно:")
          {2, 5, 10, 30}.each do |n|
            mark = n == @wave_seconds ? "[#{n} с]" : "#{n} с"
            if h.button(mark).clicked?
              @wave_seconds = n
              draw_wave
            end
          end
        end
        @wave.show(scroll)
        @wave.flush(ctx) if @wave.dirty?
        scroll.label("уровень (RMS): #{@mic_level.round(3)} · " \
                 "длина: #{@rec.size // 48_000}.#{(@rec.size % 48_000) * 10 // 48_000} c")
        if (echo = @echo)
          if scroll.button("▶ Проиграть запись").clicked?
            v = echo.play(volume: 0.9f32)
            @echo_voice = v
            if v
              # Anchor the wall-clock interpolation at the voice start.
              @play_anchor = v.cursor
              @play_t0 = play_clock
            end
            @status = v ? "эхо играет (id=#{v.not_nil!.id})" :
              "эхо: #{Egui::SystemPorts::Audio.last_error || "отказ"}"
          end
          if (vp = @echo_voice)
            scroll.label("проиграно: #{(@play_pos || vp.cursor).round(1)} / #{vp.length.round(1)} c")
          end
        end
      end
    end
  end

  # Smooth playback position: advance from the anchor by wall-clock time
  # (the raw cursor only updates per ~190 ms mixer block). The re-anchor
  # tolerance is ASYMMETRIC because the raw cursor always lags the block
  # quantization: letting the prediction run up to 0.5 s ahead is fine,
  # re-anchoring down within that window makes the line jump backwards
  # (verified by simulation: 16 backward jumps in 4 s with a 0.15 s
  # symmetric threshold). Only snap forward when the true cursor is AHEAD
  # (seek / loop restart / underrun recovery) or on large positive drift.
  private def interpolate_play_pos(v : Egui::SystemPorts::Audio::Sound) : Float32
    anchor = (@play_anchor ||= v.cursor)
    t0 = (@play_t0 ||= play_clock)
    predicted = anchor + (play_clock - t0)
    actual = v.cursor
    if actual > predicted + 0.1 || predicted - actual > 0.5
      @play_anchor = actual
      @play_t0 = play_clock
      predicted = actual
    end
    predicted = 0.0 if predicted < 0
    {predicted, v.length}.min.to_f32!
  end

  # Monotonic wall-clock seconds (Time.monotonic is deprecated in 1.21).
  private def play_clock : Float64
    (Time.instant - CLOCK_REF).total_nanoseconds.to_f / 1e9
  end

  CLOCK_REF = Time.instant

  private def play_click(sample : Egui::SystemPorts::Audio::Sample?) : Nil
    if (s = sample)
      if (v = s.play(volume: @sfx_vol.to_f32!, bus: "sfx"))
        @status = "клик играет (id=#{v.id})"
      else
        @status = "клик: #{Egui::SystemPorts::Audio.last_error || "отказ"}"
      end
    else
      # Fallback for the v1 path: the plain fire-and-forget play.
      ok = Egui::SystemPorts::Audio.play(@wav_path, volume: @sfx_vol.to_f32!)
      @status = ok ? "клик (файл) играет" :
        "клик: #{Egui::SystemPorts::Audio.last_error || "отказ"}"
    end
  end

  # Redraw the waveform view: a floating window over the recording
  # buffer with a FIXED time scale — `@wave_seconds` of audio spread
  # over the canvas width, anchored to the newest sample. Shorter than
  # the window: the wave fills left→right at the same scale. Longer:
  # the window slides (scrolls), the right edge is always "now".
  # Symmetric min/max bars around the center line, one-second grid,
  # brightness rising toward the live edge.
  private def draw_wave : Nil
    w = @wave.width
    h = @wave.height
    cy = h // 2
    @wave.fill_with(Egui::Color32.new(28, 30, 36))
    @wave.span(0, w - 1, cy, Egui::Color32.new(70, 74, 84))

    rate = 48_000
    window_frames = @wave_seconds * rate
    # Fixed scale: frames per bar never changes while recording grows.
    bucket = {(window_frames + w - 1) // w, 1}.max
    window_start = {@rec.size - window_frames, 0}.max
    tail = @rec.size - window_start
    return if tail == 0

    # One-second gridlines (skip the left edge).
    sec_step = {rate // bucket, 1}.max
    x = sec_step
    while x < w
      @wave.line(x, 1, x, h - 2, Egui::Color32.new(44, 47, 55))
      x += sec_step
    end

    half = cy - 3
    bars = {tail // bucket + (tail % bucket > 0 ? 1 : 0), w}.min
    bars.times do |bar|
      start = window_start + bar * bucket
      break if start >= @rec.size
      fin = {start + bucket, @rec.size}.min
      peak = 0.0f32
      (start...fin).each do |i|
        a = @rec[i].abs
        peak = a if a > peak
      end
      amp = (peak.clamp(0.0f32, 1.0f32) * half).to_i32!
      next if amp < 1
      g = 110 + bar * 130 // {bars, 1}.max # brighter toward live edge
      @wave.line(bar, cy - amp, bar, cy + amp,
        Egui::Color32.new((g // 4).to_u8!, g.to_u8!, (g // 3).to_u8!))
    end

    # Playback cursor: bright line at the echo voice's position (only
    # the part of the recording inside the visible window maps to x).
    if (pos = @play_pos)
      frame = (pos * rate).to_i64
      if frame >= window_start
        x = ((frame - window_start) // bucket).to_i32
        if x >= 0 && x < w
          @wave.line(x, 0, x, h - 1, Egui::Color32.new(250, 210, 120))
          @wave.line(x + 1, 0, x + 1, h - 1,
            Egui::Color32.new(250, 210, 120)) if x + 1 < w
        end
      end
    end
  end

  # Wrap the recorded PCM into a 16-bit WAV file image and decode it
  # back as a replay-cheap sample (the in-memory embedded-asset path —
  # no disk involved).
  private def make_echo : Nil
    return if @rec.empty?
    @echo = Egui::SystemPorts::Audio.sample(recording_wav)
    if @echo.nil?
      @status = "эхо: #{Egui::SystemPorts::Audio.last_error || "не собралось"}"
    end
  end

  private def recording_wav : Bytes
    le = IO::ByteFormat::LittleEndian
    rate = 48_000
    pcm16 = Bytes.new(@rec.size * 2)
    @rec.each_with_index do |s, i|
      le.encode((s.clamp(-1.0f32, 1.0f32) * 32767.0f32).to_i16!,
        pcm16[i * 2, 2])
    end
    wav = Bytes.new(44 + pcm16.size)
    "RIFF".each_char_with_index { |c, i| wav[i] = c.ord.to_u8 }
    le.encode((36 + pcm16.size).to_u32, wav[4, 4])
    "WAVE".each_char_with_index { |c, i| wav[8 + i] = c.ord.to_u8 }
    "fmt ".each_char_with_index { |c, i| wav[12 + i] = c.ord.to_u8 }
    le.encode(16u16, wav[16, 2]); le.encode(1u16, wav[20, 2])
    le.encode(1u16, wav[22, 2]) # mono
    le.encode(rate.to_u32!, wav[24, 4])
    le.encode((rate * 2).to_u32, wav[28, 4]); le.encode(2u16, wav[32, 2])
    le.encode(16u16, wav[34, 2])
    "data".each_char_with_index { |c, i| wav[36 + i] = c.ord.to_u8 }
    le.encode(pcm16.size.to_u32, wav[40, 4])
    wav[44, pcm16.size].copy_from(pcm16)
    wav
  end

end

Egui.run(AudioApp.new, title: "egui-cr — audio", inspector: :hidden)
