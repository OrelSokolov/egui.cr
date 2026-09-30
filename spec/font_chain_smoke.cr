# The CrystalFonts fallback chain, as a runnable smoke script (the
# crystalfonts_smoke.cr pattern — instantiating an AtlasFonts subclass
# in a *_spec.cr would drag the C-shim LightHintedFonts into the
# virtual Fonts dispatch and link the native lib into `crystal spec`).
#
# Run: crystal run spec/font_chain_smoke.cr

require "../src/egui"
require "../src/egui/backend/crystalfonts"

SANS = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
MONO = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"

FAILED = [] of String
def check(cond : Bool, what : String) : Nil
  FAILED << what unless cond
end

unless File.exists?(SANS) && File.exists?(MONO)
  puts "SKIP: DejaVu fonts not installed"
  exit 0
end

fonts = Egui::Backend::CrystalFonts.from_system([SANS, MONO, "/nonexistent.ttf"])
check(!fonts.nil? && fonts.not_nil!.loaded?, "chain loads (missing files skipped)")

if fonts
  stride = Egui::Backend::CrystalFonts::STRIDE

  m = fonts.glyph_index('M'.ord)
  check(m > 0 && m < stride, "Latin resolves in the primary face (gid #{m})")

  star = fonts.glyph_index('★'.ord)
  check(star > 0, "★ resolves somewhere in the chain")

  check(fonts.glyph_index('中'.ord) == 0,
    "a codepoint missing everywhere is notdef")

  g = fonts.glyph(star, 16.0)
  check(g.w > 0 && g.h > 0, "a fallback glyph bakes into the atlas")

  single = Egui::Backend::CrystalFonts.from_system([SANS]).not_nil!
  check(fonts.metrics_at(14.0) == single.metrics_at(14.0),
    "metrics come from the primary face")
  check(fonts.measure("hello", 14.0) == single.measure("hello", 14.0),
    "primary-face text measures identically to a single-font load")

  check(fonts.kern_px(stride + m, m, 16.0) == 0.0,
    "cross-face pairs never kern")
end

puts FAILED.empty? ? "OK: font fallback chain" : "#{FAILED.size} failure(s)"
exit FAILED.empty? ? 0 : 1
