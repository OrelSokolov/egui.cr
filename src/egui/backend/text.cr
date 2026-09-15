# Crystal text stack. This file holds the glyph-atlas infrastructure
# shared by the two font backends, plus the fallback rasterizer:
#
#   * AtlasFonts — the `Egui::Fonts` base: a shared 2048² RGBA atlas
#     (white RGB, coverage alpha), a {glyph id, size} glyph cache and one
#     walk (fractional advances + kerning) used by both measure and draw.
#     Draw-side, glyph quads snap to whole screen pixels.
#   * LightHintedFonts — fallback rasterizer: stb_truetype outlines
#     (exposed by the shim) with a Crystal-side light hint on BOTH axes
#     before 4x4 supersampled scanline conversion — an approximation of
#     FreeType's full grid-fitting (snapped stems/bars + whole-pixel
#     advances). Used when FreeType is unavailable.
#   * FreetypeFonts (backend/freetype.cr) — the primary backend: a direct
#     FreeType binding rasterizing hinted 8-bit coverage bitmaps.
#
# Both bake coverage with the contrast curve upstream uses for dark mode:
# alpha = 2c - c^2 (FontColorTransferFunction::TwoCoverageMinusCoverageSq).

module Egui
  module Backend
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
    # LightHintedFonts (this file, fallback) and FreetypeFonts
    # (freetype.cr, primary). One RGBA atlas + glyph cache, one walk
    # (fractional advances + kerning) for both measure and draw; a
    # backend implements glyph production and metrics.
    abstract class AtlasFonts < Egui::Fonts
      protected getter atlas : GlyphAtlas

      def initialize
        @atlas = GlyphAtlas.new(ATLAS_SIZE)
        @glyphs = {} of {Int32, Int32} => Glyph # {glyph id, size*10} -> glyph
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

      # --- Egui::Fonts -------------------------------------------------------

      def measure(text : String, size : Float64) : Egui::Vec2
        return Egui::Vec2.zero if text.empty? || !loaded?
        width = walk(text, size) { |_, _| }
        asc, desc = metrics_at(size)
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
          pen += kern_px(prev, gid, size) if prev > 0
          pen += letter_spacing if idx > 0
          g = glyph(gid, size)
          yield pen, g
          pen += g.advance
          prev = gid
        end
        pen
      end

      def glyph(gid : Int32, size : Float64) : Glyph
        @glyphs[{gid, size_key(size)}] ||= build_glyph(gid, size)
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

    # Fallback backend: stb_truetype outlines with a Crystal-side light
    # hint on both axes (snap horizontal strokes to pixel rows, vertical
    # stems to pixel columns, thickness to whole pixels, grid-fitted
    # advances) — approximating FreeType's full grid-fitting. See the
    # header comment and docs/ANALYSIS.md; for real hinting prefer
    # FreetypeFonts.
    class LightHintedFonts < AtlasFonts

      # One straight edge of the flattened outline, in bitmap pixels (y down).
      private struct Edge
        getter x0, y0, x1, y1 : Float64

        def initialize(@x0 : Float64, @y0 : Float64, @x1 : Float64, @y1 : Float64)
        end
      end

      def self.from_system(paths : Array(String)) : LightHintedFonts?
        paths.each do |path|
          next unless File.exists?(path)
          data = File.read(path)
          font = new(data)
          return font if font.loaded?
        end
        nil
      end

      @info : Void*
      @asc : Float64 = 0.0
      @desc : Float64 = 0.0 # negative, font units
      @cap_units : Float64 = 0.0    # cap height, font units (blue zones)
      @xheight_units : Float64 = 0.0

      def initialize(@font_data : String)
        super()
        # The heuristic keeps glyphs at their design positions (no
        # positional snap — see the X-hinting notes), which next to
        # FreeType's hinted advances reads tight; open the tracking up
        # slightly (0.22px tuned by eye against the FreeType tab).
        @letter_spacing = 0.22
        # stbtt does not copy the buffer: @font_data must outlive the font
        # (instance field, so it does).
        data = @font_data.to_unsafe
        @info = LibEguiCr.font_info_new(data, 0)
        @glyph_ids = {} of Int32 => Int32       # codepoint -> glyph id
        @advances = {} of Int32 => Int32        # glyph id -> advance (font units)
        @metrics = {} of Int32 => {Float64, Float64}
        @scales = {} of Int32 => Float64
        if loaded?
          asc = uninitialized Int32
          desc = uninitialized Int32
          gap = uninitialized Int32
          LibEguiCr.font_vmetrics(@info, pointerof(asc), pointerof(desc), pointerof(gap))
          @asc = asc.to_f64
          @desc = desc.to_f64
          @cap_units, @xheight_units = measure_zone_heights
        end
      end

      # Cap/x-height in font units — the blue-zone anchors for the
      # curve-extreme snap (augment_blue_zones). stb exposes no such
      # metrics, so they are measured from reference glyph outlines.
      private def measure_zone_heights : {Float64, Float64}
        cap = outline_ymax('I') || outline_ymax('Н') || 0.0
        xh = outline_ymax('x') || outline_ymax('о') || 0.0
        {cap, xh}
      end

      private def outline_ymax(ch : Char) : Float64?
        gid = glyph_index(ch.ord)
        return nil if gid == 0
        count = uninitialized Int32
        shape = LibEguiCr.glyph_shape(@info, gid, pointerof(count))
        return nil if count == 0 || shape.null?
        ymax = nil
        count.times do |i|
          v = shape[i]
          ymax = v.y.to_f64 if ymax.nil? || v.y > ymax.not_nil!
        end
        LibEguiCr.glyph_shape_free(@info, shape)
        ymax
      end

      def loaded? : Bool
        !@info.null?
      end

      # {ascender, descender} in px (descender negative), cached per size.
      def metrics_at(size : Float64) : {Float64, Float64}
        @metrics[size_key(size)] ||= begin
          s = scale_at(size)
          {@asc * s, @desc * s}
        end
      end

      def kern_px(prev_gid : Int32, gid : Int32, size : Float64) : Float64
        # Fractional, like the advances — the draw path snaps positions.
        LibEguiCr.glyph_kern(@info, prev_gid, gid).to_f64 * scale_at(size)
      end

      private def scale_at(size : Float64) : Float64
        @scales[size_key(size)] ||= begin
          scale = 0.0
          if loaded?
            # Same convention fontstash used: `size` pixels of (ascender -
            # descender) height, so widget layout doesn't shift.
            scale = LibEguiCr.scale_for_pixel_height(@info, size.to_f32).to_f64
          end
          scale
        end
      end

      def glyph_index(codepoint : Int32) : Int32
        @glyph_ids[codepoint] ||= LibEguiCr.font_find_glyph(@info, codepoint)
      end

      private def advance_of(gid : Int32) : Int32
        @advances[gid] ||= begin
          adv = uninitialized Int32
          lsb = uninitialized Int32
          LibEguiCr.glyph_hmetrics(@info, gid, pointerof(adv), pointerof(lsb))
          adv
        end
      end

      # --- stb outline --------------------------------------------------------

      VMOVE  = 1u8
      VLINE  = 2u8
      VCURVE = 3u8
      VCUBIC = 4u8

      # A contour element in font units, y up: line/curve to (x, y).
      private struct Cmd
        getter kind : UInt8
        getter x, y, cx, cy, cx1, cy1 : Float64

        def initialize(@kind : UInt8, @x : Float64, @y : Float64,
                       @cx : Float64 = 0.0, @cy : Float64 = 0.0,
                       @cx1 : Float64 = 0.0, @cy1 : Float64 = 0.0)
        end
      end

      # AtlasFonts: rasterize via stb outline + two-axis light hint.
      def build_glyph(gid : Int32, size : Float64) : Glyph
        s = scale_at(size)
        # Fractional advance: glyph POSITIONS are snapped to whole pixels
        # at draw time (round(pen + xoff), see paint_text), not advances —
        # rounding each advance accumulates error down a run
        # (sum(round) != round(sum)), drifting long words by several
        # pixels. This matches upstream egui's pixel snapping.
        adv = advance_of(gid).to_f64 * s

        count = uninitialized Int32
        shape = LibEguiCr.glyph_shape(@info, gid, pointerof(count))
        blank = Glyph.new(0, 0, 0, 0, 0, 0, 0, 0, 0.0, 0, adv)
        return blank if count == 0 || shape.null?

        contours = parse_contours(shape, count)
        LibEguiCr.glyph_shape_free(@info, shape)
        return blank if contours.empty?

        yhint = axis_hint_map(contours, s, axis_y: true)
        xhint = axis_hint_map(contours, s, axis_y: false)
        yhint = augment_blue_zones(contours, s, yhint)

        # Bounding box in pixel space (y up), after the hint remaps.
        x_min = y_min = Float64::MAX
        x_max = y_max = Float64::MIN
        each_outline_point(contours) do |x, y|
          px = remap(x * s, xhint)
          py = remap(y * s, yhint)
          x_min = {x_min, px}.min
          x_max = {x_max, px}.max
          y_min = {y_min, py}.min
          y_max = {y_max, py}.max
        end

        top = y_max.ceil          # bitmap top over the baseline (px)
        left = x_min.floor
        w = (x_max.ceil - left).to_i
        h = (top - y_min.floor).to_i

        if w > 0 && h > 0 && w <= atlas.size && h <= atlas.size
          edges = [] of Edge
          to_bitmap = ->(x : Float64, y : Float64) {
            {remap(x * s, xhint) - left, top - remap(y * s, yhint)}
          }
          contours.each do |contour|
            flatten_contour(contour, to_bitmap, edges)
          end
          cov = rasterize_edges(edges, w, h)
          if slot = atlas.alloc(w, h)
            ax, ay = slot
            atlas.blit(ax, ay, w, h, cov)
            inv = 1.0f32 / atlas.size.to_f32
            return Glyph.new(ax * inv, ay * inv, (ax + w) * inv, (ay + h) * inv,
              ax, ay, w, h, x_min, top.to_i, adv)
          end
          # Atlas full: drop the glyph, like fontstash does.
        end
        Glyph.new(0, 0, 0, 0, 0, 0, 0, 0, x_min, top.to_i, adv)
      end

      # vertices -> array of contours; each contour is {start point, cmds}.
      # The contour closes implicitly at its start point; the rasterizer's
      # winding math does not need the closing edge repeated.
      private def parse_contours(shape : LibEguiCr::StbVertex*, count : Int32)
        contours = [] of {Float64, Float64, Array(Cmd)}
        start_x = start_y = 0.0
        cmds = nil
        count.times do |i|
          v = shape[i]
          case v.type
          when VMOVE
            contours << {start_x, start_y, cmds} if cmds && !cmds.empty?
            start_x = v.x.to_f64
            start_y = v.y.to_f64
            cmds = [] of Cmd
          when VLINE
            (cmds ||= [] of Cmd) << Cmd.new(VLINE, v.x.to_f64, v.y.to_f64)
          when VCURVE
            (cmds ||= [] of Cmd) << Cmd.new(VCURVE, v.x.to_f64, v.y.to_f64,
              v.cx.to_f64, v.cy.to_f64)
          when VCUBIC
            (cmds ||= [] of Cmd) << Cmd.new(VCUBIC, v.x.to_f64, v.y.to_f64,
              v.cx.to_f64, v.cy.to_f64, v.cx1.to_f64, v.cy1.to_f64)
          end
        end
        contours << {start_x, start_y, cmds.not_nil!} if cmds && !cmds.empty?
        contours
      end

      # Every on-curve and control point, for the bounding box.
      private def each_outline_point(contours, &)
        contours.each do |_sx, _sy, cmds|
          yield _sx, _sy
          cmds.each do |cmd|
            yield cmd.x, cmd.y
            if cmd.kind == VCURVE
              yield cmd.cx, cmd.cy
            elsif cmd.kind == VCUBIC
              yield cmd.cx, cmd.cy
              yield cmd.cx1, cmd.cy1
            end
          end
        end
      end

      # The light-hint anchor map for a glyph (orig py -> snapped py).
      # Public for tests/debugging of the hinting heuristic.
      def light_hint_for(ch : Char, size : Float64) : Array({Float64, Float64})?
        return nil unless loaded?
        gid = glyph_index(ch.ord)
        count = uninitialized Int32
        shape = LibEguiCr.glyph_shape(@info, gid, pointerof(count))
        return nil if count == 0 || shape.null?
        contours = parse_contours(shape, count)
        LibEguiCr.glyph_shape_free(@info, shape)
        light_hint_map_y(contours, scale_at(size))
      end

      # The light-hint X anchor map for a glyph (orig px -> hinted px).
      # Public for tests/debugging of the hinting heuristic.
      def light_hint_x_for(ch : Char, size : Float64) : Array({Float64, Float64})?
        return nil unless loaded?
        gid = glyph_index(ch.ord)
        count = uninitialized Int32
        shape = LibEguiCr.glyph_shape(@info, gid, pointerof(count))
        return nil if count == 0 || shape.null?
        contours = parse_contours(shape, count)
        LibEguiCr.glyph_shape_free(@info, shape)
        axis_hint_map(contours, scale_at(size), axis_y: false)
      end

      private def light_hint_map_y(contours, scale : Float64)
        axis_hint_map(contours, scale, axis_y: true)
      end

      # --- light hint (both axes) ----------------------------------------------
      #
      # Collects straight edges perpendicular to the axis, long enough to
      # matter (the crossbars of e/H/A for Y; the stems of l/I/n for X),
      # clusters their positions in pixel space and snaps each cluster to
      # a whole pixel row (Y) or column (X) — the fallback's
      # approximation of FreeType's full grid-fitting: vertical stems
      # come out as crisp pixel columns, not AA-fuzzed bands. Returns a
      # monotone piecewise-linear map (orig px -> hinted px); nil =
      # nothing to snap.
      private def axis_hint_map(contours, scale : Float64,
                                axis_y : Bool) : Array({Float64, Float64})?
        # Approximate polygon in pixel space (curves through their control
        # points) — used to ray-cast the thickness of strokes whose second
        # edge is a curve, and to probe which side of an edge is interior.
        poly = [] of {Float64, Float64, Float64, Float64}
        edges = [] of {Float64, Float64} # {pos px, cross-axis mid} of edges
        contours.each do |sx, sy, cmds|
          fx, fy = sx, sy                 # previous point, font units
          px, py = sx * scale, sy * scale # previous point, pixels
          cmds.each do |cmd|
            x, y = cmd.x * scale, cmd.y * scale
            case cmd.kind
            when VLINE
              poly << {px, py, x, y}
              if axis_y
                if fy == cmd.y && (cmd.x - fx).abs * scale >= 1.5
                  edges << {py, (px + x) / 2.0}
                end
              elsif fx == cmd.x && (cmd.y - fy).abs * scale >= 1.5
                edges << {px, (py + y) / 2.0}
              end
            when VCURVE
              cx, cy = cmd.cx * scale, cmd.cy * scale
              poly << {px, py, cx, cy}
              poly << {cx, cy, x, y}
            when VCUBIC
              c0x, c0y = cmd.cx * scale, cmd.cy * scale
              c1x, c1y = cmd.cx1 * scale, cmd.cy1 * scale
              poly << {px, py, c0x, c0y}
              poly << {c0x, c0y, c1x, c1y}
              poly << {c1x, c1y, x, y}
            end
            fx, fy = cmd.x, cmd.y
            px, py = x, y
          end
        end
        return nil if edges.empty?

        # Stroke-search window, in pixels, scaled with the em size: a
        # stem is ~0.09*size px and a counter ~0.15*size, so 0.13*size
        # sits between them at every size. A fixed window (the 1.5/2.5px
        # this used to be) stops pairing strokes above ~20px — both
        # edges then snap to integers independently and large-size stems
        # render as flat, visibly thinner columns ('Е'/'Б' at 24-32px).
        win = scale * (@asc - @desc) * 0.13

        # Nonzero-winding probe: leftward ray for Y, upward ray for X.
        inside = ->(qx : Float64, qy : Float64) do
          w = 0
          if axis_y
            poly.each do |x0, y0, x1, y1|
              if (y0 <= qy) != (y1 <= qy)
                t = (qy - y0) / (y1 - y0)
                xc = x0 + t * (x1 - x0)
                w += xc <= qx ? (y1 > y0 ? 1 : -1) : 0
              end
            end
          else
            poly.each do |x0, y0, x1, y1|
              if (x0 <= qx) != (x1 <= qx)
                t = (qx - x0) / (x1 - x0)
                yc = y0 + t * (y1 - y0)
                w += yc <= qy ? (x1 > x0 ? 1 : -1) : 0
              end
            end
          end
          w != 0
        end

        # Nearest outline crossing of a ray cast along the axis.
        crossing = ->(qx : Float64, qy : Float64, pos_dir : Bool) do
          best = nil
          if axis_y
            poly.each do |x0, y0, x1, y1|
              next if x0 == x1
              if (x0 <= qx) != (x1 <= qx)
                yc = y0 + (qx - x0) / (x1 - x0) * (y1 - y0)
                if pos_dir && yc > qy + 0.01
                  best = yc if best.nil? || yc < best.not_nil!
                elsif !pos_dir && yc < qy - 0.01
                  best = yc if best.nil? || yc > best.not_nil!
                end
              end
            end
          else
            poly.each do |x0, y0, x1, y1|
              next if y0 == y1
              if (y0 <= qy) != (y1 <= qy)
                xc = x0 + (qy - y0) / (y1 - y0) * (x1 - x0)
                if pos_dir && xc > qx + 0.01
                  best = xc if best.nil? || xc < best.not_nil!
                elsif !pos_dir && xc < qx - 0.01
                  best = xc if best.nil? || xc > best.not_nil!
                end
              end
            end
          end
          best
        end

        edges.sort_by!(&.[0])
        # Cluster edges closer than half a pixel (one stroke drawn as
        # several segments lands on slightly different positions).
        clusters = [] of {Float64, Float64} # {pos px, cross-axis mid}
        acc_pos = edges[0][0]
        acc_mid = edges[0][1]
        cnt = 1
        (1...edges.size).each do |i|
          a, b = edges[i - 1][0], edges[i][0]
          if b - a <= 0.5
            acc_pos += edges[i][0]
            acc_mid += edges[i][1]
            cnt += 1
          else
            clusters << {acc_pos / cnt, acc_mid / cnt}
            acc_pos, acc_mid = edges[i][0], edges[i][1]
            cnt = 1
          end
        end
        clusters << {acc_pos / cnt, acc_mid / cnt}

        # Snap. Clusters within `win` are the two edges of ONE stroke:
        # quantize it as a unit — Y: lower edge to the nearest pixel and
        # thickness to `round(t)` (crossbars come out as solid pixel
        # rows); X: keep the position, quantize only the thickness. A
        # stroke whose second edge is a CURVE is measured by casting an
        # axis ray from the straight edge toward the interior, then
        # quantized the same way. Hairlines (<0.5px) are left unhinted.
        map = [] of {Float64, Float64}
        i = 0
        while i < clusters.size
          pos, mid = clusters[i]
          partner = clusters[i + 1]?
          if partner && partner[0] - pos < win
            lo, hi = pos, partner[0]
            i += 2
          else
            interior_neg = axis_y ? inside.call(mid, pos - 0.05)
                                  : inside.call(pos - 0.05, mid)
            opposite = crossing.call(axis_y ? mid : pos,
                                     axis_y ? pos : mid, !interior_neg)
            if opposite && (opposite - pos).abs < win
              lo, hi = interior_neg ? {opposite, pos} : {pos, opposite}
            else
              # X: an unpaired straight edge gets NO anchor. Snapping it
              # to a pixel column shifts that part of the glyph by up to
              # 0.5px while the rest stays put (piecewise-linear map =>
              # shear): 'a' leaned right, 'b' left, and the pair read as
              # merged. The pen is fractional anyway, so a glyph-local
              # integer snap never lands on a screen pixel column.
              i += 1
              next if !axis_y
              map << {pos, pos.round}
              next
            end
            i += 1
          end
          t = hi - lo
          if t >= 0.5
            if axis_y
              # Y: quantize thickness to whole pixels (min 1), rounded to
              # the nearest — crossbars come out as solid pixel rows.
              lo_q = lo.round.to_i
              t_q = {t.round.to_i, 1}.max
              map << {lo, lo_q.to_f64}
              map << {hi, (lo_q + t_q).to_f64}
            else
              # X: keep the stem at its natural position (no leading-edge
              # snap — see the unpaired-edge comment above), set its
              # thickness to the natural width but never below 1px solid
              # — FreeType grid-fits sub-pixel stems (0.5px at small
              # sizes) up to one full column. Plus a light stem darkening
              # (+0.15px, what FT's autohinter does): DejaVu's bytecode
              # widens stems when hinting (design 2.05px renders as ~2.3
              # at 24px), so raw natural width reads thin next to the
              # FreeType tab.
              map << {lo, lo}
              map << {hi, lo + {t, 1.0}.max + 0.15}
            end
          end
        end
        return nil if map.empty?

        fix_monotonic(map)

        # Pin the baseline (Y only): y=0 must map to 0. Without this,
        # glyphs whose strokes snapped up/down shift as a whole relative
        # to unhinted neighbours (e.g. 'e' sinking a pixel below 'o' —
        # every glyph with a crossbar carries its snap delta into the
        # baseline). X has no natural anchor.
        if axis_y
          map << {0.0, 0.0}
          map.sort_by!(&.[0])
        end
        map
      end

      # Keep the anchor sequence strictly increasing in snapped space:
      # push apart when the originals allow it, otherwise drop the later
      # anchor.
      private def fix_monotonic(map : Array({Float64, Float64})) : Nil
        map.sort_by!(&.[0])
        k = 1
        while k < map.size
          o, s = map[k]
          po, ps = map[k - 1]
          if s <= ps
            if o - po >= 1.5
              map[k] = {o, ps + 1}
              k += 1
            else
              map.delete_at(k)
            end
          else
            k += 1
          end
        end
      end

      # Blue-zone snap for the Y extremes (what FreeType's blue zones do
      # with overshoot): the outline's topmost/bottommost points snap to
      # the nearest zone — baseline, x-height, cap height, measured from
      # the font itself — when within 0.7px, otherwise to the nearest
      # pixel row with a 0.25px inward bias. Without this, round glyphs
      # ('0'-'9', 'о', 'е') keep their ±0.5px overshoot and render 1-2px
      # taller than FreeType, with faint rows above/below the body.
      private def augment_blue_zones(contours, scale : Float64, ymap : Array({Float64,
                                                                                Float64})?) : Array({Float64, Float64})?
        y_min = y_max = nil
        each_outline_point(contours) do |_x, y|
          py = y * scale
          y_min = py if y_min.nil? || py < y_min.not_nil!
          y_max = py if y_max.nil? || py > y_max.not_nil!
        end
        return ymap if y_min.nil?
        y_min = y_min.not_nil!
        y_max = y_max.not_nil!
        map = ymap ? ymap.dup : [] of {Float64, Float64}
        zones = [0.0]
        zones << (@xheight_units * scale).round if @xheight_units > 0
        zones << (@cap_units * scale).round if @cap_units > 0
        # Skip only when an existing anchor already sits AT or BEYOND the
        # extreme (it governs that end); an anchor on this side but
        # closer to the baseline must not leave the overshoot unhinted
        # ('е' keeping a faint row below the baseline).
        unless map.any? { |o, _| o >= y_max - 0.01 && (o - y_max).abs < 0.75 }
          map << {y_max, zone_snap(y_max, zones) || (y_max - 0.25).round}
        end
        unless map.any? { |o, _| o <= y_min + 0.01 && (o - y_min).abs < 0.75 }
          map << {y_min, zone_snap(y_min, zones) || (y_min + 0.25).round}
        end
        return ymap if map.size == (ymap ? ymap.not_nil!.size : 0)
        map << {0.0, 0.0} # keep the baseline pinned
        fix_monotonic(map)
        map
      end

      private def zone_snap(v : Float64, zones : Array(Float64), tol = 0.7) : Float64?
        best = nil
        zones.each do |z|
          d = (v - z).abs
          best = z if d <= tol && (best.nil? || d < (v - best.not_nil!).abs)
        end
        best
      end

      # Piecewise-linear remap through the anchors (axis-agnostic).
      # Outside the outermost anchors the mapping is the identity — the
      # baseline anchor at 0 (Y) and the untouched overshoot regions keep
      # every glyph on the same baseline; only the distance between
      # snapped strokes flexes.
      private def remap(v : Float64, map : Array({Float64, Float64})?) : Float64
        return v unless map
        # Strict inequalities: the outermost anchors themselves must hit
        # the interpolation path (v == first[0] / v == last[0]), not the
        # identity branches — otherwise the first/last snapped edge never
        # moves (the top bar of 'г' staying unhinted while its underside
        # snapped, collapsing the bar).
        first = map[0]
        return v if v < first[0]
        last = map[-1]
        return v if v > last[0]
        (1...map.size).each do |i|
          a, b = map[i - 1], map[i]
          if v >= a[0] && v <= b[0]
            t = (v - a[0]) / {b[0] - a[0], 1e-9}.max
            return a[1] + t * (b[1] - a[1])
          end
        end
        v
      end

      # --- flatten + rasterize --------------------------------------------------

      FLAT_TOL = 0.1  # px, curve flatteness tolerance
      MAX_DEPTH = 10

      # Walk a contour, flattening curves, emitting bitmap-space edges (y
      # down, origin at the bitmap top-left).
      private def flatten_contour(contour, to_bitmap, edges : Array(Edge))
        sx, sy, cmds = contour
        px, py = to_bitmap.call(sx, sy)
        cmds.each do |cmd|
          x, y = to_bitmap.call(cmd.x, cmd.y)
          case cmd.kind
          when VLINE
            edges << Edge.new(px, py, x, y)
          when VCURVE
            cx, cy = to_bitmap.call(cmd.cx, cmd.cy)
            flatten_quadratic(px, py, cx, cy, x, y, 0, edges)
          when VCUBIC
            c0x, c0y = to_bitmap.call(cmd.cx, cmd.cy)
            c1x, c1y = to_bitmap.call(cmd.cx1, cmd.cy1)
            flatten_cubic(px, py, c0x, c0y, c1x, c1y, x, y, 0, edges)
          end
          px, py = x, y
        end
      end

      private def flat?(x0, y0, cx, cy, x1, y1) : Bool
        mx = (x0 + x1) / 2.0
        my = (y0 + y1) / 2.0
        dx = cx - mx
        dy = cy - my
        dx * dx + dy * dy <= FLAT_TOL * FLAT_TOL
      end

      private def flatten_quadratic(x0, y0, cx, cy, x1, y1, depth, out edges : Array(Edge))
        unless depth >= MAX_DEPTH || flat?(x0, y0, cx, cy, x1, y1)
          # de Casteljau split at t = 0.5
          ax = (x0 + cx) / 2.0
          ay = (y0 + cy) / 2.0
          bx = (cx + x1) / 2.0
          by = (cy + y1) / 2.0
          mx = (ax + bx) / 2.0
          my = (ay + by) / 2.0
          flatten_quadratic(x0, y0, ax, ay, mx, my, depth + 1, edges)
          flatten_quadratic(mx, my, bx, by, x1, y1, depth + 1, edges)
          return
        end
        edges << Edge.new(x0, y0, x1, y1)
      end

      private def flatten_cubic(x0, y0, c0x, c0y, c1x, c1y, x1, y1, depth, out edges : Array(Edge))
        if depth >= MAX_DEPTH
          edges << Edge.new(x0, y0, x1, y1)
          return
        end
        # flat when both controls sit near the chord
        m0x = (x0 + x1) / 2.0
        m0y = (y0 + y1) / 2.0
        d0 = (c0x - m0x) * (c0x - m0x) + (c0y - m0y) * (c0y - m0y)
        d1 = (c1x - m0x) * (c1x - m0x) + (c1y - m0y) * (c1y - m0y)
        unless d0 <= FLAT_TOL * FLAT_TOL && d1 <= FLAT_TOL * FLAT_TOL
          # split at t = 0.5
          ax = (x0 + c0x) / 2.0
          ay = (y0 + c0y) / 2.0
          bx = (c0x + c1x) / 2.0
          by = (c0y + c1y) / 2.0
          cx = (c1x + x1) / 2.0
          cy = (c1y + y1) / 2.0
          abx = (ax + bx) / 2.0
          aby = (ay + by) / 2.0
          bcx = (bx + cx) / 2.0
          bcy = (by + cy) / 2.0
          mx = (abx + bcx) / 2.0
          my = (aby + bcy) / 2.0
          flatten_cubic(x0, y0, ax, ay, abx, aby, mx, my, depth + 1, edges)
          flatten_cubic(mx, my, bcx, bcy, cx, cy, x1, y1, depth + 1, edges)
          return
        end
        edges << Edge.new(x0, y0, x1, y1)
      end

      SS = 4 # supersampling per axis (16 samples/pixel)

      # Nonzero-winding rasterizer: for every sample row, sweep crossings
      # left-to-right keeping a winding prefix; a sample is inside where the
      # winding is nonzero. Coverage = inside samples / SS^2, then the
      # upstream contrast curve 2c - c^2 (bolder edges, dark-mode default).
      private def rasterize_edges(edges : Array(Edge), w : Int32, h : Int32) : Bytes
        counts = Array(Int32).new(w * h, 0)
        total = SS * SS
        h.times do |py|
          SS.times do |sr|
            sy = py + (sr + 0.5) / SS
            crossings = [] of {Float64, Int32}
            edges.each do |e|
              y0, y1 = e.y0, e.y1
              next if y0 == y1
              if (y0 <= sy < y1) || (y1 <= sy < y0)
                t = (sy - y0) / (y1 - y0)
                crossings << {e.x0 + t * (e.x1 - e.x0), y1 > y0 ? 1 : -1}
              end
            end
            next if crossings.empty?
            crossings.sort_by!(&.[0])
            wind = 0
            ci = 0
            row = py * w
            w.times do |px|
              SS.times do |sc|
                sx = px + (sc + 0.5) / SS
                while ci < crossings.size && crossings[ci][0] <= sx
                  wind += crossings[ci][1]
                  ci += 1
                end
                counts[row + px] += 1 if wind != 0
              end
            end
          end
        end
        Bytes.new(w * h) do |i|
          c = counts[i].to_f64 / total
          ((2.0 * c - c * c) * 255.0).round.to_u8
        end
      end

    end

    # --- atlas (shared by the font backends) -----------------------------------

    # 2048² so retina (2x) rasterizations — 4x the area — still fit
    # alongside the point-size copies the measure path bakes.
    ATLAS_SIZE = 2048

    # RGBA8 glyph atlas with shelf packing. RGB is white; alpha is the
    # glyph coverage — the draw path multiplies by the text color.
    class GlyphAtlas
      getter size : Int32
      getter view_id = 0_u32
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
