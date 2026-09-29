# Headless parity spec: CrystalFonts (the freetype-cr port backend) vs
# FreetypeFonts (the system libfreetype FFI) — glyph indices, kerning,
# metrics, measured widths and the actual atlas coverage of baked glyphs
# must be identical, per size and per char. This is the integration-side
# twin of freetype.cr's own acceptance runs.
#
# Run: crystal run --release spec/crystalfonts_smoke.cr [-- <font.ttf> ...]

require "../src/egui"
require "../src/egui/backend/freetype"
require "../src/egui/backend/crystalfonts"

paths = ARGV.empty? ? Egui::SystemPorts::Fonts.search_paths : ARGV

ft = Egui::Backend::FreetypeFonts.from_system(paths)
mine = Egui::Backend::CrystalFonts.from_system(paths)
unless ft && mine
  puts "FAIL: backends did not load (ft=#{!!ft} mine=#{!!mine})"
  exit 1
end

failures = 0

# 1. metrics: identical line boxes, or widget layout shifts between tabs.
{10.0, 12.0, 13.0, 14.0, 16.0, 20.0, 24.0, 37.0}.each do |size|
  a1, d1 = ft.metrics_at(size)
  a2, d2 = mine.metrics_at(size)
  if a1 != a2 || d1 != d2
    failures += 1
    puts "METRICS size=#{size}: ft=#{a1}/#{d1} mine=#{a2}/#{d2}"
  end
end

# 2. glyph indices for the alphabets the preview and the UI use.
CHARS = ("ABCDEFGHIJKLMNOPQRSTUVWXYZ" \
         "abcdefghijklmnopqrstuvwxyz" \
         "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ" \
         "абвгдеёжзийклмнопрстуфхцчшщъыьэюя" \
         "0123456789.,:;!?—–-()[]{}«»\"'…").chars
gids = CHARS.map { |c| {c, ft.glyph_index(c.ord)} }
gids.each do |c, gid|
  m = mine.glyph_index(c.ord)
  next if gid == m
  failures += 1
  puts "GLYPH_ID #{c.inspect}: ft=#{gid} mine=#{m}"
end

# 3. per-size: kerning, advances/measured widths, bitmap coverage.
{12.0, 14.0, 16.0, 24.0, 37.0}.each do |size|
  # kerning between consecutive glyph pairs of the sample text
  text = "TAVa Woff Type Hut 0123 — Тест"
  prev = 0
  text.each_char do |ch|
    gid = mine.glyph_index(ch.ord)
    if prev > 0
      k1 = ft.kern_px(prev, gid, size)
      k2 = mine.kern_px(prev, gid, size)
      if k1 != k2
        failures += 1
        puts "KERN size=#{size} #{prev},#{gid} (#{ch.inspect}): ft=#{k1} mine=#{k2}"
      end
    end
    prev = gid
  end

  w1 = ft.measure(text, size).x
  w2 = mine.measure(text, size).x
  if w1 != w2
    failures += 1
    puts "MEASURE size=#{size}: ft=#{w1.round(3)} mine=#{w2.round(3)}"
  end

  # bitmap identity: same atlas region bytes for the same glyph
  gids.each do |c, _|
    g1 = ft.glyph(ft.glyph_index(c.ord), size)
    g2 = mine.glyph(mine.glyph_index(c.ord), size)
    same = g1.w == g2.w && g1.h == g2.h && g1.ytop == g2.ytop &&
           g1.xoff == g2.xoff && g1.advance == g2.advance
    if same && g1.w > 0
      b1 = ft.glyph_coverage(g1)
      b2 = mine.glyph_coverage(g2)
      same = b1 == b2
    end
    unless same
      failures += 1
      puts "GLYPH size=#{size} #{c.inspect}: ft=#{g1.w}x#{g1.h}+#{g1.xoff}+#{g1.ytop} " \
           "adv=#{g1.advance} mine=#{g2.w}x#{g2.h}+#{g2.xoff}+#{g2.ytop} adv=#{g2.advance}"
    end
  end
end

if failures.zero?
  puts "RESULT: PASS (CrystalFonts == FreetypeFonts)"
else
  puts "RESULT: FAIL (#{failures} diffs)"
end
exit(failures.zero? ? 0 : 1)
