# egui-cr device-API demo — the "PWA batteries": Audio (minaudio
# shard), Haptics, Share, WakeLock, Badge. One panel per port; the
# buttons work everywhere, they just degrade honestly (the labels show
# what the current platform actually supports — see the port files).
#
# The demo sound is generated at startup (a soft chime), so no binary
# assets ship with the example.

require "../src/egui/backend_selector"
require "../src/egui/backend/audio"

class DeviceApiApp < Egui::App
  # On Android write into the app's cache dir through the sysport —
  # TMPDIR is not guaranteed to be set in app processes on all vendor
  # builds (a failed write here used to read as "аудио недоступно").
  @wav_path : String = File.join(chime_dir, "egui_device_api_chime.wav")
  # v2 surface: a decoded-once sample (clicks) and the mic level meter.
  @chime_sample : Egui::SystemPorts::Audio::Sample?
  @mic : Egui::SystemPorts::Microphone::Mic?
  @mic_buf = Bytes.new(4800 * 4) # 100 ms of mono f32 @ 48 kHz
  @mic_level = 0.0f32
  @badge : Int32 = 3
  @wake : Bool = false
  @status : String = ""

  def self.chime_dir : String
    {% if flag?(:android) %}
      Egui::SystemPorts::Android.dir(Egui::SystemPorts::Android::DIR_CACHE) ||
        Dir.tempdir
    {% else %}
      Dir.tempdir
    {% end %}
  rescue
    "."
  end

  def initialize
    super
    # A failure here (vendor build without a usable temp dir) must not
    # kill the app at boot — the audio button just reports "недоступно".
    begin
      write_chime
    rescue ex
      @wav_path = ""
      puts "[device_api] chime write failed: #{ex.message}"
    end
    # Decode the chime once for the replay-cheap sample path.
    @chime_sample = @wav_path.empty? ? nil :
      Egui::SystemPorts::Audio.sample(@wav_path)
  end

  # A little two-tone chime (16-bit PCM WAV, 44.1 kHz).
  def write_chime : Nil
    rate = 44_100
    frames = rate * 3 // 2
    le = IO::ByteFormat::LittleEndian
    wav = Bytes.new(44 + frames * 2)
    "RIFF".each_char_with_index { |c, i| wav[i] = c.ord.to_u8 }
    le.encode((36 + frames * 2).to_u32, wav[4, 4])
    "WAVE".each_char_with_index { |c, i| wav[8 + i] = c.ord.to_u8 }
    "fmt ".each_char_with_index { |c, i| wav[12 + i] = c.ord.to_u8 }
    le.encode(16u16, wav[16, 2]); le.encode(1u16, wav[20, 2])
    le.encode(1u16, wav[22, 2]); le.encode(rate.to_u32!, wav[24, 4])
    le.encode((rate * 2).to_u32!, wav[28, 4]); le.encode(2u16, wav[32, 2])
    le.encode(16u16, wav[34, 2])
    "data".each_char_with_index { |c, i| wav[36 + i] = c.ord.to_u8 }
    le.encode((frames * 2).to_u32, wav[40, 4])
    gmax = 0.0
    frames.times do |f|
      # Seconds, not frame index: sin(t_int * freq * 2π) with integer
      # t_int and integer freq is always sin of a whole number of
      # cycles — i.e. digital silence. That bug shipped the chime as
      # near-zero PCM on every platform ("play() true but silent").
      t = f.to_f64 / rate
      # 660 Hz for 0.6 s, then 880 Hz; fading tail, no hard click.
      freq = t < 0.6 ? 660.0 : 880.0
      # ~43% full scale: the old 18% was near-inaudible through phone
      # speakers ("звук играет, но звука нету").
      amp = 14000 * (1.0 - t / (frames.to_f64 / rate))
      s = Math.sin(t * freq * 2 * Math::PI) * amp
      gmax = s.abs if s.abs > gmax
      le.encode(s.to_i16!, wav[44 + f * 2, 2])
    end
    File.write(@wav_path, wav)
    # On-device self-check: generation-side amplitude AND a binary
    # reread (String#read would mangle PCM through UTF-8 replacement).
    # "playing but inaudible" with an active mixer track means zero
    # PCM — this pins the culprit in two log lines.
    puts "[device_api] chime gen: max=#{gmax.round.to_i} " \
         "sin(1)=#{Math.sin(1.0).round(4)} PI=#{Math::PI.round(4)}"
    reread = Bytes.new(wav.size)
    File.open(@wav_path) { |fh| fh.read(reread) }
    max = 0
    nonzero = 0
    (44...reread.size - 1).step(2) do |i|
      v = (reread[i].to_i32 | (reread[i + 1].to_i32 << 8)).to_i16!
      a = v.abs
      max = a if a > max
      nonzero += 1 unless v.zero?
    end
    puts "[device_api] chime verify: bytes=#{reread.size} " \
         "max_amp=#{max} nonzero=#{nonzero}/#{(reread.size - 44) // 2}"
  end

  def update(ctx : Egui::Context) : Nil
    ctx.window("Device API", Egui::Pos2.new(40.0, 40.0), width: 460.0) do |ui|
      ui.heading("PWA-батарейки")
      ui.label(@status) unless @status.empty?

      ui.separator
      ui.label("Audio — #{Egui::SystemPorts::Audio.supported? ? "minaudio" : "нет"}")
      if ui.button("Играть звук").clicked?
        ok = !@wav_path.empty? && Egui::SystemPorts::Audio.play(@wav_path)
        puts "[device_api] audio play: #{ok}"
        @status = ok ? "звук играет" :
          "аудио: #{Egui::SystemPorts::Audio.last_error || "недоступно"}"
      end
      if ui.button("Клик сэмплом (decode once)").clicked?
        if (s = @chime_sample)
          ok = !s.play(volume: 0.8f32, bus: "ui").nil?
        else
          ok = false
        end
        puts "[device_api] sample play: #{ok}"
        @status = ok ? "сэмпл играет" :
          "сэмпл: #{Egui::SystemPorts::Audio.last_error || "не загрузился"}"
      end
      if ui.button("Стоп все звуки").clicked?
        Egui::SystemPorts::Audio.stop_all
        puts "[device_api] audio stop_all"
        @status = "звуки остановлены"
      end

      ui.separator
      ui.label("Микрофон — #{Egui::SystemPorts::Microphone.supported? ? "pull-модель" : "нет"}")
      mic = @mic
      if mic.nil?
        if ui.button("Открыть микрофон").clicked?
          @mic = Egui::SystemPorts::Microphone.open
          @status = @mic ? "микрофон открыт" :
            "микрофон: #{Egui::SystemPorts::Microphone.last_error || "отказ"}"
        end
      else
        # Pull every frame; RMS over the fresh chunk feeds the meter.
        got = mic.read(@mic_buf)
        if got > 0
          sum = 0.0f32
          ptr = @mic_buf.to_unsafe.as(Float32*)
          got.times { |i| v = ptr[i]; sum += v * v }
          @mic_level = Math.sqrt(sum / got)
        end
        ui.label("уровень (RMS): #{@mic_level.round(4)}")
        if ui.button("Закрыть микрофон").clicked?
          mic.close
          @mic = nil
          @mic_level = 0.0f32
          @status = "микрофон закрыт"
        end
      end

      ui.separator
      ui.label("Haptics — #{Egui::SystemPorts::Haptics.supported? ? "да" : "no-op на десктопе"}")
      ui.horizontal do |h|
        %w(лёгкий средний тяжёлый).each_with_index do |name, i|
          if h.button(name).clicked?
            puts "[device_api] haptic tap #{i}"
            Egui::SystemPorts::Haptics.tap(i)
          end
        end
      end

      ui.separator
      ui.label("Share")
      if ui.button("Поделиться текстом").clicked?
        ok = Egui::SystemPorts::Share.text(
          "egui-cr demo", "Смотри, что умеет egui.cr!")
        puts "[device_api] share: #{ok}"
        @status = ok ? "отправлено (буфер обмена на десктопе)" : "не вышло"
      end

      ui.separator
      if ui.checkbox(@wake, "Не гасить экран (WakeLock)").changed?
        @wake = !@wake
        if @wake
          ok = Egui::SystemPorts::WakeLock.acquire("demo")
          puts "[device_api] wakelock acquire: #{ok}"
          @status = "wakelock: #{ok}"
        else
          Egui::SystemPorts::WakeLock.release
          puts "[device_api] wakelock release"
          @status = "wakelock снят"
        end
      end

      ui.separator
      ui.label("Badge — #{Egui::SystemPorts::Badge.supported? ? "dock/иконка" : "нет на этой платформе"}")
      ui.horizontal do |h|
        if h.button("Badge: #{@badge}").clicked?
          ok = Egui::SystemPorts::Badge.set(@badge)
          puts "[device_api] badge set #{@badge}: #{ok}"
          @status = "badge установлен"
        end
        if h.button("+1").clicked?
          @badge += 1
          puts "[device_api] badge +1: #{Egui::SystemPorts::Badge.set(@badge)}"
        end
        if h.button("Снять").clicked?
          @badge = 0
          Egui::SystemPorts::Badge.clear
          puts "[device_api] badge clear"
        end
      end
    end
  end
end

Egui.run(DeviceApiApp.new, title: "egui-cr — device API",
  inspector: :hidden)
