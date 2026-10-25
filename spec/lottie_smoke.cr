# Headless rlottie C smoke test: exercises the shim —
# backend/rlottie_shim.c through Egui::Backend::Rlottie::Animation —
# against the handcrafted assets/lottie/spinner.json (a rounded
# square rotating 360° over 60 frames @ 60 fps). Not part of
# `crystal spec` (it links the LOTTIE=1 archives, which a fresh clone
# may not have built); run:
#
#   LOTTIE=1 rake build:native
#   crystal run spec/lottie_smoke.cr --link-flags \
#     "-Llib -Llib/rlottie -legui_cr_sokol -legui_cr_rlottie -lrlottie -lc++ \
#      -framework Cocoa -framework OpenGL -framework QuartzCore \
#      -framework AVFoundation -framework CoreMedia -framework IOKit"
#
# (macOS frameworks: the stb glue inside librlottie.a pulls
# sokol_shim.o, whose camera section references them — same link set
# the Rakefile adds for every example.)
require "../src/egui"
require "../src/egui/backend/rlottie"

ASSET = File.read("#{__DIR__}/../assets/lottie/spinner.json")

def coverage(buf : Bytes) : Float64
  covered = buf.each_slice(4).count { |(_, _, _, a)| a > 8 }
  covered.to_f64 / (buf.size / 4)
end

# Number of differing RGBA bytes between two same-size renders.
def pixel_diff(a : Bytes, b : Bytes) : Int32
  a.zip(b).count { |(x, y)| x != y }
end

fails = 0

# 1. Metadata: viewport, frame count, fps.
anim = Egui::Backend::Rlottie::Animation.from_json(ASSET)
if anim.nil?
  puts "FAIL: rlottie rejected the asset"
  abort
end
if anim.width != 512 || anim.height != 512
  puts "FAIL: viewport #{anim.width}x#{anim.height}, want 512x512"
  fails += 1
end
if anim.frame_count != 60
  puts "FAIL: frame count #{anim.frame_count}, want 60"
  fails += 1
end
if anim.fps != 60.0
  puts "FAIL: fps #{anim.fps}, want 60"
  fails += 1
end
if (anim.duration - 1.0).abs > 1e-9
  puts "FAIL: duration #{anim.duration}, want 1.0"
  fails += 1
end

# 2. Frame 0 renders: sane coverage, un-premultiplied straight alpha
# (a==0 pixels must carry zeroed RGB — the premul contract).
W = 256
H = 256
f0 = Bytes.new(W * H * 4)
unless anim.render(0, f0, W, H)
  puts "FAIL: render(0) returned false"
  fails += 1
end
cov0 = coverage(f0)
if cov0 < 0.05 || cov0 > 0.5
  puts "FAIL: frame 0 coverage #{cov0.round(3)} out of band"
  fails += 1
end
f0.each_slice(4) do |(r, g, b, a)|
  if a.zero? && (r != 0 || g != 0 || b != 0)
    puts "FAIL: a=0 pixel with nonzero RGB (premul not un-done)"
    fails += 1
    break
  end
end

# 3. Rotation shows: frame 10 (60°) differs from frame 0 pixel-wise.
# (Not frame 30 — a square at 180° is pixel-identical to 0°.)
f10 = Bytes.new(W * H * 4)
anim.render(10, f10, W, H)
if pixel_diff(f0, f10) < W * H / 10
  puts "FAIL: frames 0 and 10 nearly identical (rotation not rendering?)"
  fails += 1
end

# 4. Determinism: re-render of frame 0 is byte-identical.
f0b = Bytes.new(W * H * 4)
anim.render(0, f0b, W, H)
if pixel_diff(f0, f0b) != 0
  puts "FAIL: re-render of frame 0 differs"
  fails += 1
end

# 5. Memoization: same source parses to the same instance.
if !Egui::Backend::Rlottie::Animation.from_json(ASSET).same?(anim)
  puts "FAIL: from_json not memoized"
  fails += 1
end

if fails.zero?
  puts "lottie_smoke: OK (cov0=#{cov0.round(3)}, diff10=#{pixel_diff(f0, f10)})"
else
  abort "lottie_smoke: #{fails} failure(s)"
end
