# Canvas2D fill_text through a REAL font stack — the crystalfonts_smoke
# pattern: instantiating an AtlasFonts subclass in a *_spec.cr would
# link the native lib into `crystal spec`, so the font-backed half of
# the Canvas2D surface lives here as a runnable smoke script.
#
# Run: crystal run spec/canvas2d_font_smoke.cr

require "../src/egui"
require "../src/egui/driver/crystalfonts"

SANS = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

unless File.exists?(SANS)
  puts "SKIP: DejaVu fonts not installed"
  exit 0
end

fonts = Egui::Driver::CrystalFonts.from_system([SANS])
unless fonts && fonts.not_nil!.loaded?
  puts "FAIL: CrystalFonts did not load #{SANS}"
  exit 1
end

SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(900.0, 700.0))
ctx = Egui::Context.new
ctx.fonts = fonts.not_nil!

FAILED = [] of String
def check(cond : Bool, what : String) : Nil
  puts "#{cond ? "ok  " : "FAIL"} #{what}"
  FAILED << what unless cond
end

canvas = Egui::Canvas2D.new("t", 160, 40)
canvas.fill_style = Egui::Color32.rgb(255, 0, 0)
canvas.font_size = 16.0

raw = Egui::RawInput.new(SCREEN, [] of Egui::Event, 0.016)
ctx.begin_frame(raw)
ctx.central_panel do |ui|
  ui.canvas2d(canvas) { } # binds ctx for measure_text
end
ctx.end_frame

w = canvas.measure_text("Hello").x
check(w > 20.0 && w < 80.0, "measure_text(\"Hello\") at 16px ≈ #{w.round(1)}px (20..80)")

canvas.text_baseline = :top
canvas.fill_text("Hello", 4.0, 4.0)
ctx.begin_frame(raw)
ctx.central_panel do |ui|
  ui.canvas2d(canvas) { }
end
ctx.end_frame

px = ctx.textures.pixels(canvas.texture_id)
raise "no texture" unless px
wpx, hpx, data = px
check(wpx == 160 && hpx == 40, "baked at canvas size #{wpx}x#{hpx}")

def px_at(data : Bytes, w : Int32, x : Int32, y : Int32) : Egui::Color32
  i = (y.to_i64 * w + x) * 4
  Egui::Color32.new(data[i], data[i + 1], data[i + 2], data[i + 3])
end

# scan the em band (top-anchored 16px text at y=4 → rows 4..22)
found = 0
red = 0
(4..22).each do |y|
  (4...4 + w.ceil.to_i + 4).each do |x|
    p = px_at(data, wpx, x, y)
    next if p.a == 0
    found += 1
    red += 1 if p.r > 100 && p.g < 100
  end
end
check(found > 20, "glyph pixels present (#{found})")
check(red == found, "glyph pixels are the fill color (#{red}/#{found})")
above = (0..2).any? { |y| (0...wpx).any? { |x| px_at(data, wpx, x, y).a > 0 } }
check(!above, "no pixels above the text band")
below = (30...40).any? { |y| (0...wpx).any? { |x| px_at(data, wpx, x, y).a > 0 } }
check(!below, "no pixels below the text band")

if FAILED.empty?
  puts "RESULT: PASS"
else
  puts "RESULT: FAIL (#{FAILED.size})"
  exit 1
end
