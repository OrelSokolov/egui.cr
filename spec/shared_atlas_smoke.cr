# The registry-shared glyph atlas (sokol.cr's font-selector fix), as a
# runnable smoke script: several stacks baking into ONE GlyphAtlas, the
# epoch invalidation on a foreign reset, and the per-stack overflow
# flags. Runnable script, not a *_spec.cr, for the same reason as
# font_chain_smoke.cr — instantiating an AtlasFonts subclass would pull
# the C-shim LightHintedFonts into the virtual Fonts dispatch.
#
# Run: crystal run spec/shared_atlas_smoke.cr

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

atlas = Egui::Backend::GlyphAtlas.new(Egui::Backend::ATLAS_SIZE)
a = Egui::Backend::CrystalFonts.from_system([SANS], atlas).not_nil!
b = Egui::Backend::CrystalFonts.from_system([MONO], atlas).not_nil!
own = Egui::Backend::CrystalFonts.from_system([MONO]).not_nil!

check(a.atlas.same?(atlas) && b.atlas.same?(atlas), "stacks share the given atlas")
check(!own.atlas.same?(atlas), "a nil atlas means a private one")

# Bake the same text through both shared stacks: distinct slots, real
# coverage in both.
ga = a.glyph(a.glyph_index('A'.ord), 16.0)
gb = b.glyph(b.glyph_index('A'.ord), 16.0)
check(ga.w > 0 && gb.w > 0, "glyphs of both stacks bake")
check(a.atlas_view_id == b.atlas_view_id, "shared atlas = one view id")

# A foreign reset (what sokol.cr's registry does when ANY stack
# overflows): the epoch bump must invalidate the OTHER stack's cache —
# its stale UVs point at wiped slots — while a private-atlas stack is
# unaffected.
atlas.reset
g2 = b.glyph(b.glyph_index('A'.ord), 16.0)
check(g2.ax != gb.ax || g2.ay != gb.ay || g2.u0 != gb.u0,
  "a foreign reset re-bakes the neighbour's cached glyph")
cov = b.glyph_coverage(g2).not_nil!
check(cov.any?(&.>(128)), "the re-baked glyph has real coverage (not a stale blank read)")
check(b.glyph(b.glyph_index('B'.ord), 16.0).w > 0,
  "baking continues on the fresh shelves after a reset")

g_own_before = own.glyph(own.glyph_index('A'.ord), 16.0)
atlas.reset # a second foreign reset must not disturb the private atlas
g_own_after = own.glyph(own.glyph_index('A'.ord), 16.0)
check(g_own_after.ax == g_own_before.ax && g_own_after.ay == g_own_before.ay,
  "a private-atlas stack ignores foreign resets")

# Overflow flags: alloc_glyph flags the stack; the registry polls
# needs_reset?, resets, then acknowledges via clear_overflow_flag (the
# shared path) — reset_if_full stays the private-atlas path. Fill the
# atlas for real: a wide charset across fractional sizes (the
# atlas_fill_dbg recipe — each 0.1px step bakes a fresh glyph set).
check(!a.needs_reset?, "a fresh stack is not flagged")
charset = "ИнспекторстилейПравыйкликполюбомувиджетуInspectF12панель" \
          "КнопкиСохранитьОтменаБезслучайныхбуквПрочееeguiinspiration" \
          "ЧекбоксСкоростьПрогрессВыбранныйпунктТумблерЭлементКласс0123456789"
size = 9.0
while size <= 40.0 && !a.needs_reset?
  a.walk(charset, size) { |_p, _g| }
  size += 0.1
end
check(a.needs_reset?, "exhausting the shared atlas flags the stack")
b.walk("hello", 16.0) { |_p, _g| } # neighbour bakes through the full atlas
atlas.reset
a.clear_overflow_flag
b.clear_overflow_flag
check(!a.needs_reset? && !b.needs_reset?, "clear_overflow_flag acknowledges")
blanks = 0
a.walk(charset, 12.0) { |_p, g| blanks += 1 if g.w == 0 }
b.walk("hello", 16.0) { |_p, g| blanks += 1 if g.w == 0 }
check(blanks.zero?, "every glyph re-bakes after the registry-style reset")

# The private-atlas reset path (specs / standalone stacks) is unchanged.
own.walk(charset, 16.0) { |_p, _g| }
own.reset_if_full
blanks = 0
own.walk(charset, 16.0) { |_p, g| blanks += 1 if g.w == 0 }
check(blanks.zero?, "reset_if_full recovers a private atlas")

puts FAILED.empty? ? "OK: shared glyph atlas" : "#{FAILED.size} failure(s)"
exit FAILED.empty? ? 0 : 1
