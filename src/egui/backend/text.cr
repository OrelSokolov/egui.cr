# Crystal text stack. This file holds the glyph-atlas infrastructure
# shared by the font backends:
#
#   * AtlasFonts — the `Egui::Fonts` base: a shared 2048² RGBA atlas
#     (white RGB, coverage alpha), a {glyph id, size} glyph cache and one
#     walk (fractional advances + kerning) used by both measure and draw.
#     Draw-side, glyph quads snap to whole screen pixels.
#   * CrystalFonts (backend/crystalfonts.cr) — the primary backend: the
#     freetype-cr GitHub shard (SFNT + ttinterp hinter + ftgrays
#     rasterizer, pure Crystal). What release builds always run on.
#   * FreetypeFonts (backend/freetype.cr) — a C-FFI binding of the system
#     libfreetype: real hinted bitmaps, used as a DEV-build accelerator
#     behind C_EXTENSIONS (debug codegen is 10-100x slower; the C library
#     is fast regardless of Crystal's flags).
#
# All bake coverage with the contrast curve upstream uses for dark mode:
# alpha = 2c - c^2 (FontColorTransferFunction::TwoCoverageMinusCoverageSq).

module Egui
  module Backend
    # C-accelerators (C-FFI FreeType, the C NanoSVG shim): a dev-only
    # convenience, off by default — a fresh clone builds a self-contained
    # pure-Crystal UI with no libfreetype. Enabled by `USE_C_EXTENSIONS=1`
    # in the repo root's .env (or in the build environment); --release
    # NEVER uses them. Compile-time, so the C code is not even linked
    # when off. (Must expand to a plain Bool literal: macro-`if` over a
    # non-literal constant would read back as an always-truthy AST node
    # from other files' `{% if %}`s.)
    {% begin %}
      {% cext = false %}
      {% unless flag?(:release) %}
        {% dotenv = read_file?(".env") || "" %}
        {% env_val = env("USE_C_EXTENSIONS") || "" %}
        # Line-anchored so the commented line in .env.example stays off.
        {% cext = (env_val == "1") ||
                   dotenv.starts_with?("USE_C_EXTENSIONS=1") ||
                   dotenv.includes?("\nUSE_C_EXTENSIONS=1") %}
      {% end %}
      C_EXTENSIONS = {{ cext }}
    {% end %}
    # A rasterized glyph: atlas rect + placement relative to the pen.
    struct Glyph
      getter u0, v0, u1, v1 : Float32 # atlas UVs
      getter ax, ay : Int32           # atlas slot (px; 0,0 for blanks)
      getter w, h : Int32             # bitmap size (0 = blank glyph)
      getter xoff : Float64           # left bearing (px, fractional)
      getter ytop : Int32             # bitmap top over baseline (px)
      getter advance : Float64        # pen advance (px, fractional)

      def initialize(@u0 : Float32, @v0 : Float32, @u1 : Float32, @v1 : Float32,
                     @ax : Int32, @ay : Int32, @w : Int32, @h : Int32,
                     @xoff : Float64, @ytop : Int32, @advance : Float64)
      end
    end

    # The `Egui::Fonts` implementation shared by the font backends:
    # CrystalFonts (crystalfonts.cr, primary) and FreetypeFonts
    # (freetype.cr, C-FFI dev accelerator). One RGBA atlas + glyph
    # cache, one walk (fractional advances + kerning) for both measure
    # and draw; a backend implements glyph production and metrics.
    abstract class AtlasFonts < Egui::Fonts
      # The atlas this stack bakes into: its OWN (default — specs,
      # standalone tools) or a SHARED one owned by the backend registry
      # (sokol.cr: one GPU texture for every stack the registry creates,
      # so a font picker flipping through hundreds of families cannot
      # exhaust the shim's atlas cap or VRAM).
      getter atlas : GlyphAtlas
      @atlas_epoch : UInt32

      def initialize(atlas : GlyphAtlas? = nil)
        @atlas = atlas || GlyphAtlas.new(ATLAS_SIZE)
        @atlas_epoch = @atlas.epoch
        @glyphs = {} of {Int32, Int32} => Glyph # {glyph id, size*10} -> glyph
        @needs_reset = false
      end

      abstract def loaded? : Bool
      abstract def glyph_index(codepoint : Int32) : Int32
      # Kerning between two glyph ids (px) at the given size.
      abstract def kern_px(prev_gid : Int32, gid : Int32, size : Float64) : Float64
      # {ascender, descender} in px for a size (descender negative).
      abstract def metrics_at(size : Float64) : {Float64, Float64}
      protected abstract def build_glyph(gid : Int32, size : Float64) : Glyph

      # Extra spacing between letters (px) — added BETWEEN glyphs only,
      # never after the last one, so `measure` widths stay exact.
      # Backends whose glyph placement reads tighter than their
      # reference open this up (live-tunable: fontpreview exposes it).
      property letter_spacing : Float64 = 0.0

      # Pixels per point the draw path rasterizes at (set by the backend
      # each frame; 1.0 headless). Hinted advances are per-ppem, NOT
      # linear in size — SF Mono advances 7.0px at 14pt but 15px at the
      # retina draw size (28px) — so `measure` must walk the run at the
      # same physical size the glyphs will be drawn at and fold the
      # width back to points, or every widget lays out on advances the
      # painter then exceeds (in a terminal grid the cursor visibly
      # drifts off the text).
      property scale : Float64 = 1.0

      # --- Egui::Fonts -------------------------------------------------------

      def measure(text : String, size : Float64) : Egui::Vec2
        return Egui::Vec2.zero if text.empty? || !loaded?
        width = walk(text, size * @scale) { |_, _| } / @scale
        asc, desc = metrics_at(size)
        Egui::Vec2.new(width, asc - desc)
      end

      # Memoized `measure` for STATIC text (labels, captions, button
      # texts — strings that return frame after frame unchanged).
      # Anything the user types into (TextEdit/TextArea/…) keeps calling
      # #measure: its content churns per keystroke, and dead entries
      # would only pollute the map.
      #
      # The same (text, physical size, tracking) always walks to the
      # same width — advances and kerning are per-glyph constants of
      # the font — so no invalidation is ever needed for correctness:
      # every width input (draw size = size * scale, letter_spacing)
      # rides the key. Memory is bounded by TWO guards: a LENGTH filter
      # (unbounded distinct strings — buffer lines, caret prefixes —
      # must never land here) and a COUNT cap with clear-on-overflow
      # (every dropped entry rebuilds in one walk, cheaper than LRU
      # bookkeeping on every hit).
      MEASURE_CACHE_TEXT_MAX = 64
      MEASURE_CACHE_MAX      = 8192
      @measure_cache = {} of {String, Int32, Int32} => Float64

      def measure_cached(text : String, size : Float64) : Egui::Vec2
        return Egui::Vec2.zero if text.empty? || !loaded?
        asc, desc = metrics_at(size)
        key = {text, size_key(size * @scale), size_key(@letter_spacing)}
        if (width = @measure_cache[key]?)
          Egui::Bench.count("fonts.measure_cached.hit")
          return Egui::Vec2.new(width, asc - desc)
        end
        Egui::Bench.count("fonts.measure_cached.miss")
        width = Egui::Bench.span("Fonts#measure_cached(miss)") do
          walk(text, size * @scale) { |_, _| } / @scale
        end
        @measure_cache.clear if @measure_cache.size >= MEASURE_CACHE_MAX
        @measure_cache[key] = width
        Egui::Vec2.new(width, asc - desc)
      end

      # Walk the run exactly like the draw path does (fractional advances +
      # kerning), yielding (pen_x, glyph) per char. Returns the final pen.
      def walk(text : String, size : Float64, & : Float64, Glyph -> Nil) : Float64
        return 0.0 if text.empty? || !loaded?
        pen = 0.0
        prev = 0
        text.each_char_with_index do |ch, idx|
          gid = glyph_index(ch.ord)
          pen += kern_at(prev, gid, size) if prev > 0
          pen += letter_spacing if idx > 0
          g = glyph(gid, size)
          yield pen, g
          pen += g.advance
          prev = gid
        end
        pen
      end

      # Memoized kerning in front of the backend FFI: kerning is a
      # constant per (glyph pair, size) of the immutable font file, so
      # no invalidation is ever needed. Real text touches a few hundred
      # distinct pairs; the cap exists only as a hard bound (a sythetic
      # sweep over every glyph pair of a CJK font would be huge) —
      # clear-on-overflow like the measure cache.
      KERN_CACHE_MAX = 65_536
      @kern_cache = {} of {Int32, Int32, Int32} => Float64

      private def kern_at(prev_gid : Int32, gid : Int32, size : Float64) : Float64
        key = {prev_gid, gid, size_key(size)}
        if (k = @kern_cache[key]?)
          k
        else
          k = kern_px(prev_gid, gid, size)
          @kern_cache.clear if @kern_cache.size >= KERN_CACHE_MAX
          @kern_cache[key] = k
          k
        end
      end

      def glyph(gid : Int32, size : Float64) : Glyph
        # A reset of a SHARED atlas (another stack overflowed it — see
        # sokol.cr's registry-level reset) bumped its epoch: every cached
        # UV of ours now points at overwritten slots. Drop the whole
        # glyph cache; live glyphs re-bake on demand below.
        if @atlas_epoch != @atlas.epoch
          @atlas_epoch = @atlas.epoch
          @glyphs.clear
        end
        @glyphs[{gid, size_key(size)}] ||= build_glyph(gid, size)
      end

      # Allocate an atlas slot for a glyph bitmap, flagging the atlas as
      # exhausted when the packer refuses (sizes accumulate — a font-size
      # drag bakes a full glyph set per 0.1px step). The glyph itself is
      # still dropped for this frame; `reset_if_full` recovers before the
      # next one.
      protected def alloc_glyph(w : Int32, h : Int32) : {Int32, Int32}?
        @needs_reset = true unless slot = @atlas.alloc(w, h)
        slot
      end

      # Wipe the atlas and the glyph cache when a frame overflowed it
      # (fontstash's texture reset): everything visible re-bakes on
      # demand, so dropped letters come back instead of staying blank
      # forever (dropped glyphs are cached as blanks otherwise). Call
      # before `flush`, outside a render pass; a true result means the
      # caller should re-`touch` this frame's text commands. For stacks
      # on a SHARED atlas the registry resets the atlas itself and calls
      # #clear_overflow_flag instead (one wipe covers every stack; the
      # epoch bump invalidates the caches lazily in #glyph).
      def reset_if_full : Bool
        return false unless @needs_reset
        @needs_reset = false
        @atlas.reset
        @atlas_epoch = @atlas.epoch
        @glyphs.clear
        true
      end

      # Did a frame's baking overflow the atlas? (Registry-level reset
      # in sokol.cr polls this across every live stack.)
      def needs_reset? : Bool
        @needs_reset
      end

      # Acknowledge an overflow WITHOUT touching the atlas: the registry
      # already reset the SHARED atlas this stack bakes into — the epoch
      # mismatch invalidates the glyph cache lazily in #glyph.
      def clear_overflow_flag : Nil
        @needs_reset = false
      end

      # Coverage bytes of a baked glyph's atlas slot (specs/tests);
      # nil for blank glyphs.
      def glyph_coverage(g : Glyph) : Bytes?
        return nil if g.w == 0 || g.h == 0
        @atlas.debug_region(g)
      end

      # Rasterized coverage bitmap as text (debug/tests) — works for
      # every backend: glyphs land in the shared atlas either way.
      def debug_bitmap(ch : Char, size : Float64) : Nil
        g = glyph(glyph_index(ch.ord), size)
        puts "#{ch.inspect}: w=#{g.w} h=#{g.h} ytop=#{g.ytop} adv=#{g.advance.round(2)}"
        return if g.w == 0
        cov = @atlas.debug_region(g)
        scale = " .:-=+*#%@"
        g.h.times do |row|
          line = String.build do |s|
            g.w.times do |col|
              a4 = cov[row * g.w + col]?
              s << scale[{(a4 ? a4.not_nil!.to_i32 * 10 // 256 : 0), 9}.min]
            end
          end
          puts "  #{line}"
        end
      end

      # Rasterize every glyph a text command needs. Called before the render
      # pass: sg_update_image is illegal inside a pass, so the atlas must be
      # uploaded first (see flush). `scale` = framebuffer pixels per point —
      # glyphs are rasterized at the physical size (crisp on retina); 1.0
      # for callers without a window (specs, fontpreview tabs).
      def touch(cmd : Egui::TextCmd, scale : Float64 = 1.0) : Nil
        walk(cmd.text, cmd.size * scale) { |_, _| }
      end

      # Upload dirty atlas regions to the GPU. Must run outside a pass.
      def flush : Nil
        @atlas.flush
      end

      def atlas_view_id : UInt32
        @atlas.view_id
      end

      protected def size_key(size : Float64) : Int32
        (size * 10.0).round.to_i
      end
    end

    # --- atlas (shared by the font backends) -----------------------------------

    # 2048² so retina (2x) rasterizations — 4x the area — still fit
    # alongside the point-size copies the measure path bakes.
    ATLAS_SIZE = 2048

    # RGBA8 glyph atlas with shelf packing. RGB is white; alpha is the
    # glyph coverage — the draw path multiplies by the text color.
    # Baked glyphs are never freed individually; when the shelves run
    # out (font-size drags bake a set per fractional size), `reset`
    # empties everything for a full re-bake. The registry may share ONE
    # atlas between many stacks (see AtlasFonts#initialize); `epoch`
    # lets each stack detect a foreign reset and drop its stale UVs.
    class GlyphAtlas
      getter size : Int32
      getter view_id = 0_u32
      # Bumped by every #reset: stacks sharing this atlas compare their
      # remembered epoch in AtlasFonts#glyph and invalidate on a drift.
      getter epoch = 0_u32
      @rgba : Bytes
      @dirty = false
      @shelf_x = 0
      @shelf_y = 0
      @shelf_h = 0

      def initialize(@size : Int32)
        @rgba = Bytes.new(@size * @size * 4)
      end

      # Shelf packer with a 1px border around every glyph so LINEAR
      # sampling never bleeds between neighbours.
      def alloc(w : Int32, h : Int32) : {Int32, Int32}?
        return nil if w <= 0 || h <= 0
        return nil if w + 2 > @size || h + 2 > @size
        if @shelf_x + w + 2 > @size
          @shelf_x = 0
          @shelf_y += @shelf_h
          @shelf_h = 0
        end
        return nil if @shelf_y + h + 2 > @size
        x = @shelf_x
        y = @shelf_y
        @shelf_x += w + 2
        @shelf_h = {@shelf_h, h + 2}.max
        {x, y}
      end

      def blit(x : Int32, y : Int32, w : Int32, h : Int32, cov : Bytes) : Nil
        h.times do |row|
          di = ((y + row) * @size + x) * 4
          si = row * w
          w.times do |col|
            @rgba[di] = 255_u8
            @rgba[di + 1] = 255_u8
            @rgba[di + 2] = 255_u8
            @rgba[di + 3] = cov[si + col]
            di += 4
          end
        end
        @dirty = true
      end

      # Empty the atlas: shelf state back to the origin, pixels zeroed.
      # Keeps the GPU texture/view id — the next `flush` re-uploads the
      # whole buffer. (fontstash's reset-and-rebake, invoked by
      # AtlasFonts#reset_if_full when the packer runs out of space, or
      # by the backend registry when ANY sharing stack overflowed.)
      def reset : Nil
        @shelf_x = 0
        @shelf_y = 0
        @shelf_h = 0
        @rgba.fill(0_u8)
        @dirty = true
        @epoch += 1_u32
      end

      # Create/update this atlas's GPU texture. Outside of a render
      # pass only. The shim keeps a per-instance registry keyed by the
      # view id, so several backends' atlases can coexist.
      def flush : Nil
        return if @view_id != 0 && !@dirty
        if @view_id == 0
          @view_id = LibEguiCr.atlas_create(@size, @size, @rgba)
        else
          LibEguiCr.atlas_update(@view_id, @size, @size, @rgba)
        end
        @dirty = false
      end

      # The alpha bytes of a glyph's atlas slot (debug/tests).
      def debug_region(g : Glyph) : Bytes
        out = Bytes.new(g.w * g.h)
        g.h.times do |row|
          g.w.times do |col|
            out[row * g.w + col] = @rgba[((g.ay + row) * @size +
              g.ax + col) * 4 + 3]
          end
        end
        out
      end
    end
  end
end
