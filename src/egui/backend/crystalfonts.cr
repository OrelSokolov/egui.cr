# Pure-Crystal font backend — the PRIMARY one for every build mode:
# the freetype-cr GitHub shard (OrelSokolov/freetype.cr) — SFNT
# parsing, the TrueType bytecode hinter (ttinterp) and the ftgrays
# rasterizer, no libfreetype.so involved. Produces the same hinted
# 8-bit coverage bitmaps the C-FFI FreetypeFonts gets from the C
# library; spec/crystalfonts_smoke.cr diff-proves the parity, and the
# fontpreview example carries it as a live-switchable tab. Dev builds
# with C_EXTENSIONS enabled accelerate through the C FFI first; this
# backend is what release binaries run on.
#
# The size convention matches FreetypeFonts exactly — `size` pixels of
# (ascender - descender) height with the ascender/descender picked like
# FreeType's sfnt_load_face — so widget layout does not shift between
# the tabs. The face size FreeType would see from that request is an
# integer ppem (FT_Request_Metrics rounds), which is what
# TT::HintedFace#set_pixel_size takes.

require "freetype-cr"
require "./text"

module Egui
  module Backend
    class CrystalFonts < AtlasFonts
      def self.from_system(paths : Array(String)) : CrystalFonts?
        paths.each do |path|
          next unless File.exists?(path)
          begin
            font = new(File.read(path))
          rescue TT::ParseError
            next
          end
          return font if font.loaded?
        end
        nil
      end

      @face : TT::HintedFace
      @upem : Float64 = 0.0
      @asc : Float64 = 0.0
      @desc : Float64 = 0.0  # negative, font units
      @ppem_set : Int32 = -1 # size_key-unrelated: the integer ppem armed on the face
      @glyph_ids = {} of Int32 => Int32
      @kerns = {} of {Int32, Int32, Int32} => Float64
      @metrics = {} of Int32 => {Float64, Float64}

      def initialize(@font_data : String)
        super()
        # TT::HintedFace keeps slices into the buffer, not a copy:
        # @font_data must outlive the face (instance field, so it does).
        @face = TT::HintedFace.new(@font_data.to_slice)
        font = @face.font
        @upem = font.upem.to_f64
        # FT_Face->ascender/descender selection (sfobjs.c) lives in the
        # parser — same values the FFI backend reads off FT_FaceRec.
        @asc = font.ascender.to_f64
        @desc = font.descender.to_f64
      end

      def loaded? : Bool
        @upem > 0 && @asc > @desc
      end

      def glyph_index(codepoint : Int32) : Int32
        @glyph_ids[codepoint] ||= @face.font.glyph_index(codepoint)
      end

      # {ascender, descender} in px (descender negative), cached per size —
      # computed linearly from the font units exactly like FreetypeFonts.
      def metrics_at(size : Float64) : {Float64, Float64}
        @metrics[size_key(size)] ||= begin
          scale = size / (@asc - @desc)
          {@asc * scale, @desc * scale}
        end
      end

      # FT_Get_Kerning(FT_KERNING_DEFAULT): font units -> FT_MulFix by the
      # size's x_scale, scaled down through MulDiv when ppem < 25, then
      # rounded to whole pixels.
      def kern_px(prev_gid : Int32, gid : Int32, size : Float64) : Float64
        @kerns[{prev_gid, gid, size_key(size)}] ||= begin
          ppem = ppem_for(size)
          set_ppem(ppem)
          units = @face.font.kerning(prev_gid, gid)
          k26 = TT::Fixed.mulfix(units.to_i64, @x_scale)
          k26 = TT::Fixed.muldiv(k26, ppem, 25) if ppem < 25
          TT::Fixed.pix_round(k26).to_f64 / 64.0
        end
      end

      # --- AtlasFonts: rasterize via the Crystal port ------------------------

      def build_glyph(gid : Int32, size : Float64) : Glyph
        set_ppem(ppem_for(size))
        begin
          g = @face.load_glyph(gid, hint: true)
        rescue ex : TT::ParseError | TT::ExecutionError
          # A malformed glyph the C library would survive by blanking it.
          return Glyph.new(0, 0, 0, 0, 0, 0, 0, 0, 0.0, 0, 0.0)
        end
        adv = g.advance.to_f64 / 64.0
        if g.xs.empty? || g.contours.empty?
          return Glyph.new(0, 0, 0, 0, 0, 0, 0, 0, 0.0, 0, adv)
        end

        outline = Ftgrays::Outline.new(g.xs, g.ys, g.tags, g.contours)
        bmp = Ftrender.render_glyph(outline)
        w, h = bmp.width, bmp.height
        if w > 0 && h > 0 && w <= atlas.size && h <= atlas.size
          if slot_xy = alloc_glyph(w, h)
            ax, ay = slot_xy
            atlas.blit(ax, ay, w, h, contrast_curve(bmp.buffer))
            inv = 1.0f32 / atlas.size.to_f32
            return Glyph.new(ax * inv, ay * inv, (ax + w) * inv, (ay + h) * inv,
              ax, ay, w, h, bmp.left.to_f64, bmp.top, adv)
          end
          # Atlas full: blank this frame (a reset recovers on the next).
        end
        Glyph.new(0, 0, 0, 0, 0, 0, 0, 0, bmp.left.to_f64, bmp.top, adv)
      end

      # alpha = 2c - c^2 — the contrast curve every backend bakes in.

      private def contrast_curve(cov : Bytes) : Bytes
        cov.map do |v|
          c = v.to_f64 / 255.0
          ((2.0 * c - c * c) * 255.0).round.to_u8
        end
      end

      # The integer ppem FreeType's FT_Request_Size(NOMINAL) settles on for
      # FreetypeFonts' fractional height request: trunc26.6 then (h + 32) >> 6.

      private def ppem_for(size : Float64) : Int32
        h = (size * @upem / (@asc - @desc) * 64.0).to_i64
        {((h &+ 32) >> 6).to_i32, 1}.max
      end

      # x_scale of the armed size, kept in step with the face (kerning needs
      # it before any glyph load happens).
      @x_scale : Int64 = 0_i64

      private def set_ppem(ppem : Int32) : Nil
        return if @ppem_set == ppem
        @face.set_pixel_size(ppem)
        @x_scale = TT::Fixed.divfix(ppem.to_i64 << 6, @upem.to_i64)
        @ppem_set = ppem
      end
    end
  end
end
