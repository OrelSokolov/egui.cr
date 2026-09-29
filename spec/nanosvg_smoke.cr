# Headless NanoSVG smoke test: exercises the REAL C path —
# backend/nanosvg_shim.c through Egui::Backend::NanoSvg.rasterize —
# against lucide-style strokes, polygon fills, gradients and
# currentColor tinting. Not part of `crystal spec` (it links the
# native archive, which a fresh clone may not have built); run:
#
#   rake build:native
#   crystal run spec/nanosvg_smoke.cr --link-flags "-Llib"
require "../src/egui"
require "../src/egui/backend/nanosvg"

def px(buf : Bytes, w : Int32, x : Int32, y : Int32) : UInt8
  buf[(y * w + x) * 4 + 3]
end

def coverage(buf : Bytes) : Float64
  covered = buf.each_slice(4).count { |(_, _, _, a)| a > 8 }
  covered.to_f64 / (buf.size / 4)
end

fails = 0

# 1. Lucide-style stroked path (root-inherited paint, currentColor).
src = %(<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2z"/></svg>)
buf = Egui::Backend::NanoSvg.rasterize(src, Egui::Color32.rgb(200, 30, 30), 48, 48)
if buf.nil? || coverage(buf.not_nil!) < 0.1 || coverage(buf.not_nil!) > 0.6
  puts "FAIL: lucide stroke coverage out of band: #{buf && coverage(buf.not_nil!)}"
  fails += 1
else
  # the tint rode through currentColor
  i = (0...buf.not_nil!.size // 4).index { |p| buf.not_nil![p * 4 + 3] == 255 } || 0
  r = buf.not_nil![i * 4]
  puts "lucide stroke: coverage=#{coverage(buf.not_nil!).round(3)} r@opaque=#{r}"
  if r != 200
    puts "FAIL: currentColor tint not applied (r=#{r}, want 200)"
    fails += 1
  end
end

# 2. Filled polygon — the real fill the built-in fallback cannot do
# (it degrades to a stroked outline, leaving the interior empty).
tri = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><polygon points="10,90 90,90 50,10" fill="#00AA00"/></svg>)
buf = Egui::Backend::NanoSvg.rasterize(tri, Egui::Color32.rgb(0, 0, 0), 100, 100).not_nil!
if px(buf, 100, 50, 60) != 255
  puts "FAIL: polygon interior not filled (alpha=#{px(buf, 100, 50, 60)})"
  fails += 1
else
  puts "polygon fill: interior alpha=#{px(buf, 100, 50, 60)} g=#{buf[(60 * 100 + 50) * 4 + 1]}"
end

# 3. Vertical gradient across a rect (top stop ≠ bottom stop).
grad = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#0000FF"/></linearGradient></defs><rect x="0" y="0" width="10" height="10" fill="url(#g)"/></svg>)
buf = Egui::Backend::NanoSvg.rasterize(grad, Egui::Color32.rgb(0, 0, 0), 20, 20).not_nil!
top = buf[(2 * 20 + 10) * 4, 4]      # near-white
bottom = buf[(17 * 20 + 10) * 4, 4]  # blue
puts "gradient: top=#{top.map(&.to_s(16).rjust(2, '0')).join} bottom=#{bottom.map(&.to_s(16).rjust(2, '0')).join}"
if top[0] < 200 || bottom[0] > 60 || bottom[2] < 200
  puts "FAIL: gradient orientation/colors wrong"
  fails += 1
end

# 4. Unparseable source → nil (the built-in fallback takes over).
if Egui::Backend::NanoSvg.rasterize("this is not svg at all", Egui::Color32.rgb(0, 0, 0), 8, 8) != nil
  puts "FAIL: garbage source should return nil"
  fails += 1
end

# 5. The real asset bakes clean.
if File.exists?("assets/icon.svg")
  buf = Egui::Backend::NanoSvg.rasterize(File.read("assets/icon.svg"),
    Egui::Color32.rgb(0, 0, 0), 128, 128).not_nil!
  puts "assets/icon.svg: coverage=#{coverage(buf).round(3)}"
end

if fails.zero?
  puts "nanosvg smoke: OK"
else
  puts "nanosvg smoke: #{fails} failure(s)"
  exit 1
end
