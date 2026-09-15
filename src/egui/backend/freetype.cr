# Primary font backend: a direct Crystal binding of FreeType. FT_Load_Glyph
# with FT_LOAD_DEFAULT | FT_LOAD_RENDER gives hinted 8-bit coverage bitmaps вЂ”
# the TrueType/CFF hinters snap stem edges to the pixel grid properly, which
# is what the light-hint heuristic in text.cr approximates. LightHintedFonts
# remains as the fallback for systems without FreeType.
#
# Everything here goes through real FreeType functions except the two big
# opaque structs (FT_FaceRec, FT_GlyphSlotRec), which are too large to
# mirror completely: only the accessed fields are mapped, with offsets
# verified against the system headers via offsetof(3):
#
#   FT_Long / FT_Pos is C long вЂ” 8 bytes on LP64 (Linux/macOS), 4 on
#   Win64 вЂ” so every mirror below switches paddings/widths with the
#   platform (verified against freetype 2.13 headers on Linux and the
#   2.14.3 headers shipped with the Windows binaries):
#
#   LP64 (Linux):                Win64:
#     FT_FaceRec                   FT_FaceRec
#       units_per_EM  @136           units_per_EM  @104
#       ascender      @138           ascender      @106
#       descender     @140           descender     @108
#       glyph         @152           glyph         @120
#       size          @160           size          @128
#     FT_GlyphSlot               FT_GlyphSlot
#       advance       @128           advance       @88
#       bitmap        @152           bitmap        @104
#       bitmap_left   @192           bitmap_left   @144
#       bitmap_top    @196           bitmap_top    @148
#
# Size convention (same as the stb backend and fontstash's FreeType path):
# `size` pixels of (ascender - descender) height, so widget layout does not
# shift between backends. FT_Face's size is stateful вЂ” set_size must run
# before every call whose result depends on it.

require "./text"

# Minimal FreeType binding: only what FreetypeFonts needs. The three big
# structs are partially mirrored вЂ” see the offset notes in the header
# comment. Field layout is plain C (Crystal structs follow it), so the
# skip paddings below are byte-exact.
@[Link("freetype")]
lib LibFreetype
  FT_LOAD_DEFAULT             = 0
  FT_LOAD_RENDER              = 0x4
  FT_KERNING_DEFAULT          = 0
  FT_PIXEL_MODE_GRAY          = 2
  FT_SIZE_REQUEST_TYPE_NOMINAL = 0

  # C long: 8 bytes on LP64, 4 on Win64 вЂ” all 26.6/16.16 fields below
  # go through it, and so do the call signatures.
  {% if flag?(:win32) %}
    alias Long = Int32
  {% else %}
    alias Long = Int64
  {% end %}

  struct Vector # FT_Vector, 26.6 fixed point
    x : Long
    y : Long
  end

  struct Bitmap # FT_Bitmap
    rows : Int32
    width : Int32
    pitch : Int32
    pad0 : Int32
    buffer : UInt8*
    num_grays : UInt16
    pixel_mode : UInt8
    palette_mode : UInt8
    pad1 : UInt8[4]
    palette : Void*
  end

  struct GlyphSlotRec # FT_GlyphSlotRec (accessed fields only)
    # pad0 covers library, face, next, reserved, generic, metrics вЂ” the
    # metrics block is 8 FT_Pos: 64 bytes on LP64, 32 on Win64.
    {% if flag?(:win32) %}
      pad0 : UInt8[80]
    {% else %}
      pad0 : UInt8[112]
    {% end %}
    linear_hori_advance : Long    # 16.16
    linear_vert_advance : Long    # 16.16
    advance : Vector              # 26.6
    format : Int32                # FT_Glyph_Format
    pad2 : Int32
    bitmap : Bitmap
    bitmap_left : Int32
    bitmap_top : Int32
  end

  struct SizeRequestRec # FT_Size_RequestRec
    type : Int32      # FT_Size_Request_Type
    {% unless flag?(:win32) %}
      pad0 : Int32    # Long is 8-aligned on LP64
    {% end %}
    width : Long      # 26.6
    height : Long     # 26.6
    hori_resolution : UInt32 # dpi; 0 = 72 в†’ pixels
    vert_resolution : UInt32
  end

  struct FaceRec # FT_FaceRec (accessed fields only)
    # pad0 covers num_faces вЂ¦ bbox вЂ” five FT_Long fields plus the FT_BBox
    # of four FT_Pos shrink with the long width.
    {% if flag?(:win32) %}
      pad0 : UInt8[104]
    {% else %}
      pad0 : UInt8[136]
    {% end %}
    units_per_em : UInt16
    ascender : Int16      # font units
    descender : Int16     # font units, negative
    pad1 : UInt8[10]
    glyph : GlyphSlotRec*
    size : Void*           # FT_SizeRec*
  end

  fun init_free_type = FT_Init_FreeType(a_library : Void**) : Int32
  fun new_memory_face = FT_New_Memory_Face(library : Void*, file_base : UInt8*,
                                           file_size : Long, face_index : Long,
                                           a_face : FaceRec**) : Int32
  fun request_size = FT_Request_Size(face : FaceRec*, req : SizeRequestRec*) : Int32
  fun load_glyph = FT_Load_Glyph(face : FaceRec*, glyph_index : UInt32,
                                 load_flags : Int32) : Int32
  fun get_char_index = FT_Get_Char_Index(face : FaceRec*, char_code : UInt32) : UInt32
  fun get_kerning = FT_Get_Kerning(face : FaceRec*, left_glyph_index : UInt32,
                                   right_glyph_index : UInt32, kern_mode : UInt32,
                                   akerning : Vector*) : Int32
end

module Egui
  module Backend
    # Coerce through the FT_Long alias вЂ” same call sites on both ABIs.
    def self.ft_long(v : Int | Float64) : LibFreetype::Long
      {% if flag?(:win32) %}
        v.to_i32
      {% else %}
        v.to_i64
      {% end %}
    end

    class FreetypeFonts < AtlasFonts
      def self.from_system(paths : Array(String)) : FreetypeFonts?
        paths.each do |path|
          next unless File.exists?(path)
          font = new(File.read(path))
          return font if font.loaded?
        end
        nil
      end

      @library : Void*
      @face : LibFreetype::FaceRec*
      @upem : Float64 = 0.0
      @asc : Float64 = 0.0
      @desc : Float64 = 0.0  # negative, font units
      @size_set : Int32 = -1 # size_key of the face's current size
      @glyph_ids = {} of Int32 => Int32
      @kerns = {} of {Int32, Int32, Int32} => Float64
      @metrics = {} of Int32 => {Float64, Float64}

      def initialize(@font_data : String)
        super()
        @library = Pointer(Void).null
        @face = Pointer(LibFreetype::FaceRec).null
        ft_lib = uninitialized Void*
        if LibFreetype.init_free_type(pointerof(ft_lib)) == 0
          @library = ft_lib
          # FT_New_Memory_Face does not copy the buffer: @font_data must
          # outlive the face (instance field, so it does).
          face = uninitialized LibFreetype::FaceRec*
          if LibFreetype.new_memory_face(@library, @font_data.to_unsafe,
                                         Backend.ft_long(@font_data.bytesize),
                                         Backend.ft_long(0), pointerof(face)) == 0
            @face = face
          end
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

      def glyph_index(codepoint : Int32) : Int32
        @glyph_ids[codepoint] ||= LibFreetype.get_char_index(@face, codepoint.to_u32).to_i32
      end

      # {ascender, descender} in px (descender negative), cached per size.
      # Computed linearly from the font units вЂ” the same convention as
      # LightHintedFonts (size pixels of ascender-descender height) вЂ”
      # because FT's scaled metrics are rounded to whole pixels (DejaVu:
      # 13/-4 = 17px at size 16), which would shift widget layout.
      def metrics_at(size : Float64) : {Float64, Float64}
        @metrics[size_key(size)] ||= begin
          scale = size / (@asc - @desc)
          {@asc * scale, @desc * scale}
        end
      end

      def kern_px(prev_gid : Int32, gid : Int32, size : Float64) : Float64
        @kerns[{prev_gid, gid, size_key(size)}] ||= begin
          set_size(size)
          vec = uninitialized LibFreetype::Vector
          if LibFreetype.get_kerning(@face, prev_gid.to_u32, gid.to_u32,
                                     LibFreetype::FT_KERNING_DEFAULT,
                                     pointerof(vec)) == 0
            vec.x / 64.0
          else
            0.0
          end
        end
      end

      # --- AtlasFonts: rasterize via FreeType ----------------------------------

      def build_glyph(gid : Int32, size : Float64) : Glyph
        set_size(size)
        if LibFreetype.load_glyph(@face, gid.to_u32,
                                  LibFreetype::FT_LOAD_DEFAULT |
                                  LibFreetype::FT_LOAD_RENDER) != 0
          return Glyph.new(0, 0, 0, 0, 0, 0, 0, 0, 0.0, 0, 0.0)
        end
        slot = @face.value.glyph
        adv = slot.value.advance.x.to_f64 / 64.0
        bmp = slot.value.bitmap
        w, h = bmp.width, bmp.rows
        if w > 0 && h > 0 && bmp.pixel_mode == LibFreetype::FT_PIXEL_MODE_GRAY &&
           w <= atlas.size && h <= atlas.size
          cov = bitmap_coverage(bmp)
          if slot_xy = atlas.alloc(w, h)
            ax, ay = slot_xy
            atlas.blit(ax, ay, w, h, cov)
            inv = 1.0f32 / atlas.size.to_f32
            return Glyph.new(ax * inv, ay * inv, (ax + w) * inv, (ay + h) * inv,
              ax, ay, w, h, slot.value.bitmap_left.to_f64, slot.value.bitmap_top, adv)
          end
          # Atlas full: drop the glyph, like fontstash does.
        end
        Glyph.new(0, 0, 0, 0, 0, 0, 0, 0, slot.value.bitmap_left.to_f64,
          slot.value.bitmap_top, adv)
      end

      # Copy the 8-bit coverage out of the FT_Bitmap (pitch = row stride,
      # negative pitch = bottom-up rows), applying the same contrast curve
      # as the light-hint backend: alpha = 2c - c^2.
      private def bitmap_coverage(bmp : LibFreetype::Bitmap) : Bytes
        w, h, pitch = bmp.width, bmp.rows, bmp.pitch
        stride = pitch.abs
        cov = Bytes.new(w * h)
        h.times do |r|
          src = pitch < 0 ? (h - 1 - r) : r
          row = bmp.buffer + src * stride
          w.times { |c| cov[r * w + c] = row[c] }
        end
        cov.map! do |v|
          c = v.to_f64 / 255.0
          ((2.0 * c - c * c) * 255.0).round.to_u8
        end
      end

      # Set the face's (stateful) size for every call that depends on it.
      private def set_size(size : Float64) : Nil
        key = size_key(size)
        return if @size_set == key
        req = LibFreetype::SizeRequestRec.new
        req.type = LibFreetype::FT_SIZE_REQUEST_TYPE_NOMINAL
        req.width = 0_i64
        req.height = Backend.ft_long(size * @upem / (@asc - @desc) * 64.0) # 26.6
        req.hori_resolution = 0_u32 # 0 = default 72 dpi в†’ pixels
        req.vert_resolution = 0_u32
        LibFreetype.request_size(@face, pointerof(req))
        @size_set = key
      end
    end
  end
end
