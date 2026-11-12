# Headless benchmark of the html gallery frame (the app from
# examples/html_gallery_components/html_gallery_app.cr) — the CPU part
# of a frame BEFORE any FFI/GPU work, same harness shape as
# bench/chat_bench.cr: Egui::Bench drives update()/end_frame, no
# sokol backend. 79 cards × 3 readonly code panels + the live demos.
#
#   crystal build --release bench/html_bench.cr -o bin/benchmarks/html_bench && ./bin/benchmarks/html_bench
#   SCROLL=1 ./bin/benchmarks/html_bench   # start scrolled to the middle

require "../src/egui"
require "../src/egui/driver/crystalfonts"
require "../examples/html_gallery_components/html_gallery_app"

WIDTH  = (ENV["BENCH_W"]? || "1100").to_f64
HEIGHT = (ENV["BENCH_H"]? || "800").to_f64

# Real font stack, like Sokol#on_init picks one — forced to the pure
# Crystal backend (what release ships): the headless monospace
# estimate would make measure() free and the bench would measure a
# different program than the one shipping.
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

app = HtmlGalleryApp.new
if (font = bench_font)
  app.ctx.fonts = font
else
  puts "fonts: NONE — headless monospace estimate (measure() unrealistic)"
end

# Scroll the gallery to its middle before the measured frames (the
# steady state of actually browsing the cards), then idle.
scrolled = ENV["SCROLL"]? == "1"

puts "html gallery bench: #{WIDTH}x#{HEIGHT}#{scrolled ? ", scrolled to middle" : ", at top"}"
Egui::Bench.run(app, width: WIDTH, height: HEIGHT, warmup: 5, frames: 30) do |d|
  if scrolled && d.index == 4
    40.times { d.scroll(0.0, -3.0) }
  end
end
