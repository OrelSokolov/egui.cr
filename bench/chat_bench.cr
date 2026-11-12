# Headless benchmark of the chat's two-zone frame (the app from
# examples/chat_components/chat_app.cr) with a 100k-entry LOG — the
# CPU part of a frame BEFORE any FFI/GPU work, same harness shape as
# bench/lucide_bench.cr: Egui::Bench drives update()/end_frame, no
# sokol backend.
#
#   crystal build bench/chat_bench.cr -o bin/benchmarks/chat_bench && ./bin/benchmarks/chat_bench
#   N=1000000 ./bin/benchmarks/chat_bench    # a million-entry log
#
# Scenarios (each a fresh app, same seeded log):
#   idle    — nothing moves; the log is pinned to the bottom (the
#             steady state of reading a finished session).
#   stream  — a live reply streams into the active zone word by word
#             and finalizes into the log every 25 frames (live agent
#             output over a huge history).
#   scroll  — three wheel notches per frame over the log (reading
#             back through the history, kinetic scroll active).
#   resize  — the log's wrap width swings ±40 px every frame: every
#             frame pays the synchronous whole-log rewrap that keeps
#             the scrollbar honest (the greedy counter, not a full
#             Fonts#layout pass).

require "../src/egui"
require "../src/egui/driver/crystalfonts"
require "../examples/chat_components/chat_app"

N = (ENV["N"]? || "100000").to_i
WIDTH  = (ENV["BENCH_W"]? || "1920").to_f64
HEIGHT = (ENV["BENCH_H"]? || "1080").to_f64

# The bench face of the app: seeding + the streaming scenario pokes.
# (Crystal private methods stay callable in subclasses.)
class BenchChatApp < ChatApp
  STREAM_TEXT = "Стриминговый ответ гонится по словам в активную зону " \
                "поверх стотысячного лога, проверяя что кадр не деградирует."

  # Fill the LOG with a realistic role mix (the same append path the
  # live app uses — stick-to-bottom included).
  def seed(entries : Int32) : Nil
    entries.times do |i|
      role = case i % 7
             when 0 then :user
             when 1 then :assistant
             when 2 then :tool_run
             when 3 then :tool_result
             when 4 then :think
             when 5 then :ci
             else        :user
             end
      text = case role
             when :user
               "добавь поле поиска в таблицу и почини валидацию формы ##{i}"
             when :assistant
               "Готово: индекс перестроен, тесты зелёные, счётчик ##{i}"
             when :tool_run
               "Выполнена команда: bash — crystal spec spec/chat_spec.cr ##{i}"
             when :tool_result
               "→ 24 examples, 0 failures, 1.2s ##{i}"
             when :think
               "Обдумано · 0.9 с ##{i}"
             else
               "CI passed ✓ · 2.5 с ##{i}"
             end
      append(role, text)
    end
  end

  # The live-reply scenario: word `words` of the stream this frame.
  def stream_tick(words : Int32) : Nil
    zone = (@zones["bench/stream"] ||= Zone.new(:stream, ""))
    zone.text = STREAM_TEXT.split(' ')[0, words].join(' ')
    ctx.request_repaint
  end

  def stream_release : Nil
    return unless (zone = @zones.delete("bench/stream"))
    append(:assistant, zone.text) # the release invariant: into the log
  end
end

# Real font stack, like Sokol#on_init picks one — forced to the pure
# Crystal backend (what release ships): the headless monospace
# estimate would make measure() free and the bench would measure a
# different program than the one shipping. The chat's own mono stack:
# DejaVu Sans Mono + the Symbols2 braille fallback.
def bench_font : Egui::Driver::CrystalFonts?
  paths = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf",
  ].select { |p| File.exists?(p) }
  return nil if paths.empty?
  Egui::Driver::CrystalFonts.from_system(paths)
end

def bench(label : String, frames : Int32, &scenario : Egui::Bench::FrameDriver ->) : Nil
  app = BenchChatApp.new
  app.seed(N)
  if (font = bench_font)
    app.ctx.fonts = font
  else
    puts "fonts: NONE — headless monospace estimate (measure() unrealistic)"
  end
  puts "-- #{label}: #{app.log.size} log entries, active zone " \
       "#{label == "stream" ? "streaming" : "empty"}"
  Egui::Bench.run(app, width: WIDTH, height: HEIGHT, warmup: 5,
    frames: frames) { |d| scenario.call(d) }
  puts
end

puts "chat two-zone bench: N=#{N} (set N=… to resize the log)"
puts

bench("idle", 30) { |_d| }

bench("stream", 50) do |d|
  ph = d.index % 25
  d.app.as(BenchChatApp).stream_release if ph == 0 && d.index > 0
  d.app.as(BenchChatApp).stream_tick(ph + 1)
end

bench("scroll", 30) do |d|
  d.scroll(0.0, -3.0) # wheel notches, reading back
end

bench("resize", 30) do |d|
  # Simulate dragging the window edge: the log's wrap width swings
  # ±40 px, so every frame re-wraps the whole 100k geometry.
  app = d.app.as(BenchChatApp)
  app.forced_wrap_width = 1500.0 + (d.index.even? ? 40.0 : -40.0)
end
