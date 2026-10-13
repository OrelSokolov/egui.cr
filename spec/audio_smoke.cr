# Real-device audio smoke test: exercises the full port stack through
# backend/audio.cr (AudioRunner + MicRunner over MinAudio) with a
# generated WAV — engine, sample, stream, bus, mic ring. Not in CI (a
# device may be absent); run manually:
#
#   crystal run spec/audio_smoke.cr --link-flags \
#     "-Llib -Llib/minaudio/lib -framework Cocoa -framework OpenGL \
#      -framework QuartzCore -framework AVFoundation -framework \
#      CoreMedia -framework IOKit"
require "../src/egui"
require "../src/egui/backend/audio"

A = Egui::SystemPorts::Audio
M = Egui::SystemPorts::Microphone

class Smoke
  @@failures = 0

  def self.failures : Int32
    @@failures
  end

  def self.check(cond : Bool, what : String) : Nil
    puts(cond ? "  ok  #{what}" : "  FAIL #{what}")
    @@failures += 1 unless cond
  end
end

# A 0.5s decaying 440 Hz blip, 16-bit mono WAV.
le = IO::ByteFormat::LittleEndian
rate = 44_100
frames = rate // 2
wav = Bytes.new(44 + frames * 2)
"RIFF".each_char_with_index { |c, i| wav[i] = c.ord.to_u8 }
le.encode((36 + frames * 2).to_u32, wav[4, 4])
"WAVE".each_char_with_index { |c, i| wav[8 + i] = c.ord.to_u8 }
"fmt ".each_char_with_index { |c, i| wav[12 + i] = c.ord.to_u8 }
le.encode(16u16, wav[16, 2]); le.encode(1u16, wav[20, 2])
le.encode(1u16, wav[22, 2]); le.encode(rate.to_u32!, wav[24, 4])
le.encode((rate * 2).to_u32, wav[28, 4]); le.encode(2u16, wav[32, 2])
le.encode(16u16, wav[34, 2])
"data".each_char_with_index { |c, i| wav[36 + i] = c.ord.to_u8 }
le.encode((frames * 2).to_u32, wav[40, 4])
frames.times do |f|
  t = f.to_f64 / rate
  le.encode((Math.sin(t * 440 * 2 * Math::PI) * 12000 * (1.0 - t * 2)).to_i16!,
    wav[44 + f * 2, 2])
end
path = File.join(Dir.tempdir, "egui_audio_smoke.wav")
File.write(path, wav)

puts "-- port surface --"
Smoke.check(A.supported?, "audio runner installed")
Smoke.check(M.supported?, "mic runner installed")

puts "-- samples --"
sample = A.sample(path)
Smoke.check(!sample.nil?, "sample from file")
embedded = A.sample(wav)
Smoke.check(!embedded.nil?, "sample from bytes")
if (s = sample)
  voice = s.play(volume: 0.8f32, bus: "sfx")
  Smoke.check(!voice.nil?, "sample replay")
  Smoke.check(voice.not_nil!.playing?, "replay playing")
end

puts "-- stream --"
music = A.play_stream(path, volume: 0.5f32, loop: true, bus: "music")
Smoke.check(!music.nil?, "stream started")
if (m = music)
  sleep 100.milliseconds
  Smoke.check(m.playing?, "stream playing")
  Smoke.check(m.cursor > 0.0f32, "cursor advanced (#{m.cursor.round(2)}s)")
  Smoke.check(m.length > 0.0f32, "length known (#{m.length.round(2)}s)")
  m.volume = 0.3f32
  m.fade_out_and_stop(150)
end

puts "-- buses/master --"
A.bus("sfx").volume = 0.5f32
A.master_volume = 0.8f32
A.pause_all
A.resume_all
Smoke.check(true, "bus/master calls did not raise")

puts "-- microphone --"
mic = M.open
if mic
  buf = Bytes.new(4800 * 4)
  slept = 0
  while mic.available_frames == 0 && slept < 30
    sleep 100.milliseconds
    slept += 1
  end
  got = mic.read(buf)
  Smoke.check(got > 0, "mic delivered frames (#{got})")
  mic.close
  Smoke.check(mic.read(buf) == 0, "dead handle reads 0")
else
  puts "  (mic refused: #{M.last_error} — permission or no device)"
end

sleep 300.milliseconds
A.stop_all
puts Smoke.failures.zero? ? "SMOKE OK" : "SMOKE FAILURES: #{Smoke.failures}"
exit(Smoke.failures.zero? ? 0 : 1)
