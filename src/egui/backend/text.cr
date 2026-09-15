# Crystal text stack. This file holds the glyph-atlas infrastructure
# shared by the two font backends, plus the fallback rasterizer:
#
#   * AtlasFonts — the `Egui::Fonts` base: a shared 1024² RGBA atlas
#     (white RGB, coverage alpha), a {glyph id, size} glyph cache and one
#     walk (fractional advances + kerning) used by both measure and draw.
#     Draw-side, glyph quads snap to whole screen pixels.
#   * LightHintedFonts — fallback rasterizer: stb_truetype outlines
#     (exposed by the shim) with a Crystal-side light Y-hint before 4x4
#     supersampled scanline conversion — a heuristic port of upstream
#     egui's "sharper text" work. Used when FreeType is unavailable.
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
        text.each_char do |ch|
          gid = glyph_index(ch.ord)
          pen += kern_px(prev, gid, size) if prev > 0
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

      # Rasterize every glyph a text command needs. Called before the render
      # pass: sg_update_image is illegal inside a pass, so the atlas must be
      # uploaded first (see flush).
      def touch(cmd : Egui::TextCmd) : Nil
        walk(cmd.text, cmd.size) { |_, _| }
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
    # Y-hint (snap horizontal strokes to pixel rows) before scanline
    # conversion. See the header comment and docs/ANALYSIS.md; for real
    # hinting prefer FreetypeFonts.
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

      def initialize(@font_data : String)
        super()
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
        end
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

      # AtlasFonts: rasterize via stb outline + light Y-hint.
      def build_glyph(gid : Int32, size : Float64) : Glyph
        s = scale_at(size)
        adv = advance_of(gid).to_f64 * s

        count = uninitialized Int32
        shape = LibEguiCr.glyph_shape(@info, gid, pointerof(count))
        blank = Glyph.new(0, 0, 0, 0, 0, 0, 0, 0, 0.0, 0, adv)
        return blank if count == 0 || shape.null?

        contours = parse_contours(shape, count)
        LibEguiCr.glyph_shape_free(@info, shape)
        return blank if contours.empty?

        hint = light_hint_map(contours, s)

        # Bounding box in pixel space (y up), after the hint remap.
        x_min = y_min = Float64::MAX
        x_max = y_max = Float64::MIN
        each_outline_point(contours) do |x, y|
          px = x * s
          py = remap_y(y * s, hint)
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
            {x * s - left, top - remap_y(y * s, hint)}
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
        light_hint_map(contours, scale_at(size))
      end

      # Rasterized coverage bitmap as text (debug/tests).
      def debug_bitmap(ch : Char, size : Float64) : Nil
        g = glyph(glyph_index(ch.ord), size)
        puts "#{ch.inspect}: w=#{g.w} h=#{g.h} ytop=#{g.ytop} adv=#{g.advance.round(2)}"
        return if g.w == 0
        cov = atlas.debug_region(g)
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

      # --- light Y-hint --------------------------------------------------------
      #
      # Collects straight horizontal edges wide enough to matter (the
      # crossbars of e/H/A, stem tops and bottoms), clusters their pixel Ys
      # and snaps each cluster to a whole row. Returns a monotone
      # piecewise-linear map (orig py -> hinted py); nil = nothing to snap.
      private def light_hint_map(contours, scale : Float64) : Array({Float64, Float64})?
        # Approximate polygon in pixel space (curves through their control
        # points) — used to ray-cast the thickness of strokes whose second
        # edge is a curve, and to probe which side of an edge is interior.
        poly = [] of {Float64, Float64, Float64, Float64}
        edges = [] of {Float64, Float64} # {y px, x mid} of horizontal edges
        contours.each do |sx, sy, cmds|
          fx, fy = sx, sy                 # previous point, font units
          px, py = sx * scale, sy * scale # previous point, pixels
          cmds.each do |cmd|
            x, y = cmd.x * scale, cmd.y * scale
            case cmd.kind
            when VLINE
              poly << {px, py, x, y}
              if fy == cmd.y && (cmd.x - fx).abs * scale >= 1.5
                edges << {py, (px + x) / 2.0}
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

        # Nonzero-winding probe (leftward ray).
        inside = ->(qx : Float64, qy : Float64) do
          w = 0
          poly.each do |x0, y0, x1, y1|
            if (y0 <= qy) != (y1 <= qy)
              t = (qy - y0) / (y1 - y0)
              xc = x0 + t * (x1 - x0)
              w += xc <= qx ? (y1 > y0 ? 1 : -1) : 0
            end
          end
          w != 0
        end

        # Nearest outline crossing of a vertical ray from (qx, qy).
        crossing = ->(qx : Float64, qy : Float64, up : Bool) do
          best = nil
          poly.each do |x0, y0, x1, y1|
            next if x0 == x1
            if (x0 <= qx) != (x1 <= qx)
              yc = y0 + (qx - x0) / (x1 - x0) * (y1 - y0)
              if up && yc > qy + 0.01
                best = yc if best.nil? || yc < best.not_nil!
              elsif !up && yc < qy - 0.01
                best = yc if best.nil? || yc > best.not_nil!
              end
            end
          end
          best
        end

        edges.sort_by!(&.[0])
        # Cluster edges closer than half a pixel (one stroke drawn as
        # several segments lands on slightly different Ys).
        clusters = [] of {Float64, Float64} # {y px, x mid}
        acc_y = edges[0][0]
        acc_x = edges[0][1]
        cnt = 1
        (1...edges.size).each do |i|
          a, b = edges[i - 1][0], edges[i][0]
          if b - a <= 0.5
            acc_y += edges[i][0]
            acc_x += edges[i][1]
            cnt += 1
          else
            clusters << {acc_y / cnt, acc_x / cnt}
            acc_y, acc_x = edges[i][0], edges[i][1]
            cnt = 1
          end
        end
        clusters << {acc_y / cnt, acc_x / cnt}

        # Snap. Clusters closer than 1.5px are the two edges of ONE
        # stroke: quantize it as a unit — lower edge to the nearest row,
        # thickness to ceil(t) (min 1px). A ~1.1px stroke must not
        # collapse to a single hairline row while the unhinted vertical
        # stem next to it keeps ~1.5px of apparent width (the top bar of
        # Cyrillic 'г' looking emaciated next to its own stem). A stroke
        # whose second edge is a CURVE (also 'г') is measured by casting a
        # vertical ray from the straight edge toward the interior, then
        # quantized the same way. Hairlines (<0.5px) are left unhinted.
        map = [] of {Float64, Float64}
        i = 0
        while i < clusters.size
          y, xmid = clusters[i]
          partner = clusters[i + 1]?
          if partner && partner[0] - y < 1.5
            lo, hi = y, partner[0]
            i += 2
          else
            interior_below = inside.call(xmid, y - 0.05)
            opposite = crossing.call(xmid, y, !interior_below)
            if opposite && (opposite - y).abs < 2.5
              lo, hi = interior_below ? {opposite, y} : {y, opposite}
            else
              map << {y, y.round}
              i += 1
              next
            end
            i += 1
          end
          t = hi - lo
          if t >= 0.5
            # Stroke-thickness quantization: plain ceil(), min 1px. (A
            # bolder rule — anything above 0.75px to 2px — made every
            # small horizontal stroke look fat; this backend is now only
            # the fallback anyway, see FreetypeFonts for real hinting.)
            t_q = {t.ceil.to_i, 1}.max
            lo_q = lo.round.to_i
            hi_q = lo_q + t_q
            map << {lo, lo_q.to_f64}
            map << {hi, hi_q.to_f64}
          end
        end
        return nil if map.empty?

        # Leftover interactions (lone edges next to pairs) can break the
        # monotonicity of the snapped sequence: push apart when the
        # originals are far enough, otherwise drop the later anchor.
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

        # Pin the baseline: y=0 must map to 0. Without this, glyphs whose
        # strokes snapped up/down shift as a whole relative to unhinted
        # neighbours (e.g. 'e' sinking a pixel below 'o' — every glyph
        # with a crossbar carries its snap delta into the baseline).
        map << {0.0, 0.0}
        map.sort_by!(&.[0])
        map
      end

      # Piecewise-linear remap through the anchors. Outside the outermost
      # anchors the mapping is the identity — the baseline anchor at 0 and
      # the untouched cap/overshoot region keep every glyph on the same
      # baseline; only the distance between snapped strokes flexes.
      private def remap_y(y : Float64, map : Array({Float64, Float64})?) : Float64
        return y unless map
        # Strict inequalities: the outermost anchors themselves must hit
        # the interpolation path (y == first[0] / y == last[0]), not the
        # identity branches — otherwise the first/last snapped edge never
        # moves (the top bar of 'г' staying unhinted while its underside
        # snapped, collapsing the bar).
        first = map[0]
        return y if y < first[0]
        last = map[-1]
        return y if y > last[0]
        (1...map.size).each do |i|
          a, b = map[i - 1], map[i]
          if y >= a[0] && y <= b[0]
            t = (y - a[0]) / {b[0] - a[0], 1e-9}.max
            return a[1] + t * (b[1] - a[1])
          end
        end
        y
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

    ATLAS_SIZE = 1024

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

      # Create/update the GPU texture. Outside of a render pass only.
      def flush : Nil
        return if @view_id != 0 && !@dirty
        if @view_id == 0
          @view_id = LibEguiCr.atlas_create(@size, @size, @rgba)
        else
          LibEguiCr.atlas_update(@size, @size, @rgba)
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
