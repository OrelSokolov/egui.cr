# Headless benchmark of the Raven Music exml frame (the app from
# examples/music_components/music_app.cr, what bin/clones/music_exml
# runs) — the CPU part of a frame BEFORE any FFI/GPU work:
#
#   crystal build bench/music_bench.cr -o bin/benchmarks/music_bench && ./bin/benchmarks/music_bench
#   MUSIC_PAGE=album   ./bin/benchmarks/music_bench
#   MUSIC_PAGE=library ./bin/benchmarks/music_bench

require "../src/egui"
require "../src/egui/driver/crystalfonts"
require "../examples/music_components/music_app"

WIDTH  = (ENV["BENCH_W"]? || "1360").to_f64
HEIGHT = (ENV["BENCH_H"]? || "860").to_f64

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

app = MusicExmlApp.new
if (font = bench_font)
  app.ctx.fonts = font
else
  puts "fonts: NONE — headless monospace estimate (measure() unrealistic)"
end

page = ENV["MUSIC_PAGE"]? || "home"
puts "music exml bench: #{WIDTH}x#{HEIGHT} page=#{page}"
frames = (ENV["FRAMES"]? || "30").to_i
Egui::Bench.run(app, width: WIDTH, height: HEIGHT, warmup: 5, frames: frames)
