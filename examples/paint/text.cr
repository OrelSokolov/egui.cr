# Text-on-canvas rasterizer for the Paint demo: loads the first system
# font through the egui-cr FreeType binding (already linked by the
# sokol backend) and blends hinted 8-bit coverage glyphs straight into
# an Egui::Canvas pixel buffer — the same rendering path the UI's own
# text uses, so what you preview is what gets committed.

class PaintText
  @library : Void* = Pointer(Void).null
  @face : LibFreetype::FaceRec* = Pointer(LibFreetype::FaceRec).null
  @font_data : String = ""
  @upem : Float64 = 0.0
  @asc : Float64 = 0.0
  @desc : Float64 = 0.0
  @size_set : Int32 = -1

  def initialize
    Egui::SystemPorts::Fonts.search_paths.each do |path|
      next unless File.exists?(path)
      @font_data = File.read(path)
      ft_lib = uninitialized Void*
      next unless LibFreetype.init_free_type(pointerof(ft_lib)) == 0
      @library = ft_lib
      face = uninitialized LibFreetype::FaceRec*
      if LibFreetype.new_memory_face(@library, @font_data.to_unsafe,
                                     Egui::Backend.ft_long(@font_data.bytesize),
                                     Egui::Backend.ft_long(0),
                                     pointerof(face)) == 0
        @face = face
      end
      break if loaded?
    end
    if loaded?
      @upem = @face.value.units_per_em.to_f64
      @asc = @face.value.ascender.to_f64
      @desc = @face.value.descender.to_f64
    end
  end

  def loaded? : Bool
    !@face.null?
  end

  # Draw `text` with its TOP-LEFT at (x, y) in canvas pixels.
  def draw(canvas : Egui::Canvas, x : Int32, y : Int32, text : String,
           size : Int32, color : Egui::Color32) : Nil
    return unless loaded?
    set_size(size.to_f64)
    baseline = (y + @asc * size / (@asc - @desc)).round.to_i
    pen_x = x
    prev_gid = 0
    text.each_char do |ch|
      gid = LibFreetype.get_char_index(@face, ch.ord)
      if prev_gid != 0 && gid != 0
        vec = uninitialized LibFreetype::Vector
        if LibFreetype.get_kerning(@face, prev_gid.to_u32, gid.to_u32,
                                   LibFreetype::FT_KERNING_DEFAULT,
                                   pointerof(vec)) == 0
          pen_x += (vec.x / 64.0).round.to_i
        end
      end
      if LibFreetype.load_glyph(@face, gid,
                                LibFreetype::FT_LOAD_DEFAULT |
                                LibFreetype::FT_LOAD_RENDER) == 0
        slot = @face.value.glyph
        bmp = slot.value.bitmap
        if bmp.width > 0 && bmp.rows > 0 &&
           bmp.pixel_mode == LibFreetype::FT_PIXEL_MODE_GRAY
          gx = pen_x + slot.value.bitmap_left
          gy = baseline - slot.value.bitmap_top
          stride = bmp.pitch.abs
          bmp.rows.times do |r|
            src = bmp.pitch < 0 ? bmp.rows - 1 - r : r
            row = bmp.buffer + src * stride
            bmp.width.times do |c|
              cov = row[c]
              next if cov == 0
              canvas.blend(gx + c, gy + r, color, cov)
            end
          end
        end
        pen_x += (slot.value.advance.x / 64.0).round.to_i
      end
      prev_gid = gid
    end
    canvas.mark_dirty
  end

  def measure(text : String, size : Int32) : Egui::Vec2
    return Egui::Vec2.new(0.0, size.to_f64) unless loaded? || text.empty?
    set_size(size.to_f64)
    w = 0_i64
    prev_gid = 0
    text.each_char do |ch|
      gid = LibFreetype.get_char_index(@face, ch.ord)
      if prev_gid != 0 && gid != 0
        vec = uninitialized LibFreetype::Vector
        if LibFreetype.get_kerning(@face, prev_gid.to_u32, gid.to_u32,
                                   LibFreetype::FT_KERNING_DEFAULT,
                                   pointerof(vec)) == 0
          w += (vec.x / 64.0).round.to_i
        end
      end
      if LibFreetype.load_glyph(@face, gid, LibFreetype::FT_LOAD_DEFAULT) == 0
        w += (@face.value.glyph.value.advance.x / 64.0).round.to_i
      end
      prev_gid = gid
    end
    Egui::Vec2.new(w.to_f64, (@asc - @desc) * size / (@asc - @desc))
  end

  private def set_size(size : Float64) : Nil
    key = (size * 4.0).to_i
    return if @size_set == key
    req = LibFreetype::SizeRequestRec.new
    req.type = LibFreetype::FT_SIZE_REQUEST_TYPE_NOMINAL
    req.width = 0_i64
    req.height = Egui::Backend.ft_long(size * @upem / (@asc - @desc) * 64.0)
    req.hori_resolution = 0_u32
    req.vert_resolution = 0_u32
    LibFreetype.request_size(@face, pointerof(req))
    @size_set = key
  end
end
