# A minimal SVG viewer widget — no external dependencies for the
# vector path: SVG source is parsed once (a small subset) and painted
# as vector primitives through the regular Painter commands, crisp at
# any size. On a GPU backend, #paint instead replays a cached
# software-rasterized texture per size (see #paint and #rasterize —
# the font-atlas approach applied to vector art). The bake itself
# goes through an EXTERNAL rasterizer when one is linked — NanoSVG
# (backend/nanosvg.cr) brings real polygon fills, arbitrary-angle
# gradients and nested transforms — with the built-in #rasterize as
# the fallback (the freetype.cr/text.cr split).
#
# Supported subset (enough for logo-style artwork like
# assets/icon.svg and for stroke icon sets like Lucide): `<svg>`
# width/height/viewBox, `<defs>` with `<linearGradient>` + `<stop>`,
# and the shape elements `<rect>` (incl. `rx` rounding), `<circle>`,
# `<line>`, `<text>` (fill, stroke, stroke-width, font-size,
# text-anchor, dominant-baseline), `<path>`, `<polyline>` and
# `<polygon>`. The viewBox is fitted into the widget rect with the
# aspect preserved and centered (like `<img>` object-fit).
#
# Icon-set conventions: paint attributes on the root `<svg>` are
# inherited by every shape (Lucide/Tabler put `fill="none"
# stroke="currentColor" stroke-width="2"` on the root and nothing on
# the shapes), and `currentColor` resolves to the `current_color`
# parse argument (BLACK by default — `Icon.from_file` passes its
# `tint:` there).
#
# Painter limitations shape the mapping: gradients are per-vertex
# vertical only (`RectCmd#fill2`), so a vertical gradient maps to
# fill→fill2 and any other orientation falls back to the blended
# midpoint; circles/lines/text take flat colors. Paths are flattened
# to polylines (curves subdivided, arcs sampled from the center
# parameterization) and STROKED as line segments — a filled path has
# no polygon tessellation in the backend yet, so it degrades to
# stroking its outline with the fill color.

module Egui
  class Svg
    include Widget

    # Intrinsic viewBox: min corner + extent in user units.
    struct ViewBox
      getter min_x : Float64
      getter min_y : Float64
      getter width : Float64
      getter height : Float64

      def initialize(@min_x, @min_y, @width, @height)
      end
    end

    # Two-stop linear gradient (`x1..y2` decide the orientation flag).
    struct LinearGradient
      getter id : String
      getter first : Color32
      getter last : Color32
      getter vertical : Bool

      def initialize(@id, @first, @last, @vertical)
      end
    end

    alias Paint = Color32 | LinearGradient

    struct RectShape
      getter x : Float64
      getter y : Float64
      getter w : Float64
      getter h : Float64
      getter rx : Float64
      getter fill : Paint?
      getter stroke : Color32?
      getter stroke_width : Float64

      def initialize(@x, @y, @w, @h, @rx, @fill, @stroke, @stroke_width)
      end
    end

    struct CircleShape
      getter cx : Float64
      getter cy : Float64
      getter r : Float64
      getter fill : Paint?
      getter stroke : Color32?
      getter stroke_width : Float64

      def initialize(@cx, @cy, @r, @fill, @stroke, @stroke_width)
      end
    end

    struct LineShape
      getter x1 : Float64
      getter y1 : Float64
      getter x2 : Float64
      getter y2 : Float64
      getter width : Float64
      getter color : Color32

      def initialize(@x1, @y1, @x2, @y2, @width, @color)
      end
    end

    struct TextShape
      getter x : Float64
      getter y : Float64
      getter size : Float64
      getter text : String
      getter color : Color32
      getter anchor : Symbol # text-anchor: :start / :middle / :end
      # dominant-baseline: true = `central` (y is the glyph-box center),
      # false = alphabetic (y is the baseline).
      getter central : Bool

      def initialize(@x, @y, @size, @text, @color, @anchor, @central)
      end
    end

    alias Shape = RectShape | CircleShape | LineShape | TextShape | PolylineShape

    # A flattened outline: one `<path>` subpath or a whole
    # `<polyline>`/`<polygon>`. User-unit points, stroked as painter
    # line segments (see the class docs for the fill degradation).
    # `round_caps`/`round_joins` carry the root/shape
    # `stroke-linecap`/`stroke-linejoin` = `round` — segments are
    # individual quads, so #paint back-fills corners and open ends
    # with small discs to reproduce the round look (stroke icon sets
    # like Lucide are drawn with round everything).
    struct PolylineShape
      getter points : Array(Vec2)
      getter? closed : Bool
      getter stroke : Color32?
      getter stroke_width : Float64
      getter? round_caps : Bool
      getter? round_joins : Bool

      def initialize(@points, @closed, @stroke, @stroke_width,
                     @round_caps = false, @round_joins = false)
      end
    end

    # Square widget by default — the common logo shape.
    property size : Vec2

    @shapes : Array(Shape)
    @view : ViewBox
    # Kept for the raster-texture cache key (see #paint): the raw
    # source and the tint `currentColor` resolved to — two Svgs with
    # the same source/tint share one baked texture whatever their
    # instance identity (Icon memoizes parses, but `ui.svg` builds a
    # fresh Svg every frame).
    @source : String
    @current_color : Color32

    # `current_color` resolves `currentColor` in the source (icon
    # sets are monochrome; pass the theme fg here).
    def initialize(source : String, @size : Vec2 = Vec2.new(128.0, 128.0),
                   current_color : Color32 = BLACK)
      @source = source
      @current_color = current_color
      @shapes, @view = Svg.parse(source, current_color)
    end

    # From a file on disk (e.g. assets/icon.svg).
    def self.load(path : String, size : Vec2 = Vec2.new(128.0, 128.0)) : self
      new(File.read(path), size)
    end

    def ui(ui : Ui) : Response
      rect = ui.allocate_at_least(@size)
      paint(ui, rect)
      ui.interact(rect, ui.next_widget_id, Sense.none)
    end

    # Fit the viewBox into `rect` (aspect preserved, centered) and
    # replay the shapes as painter commands.
    #
    # On a graphical backend (real TextureRegistry) this first routes
    # through the RASTER-TEXTURE CACHE — the font-atlas approach
    # applied to vector art: the whole Svg is software-rasterized ONCE
    # per (source, tint, pixel size) into an RGBA texture with
    # analytic anti-aliasing, then replayed as ONE textured quad per
    # frame. A size change re-bakes (like a font atlas rebakes per
    # ppem); MAX_RASTER_SIZES bounds the bakes per icon so a size
    # slider evicts the oldest instead of accumulating. Headless (no
    # GPU) keeps the direct vector path so specs still assert on
    # LineCmd/CircleCmd geometry.
    MAX_RASTER_SIZES = 8
    # Global budget across ALL Svgs (GPU memory + the sokol image
    # pool): past it the oldest bake is destroyed FIFO — scrolled-away
    # icons re-bake on return (~a millisecond each), memory stays
    # bounded whatever the app does. Sized to hold the full lucide
    # set (~1850) plus headroom: sokol frees destroyed image slots a
    # few frames LATE, so a budget below the working set makes rapid
    # eviction churn exhaust the pool even with the cap respected
    # (the LUCIDE_NO_CULL stress lesson).
    MAX_RASTER_TEXTURES = 2000
    @@raster_cache = {} of {String, Color32} =>
      Array(Tuple(Int32, Int32, UInt64))
    @@raster_order = [] of Tuple({String, Color32}, UInt64)

    # Primary rasterizer for the texture bake: (source, tint, w, h) →
    # straight-alpha RGBA8 bytes, or nil to use the built-in
    # #rasterize. backend/nanosvg.cr sets it to NanoSVG when the
    # native backend is linked; headless builds leave it nil — the
    # freetype.cr/text.cr primary/fallback split for vector art.
    class_property external_rasterizer : Proc(String, Color32, Int32,
      Int32, Bytes?) | ::Nil = nil

    def paint(ui : Ui, rect : Rect) : Nil
      Egui::Bench.span("Svg#paint") { paint_body(ui, rect) }
    end

    private def paint_body(ui : Ui, rect : Rect) : Nil
      painter = ui.painter
      scale = {rect.width / @view.width, rect.height / @view.height}.min

      if ui.ctx.textures.graphical?
        fit_w = @view.width * scale
        fit_h = @view.height * scale
        ppp = ui.ctx.pixels_per_point
        # Raster and quad are DERIVED from each other: bake at whole
        # physical pixels, then draw the quad at exactly that many
        # pixels, snapped to the pixel grid — a 1:1 texel-to-pixel
        # mapping samples without resampling blur. This is why fonts
        # are crisp: they rasterize at their exact ppem and land
        # 1:1. (A quad of 44.2 px sampling a 45-texel raster smears
        # every texel into its neighbor — the "soapy icon" look.)
        tw = {(fit_w * ppp).round.to_i, 1}.max
        th = {(fit_h * ppp).round.to_i, 1}.max
        if (id = raster_texture(ui.ctx.textures, tw, th)) != 0_u64
          qw = tw / ppp
          qh = th / ppp
          cx = rect.left + rect.width / 2.0
          cy = rect.top + rect.height / 2.0
          x0 = (((cx - qw / 2.0) * ppp).round) / ppp
          y0 = (((cy - qh / 2.0) * ppp).round) / ppp
          painter.image(Rect.from_min_size(Pos2.new(x0, y0),
            Vec2.new(qw, qh)), id)
          return
        end
        # texture upload failed — fall through to the vector path
      end

      ox = rect.left + (rect.width - @view.width * scale) / 2.0 - @view.min_x * scale
      oy = rect.top + (rect.height - @view.height * scale) / 2.0 - @view.min_y * scale

      @shapes.each do |shape|
        case shape
        when RectShape
          r = Rect.from_min_size(Pos2.new(ox + shape.x * scale, oy + shape.y * scale),
            Vec2.new(shape.w * scale, shape.h * scale))
          fill = nil
          fill2 = nil
          if (g = shape.fill.as?(LinearGradient))
            if g.vertical
              fill = g.first
              fill2 = g.last
            else
              fill = blend(g.first, g.last)
            end
          elsif (c = shape.fill.as?(Color32))
            fill = c
          end
          painter.rect(r, shape.rx * scale, fill: fill, fill2: fill2,
            stroke_color: shape.stroke, stroke_width: shape.stroke_width * scale)
        when CircleShape
          center = Pos2.new(ox + shape.cx * scale, oy + shape.cy * scale)
          fill = nil
          if (g = shape.fill.as?(LinearGradient))
            fill = blend(g.first, g.last)
          elsif (c = shape.fill.as?(Color32))
            fill = c
          end
          painter.circle(center, shape.r * scale, fill: fill,
            stroke: shape.stroke, stroke_width: shape.stroke_width * scale)
        when LineShape
          painter.line(Pos2.new(ox + shape.x1 * scale, oy + shape.y1 * scale),
            Pos2.new(ox + shape.x2 * scale, oy + shape.y2 * scale),
            shape.width * scale, shape.color)
        when TextShape
          size = shape.size * scale
          x = ox + shape.x * scale
          # painter.text anchors at the LEFT-CENTER of the text box;
          # SVG anchors x at start/middle/end of the line.
          if shape.anchor != :start
            w = ui.ctx.fonts.measure(shape.text, size).x
            x -= shape.anchor == :middle ? w / 2.0 : w
          end
          # central: y is the center already; alphabetic: center sits
          # roughly 0.35 em above the baseline.
          y = oy + shape.y * scale - (shape.central ? 0.0 : 0.35 * size)
          painter.text(Pos2.new(x, y), shape.text, size, shape.color)
        when PolylineShape
          next unless (s = shape.stroke) && shape.stroke_width > 0.0
          pts = shape.points.map { |p|
            Pos2.new(ox + p.x * scale, oy + p.y * scale) }
          pts << pts.first if shape.closed?
          # Half a point keeps a 512-unit logo scaled far down from
          # losing its hairline strokes entirely.
          w = {shape.stroke_width * scale, 0.5}.max
          (1...pts.size).each do |i|
            painter.line(pts[i - 1], pts[i], w, s)
          end
          # Round joins/caps: every segment is its own rectangle quad,
          # so corners notch and open ends butt square — a disc at
          # each REAL corner (near-collinear flattened-curve vertices
          # skip theirs, they already overlap) and at the two ends
          # fills the gap.
          if shape.round_caps? || shape.round_joins?
            r = w / 2.0
            last = pts.size - 1
            pts.each_with_index do |p, i|
              if (shape.round_caps? && (i.zero? || i == last)) ||
                 (shape.round_joins? && i > 0 && i < last &&
                  corner?(pts[i - 1], p, pts[i + 1]))
                painter.circle(p, r, fill: s)
              end
            end
          end
        end
      end
    end

    # Cache lookup/bake for #paint's textured path. Keyed by
    # (source, tint) with per-size entries — the "invalidate on size
    # change" contract, same as the font atlas per-ppem rebake.
    private def raster_texture(registry : TextureRegistry,
                               w_px : Int32, h_px : Int32) : UInt64
      key = {@source, @current_color}
      sizes = (@@raster_cache[key] ||= [] of Tuple(Int32, Int32, UInt64))
      sizes.each do |tw, th, id|
        if !id.zero? && tw == w_px && th == h_px
          Egui::Bench.count("svg.raster.hit")
          return id
        end
      end
      Egui::Bench.count("svg.raster.miss")
      pixels = if (raster = Svg.external_rasterizer) &&
                  (bytes = raster.call(@source, @current_color, w_px, h_px))
        Egui::Bench.count("svg.raster.external")
        bytes
      else
        Egui::Bench.count("svg.raster.fallback")
        rasterize(w_px, h_px)
      end
      id = Egui::Bench.span("Svg#rasterize") do
        registry.register_rgba(w_px, h_px, pixels)
      end
      return 0_u64 if id.zero?
      if sizes.size >= MAX_RASTER_SIZES
        old = sizes.shift?
        if old && !old[2].zero?
          registry.destroy_later(old[2])
          @@raster_order.reject! { |_, oid| oid == old[2] }
        end
      end
      while @@raster_order.size >= MAX_RASTER_TEXTURES
        old_key, old_id = @@raster_order.shift
        if (arr = @@raster_cache[old_key]?)
          arr.reject! { |_, _, oid| oid == old_id }
          @@raster_cache.delete(old_key) if arr.empty?
        end
        # destroy_later, not destroy: an earlier cell this frame may
        # already have emitted an ImageCmd for this id (see
        # TextureRegistry#destroy_later).
        registry.destroy_later(old_id) unless old_id.zero?
      end
      sizes << {w_px, h_px, id}
      @@raster_order << {key, id}
      id
    end

    # Software-rasterize the shapes into a w×h RGBA8 bitmap (straight
    # alpha) — the FALLBACK bake path (NanoSVG is the primary; see
    # .external_rasterizer): per-pixel analytic coverage from the
    # signed distance to each shape's edge (cov = half-extent + 0.5 −
    # dist), so edges anti-alias with a one-pixel ramp — no MSAA, no
    # supersampling. Round caps/joins come free from the same
    # distance fields (segment + disc unions). TextShape is skipped
    # (needs the font stack; #paint still draws it live) — icon sets
    # don't use SVG <text>.
    def rasterize(w : Int32, h : Int32) : Bytes
      buf = Bytes.new(w * h * 4, 0)
      scale = {w.to_f64 / @view.width, h.to_f64 / @view.height}.min
      ox = (w - @view.width * scale) / 2.0 - @view.min_x * scale
      oy = (h - @view.height * scale) / 2.0 - @view.min_y * scale

      @shapes.each do |shape|
        case shape
        when PolylineShape
          next unless (s = shape.stroke) && shape.stroke_width > 0.0
          hw = {shape.stroke_width * scale / 2.0, 0.5}.max
          pts = shape.points.map { |p| {ox + p.x * scale, oy + p.y * scale} }
          pts << pts.first if shape.closed?
          (1...pts.size).each do |i|
            a, b = pts[i - 1], pts[i]
            stamp_segment(buf, w, h, a[0], a[1], b[0], b[1], hw, s)
          end
          if shape.round_caps? || shape.round_joins?
            last = pts.size - 1
            pts.each_with_index do |p, i|
              if (shape.round_caps? && (i.zero? || i == last)) ||
                 (shape.round_joins? && i > 0 && i < last &&
                  raster_corner?(pts[i - 1], p, pts[i + 1]))
                stamp_disc(buf, w, h, p[0], p[1], hw, s)
              end
            end
          end
        when LineShape
          hw = {shape.width * scale / 2.0, 0.5}.max
          stamp_segment(buf, w, h, ox + shape.x1 * scale, oy + shape.y1 * scale,
            ox + shape.x2 * scale, oy + shape.y2 * scale, hw, shape.color)
        when CircleShape
          cx = ox + shape.cx * scale
          cy = oy + shape.cy * scale
          r = shape.r * scale
          if (c = flat_fill(shape.fill))
            stamp_disc(buf, w, h, cx, cy, r, c)
          end
          if (s = shape.stroke) && shape.stroke_width > 0.0
            stamp_ring(buf, w, h, cx, cy, r,
              {shape.stroke_width * scale / 2.0, 0.5}.max, s)
          end
        when RectShape
          stamp_round_rect(buf, w, h, ox + shape.x * scale, oy + shape.y * scale,
            shape.w * scale, shape.h * scale, shape.rx * scale,
            flat_fill(shape.fill), shape.stroke,
            shape.stroke_width > 0.0 ? {shape.stroke_width * scale / 2.0, 0.5}.max : 0.0)
        end
      end
      buf
    end

    # A gradient flattens to the blended midpoint (the raster has no
    # per-vertex gradient quads — the same degradation as a
    # non-vertical gradient in the vector path).
    private def flat_fill(fill : Paint?) : Color32?
      case f = fill
      when Color32 then f
      when LinearGradient then blend(f.first, f.last)
      end
    end

    private def put_pixel(buf : Bytes, w : Int32, x : Int32, y : Int32,
                          c : Color32, cov : Float64) : Nil
      a = (cov * 255.0).round.clamp(0.0, 255.0).to_u8
      i = (y * w + x) * 4
      # Topmost coverage wins: overlapping strokes at a join take the
      # max instead of additively saturating.
      return if a <= buf[i + 3]
      buf[i] = c.r
      buf[i + 1] = c.g
      buf[i + 2] = c.b
      buf[i + 3] = a
    end

    # Pixel-bbox clamp (Int32 has no #min/#max pair idiom).
    private def clamp_px(v : Int32, lo : Int32, hi : Int32) : Int32
      v < lo ? lo : (v > hi ? hi : v)
    end

    private def stamp_segment(buf : Bytes, w : Int32, h : Int32,
                              ax : Float64, ay : Float64,
                              bx : Float64, by : Float64,
                              hw : Float64, c : Color32) : Nil
      pad = hw + 1.0
      x0 = clamp_px(({ax, bx}.min - pad).floor.to_i, 0, w - 1)
      x1 = clamp_px(({ax, bx}.max + pad).ceil.to_i, 0, w - 1)
      y0 = clamp_px(({ay, by}.min - pad).floor.to_i, 0, h - 1)
      y1 = clamp_px(({ay, by}.max + pad).ceil.to_i, 0, h - 1)
      dx = bx - ax
      dy = by - ay
      len2 = dx * dx + dy * dy
      (y0..y1).each do |py|
        (x0..x1).each do |px|
          rx = px + 0.5 - ax
          ry = py + 0.5 - ay
          t = if len2 > 1e-12
                u = (rx * dx + ry * dy) / len2
                u < 0.0 ? 0.0 : (u > 1.0 ? 1.0 : u)
              else
                0.0
              end
          qx = t * dx - rx
          qy = t * dy - ry
          cov = hw + 0.5 - Math.sqrt(qx * qx + qy * qy)
          put_pixel(buf, w, px, py, c, cov) if cov > 0.0
        end
      end
    end

    private def stamp_disc(buf : Bytes, w : Int32, h : Int32,
                           cx : Float64, cy : Float64, r : Float64,
                           c : Color32) : Nil
      x0 = clamp_px((cx - r - 1.0).floor.to_i, 0, w - 1)
      x1 = clamp_px((cx + r + 1.0).ceil.to_i, 0, w - 1)
      y0 = clamp_px((cy - r - 1.0).floor.to_i, 0, h - 1)
      y1 = clamp_px((cy + r + 1.0).ceil.to_i, 0, h - 1)
      (y0..y1).each do |py|
        (x0..x1).each do |px|
          dx = px + 0.5 - cx
          dy = py + 0.5 - cy
          cov = r + 0.5 - Math.sqrt(dx * dx + dy * dy)
          put_pixel(buf, w, px, py, c, cov) if cov > 0.0
        end
      end
    end

    private def stamp_ring(buf : Bytes, w : Int32, h : Int32,
                           cx : Float64, cy : Float64, r : Float64,
                           hw : Float64, c : Color32) : Nil
      x0 = clamp_px((cx - r - hw - 1.0).floor.to_i, 0, w - 1)
      x1 = clamp_px((cx + r + hw + 1.0).ceil.to_i, 0, w - 1)
      y0 = clamp_px((cy - r - hw - 1.0).floor.to_i, 0, h - 1)
      y1 = clamp_px((cy + r + hw + 1.0).ceil.to_i, 0, h - 1)
      (y0..y1).each do |py|
        (x0..x1).each do |px|
          dx = px + 0.5 - cx
          dy = py + 0.5 - cy
          d = Math.sqrt(dx * dx + dy * dy)
          cov = hw + 0.5 - (d - r).abs
          put_pixel(buf, w, px, py, c, cov) if cov > 0.0
        end
      end
    end

    # Filled/stroked rounded rect through its signed distance field
    # (the iq sdRoundBox formulation, clamped radius included).
    private def stamp_round_rect(buf : Bytes, w : Int32, h : Int32,
                                 x : Float64, y : Float64, rw : Float64,
                                 rh : Float64, rr : Float64,
                                 fill : Color32?, stroke : Color32?,
                                 hw : Float64) : Nil
      rr = {rr, rw / 2.0, rh / 2.0, 0.0}.min
      cx = x + rw / 2.0
      cy = y + rh / 2.0
      hx = rw / 2.0 - rr
      hy = rh / 2.0 - rr
      x0 = clamp_px((x - hw - 1.0).floor.to_i, 0, w - 1)
      x1 = clamp_px((x + rw + hw + 1.0).ceil.to_i, 0, w - 1)
      y0 = clamp_px((y - hw - 1.0).floor.to_i, 0, h - 1)
      y1 = clamp_px((y + rh + hw + 1.0).ceil.to_i, 0, h - 1)
      (y0..y1).each do |py|
        (x0..x1).each do |px|
          qx = (px + 0.5 - cx).abs - hx
          qy = (py + 0.5 - cy).abs - hy
          ox = qx > 0.0 ? qx : 0.0
          oy = qy > 0.0 ? qy : 0.0
          d = (qx > qy ? qx : qy)
          d = d < 0.0 ? d : 0.0
          d += Math.sqrt(ox * ox + oy * oy) - rr
          if (f = fill)
            cov = 0.5 - d
            put_pixel(buf, w, px, py, f, cov) if cov > 0.0
          end
          if (s = stroke) && hw > 0.0
            cov = hw + 0.5 - d.abs
            put_pixel(buf, w, px, py, s, cov) if cov > 0.0
          end
        end
      end
    end

    # Raster twin of #corner?: near-collinear flattened-curve vertices
    # (~15° of straight) skip their join disc.
    private def raster_corner?(a : {Float64, Float64}, p : {Float64, Float64},
                               b : {Float64, Float64}) : Bool
      ax = p[0] - a[0]
      ay = p[1] - a[1]
      bx = b[0] - p[0]
      by = b[1] - p[1]
      la = Math.sqrt(ax * ax + ay * ay)
      lb = Math.sqrt(bx * bx + by * by)
      return false if la < 1e-9 || lb < 1e-9
      (ax * bx + ay * by) / (la * lb) < 0.966
    end

    # Is the bend at `p` a real corner? Near-collinear (within ~15°
    # of straight) is the flattened-curve case: the neighboring
    # segment quads already overlap, no join disc needed.
    private def corner?(prev : Pos2, p : Pos2, nxt : Pos2) : Bool
      ax = p.x - prev.x
      ay = p.y - prev.y
      bx = nxt.x - p.x
      by = nxt.y - p.y
      la = Math.sqrt(ax * ax + ay * ay)
      lb = Math.sqrt(bx * bx + by * by)
      return false if la < 1e-9 || lb < 1e-9
      (ax * bx + ay * by) / (la * lb) < 0.966
    end

    # -- parsing ----------------------------------------------------------

    # Parse `source` into (shapes, viewBox). Comments, the XML decl and
    # anything outside the supported tags are ignored.
    def self.parse(source : String,
                   current_color : Color32 = BLACK) : {Array(Shape), ViewBox}
      src = source.gsub(/<!--.*?-->/m, "").gsub(/<\?.*?\?>/, "")

      gradients = {} of String => LinearGradient
      src.scan(/<linearGradient\b([^>]*)>(.*?)<\/linearGradient>/m) do |m|
        gattrs = attrs(m[1])
        id = gattrs["id"]?
        colors = m[2].scan(/<stop\b([^>]*?)\/?>/).compact_map do |sm|
          color(attrs(sm[1])["stop-color"]?, current_color)
        end
        next unless id && !colors.empty?
        x1 = num(gattrs, "x1", 0.0)
        y1 = num(gattrs, "y1", 0.0)
        x2 = num(gattrs, "x2", 1.0)
        y2 = num(gattrs, "y2", 0.0)
        gradients[id] = LinearGradient.new(id, colors.first, colors.last,
          (y2 - y1).abs >= (x2 - x1).abs)
      end

      root = src.match(/<svg\b([^>]*)>/)
      root_attrs = root ? attrs(root[1]) : {} of String => String
      view = parse_view(root_attrs)

      # Icon-set inheritance: paint attributes on the root `<svg>`
      # (e.g. Lucide's `fill="none" stroke="currentColor"
      # stroke-width="2" stroke-linecap="round" stroke-linejoin="round"`)
      # are the defaults for every shape.
      root_fill = paint(root_attrs["fill"]?, gradients, current_color)
      root_stroke = color(root_attrs["stroke"]?, current_color)
      root_sw = num(root_attrs, "stroke-width", 1.0)
      root_caps = root_attrs["stroke-linecap"]? == "round"
      root_joins = root_attrs["stroke-linejoin"]? == "round"

      shapes = [] of Shape
      src.scan(/<rect\b([^>]*?)\/?>/) do |m|
        a = attrs(m[1])
        shapes << RectShape.new(num(a, "x", 0.0), num(a, "y", 0.0),
          num(a, "width", 0.0), num(a, "height", 0.0), num(a, "rx", 0.0),
          a["fill"]? ? paint(a["fill"], gradients, current_color) : root_fill,
          a["stroke"]? ? color(a["stroke"], current_color) : root_stroke,
          a["stroke-width"]? ? num(a, "stroke-width", 1.0) : root_sw)
      end
      src.scan(/<circle\b([^>]*?)\/?>/) do |m|
        a = attrs(m[1])
        shapes << CircleShape.new(num(a, "cx", 0.0), num(a, "cy", 0.0),
          num(a, "r", 0.0),
          a["fill"]? ? paint(a["fill"], gradients, current_color) : root_fill,
          a["stroke"]? ? color(a["stroke"], current_color) : root_stroke,
          a["stroke-width"]? ? num(a, "stroke-width", 1.0) : root_sw)
      end
      src.scan(/<line\b([^>]*?)\/?>/) do |m|
        a = attrs(m[1])
        shapes << LineShape.new(num(a, "x1", 0.0), num(a, "y1", 0.0),
          num(a, "x2", 0.0), num(a, "y2", 0.0),
          a["stroke-width"]? ? num(a, "stroke-width", 1.0) : root_sw,
          (a["stroke"]? ? color(a["stroke"], current_color) : root_stroke) || WHITE)
      end
      src.scan(/<text\b([^>]*)>(.*?)<\/text>/m) do |m|
        a = attrs(m[1])
        anchor = case a["text-anchor"]?
                 when "middle" then :middle
                 when "end"    then :end
                 else               :start
                 end
        fill = a["fill"]? ? color(a["fill"], current_color) : root_fill.as?(Color32)
        shapes << TextShape.new(num(a, "x", 0.0), num(a, "y", 0.0),
          num(a, "font-size", 16.0), m[2].strip,
          fill || BLACK, anchor,
          {"central", "middle"}.includes?(a["dominant-baseline"]?))
      end
      src.scan(/<path\b([^>]*?)\/?>/) do |m|
        a = attrs(m[1])
        next unless (d = a["d"]?)
        fill = a["fill"]? ? paint(a["fill"], gradients, current_color) : root_fill
        stroke = a["stroke"]? ? color(a["stroke"], current_color) : root_stroke
        # A filled, unstroked path degrades to stroking its outline
        # with the fill color (polygon fills are not in the backend).
        stroke ||= fill.as?(Color32)
        next unless stroke
        sw = a["stroke-width"]? ? num(a, "stroke-width", 1.0) : root_sw
        caps = (a["stroke-linecap"]? || (root_caps ? "round" : nil)) == "round"
        joins = (a["stroke-linejoin"]? || (root_joins ? "round" : nil)) == "round"
        parse_path(d).each do |pts, closed|
          shapes << PolylineShape.new(pts, closed, stroke, sw, caps, joins)
        end
      end
      src.scan(/<polyline\b([^>]*?)\/?>/) do |m|
        a = attrs(m[1])
        next unless (pts = parse_points(a["points"]?))
        stroke = a["stroke"]? ? color(a["stroke"], current_color) : root_stroke
        stroke ||= color(a["fill"]?, current_color)
        next unless stroke
        sw = a["stroke-width"]? ? num(a, "stroke-width", 1.0) : root_sw
        caps = (a["stroke-linecap"]? || (root_caps ? "round" : nil)) == "round"
        joins = (a["stroke-linejoin"]? || (root_joins ? "round" : nil)) == "round"
        shapes << PolylineShape.new(pts, false, stroke, sw, caps, joins)
      end
      src.scan(/<polygon\b([^>]*?)\/?>/) do |m|
        a = attrs(m[1])
        next unless (pts = parse_points(a["points"]?))
        stroke = a["stroke"]? ? color(a["stroke"], current_color) : root_stroke
        stroke ||= color(a["fill"]?, current_color)
        next unless stroke
        sw = a["stroke-width"]? ? num(a, "stroke-width", 1.0) : root_sw
        caps = (a["stroke-linecap"]? || (root_caps ? "round" : nil)) == "round"
        joins = (a["stroke-linejoin"]? || (root_joins ? "round" : nil)) == "round"
        shapes << PolylineShape.new(pts, true, stroke, sw, caps, joins)
      end

      {shapes, view}
    end

    private def self.parse_view(attrs : Hash(String, String)) : ViewBox
      if (vb = attrs["viewBox"]? || attrs["viewbox"]?)
        p = vb.split(/\s+/).map(&.to_f64?)
        if p.size == 4 && p.all?
          return ViewBox.new(p[0].not_nil!, p[1].not_nil!, p[2].not_nil!, p[3].not_nil!)
        end
      end
      w = num(attrs, "width", 100.0)
      h = num(attrs, "height", 100.0)
      ViewBox.new(0.0, 0.0, w, h)
    end

    # Attribute bag of one tag (double or single quoted values).
    private def self.attrs(tag : String) : Hash(String, String)
      h = {} of String => String
      tag.scan(/([a-zA-Z0-9:_-]+)\s*=\s*"([^"]*)/) { |m| h[m[1]] = m[2] }
      tag.scan(/([a-zA-Z0-9:_-]+)\s*=\s*'([^']*)'/) { |m| h[m[1]] = m[2] }
      h
    end

    private def self.num(a : Hash(String, String), key : String,
                         fallback : Float64) : Float64
      a[key]?.try(&.to_f64?) || fallback
    end

    # "1,2 3 4" → user-unit points (nil when odd or malformed).
    private def self.parse_points(value : String?) : Array(Vec2)?
      return nil unless value
      nums = value.split(/[\s,]+/).reject(&.empty?).map(&.to_f64?)
      return nil if nums.size < 4 || nums.size.odd? || nums.any?(&.nil?)
      pts = [] of Vec2
      (0...nums.size).step(2) do |i|
        pts << Vec2.new(nums[i].not_nil!, nums[i + 1].not_nil!)
      end
      pts
    end

    # Flatten a path `d` attribute into (points, closed) subpaths.
    # Supports M/L/H/V/C/S/Q/T/A/Z — upper and lower — with SVG's
    # implicit coordinate repetition (pairs after an M are linetos;
    # any command repeats while more numbers follow).
    private def self.parse_path(d : String) : Array(Tuple(Array(Vec2), Bool))
      r = PathReader.new(d)
      subpaths = [] of Tuple(Array(Vec2), Bool)
      points = [] of Vec2
      closed = false
      cur = Vec2.new(0.0, 0.0)
      sub_start = Vec2.new(0.0, 0.0)
      c1 : Vec2? = nil # previous cubic control point (S/s reflects it)
      qc : Vec2? = nil # previous quadratic control point (T/t reflects it)

      while (cmd = r.command?)
        case cmd
        when 'M', 'm'
          x = r.num?
          y = r.num?
          break unless x && y
          cur = cmd == 'M' ? Vec2.new(x, y) : cur + Vec2.new(x, y)
          subpaths << {points, closed} if points.size >= 2
          points = [cur]
          closed = false
          sub_start = cur
          # further coordinate pairs after the first are linetos
          while (x = r.num?) && (y = r.num?)
            cur = cmd == 'M' ? Vec2.new(x, y) : cur + Vec2.new(x, y)
            points << cur
          end
          c1 = qc = nil
        when 'L', 'l'
          while (x = r.num?) && (y = r.num?)
            cur = cmd == 'L' ? Vec2.new(x, y) : cur + Vec2.new(x, y)
            points << cur
          end
          c1 = qc = nil
        when 'H', 'h'
          while (x = r.num?)
            cur = Vec2.new(cmd == 'H' ? x : cur.x + x, cur.y)
            points << cur
          end
          c1 = qc = nil
        when 'V', 'v'
          while (y = r.num?)
            cur = Vec2.new(cur.x, cmd == 'V' ? y : cur.y + y)
            points << cur
          end
          c1 = qc = nil
        when 'C', 'c'
          while (x1 = r.num?) && (y1 = r.num?) && (x2 = r.num?) &&
                (y2 = r.num?) && (x = r.num?) && (y = r.num?)
            rel = cmd == 'c'
            a = rel ? cur + Vec2.new(x1, y1) : Vec2.new(x1, y1)
            b = rel ? cur + Vec2.new(x2, y2) : Vec2.new(x2, y2)
            e = rel ? cur + Vec2.new(x, y) : Vec2.new(x, y)
            flatten_cubic(points, cur, a, b, e)
            c1, qc, cur = b, nil, e
          end
        when 'S', 's'
          while (x2 = r.num?) && (y2 = r.num?) && (x = r.num?) && (y = r.num?)
            rel = cmd == 's'
            a = c1 ? cur * 2.0 - c1.not_nil! : cur
            b = rel ? cur + Vec2.new(x2, y2) : Vec2.new(x2, y2)
            e = rel ? cur + Vec2.new(x, y) : Vec2.new(x, y)
            flatten_cubic(points, cur, a, b, e)
            c1, qc, cur = b, nil, e
          end
        when 'Q', 'q'
          while (x1 = r.num?) && (y1 = r.num?) && (x = r.num?) && (y = r.num?)
            rel = cmd == 'q'
            a = rel ? cur + Vec2.new(x1, y1) : Vec2.new(x1, y1)
            e = rel ? cur + Vec2.new(x, y) : Vec2.new(x, y)
            flatten_quad(points, cur, a, e)
            qc, c1, cur = a, nil, e
          end
        when 'T', 't'
          while (x = r.num?) && (y = r.num?)
            a = qc ? cur * 2.0 - qc.not_nil! : cur
            e = cmd == 'T' ? Vec2.new(x, y) : cur + Vec2.new(x, y)
            flatten_quad(points, cur, a, e)
            qc, c1, cur = a, nil, e
          end
        when 'A', 'a'
          while (rx = r.num?) && (ry = r.num?) && (rot = r.num?) &&
                (large = r.flag?) && (sweep = r.flag?) &&
                (x = r.num?) && (y = r.num?)
            e = cmd == 'A' ? Vec2.new(x, y) : cur + Vec2.new(x, y)
            flatten_arc(points, cur, e, rx, ry, rot, large == 1, sweep == 1)
            cur = e
            c1 = qc = nil
          end
        when 'Z', 'z'
          # Close, and per spec the next drawing command starts a new
          # subpath from the same start point.
          subpaths << {points, true} if points.size >= 2
          points = [sub_start]
          closed = false
          cur = sub_start
          c1 = qc = nil
        end
      end

      subpaths << {points, closed} if points.size >= 2
      subpaths
    end

    # Cubic Bézier flattened to segments; step count follows the
    # control-polygon length so an icon-scaled curve stays smooth
    # without exploding the paint list.
    private def self.flatten_cubic(points : Array(Vec2), p0 : Vec2, p1 : Vec2,
                                   p2 : Vec2, p3 : Vec2) : Nil
      len = (p1 - p0).length + (p2 - p1).length + (p3 - p2).length
      steps = len.ceil.to_i.clamp(4, 32)
      (1..steps).each do |i|
        t = i.to_f64 / steps
        u = 1.0 - t
        points << Vec2.new(
          u*u*u*p0.x + 3*u*u*t*p1.x + 3*u*t*t*p2.x + t*t*t*p3.x,
          u*u*u*p0.y + 3*u*u*t*p1.y + 3*u*t*t*p2.y + t*t*t*p3.y)
      end
    end

    # Quadratic Bézier, same flattening policy as the cubic.
    private def self.flatten_quad(points : Array(Vec2), p0 : Vec2, p1 : Vec2,
                                  p2 : Vec2) : Nil
      len = (p1 - p0).length + (p2 - p1).length
      steps = len.ceil.to_i.clamp(4, 32)
      (1..steps).each do |i|
        t = i.to_f64 / steps
        u = 1.0 - t
        points << Vec2.new(
          u*u*p0.x + 2*u*t*p1.x + t*t*p2.x,
          u*u*p0.y + 2*u*t*p1.y + t*t*p2.y)
      end
    end

    # Elliptical arc via the W3C endpoint→center parameterization
    # (implementation notes F.6): solve the center, sweep start/end
    # angles, sample. Degenerate radii degrade to a straight segment;
    # coincident endpoints are a no-op per spec.
    private def self.flatten_arc(points : Array(Vec2), from : Vec2, to : Vec2,
                                 rx : Float64, ry : Float64, x_rot_deg : Float64,
                                 large : Bool, sweep : Bool) : Nil
      return if (to.x - from.x).abs < 1e-9 && (to.y - from.y).abs < 1e-9
      rx, ry = rx.abs, ry.abs
      if rx < 1e-9 || ry < 1e-9
        points << to
        return
      end

      phi = x_rot_deg * Math::PI / 180.0
      cos_p = Math.cos(phi)
      sin_p = Math.sin(phi)
      dx = (from.x - to.x) / 2.0
      dy = (from.y - to.y) / 2.0
      x1p = cos_p * dx + sin_p * dy
      y1p = -sin_p * dx + cos_p * dy

      # Scale up too-small radii until the endpoints fit (F.6.6).
      lam = x1p*x1p / (rx*rx) + y1p*y1p / (ry*ry)
      if lam > 1.0
        s = Math.sqrt(lam)
        rx *= s
        ry *= s
      end

      num = rx*rx*ry*ry - rx*rx*y1p*y1p - ry*ry*x1p*x1p
      den = rx*rx*y1p*y1p + ry*ry*x1p*x1p
      co = den > 1e-12 ? Math.sqrt({num, 0.0}.max / den) : 0.0
      co = -co if large == sweep
      cxp = co * rx * y1p / ry
      cyp = -co * ry * x1p / rx
      cx = cos_p*cxp - sin_p*cyp + (from.x + to.x) / 2.0
      cy = sin_p*cxp + cos_p*cyp + (from.y + to.y) / 2.0

      # Signed angle between two unit-ish vectors (F.6.7).
      angle = ->(ux : Float64, uy : Float64, vx : Float64, vy : Float64) do
        dot = ux*vx + uy*vy
        len = Math.sqrt((ux*ux + uy*uy) * (vx*vx + vy*vy))
        a = Math.acos((dot / len).clamp(-1.0, 1.0))
        ux*vy - uy*vx < 0.0 ? -a : a
      end
      theta1 = angle.call(1.0, 0.0, (x1p - cxp) / rx, (y1p - cyp) / ry)
      dtheta = angle.call((x1p - cxp) / rx, (y1p - cyp) / ry,
        (-x1p - cxp) / rx, (-y1p - cyp) / ry)
      dtheta += 2*Math::PI if sweep && dtheta < 0.0
      dtheta -= 2*Math::PI if !sweep && dtheta > 0.0

      steps = (dtheta.abs / (Math::PI / 12.0)).ceil.to_i.clamp(2, 72)
      (1...steps).each do |i|
        t = theta1 + dtheta * i / steps
        ct = Math.cos(t)
        st = Math.sin(t)
        points << Vec2.new(cx + rx*cos_p*ct - ry*sin_p*st,
          cy + rx*sin_p*ct + ry*cos_p*st)
      end
      points << to # land exactly on the endpoint (no FP drift)
    end

    # Cursor over path data: command letters, numbers and arc flags,
    # with whitespace/commas as separators. Hand-rolled because arc
    # flags may glue to the following number ("...a1 1 0 0112 5").
    private class PathReader
      def initialize(@s : String)
        @pos = 0
      end

      # Next command letter, or nil at the end of data.
      def command? : Char?
        skip_sep
        if (c = @s[@pos]?) && c.ascii_letter?
          @pos += 1
          c
        end
      end

      # Next number (sign, digits, optional fraction and exponent),
      # or nil where data ends or is malformed.
      def num? : Float64?
        skip_sep
        start = @pos
        i = @pos
        s = @s
        i += 1 if (b = s.byte_at?(i)) && (b == '-'.ord || b == '+'.ord)
        digits = 0
        while (b = s.byte_at?(i)) && (48 <= b <= 57)
          i += 1
          digits += 1
        end
        if (b = s.byte_at?(i)) && b == '.'.ord
          i += 1
          while (b = s.byte_at?(i)) && (48 <= b <= 57)
            i += 1
            digits += 1
          end
        end
        if digits == 0
          return nil
        end
        if (b = s.byte_at?(i)) && (b == 'e'.ord || b == 'E'.ord)
          j = i + 1
          j += 1 if (b2 = s.byte_at?(j)) && (b2 == '-'.ord || b2 == '+'.ord)
          exp_digits = 0
          while (b2 = s.byte_at?(j)) && (48 <= b2 <= 57)
            j += 1
            exp_digits += 1
          end
          i = j if exp_digits > 0
        end
        value = s.byte_slice(start, i - start).to_f64?
        return nil unless value
        @pos = i
        value
      end

      # Single 0/1 digit (arc large-arc/sweep flags). Returns Int32
      # (0/1, both truthy — a Bool here would break the && chain in
      # parse_path) or nil where data ends.
      def flag? : Int32?
        skip_sep
        if (b = @s.byte_at?(@pos)) && (b == '0'.ord || b == '1'.ord)
          @pos += 1
          b == '1'.ord ? 1 : 0
        end
      end

      private def skip_sep
        while (b = @s.byte_at?(@pos)) &&
              (b == ' '.ord || b == ','.ord || (9 <= b <= 13))
          @pos += 1
        end
      end
    end

    # `nil` for "none"/unknown; `url(#id)` resolves through `gradients`
    # (an unknown id degrades to no fill).
    private def self.paint(value : String?,
                           gradients : Hash(String, LinearGradient),
                           current_color : Color32) : Paint?
      return nil unless value
      v = value.strip
      if v.starts_with?("url(")
        id = v[4..].split(')').first?.try(&.lchop('#'))
        return id ? gradients[id]? : nil
      end
      color(v, current_color)
    end

    WHITE = Color32.rgb(255, 255, 255)
    BLACK = Color32.rgb(0, 0, 0)

    NAMED_COLORS = {
      "white"      => WHITE,
      "black"      => BLACK,
      "red"        => Color32.rgb(220, 50, 50),
      "green"      => Color32.rgb(60, 160, 60),
      "blue"       => Color32.rgb(50, 100, 220),
      "yellow"     => Color32.rgb(230, 200, 40),
      "orange"     => Color32.rgb(240, 140, 30),
      "purple"     => Color32.rgb(150, 60, 200),
      "gray"       => Color32.rgb(128, 128, 128),
      "grey"       => Color32.rgb(128, 128, 128),
      "lightgray"  => Color32.rgb(211, 211, 211),
      "darkgray"   => Color32.rgb(64, 64, 64),
      "transparent" => Color32.transparent,
    }

    # `#RGB`, `#RRGGBB`, `#RRGGBBAA`, the named set above, and
    # `currentColor` (→ `current_color`); nil = none.
    private def self.color(value : String?, current_color : Color32) : Color32?
      return nil unless value
      v = value.strip.downcase
      return nil if v.empty? || v == "none"
      return current_color if v == "currentcolor"
      if v.starts_with?('#')
        hex = v.byte_slice(1)
        b = hex.to_u64?(16)
        case hex.size
        when 3
          if b
            return Color32.rgb(16 * (b >> 8), 16 * ((b >> 4) & 0xF),
              16 * (b & 0xF))
          end
        when 6
          if b
            return Color32.rgb((b >> 16) & 0xFF, (b >> 8) & 0xFF, b & 0xFF)
          end
        when 8
          if b
            return Color32.rgba((b >> 24) & 0xFF, (b >> 16) & 0xFF,
              (b >> 8) & 0xFF, b & 0xFF)
          end
        end
      end
      NAMED_COLORS[v]?
    end

    private def blend(a : Color32, b : Color32) : Color32
      mid = ->(x : UInt8, y : UInt8) { ((x.to_i + y.to_i) // 2).to_u8 }
      Color32.new(mid.call(a.r, b.r), mid.call(a.g, b.g), mid.call(a.b, b.b))
    end
  end
end
