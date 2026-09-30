# Text-on-canvas rasterizer for the Paint demo: loads the default font
# backend (the same chain Sokol#fonts_from_system picks — CrystalFonts,
# the pure-Crystal freetype-cr port, by default; the C-FFI FreeType
# when C_EXTENSIONS is on) and blends hinted 8-bit coverage glyphs
# straight into an Egui::Canvas pixel buffer — the same rendering path
# the UI's own text uses (same atlas bake, same contrast curve), so
# what you preview is what gets committed. Works in every build mode.

class PaintText
  @fonts : Egui::Backend::AtlasFonts?

  def initialize
    @fonts = Egui::Backend::Sokol.fonts_from_system(
      Egui::SystemPorts::Fonts.search_paths)
  end

  def loaded? : Bool
    !!@fonts.try(&.loaded?)
  end

  # Draw `text` with its TOP-LEFT at (x, y) in canvas pixels.
  def draw(canvas : Egui::Canvas, x : Int32, y : Int32, text : String,
           size : Int32, color : Egui::Color32) : Nil
    fonts = @fonts
    return unless fonts && fonts.loaded?
    size_f = size.to_f64
    # Fractional pen (kerning + advances), snapped per glyph like the
    # UI draw path — rounding each advance would drift long words.
    asc, _desc = fonts.metrics_at(size_f)
    baseline = y + asc
    pen = 0.0
    prev = 0
    text.each_char do |ch|
      gid = fonts.glyph_index(ch.ord)
      pen += fonts.kern_px(prev, gid, size_f) if prev > 0
      g = fonts.glyph(gid, size_f)
      if g.w > 0 && g.h > 0 && (cov = fonts.glyph_coverage(g))
        gx = (x + pen + g.xoff).round.to_i
        gy = (baseline - g.ytop).round.to_i
        g.h.times do |r|
          g.w.times do |c|
            a = cov[r * g.w + c]
            canvas.blend(gx + c, gy + r, color, a) if a != 0
          end
        end
      end
      pen += g.advance
      prev = gid
    end
    canvas.mark_dirty
  end

  def measure(text : String, size : Int32) : Egui::Vec2
    fonts = @fonts
    return Egui::Vec2.new(0.0, size.to_f64) unless fonts.try(&.loaded?) && !text.empty?
    fonts = fonts.not_nil!
    size_f = size.to_f64
    pen = 0.0
    prev = 0
    text.each_char do |ch|
      gid = fonts.glyph_index(ch.ord)
      pen += fonts.kern_px(prev, gid, size_f) if prev > 0
      pen += fonts.glyph(gid, size_f).advance
      prev = gid
    end
    # The size convention is `size` pixels of (ascender - descender).
    Egui::Vec2.new(pen.round.to_f64, size.to_f64)
  end
end
