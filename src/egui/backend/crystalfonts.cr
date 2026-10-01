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
# EM (ppem = size, the egui/CSS convention) — so widget layout does not
# shift between the tabs and every font renders at the same visual
# height at the same nominal size (a font's ascender-descender extent
# no longer shrinks it). The face size FreeType would see from that
# request is an integer ppem (FT_Request_Metrics rounds), which is what
# TT::HintedFace#set_pixel_size takes.
#
# FONT FALLBACK CHAIN: `from_system` loads EVERY loadable path (the
# first is the primary face; later ones are fallbacks), and
# #glyph_index scans the chain per codepoint — the egui
# FontDefinitions role (a UI face + a symbols face + an emoji face in
# one atlas). Composite glyph ids pack the face index above the local
# gid (STRIDE), so the shared {gid, size} glyph cache routes each
# entry back to the face that owns the glyph. Metrics come from the
# primary; every face bakes at the same EM ppem for `size`, so its
# glyphs sit at the same visual height.

require "freetype-cr"
require "./text"

module Egui
  module Backend
    class CrystalFonts < AtlasFonts
      # Composite gid packing: gid = face_index * STRIDE + local_gid.
      # Local gids never exceed the glyph count of a sane font (< 2^20
      # even for the huge CJK faces); four faces still fit an Int32.
      STRIDE = 0x400_000_i32

      # Every loadable path becomes one face of the chain (primary
      # first); nil only when nothing parsed. Unparseable files are
      # skipped — a mixed list (TTF + a CFF the port can't read) keeps
      # the faces that work.
      def self.from_system(paths : Array(String),
                           atlas : GlyphAtlas? = nil) : CrystalFonts?
        datas = [] of String
        loaded = [] of String
        paths.each do |path|
          next unless File.exists?(path)
          data = File.read(path)
          next if data.size.zero?
          datas << data
          loaded << path
        end
        return nil if datas.empty?
        font = new(datas, atlas)
        font.face_paths.concat(loaded) if font.loaded?
        font.loaded? ? font : nil
      end

      @faces : Array(TT::HintedFace)
      # Source path per face (diagnostics; empty for direct `new` calls).
      getter face_paths : Array(String) = [] of String
      @upem : Array(Float64) = [] of Float64   # per face, font units
      @asc : Array(Float64) = [] of Float64    # per face, font units
      @desc : Array(Float64) = [] of Float64   # per face, negative
      @ppem_set : Array(Int32) = [] of Int32   # armed ppem per face
      @x_scale : Array(Int64) = [] of Int64    # armed x_scale per face
      @glyph_ids = {} of Int32 => Int32
      @kerns = {} of {Int32, Int32, Int32} => Float64
      @metrics = {} of Int32 => {Float64, Float64}

      def initialize(font_datas : Array(String), atlas : GlyphAtlas? = nil)
        super(atlas)
        @faces = [] of TT::HintedFace
        font_datas.each do |data|
          begin
            # TT::HintedFace keeps slices into the buffer, not a copy:
            # the array (and its strings) must outlive the faces — they
            # are held by this instance field, so they do.
            face = TT::HintedFace.new(data.to_slice)
          rescue TT::ParseError
            next
          end
          font = face.font
          next unless font.upem > 0 && font.ascender > font.descender
          @faces << face
          @upem << font.upem.to_f64
          # FT_Face->ascender/descender selection (sfobjs.c) lives in
          # the parser — same values the FFI backend reads off FT_FaceRec.
          @asc << font.ascender.to_f64
          @desc << font.descender.to_f64
          @ppem_set << -1
          @x_scale << 0_i64
        end
      end

      def loaded? : Bool
        !@faces.empty?
      end

      # The chain scan: the first face with a glyph for `codepoint`
      # wins (composite gid); 0 = missing everywhere (notdef, like the
      # single-font backends).
      def glyph_index(codepoint : Int32) : Int32
        @glyph_ids[codepoint] ||= begin
          gid = 0
          @faces.each_with_index do |face, i|
            local = face.font.glyph_index(codepoint)
            if local != 0
              gid = i * STRIDE + local
              break
            end
          end
          gid
        end
      end

      # {ascender, descender} in px (descender negative) of the PRIMARY
      # face, cached per size — computed linearly from the font units
      # exactly like FreetypeFonts.
      def metrics_at(size : Float64) : {Float64, Float64}
        @metrics[size_key(size)] ||= begin
          scale = size / @upem[0]
          {@asc[0] * scale, @desc[0] * scale}
        end
      end

      # FT_Get_Kerning(FT_KERNING_DEFAULT): font units -> FT_MulFix by the
      # size's x_scale, scaled down through MulDiv when ppem < 25, then
      # rounded to whole pixels. Only pairs from the SAME face kern —
      # cross-face pairs (a symbol after a letter) take zero.
      def kern_px(prev_gid : Int32, gid : Int32, size : Float64) : Float64
        pi = prev_gid // STRIDE
        gi = gid // STRIDE
        return 0.0 if pi != gi || pi >= @faces.size
        @kerns[{prev_gid, gid, size_key(size)}] ||= begin
          ppem = ppem_for(size, pi)
          set_ppem(ppem, pi)
          units = @faces[pi].font.kerning(prev_gid % STRIDE, gid % STRIDE)
          k26 = TT::Fixed.mulfix(units.to_i64, @x_scale[pi])
          k26 = TT::Fixed.muldiv(k26, ppem, 25) if ppem < 25
          TT::Fixed.pix_round(k26).to_f64 / 64.0
        rescue Exception
          0.0 # a face without parseable kern data kerns nothing
        end
      end

      # --- AtlasFonts: rasterize via the Crystal port ------------------------

      def build_glyph(gid : Int32, size : Float64) : Glyph
        i = {gid // STRIDE, @faces.size - 1}.min
        face = @faces[i]
        set_ppem(ppem_for(size, i), i)
        begin
          g = face.load_glyph(gid % STRIDE, hint: true)
        rescue ex : Exception
          # A glyph this port cannot load — the CFF-outline trap: a face
          # whose cmap PROMISES the codepoint (glyph_index > 0) but whose
          # glyph data the TrueType loader can't parse. The C library
          # survives such glyphs by blanking them; so does the chain —
          # a broken face must never take the app down.
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
      # The same EM ppem for every face (primary and fallbacks alike) —
      # one em is `size` px in each, so mixed-unit chains render at one
      # visual height.

      private def ppem_for(size : Float64, face_i : Int32) : Int32
        h = (size * 64.0).to_i64
        {((h &+ 32) >> 6).to_i32, 1}.max
      end

      # x_scale of the armed size, kept in step with each face (kerning
      # needs it before any glyph load happens).

      private def set_ppem(ppem : Int32, face_i : Int32) : Nil
        return if @ppem_set[face_i] == ppem
        begin
          @faces[face_i].set_pixel_size(ppem)
        rescue ex : Exception
          # Belt-and-suspenders: the port degrades VM ('fpgm'/'prep')
          # failures to unhinted rendering itself, but if a size setup
          # still dies, this face must not take the app down — mark the
          # ppem as done (no per-glyph retry loop) and let build_glyph's
          # rescue blank every glyph of the broken face.
          @ppem_set[face_i] = ppem
          @x_scale[face_i] = TT::Fixed.divfix(ppem.to_i64 << 6, @upem[face_i].to_i64)
          return
        end
        @x_scale[face_i] = TT::Fixed.divfix(ppem.to_i64 << 6, @upem[face_i].to_i64)
        @ppem_set[face_i] = ppem
      end
    end
  end
end
