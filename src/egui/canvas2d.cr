# Canvas2D — the browser `<canvas>` drawing surface (NativeHTML §4.3,
# Route A). An immediate-draw 2D API (moveTo/lineTo/bezier/arc, fill/
# stroke, CTM, gradients, globalAlpha, fill_text, rect-clip) whose calls
# are RECORDED into a retained op list and rasterized on the CPU through
# the NanoSVG port, one region-bounded bake per op, composited into an
# RGBA8 buffer shown as a single stream texture. Bakes run only when the
# op list changes (version counter), so an idle canvas costs no CPU.
#
# Path coordinates are transformed by the CTM when the segment is ADDED
# (canvas path semantics); stroke/fill state snapshots into each op, so
# the op list is a self-contained replay. Text draws through the Context
# font stack's CPU glyph readback (`Fonts#coverage_quads`) and needs the
# Context — it happens at bake time, not record time.
#
# Documented deviations (SPEC.md, "no half-properties" — all explicit):
#   - fill_text: the CTM translates the anchor only (no rotated text);
#     gradient fill styles are not applied to text (solid colors only).
#   - clip: the current path's bounding box intersected with the canvas
#     (exact for rect paths; rects are the supported clip shape).
#   - create_radial_gradient: a nonzero r0 collapses to a focal point at
#     the inner circle's center.
#   - textAlign :start/:end map to :left/:right.

module Egui
  class Canvas2D
    include Widget
    include AutoRepaint

    DEFAULT_FONT_SIZE = 16.0

    # --- CTM: [a c e; b d f; 0 0 1], column-vector convention ---------

    struct Affine
      getter a : Float64, b : Float64, c : Float64
      getter d : Float64, e : Float64, f : Float64

      def initialize(@a = 1.0, @b = 0.0, @c = 0.0,
                     @d = 1.0, @e = 0.0, @f = 0.0)
      end

      def self.translate(tx : Float64, ty : Float64) : Affine
        Affine.new(1.0, 0.0, 0.0, 1.0, tx, ty)
      end

      def self.scaling(sx : Float64, sy : Float64) : Affine
        Affine.new(sx, 0.0, 0.0, sy, 0.0, 0.0)
      end

      def self.rotation(rad : Float64) : Affine
        Affine.new(Math.cos(rad), Math.sin(rad),
          -Math.sin(rad), Math.cos(rad), 0.0, 0.0)
      end

      # self ∘ other — other applies FIRST (canvas `transform(m)`:
      # ctm = ctm * m).
      def *(o : Affine) : Affine
        Affine.new(
          @a * o.a + @c * o.b,
          @b * o.a + @d * o.b,
          @a * o.c + @c * o.d,
          @b * o.c + @d * o.d,
          @a * o.e + @c * o.f + @e,
          @b * o.e + @d * o.f + @f)
      end

      def apply(x : Float64, y : Float64) : {Float64, Float64}
        {@a * x + @c * y + @e, @b * x + @d * y + @f}
      end
    end

    # --- gradient paint (create_linear/create_radial_gradient) ----------

    class Gradient
      enum Kind
        Linear
        Radial
      end

      getter kind : Kind
      # Linear: endpoints (x0,y0)-(x1,y1). Radial: inner circle
      # (x0,y0,r0), outer (x1,y1,r1) — see the r0 deviation above.
      getter x0 : Float64, y0 : Float64, x1 : Float64, y1 : Float64
      getter r0 : Float64, r1 : Float64
      @stops = [] of Tuple(Float64, Color32)

      def initialize(@kind : Kind, @x0 : Float64, @y0 : Float64,
                     @x1 : Float64, @y1 : Float64,
                     @r0 : Float64 = 0.0, @r1 : Float64 = 0.0)
      end

      def add_color_stop(offset : Float64, color : Color32) : Nil
        raise "gradient stop offset out of range" unless 0.0 <= offset <= 1.0
        @stops << {offset, color}
      end

      # Value copy (an op must not see stops added after it recorded).
      def dup : Gradient
        g = Gradient.new(@kind, @x0, @y0, @x1, @y1, @r0, @r1)
        g.stops.concat(@stops)
        g
      end

      getter stops : Array(Tuple(Float64, Color32))
    end

    alias Paint = Color32 | Gradient

    # --- retained op list -----------------------------------------------

    # One path segment, coordinates in final canvas units (CTM already
    # applied). :quad stores the control point in (x0,y0) and the end
    # point in (x1,y1); :cubic stores two controls then the end point.
    struct Seg
      getter kind : Symbol
      getter x0 : Float64, y0 : Float64
      getter x1 : Float64, y1 : Float64
      getter x2 : Float64, y2 : Float64

      def initialize(@kind : Symbol, @x0 = 0.0, @y0 = 0.0,
                     @x1 = 0.0, @y1 = 0.0, @x2 = 0.0, @y2 = 0.0)
      end
    end

    # Axis-aligned box in canvas units — the clip working region and
    # the per-op raster bounds.
    private struct Box
      getter x0 : Float64, y0 : Float64
      getter x1 : Float64, y1 : Float64

      def initialize(@x0, @y0, @x1, @y1)
      end

      def self.full(w : Float64, h : Float64) : Box
        new(0.0, 0.0, w, h)
      end

      def intersect(o : Box) : Box
        Box.new({@x0, o.x0}.max, {@y0, o.y0}.max,
          {@x1, o.x1}.min, {@y1, o.y1}.min)
      end

      def grow(pad : Float64) : Box
        Box.new(@x0 - pad, @y0 - pad, @x1 + pad, @y1 + pad)
      end

      def empty? : Bool
        @x1 <= @x0 || @y1 <= @y0
      end
    end

    # The full draw state snapshot — per-op record (except clip/CTM
    # setters, which live in the working state).
    private struct State
      property ctm : Affine = Affine.new
      property fill_style : Paint = Color32.new(0, 0, 0)
      property stroke_style : Paint = Color32.new(0, 0, 0)
      property line_width : Float64 = 1.0
      property line_cap : Symbol = :butt     # :butt/:round/:square
      property line_join : Symbol = :miter   # :miter/:round/:bevel
      property line_dash = [] of Float64
      property line_dash_offset : Float64 = 0.0
      property fill_rule : Symbol = :nonzero # :nonzero/:evenodd
      property global_alpha : Float64 = 1.0
      property font_size : Float64 = DEFAULT_FONT_SIZE
      property font_family : String? = nil
      property text_align : Symbol = :left   # :left/:center/:right
      property text_baseline : Symbol = :alphabetic
      # :top/:middle/:alphabetic/:bottom
      property clip : Box

      def initialize(@clip : Box)
      end

      # Value copy for save/restore: the dash array is mutable after
      # the fact, so snapshots clone it (gradients are snapshotted per
      # op — see #snapshot_paint).
      def snapshot : State
        s = self
        s.line_dash = @line_dash.dup
        s
      end
    end

    private struct ShapeOp
      getter mode : Symbol # :fill | :stroke
      getter segs : Array(Seg)
      getter paint : Paint
      getter ctm : Affine      # gradient coordinates' transform
      getter alpha : Float64
      getter clip : Box
      getter line_width : Float64
      getter line_cap : Symbol
      getter line_join : Symbol
      getter line_dash : Array(Float64)
      getter line_dash_offset : Float64
      getter fill_rule : Symbol

      def initialize(@mode, @segs, @paint, @ctm, @alpha, @clip,
                     @line_width, @line_cap, @line_join, @line_dash,
                     @line_dash_offset, @fill_rule)
      end
    end

    private struct TextOp
      getter text : String
      getter x : Float64 # anchor, CTM already applied
      getter y : Float64
      getter color : Color32
      getter font_size : Float64
      getter font_family : String?
      getter text_align : Symbol
      getter text_baseline : Symbol
      getter alpha : Float64
      getter clip : Box

      def initialize(@text, @x, @y, @color, @font_size, @font_family,
                     @text_align, @text_baseline, @alpha, @clip)
      end
    end

    private struct ClearOp
      getter box : Box
      getter clip : Box

      def initialize(@box, @clip)
      end
    end

    alias Op = ShapeOp | TextOp | ClearOp

    # --- public surface -------------------------------------------------

    getter width : Int32
    getter height : Int32
    getter texture_id : UInt64

    @pid : Id
    @ops = [] of Op
    @state : State
    @stack = [] of State
    @segs = [] of Seg
    @pen : {Float64, Float64}? = nil
    @subpath_start : {Float64, Float64}? = nil
    @version : UInt64 = 0_u64
    @measure_ctx : Context? = nil
    # Bake cache: device-pixel buffer + the texture baked from it.
    @buf : Bytes = Bytes.empty
    @buf_w = 0
    @buf_h = 0
    @tex_w = 0
    @tex_h = 0
    @baked_version = 0_u64
    @baked_ppm = 0.0

    def initialize(id : String, @width : Int32, @height : Int32)
      @pid = Id.from("canvas2d/#{id}")
      @state = State.new(Box.full(@width.to_f64, @height.to_f64))
      @texture_id = 0_u64
    end

    def inspector_label : String?
      "canvas2d #{width}×#{height}"
    end

    # New logical size; the op list replays into the new box on the
    # next bake and the texture is recreated lazily.
    def resize(width : Int32, height : Int32) : Nil
      @width = width
      @height = height
      @state.clip = @state.clip.intersect(
        Box.full(width.to_f64, height.to_f64))
    end

    # Drop the op list and the buffer — the redraw-every-frame pattern
    # (`clear; …draw…` per change, the browser's paint loop).
    def clear : Nil
      @ops.clear
      @baked_version = 0_u64 # force the rebake even at the same version
      auto_repaint!
    end

    # --- state -----------------------------------------------------------

    {% for name in %w(fill_style stroke_style line_width line_cap
                      line_join line_dash line_dash_offset fill_rule
                      global_alpha font_size font_family text_align
                      text_baseline) %}
      def {{name.id}}=(value)
        @state.{{name.id}} = value
      end

      def {{name.id}}
        @state.{{name.id}}
      end
    {% end %}

    def save : Nil
      @stack << @state.snapshot
    end

    def restore : Nil
      @state = @stack.pop? || @state
    end

    # --- CTM --------------------------------------------------------------

    def translate(tx : Float64, ty : Float64) : Nil
      @state.ctm = @state.ctm * Affine.translate(tx, ty)
    end

    def scale(sx : Float64, sy : Float64) : Nil
      @state.ctm = @state.ctm * Affine.scaling(sx, sy)
    end

    def rotate(rad : Float64) : Nil
      @state.ctm = @state.ctm * Affine.rotation(rad)
    end

    def transform(a : Float64, b : Float64, c : Float64,
                  d : Float64, e : Float64, f : Float64) : Nil
      @state.ctm = @state.ctm * Affine.new(a, b, c, d, e, f)
    end

    def set_transform(a : Float64, b : Float64, c : Float64,
                      d : Float64, e : Float64, f : Float64) : Nil
      @state.ctm = Affine.new(a, b, c, d, e, f)
    end

    # --- path -------------------------------------------------------------

    def begin_path : Nil
      @segs.clear
      @pen = nil
      @subpath_start = nil
    end

    def close_path : Nil
      return unless (p = @pen) && (s = @subpath_start)
      @segs << Seg.new(:close)
      @pen = s
    end

    def move_to(x : Float64, y : Float64) : Nil
      tx, ty = @state.ctm.apply(x, y)
      @segs << Seg.new(:move, tx, ty)
      @pen = {tx, ty}
      @subpath_start = {tx, ty}
    end

    def line_to(x : Float64, y : Float64) : Nil
      # Browser: a lineTo with an empty path acts as moveTo.
      return move_to(x, y) unless @pen
      tx, ty = @state.ctm.apply(x, y)
      @segs << Seg.new(:line, tx, ty)
      @pen = {tx, ty}
    end

    def quadratic_curve_to(cx : Float64, cy : Float64,
                           x : Float64, y : Float64) : Nil
      return unless @pen
      cxp, cyp = @state.ctm.apply(cx, cy)
      tx, ty = @state.ctm.apply(x, y)
      @segs << Seg.new(:quad, cxp, cyp, tx, ty)
      @pen = {tx, ty}
    end

    def bezier_curve_to(c1x : Float64, c1y : Float64,
                        c2x : Float64, c2y : Float64,
                        x : Float64, y : Float64) : Nil
      return unless @pen
      c1xp, c1yp = @state.ctm.apply(c1x, c1y)
      c2xp, c2yp = @state.ctm.apply(c2x, c2y)
      tx, ty = @state.ctm.apply(x, y)
      @segs << Seg.new(:cubic, c1xp, c1yp, c2xp, c2yp, tx, ty)
      @pen = {tx, ty}
    end

    def rect(x : Float64, y : Float64, w : Float64, h : Float64) : Nil
      segs = rect_segs(x, y, w, h)
      segs.each { |seg| @segs << seg }
      @subpath_start = {segs[0].x0, segs[0].y0}
      @pen = @subpath_start
    end

    # Counterclockwise when `ccw` (angles run clockwise on screen, y down).
    def arc(cx : Float64, cy : Float64, r : Float64,
            start_angle : Float64, end_angle : Float64,
            ccw : Bool = false) : Nil
      ellipse(cx, cy, r, r, 0.0, start_angle, end_angle, ccw)
    end

    def ellipse(cx : Float64, cy : Float64, rx : Float64, ry : Float64,
                rotation : Float64, start_angle : Float64,
                end_angle : Float64, ccw : Bool = false) : Nil
      return if rx <= 0.0 || ry <= 0.0
      two_pi = Math::PI * 2.0
      sweep = end_angle - start_angle
      if ccw
        while sweep > 0.0
          sweep -= two_pi
        end
      else
        while sweep < 0.0
          sweep += two_pi
        end
      end
      sweep = two_pi * (ccw ? -1.0 : 1.0) if sweep.abs >= two_pi - 1e-9
      return if sweep.abs < 1e-9

      cosr = Math.cos(rotation)
      sinr = Math.sin(rotation)
      point = ->(t : Float64) do
        ex = rx * Math.cos(t)
        ey = ry * Math.sin(t)
        {cx + ex * cosr - ey * sinr, cy + ex * sinr + ey * cosr}
      end
      deriv = ->(t : Float64) do
        {-rx * Math.sin(t) * cosr - ry * Math.cos(t) * sinr,
         -rx * Math.sin(t) * sinr + ry * Math.cos(t) * cosr}
      end

      steps = {(sweep.abs / (Math::PI / 2.0)).ceil.to_i, 1}.max
      dth = sweep / steps
      k = 4.0 / 3.0 * Math.tan(dth / 4.0)
      steps.times do |i|
        t0 = start_angle + dth * i
        t1 = t0 + dth
        p0 = point.call(t0)
        p3 = point.call(t1)
        d0 = deriv.call(t0)
        d1 = deriv.call(t1)
        # Connect from the current pen position (canvas arc semantics);
        # an empty path gets the arc's start point as its moveTo.
        if (pen = @pen)
          @segs << Seg.new(:line, p0[0], p0[1]) unless pen == p0
        else
          @segs << Seg.new(:move, p0[0], p0[1])
          @subpath_start = p0
        end
        @segs << Seg.new(:cubic,
          p0[0] + k * d0[0], p0[1] + k * d0[1],
          p3[0] - k * d1[0], p3[1] - k * d1[1],
          p3[0], p3[1])
        @pen = p3
      end
    end

    # --- paint ------------------------------------------------------------

    def fill : Nil
      return unless drawable_path?
      paint = snapshot_paint(@state.fill_style)
      return unless paint
      record ShapeOp.new(:fill, @segs.dup, paint, @state.ctm,
        @state.global_alpha, @state.clip, @state.line_width,
        @state.line_cap, @state.line_join, @state.line_dash,
        @state.line_dash_offset, @state.fill_rule)
    end

    def stroke : Nil
      return unless drawable_path?
      paint = snapshot_paint(@state.stroke_style)
      return unless paint
      record ShapeOp.new(:stroke, @segs.dup, paint, @state.ctm,
        @state.global_alpha, @state.clip, @state.line_width,
        @state.line_cap, @state.line_join, @state.line_dash,
        @state.line_dash_offset, @state.fill_rule)
    end

    # Browser fill_rect/stroke_rect: their own path, the current path
    # is untouched.
    def fill_rect(x : Float64, y : Float64, w : Float64, h : Float64) : Nil
      paint = snapshot_paint(@state.fill_style)
      return unless paint
      record ShapeOp.new(:fill, rect_segs(x, y, w, h), paint,
        @state.ctm, @state.global_alpha, @state.clip, @state.line_width,
        @state.line_cap, @state.line_join, @state.line_dash,
        @state.line_dash_offset, @state.fill_rule)
    end

    def stroke_rect(x : Float64, y : Float64, w : Float64, h : Float64) : Nil
      paint = snapshot_paint(@state.stroke_style)
      return unless paint
      record ShapeOp.new(:stroke, rect_segs(x, y, w, h), paint,
        @state.ctm, @state.global_alpha, @state.clip, @state.line_width,
        @state.line_cap, @state.line_join, @state.line_dash,
        @state.line_dash_offset, @state.fill_rule)
    end

    def clear_rect(x : Float64, y : Float64, w : Float64, h : Float64) : Nil
      record ClearOp.new(rect_box(x, y, w, h), @state.clip)
    end

    # Intersect the working clip with the current path's bounding box
    # (rect-clip — see the header deviation).
    def clip : Nil
      box = segs_box(@segs)
      return if box.empty?
      @state.clip = @state.clip.intersect(box)
    end

    def fill_text(text : String, x : Float64, y : Float64) : Nil
      return if text.empty?
      # Gradient text is Route B (SPEC); a gradient fill style does not
      # paint text.
      color = @state.fill_style.as?(Color32)
      return unless color
      tx, ty = @state.ctm.apply(x, y)
      record TextOp.new(text, tx, ty, color, @state.font_size,
        @state.font_family, @state.text_align, @state.text_baseline,
        @state.global_alpha, @state.clip)
    end

    # Text width/height at the current font state. Needs a Context (the
    # font stacks live there) — returns zero before the first #ui.
    def measure_text(text : String) : Vec2
      return Vec2.zero if text.empty?
      ctx = @measure_ctx
      return Vec2.zero unless ctx
      ctx.fonts_for(@state.font_family).measure(text, @state.font_size)
    end

    def create_linear_gradient(x0 : Float64, y0 : Float64,
                               x1 : Float64, y1 : Float64) : Gradient
      Gradient.new(Gradient::Kind::Linear, x0, y0, x1, y1, 0.0, 0.0)
    end

    # r0 > 0 collapses to a focal point (SPEC deviation).
    def create_radial_gradient(x0 : Float64, y0 : Float64, r0 : Float64,
                               x1 : Float64, y1 : Float64,
                               r1 : Float64) : Gradient
      Gradient.new(Gradient::Kind::Radial, x0, y0, x1, y1, r0, r1)
    end

    # --- widget plumbing ---------------------------------------------------

    def ui(ui : Ui) : Response
      ctx = ui.ctx
      pump_auto_repaint(ctx)
      @measure_ctx = ctx
      rect = ui.allocate_at_least(
        Vec2.new(@width.to_f64, @height.to_f64))
      response = ui.interact(rect, @pid, Sense.click_and_drag)
      response.widget_text = "canvas2d"

      ensure_texture(ctx)
      ppm = ctx.pixels_per_point
      if !@texture_id.zero? &&
         (@baked_version != @version || @baked_ppm != ppm)
        bake(ctx, ppm)
      end
      unless @texture_id.zero?
        ui.painter.image(rect, @texture_id)
      end
      response
    end

    # Release the GPU texture (app shutdown / canvas replacement).
    def destroy_texture(ctx : Context) : Nil
      unless @texture_id.zero?
        ctx.textures.destroy_later(@texture_id)
        @texture_id = 0_u64
      end
    end

    # --- recording helpers --------------------------------------------------

    private def record(op : Op) : Nil
      @ops << op
      @version &+= 1
      auto_repaint!
    end

    private def drawable_path? : Bool
      @segs.any? { |s| s.kind != :move && s.kind != :close }
    end

    private def snapshot_paint(paint : Paint) : Paint?
      case paint
      when Gradient then paint.dup
      when Color32  then paint
      else               nil
      end
    end

    private def rect_segs(x : Float64, y : Float64,
                          w : Float64, h : Float64) : Array(Seg)
      c1 = @state.ctm.apply(x, y)
      c2 = @state.ctm.apply(x + w, y)
      c3 = @state.ctm.apply(x + w, y + h)
      c4 = @state.ctm.apply(x, y + h)
      [Seg.new(:move, c1[0], c1[1]),
        Seg.new(:line, c2[0], c2[1]),
        Seg.new(:line, c3[0], c3[1]),
        Seg.new(:line, c4[0], c4[1]),
        Seg.new(:close)]
    end

    private def rect_box(x : Float64, y : Float64,
                         w : Float64, h : Float64) : Box
      c1 = @state.ctm.apply(x, y)
      c2 = @state.ctm.apply(x + w, y + h)
      Box.new({c1[0], c2[0]}.min, {c1[1], c2[1]}.min,
        {c1[0], c2[0]}.max, {c1[1], c2[1]}.max)
    end

    private def segs_box(segs : Array(Seg)) : Box
      x0 = Float64::INFINITY
      y0 = Float64::INFINITY
      x1 = -Float64::INFINITY
      y1 = -Float64::INFINITY
      segs.each do |s|
        case s.kind
        when :move, :line
          x0 = {x0, s.x0}.min
          y0 = {y0, s.y0}.min
          x1 = {x1, s.x0}.max
          y1 = {y1, s.y0}.max
        when :quad
          x0 = {x0, s.x0, s.x1}.min
          y0 = {y0, s.y0, s.y1}.min
          x1 = {x1, s.x0, s.x1}.max
          y1 = {y1, s.y0, s.y1}.max
        when :cubic
          x0 = {x0, s.x0, s.x1, s.x2}.min
          y0 = {y0, s.y0, s.y1, s.y2}.min
          x1 = {x1, s.x0, s.x1, s.x2}.max
          y1 = {y1, s.y0, s.y1, s.y2}.max
        end
      end
      Box.new(x0, y0, x1, y1)
    end

    # --- bake -----------------------------------------------------------------

    private def ensure_texture(ctx : Context) : Nil
      dw = {(@width * ctx.pixels_per_point).round.to_i, 1}.max
      dh = {(@height * ctx.pixels_per_point).round.to_i, 1}.max
      if @texture_id.zero? || @tex_w != dw || @tex_h != dh
        destroy_texture(ctx)
        @texture_id = ctx.textures.create_stream(dw, dh)
        @tex_w = dw
        @tex_h = dh
        @baked_version = 0_u64 # the new texture is blank
      end
    end

    private def bake(ctx : Context, ppm : Float64) : Nil
      dw = @tex_w
      dh = @tex_h
      if @buf.size != dw.to_i64 * dh * 4
        @buf = Bytes.new(dw.to_i64 * dh * 4)
      end
      @buf_w = dw
      @buf_h = dh
      @buf.fill(0_u8)
      @ops.each do |op|
        case op
        in ShapeOp then bake_shape(op, ppm)
        in TextOp  then bake_text(op, ctx, ppm)
        in ClearOp then bake_clear(op, ppm)
        end
      end
      ctx.textures.update(@texture_id, dw, dh, @buf)
      @baked_version = @version
      @baked_ppm = ppm
    end

    # Canvas-space box → device-pixel raster region (clip ∩ box ∩
    # canvas, conservative-integer). Nil when empty.
    private def device_region(box : Box, ppm : Float64) : {Int32, Int32, Int32, Int32}?
      x0 = {box.x0 * ppm, 0.0}.max.ceil.to_i
      y0 = {box.y0 * ppm, 0.0}.max.ceil.to_i
      x1 = {box.x1 * ppm, @buf_w.to_f64}.min.floor.to_i
      y1 = {box.y1 * ppm, @buf_h.to_f64}.min.floor.to_i
      return nil if x1 <= x0 || y1 <= y0
      {x0, y0, x1, y1}
    end

    private def bake_shape(op : ShapeOp, ppm : Float64) : Nil
      box = segs_box(op.segs)
      pad = op.mode == :stroke ? op.line_width + 2.0 : 1.0
      region = device_region(box.grow(pad).intersect(op.clip), ppm)
      return unless region
      rx, ry, rx1, ry1 = region
      rw = rx1 - rx
      rh = ry1 - ry
      img = NanoSVG.parse(shape_svg(op), "px", 96.0_f32)
      return if img.width <= 0.0_f32 || img.height <= 0.0_f32
      # Device px = user * ppm + tx — the rasterizer translates AFTER
      # scaling (see NanoSVG::Rasterizer#rasterize), so tx is a device
      # offset here.
      src = NanoSVG::Rasterizer.rasterize(img, -rx.to_f32, -ry.to_f32,
        ppm.to_f32, rw, rh)
      blend_region!(src, rw, rh, rx, ry, op.alpha)
    end

    private def bake_clear(op : ClearOp, ppm : Float64) : Nil
      region = device_region(op.box.intersect(op.clip), ppm)
      return unless region
      rx, ry, rx1, ry1 = region
      (ry...ry1).each do |y|
        (@buf.to_unsafe + (y.to_i64 * @buf_w + rx) * 4).clear((rx1 - rx) * 4)
      end
    end

    private def bake_text(op : TextOp, ctx : Context, ppm : Float64) : Nil
      fonts = ctx.fonts_for(op.font_family)
      quads = fonts.coverage_quads(op.text, op.font_size * ppm)
      return unless quads
      asc, desc = fonts.metrics_at(op.font_size)
      w = fonts.measure(op.text, op.font_size).x
      dx = case op.text_align
           when :center then -w / 2.0
           when :right  then -w
           else              0.0
           end
      dy = case op.text_baseline
           when :top         then asc
           when :middle      then (asc + desc) / 2.0
           when :bottom      then desc
           else                   0.0 # :alphabetic
           end
      bx = (op.x + dx) * ppm
      by = (op.y + dy) * ppm
      cx0 = {op.clip.x0 * ppm, 0.0}.max.ceil.to_i
      cy0 = {op.clip.y0 * ppm, 0.0}.max.ceil.to_i
      cx1 = {op.clip.x1 * ppm, @buf_w.to_f64}.min.floor.to_i
      cy1 = {op.clip.y1 * ppm, @buf_h.to_f64}.min.floor.to_i
      return if cx1 <= cx0 || cy1 <= cy0
      cr = op.color.r.to_i32
      cg = op.color.g.to_i32
      cb = op.color.b.to_i32
      ca = op.color.a.to_i32
      quads.each do |q|
        gx = (bx + q.pen_x + q.xoff).round.to_i
        gy = (by - q.ytop).round.to_i
        yy = 0
        while yy < q.h
          sy = yy
          py = gy + sy
          yy += 1
          next if py < cy0 || py >= cy1
          row = py.to_i64 * @buf_w
          xx = 0
          while xx < q.w
            px = gx + xx
            cov = q.coverage[sy * q.w + xx].to_i32
            xx += 1
            next if px < cx0 || px >= cx1
            sai = cov * ca * op.alpha
            sai = (sai / 255.0 + 0.5).floor.to_i
            next if sai <= 0
            di = (row + px) * 4
            if sai >= 255
              @buf[di] = cr.to_u8
              @buf[di + 1] = cg.to_u8
              @buf[di + 2] = cb.to_u8
              @buf[di + 3] = 255_u8
            else
              da = @buf[di + 3].to_i32
              oa = sai + da * (255 - sai) // 255
              ia = 255 - sai
              if oa > 0
                # Int64: the 255/oa rescale peaks past Int32 (255⁴ ≈ 4.2e9).
                nr = cr.to_i64 * sai + @buf[di].to_i64 * da * ia // 255
                ng = cg.to_i64 * sai + @buf[di + 1].to_i64 * da * ia // 255
                nb = cb.to_i64 * sai + @buf[di + 2].to_i64 * da * ia // 255
                @buf[di] = {nr // oa, 255}.min.to_u8
                @buf[di + 1] = {ng // oa, 255}.min.to_u8
                @buf[di + 2] = {nb // oa, 255}.min.to_u8
              end
              @buf[di + 3] = oa.to_u8
            end
          end
        end
      end
    end

    # Source-over composite of the rw×rh raster region onto the buffer
    # at (ox, oy), premultiplying the source alpha by `alpha`.
    private def blend_region!(src : Bytes, rw : Int32, rh : Int32,
                              ox : Int32, oy : Int32, alpha : Float64) : Nil
      y = 0
      while y < rh
        sy = y
        py = oy + sy
        y += 1
        next if py < 0 || py >= @buf_h
        row = py.to_i64 * @buf_w
        x = 0
        while x < rw
          px = ox + x
          si = (sy * rw + x) * 4
          x += 1
          next if px < 0 || px >= @buf_w
          # src.a (0..255) premultiplied by the global alpha — the
          # product stays in 0..255, rounded once.
          sa = (src[si + 3].to_i32 * alpha + 0.5).floor.to_i
          next if sa <= 0
          di = (row + px) * 4
          if sa >= 255
            @buf[di] = src[si]
            @buf[di + 1] = src[si + 1]
            @buf[di + 2] = src[si + 2]
            @buf[di + 3] = src[si + 3]
          else
            da = @buf[di + 3].to_i32
            oa = sa + da * (255 - sa) // 255
            ia = 255 - sa
            if oa > 0
              # Int64: the 255/oa rescale peaks past Int32 (255⁴ ≈ 4.2e9).
              nr = src[si].to_i64 * sa + @buf[di].to_i64 * da * ia // 255
              ng = src[si + 1].to_i64 * sa + @buf[di + 1].to_i64 * da * ia // 255
              nb = src[si + 2].to_i64 * sa + @buf[di + 2].to_i64 * da * ia // 255
              @buf[di] = {nr // oa, 255}.min.to_u8
              @buf[di + 1] = {ng // oa, 255}.min.to_u8
              @buf[di + 2] = {nb // oa, 255}.min.to_u8
            end
            @buf[di + 3] = oa.to_u8
          end
        end
      end
    end

    # --- SVG serialization ---------------------------------------------------

    private def fmt(v : Float64) : String
      "%.3f" % v
    end

    private def path_d(segs : Array(Seg), io : IO) : Nil
      segs.each do |s|
        case s.kind
        when :move
          io << "M" << fmt(s.x0) << " " << fmt(s.y0)
        when :line
          io << "L" << fmt(s.x0) << " " << fmt(s.y0)
        when :quad
          io << "Q" << fmt(s.x0) << " " << fmt(s.y0) <<
            " " << fmt(s.x1) << " " << fmt(s.y1)
        when :cubic
          io << "C" << fmt(s.x0) << " " << fmt(s.y0) <<
            " " << fmt(s.x1) << " " << fmt(s.y1) <<
            " " << fmt(s.x2) << " " << fmt(s.y2)
        when :close
          io << "Z"
        end
      end
    end

    private def hex(c : Color32, io : IO) : IO
      io << "#" << c.r.to_s(16).rjust(2, '0') <<
        c.g.to_s(16).rjust(2, '0') << c.b.to_s(16).rjust(2, '0')
    end

    # The one-shape SVG document for a shape op. Shapes carry final
    # canvas coordinates (CTM baked in at record time); a gradient's
    # endpoints go through the op's CTM now — gradients are positioned
    # in the user space of the fill/stroke call (canvas semantics).
    private def shape_svg(op : ShapeOp) : String
      String.build do |s|
        s << "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"" <<
          @width << "\" height=\"" << @height << "\">"
        if (g = op.paint.as?(Gradient))
          s << "<defs>"
          case g.kind
          when .linear?
            x0, y0 = op.ctm.apply(g.x0, g.y0)
            x1, y1 = op.ctm.apply(g.x1, g.y1)
            s << "<linearGradient id=\"g\" gradientUnits=\"userSpaceOnUse\" x1=\"" <<
              fmt(x0) << "\" y1=\"" << fmt(y0) << "\" x2=\"" <<
              fmt(x1) << "\" y2=\"" << fmt(y1) << "\">"
          else
            cx, cy = op.ctm.apply(g.x1, g.y1)
            fx, fy = op.ctm.apply(g.x0, g.y0)
            s << "<radialGradient id=\"g\" gradientUnits=\"userSpaceOnUse\" cx=\"" <<
              fmt(cx) << "\" cy=\"" << fmt(cy) << "\" r=\"" <<
              fmt(g.r1) << "\" fx=\"" << fmt(fx) << "\" fy=\"" <<
              fmt(fy) << "\">"
          end
          g.stops.sort_by { |st| st[0] }.each do |off, color|
            s << "<stop offset=\"" << fmt(off) << "\" stop-color=\""
            hex(color, s) << "\""
            s << " stop-opacity=\"" << fmt(color.a.to_f64 / 255.0) << "\"" if color.a < 255
            s << "/>"
          end
          s << (g.kind.linear? ? "</linearGradient>" : "</radialGradient>")
          s << "</defs>"
          url = "url(#g)"
          opacity = 1.0
        else
          c = op.paint.as(Color32)
          url = String.build { |h| hex(c, h) }
          opacity = c.a.to_f64 / 255.0
        end

        s << "<path d=\""
        path_d(op.segs, s)
        s << "\""
        if op.mode == :fill
          s << " fill=\"" << url << "\""
          s << " fill-opacity=\"" << fmt(opacity) << "\"" if opacity < 1.0
          s << " fill-rule=\"evenodd\"" if op.fill_rule == :evenodd
          s << " stroke=\"none\""
        else
          s << " fill=\"none\" stroke=\"" << url << "\""
          s << " stroke-opacity=\"" << fmt(opacity) << "\"" if opacity < 1.0
          s << " stroke-width=\"" << fmt(op.line_width) << "\""
          s << " stroke-linecap=\"" << op.line_cap << "\""
          s << " stroke-linejoin=\"" << op.line_join << "\""
          unless op.line_dash.empty?
            s << " stroke-dasharray=\""
            op.line_dash.each_with_index do |d, i|
              s << " " if i > 0
              s << fmt(d)
            end
            s << "\""
            s << " stroke-dashoffset=\"" << fmt(op.line_dash_offset) << "\"" if op.line_dash_offset != 0.0
          end
        end
        s << "/></svg>"
      end
    end
  end
end
