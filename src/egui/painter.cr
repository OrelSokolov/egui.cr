# The paint-list half of egui_upstream/crates/egui/src/painter.rs.
#
# Commands are tagged with the current layer (Order); within a layer,
# insertion order == paint order == stacking. `commands_in_layer_order`
# flattens back-to-front for the backend (egui GraphicLayers::drain).
#
# `add_noop` + `set` reproduce egui's `Frame` trick: reserve an index,
# lay out children, then back-patch the window background under them.

module Egui
  # One side of a per-side border: width 0 means the side is off
  # (CSS `border-style: none` for that side).
  struct SideStroke
    getter width : Float64
    getter color : Color32

    def initialize(@width : Float64, @color : Color32)
    end

    def on? : Bool
      @width > 0.0
    end
  end

  # CSS per-side borders (`border-width: 1 0 0 3`, `border-top-color`):
  # each side carries its own width and color. Built by
  # `StyleVars#stroke_sides?` from the `stroke_width.*` / `stroke.*`
  # keys (the scalar `stroke_width`/`stroke` are the all-sides
  # fallbacks), or by hand for `Ui#box(stroke_sides:)`.
  struct StrokeSides
    getter top : SideStroke
    getter right : SideStroke
    getter bottom : SideStroke
    getter left : SideStroke

    def initialize(@top : SideStroke, @right : SideStroke,
                   @bottom : SideStroke, @left : SideStroke)
    end

    # The wider of two adjacent sides — what a rounded corner join
    # draws when the two sides disagree (backends pick its color too).
    def self.wider(a : SideStroke, b : SideStroke) : SideStroke
      a.width >= b.width ? a : b
    end
  end

  # CSS per-corner rounding (`border-radius: 10px 10px 4px 4px`):
  # each corner of a filled rect gets its own radius. The two-rect
  # border algorithm needs this on the INNER rect — its corner radius
  # is the outer radius minus the adjacent border width, so the inner
  # curve stays inside the outer arc with no clipping at all.
  struct CornerRadii
    getter top_left : Float64
    getter top_right : Float64
    getter bottom_right : Float64
    getter bottom_left : Float64

    def initialize(@top_left = 0.0, @top_right = 0.0,
                   @bottom_right = 0.0, @bottom_left = 0.0)
    end

    def self.uniform(v : Float64) : self
      new(v, v, v, v)
    end

    def uniform? : Bool
      @top_left == @top_right == @bottom_right == @bottom_left
    end

    def max : Float64
      {@top_left, @top_right, @bottom_right, @bottom_left}.max
    end

    # Every radius grown by `d` outwards — the radius of a rect
    # expanded by `d` (the focus ring hugging the box's curve).
    def expanded(d : Float64) : self
      CornerRadii.new(@top_left + d, @top_right + d,
        @bottom_right + d, @bottom_left + d)
    end

    # Per-corner maximum — how nested rounded-clip brackets merge
    # (Painter#clip_apply): a command already clipped by an inner
    # rounded shape that lands in an outer bracket keeps the tighter
    # corner of the two. Exact when only one of the shapes has radii;
    # an approximation when both do (the true intersection of two
    # rounded rects is not a rounded rect).
    def merge(other : CornerRadii) : CornerRadii
      CornerRadii.new(
        {@top_left, other.top_left}.max,
        {@top_right, other.top_right}.max,
        {@bottom_right, other.bottom_right}.max,
        {@bottom_left, other.bottom_left}.max)
    end

    # The CSS `border-radius` shorthand: 1-4 space-separated radii
    # (`px` optional), expanded per the standard — 1 → every corner,
    # 2 → TL/BR + TR/BL, 3 → TL + TR/BL + BR, 4 → TL TR BR BL
    # (clockwise from top-left). nil for anything else: the
    # elliptical `a / b` form has no ellipse primitive here, and a
    # percentage needs the rect that only the reader knows.
    def self.parse?(s : String) : CornerRadii?
      return nil if s.includes?('/')
      parts = s.split
      return nil unless parts.size.in?(1..4)
      nums = parts.map do |p|
        p = p[0...p.size - 2] if p.ends_with?("px")
        n = p.to_f64?
        n && n >= 0.0 ? n : nil
      end
      return nil if nums.any?(&.nil?)
      tl, tr, br, bl = case nums.size
        when 1 then {nums[0], nums[0], nums[0], nums[0]}
        when 2 then {nums[0], nums[1], nums[0], nums[1]}
        when 3 then {nums[0], nums[1], nums[2], nums[1]}
        else        {nums[0], nums[1], nums[2], nums[3]}
      end
      CornerRadii.new(tl.not_nil!, tr.not_nil!, br.not_nil!, bl.not_nil!)
    end

    # CSS corner-conflict resolution (Backgrounds & Borders §5.5):
    # when adjacent radii overlap along a side, ALL radii scale by
    # f = min(side / adjacent pair sum). For an oversized uniform
    # radius that is exactly the capsule clamp (min(w,h)/2) the
    # backends apply anyway; per-corner values get the standard's
    # proportional shrink instead of an independent per-corner clamp.
    # (A zero pair sum divides into Infinity, i.e. no constraint.)
    def fit(rect : Rect) : CornerRadii
      f = {rect.width / (@top_left + @top_right),
           rect.width / (@bottom_left + @bottom_right),
           rect.height / (@top_left + @bottom_left),
           rect.height / (@top_right + @bottom_right)}.min
      return self if f >= 1.0
      CornerRadii.new(@top_left * f, @top_right * f,
        @bottom_right * f, @bottom_left * f)
    end

    # The CSS shorthand spelling: a uniform radius collapses to one
    # number, otherwise the four corners clockwise from top-left.
    def to_s(io : IO) : Nil
      fmt = ->(v : Float64) { v % 1 == 0 ? v.to_i64.to_s : v.to_s }
      if uniform?
        io << fmt.call(@top_left)
      else
        io << fmt.call(@top_left) << ' ' << fmt.call(@top_right) << ' ' <<
          fmt.call(@bottom_right) << ' ' << fmt.call(@bottom_left)
      end
    end
  end

  struct RectCmd
    getter clip : Rect
    getter rect : Rect
    getter rounding : Float64
    # Per-corner rounding for the FILL: when set, each corner arcs
    # with its own radius (overrides `rounding` for the fill; the
    # uniform stroke path is per-corner too — only the per-side
    # `stroke_sides` path still reads `rounding`).
    getter corners : CornerRadii?
    getter fill : Color32?
    # Optional second fill color: when set, the fill becomes a vertical
    # gradient from `fill` (top) to `fill2` (bottom) — the backend
    # interpolates per-vertex (Gouraud).
    getter fill2 : Color32?
    getter stroke_color : Color32?
    getter stroke_width : Float64
    # Per-side borders: when set, each side carries its own width/color
    # and the uniform stroke pair above is ignored (it still carries
    # the fallback base for consumers reading the cmd). Painting goes
    # through the standard two-rect overlay — see
    # `.border_overlay_layers`.
    getter stroke_sides : StrokeSides?
    # Blend-off fill: OVERWRITE dst (rgb AND alpha) instead of blending
    # — see Painter#rect_replace.
    getter? replace : Bool
    # 135° gradient: fill→fill2 along the top-left→bottom-right diagonal
    # (CSS linear-gradient(135deg)); vertical when false.
    getter? diag : Bool
    # A full CSS-like gradient (`background-gradient`): when set, the
    # fill paint evaluates it per pixel (CPU) / per vertex (Gouraud)
    # instead of the flat `fill`/`fill2` pair. Geometry is relative to
    # `rect` (see `Gradient#color_at`), so it survives transforms.
    getter gradient : Gradient?
    # Rounded-clip corner radii carried next to `clip` (see
    # Painter#clip_apply): nil = a plain rect clip, otherwise the
    # backends clip to `clip` rounded by these per-corner radii.
    # Set by the painter's subtree-clip brackets, never by callers.
    getter clip_corners : CornerRadii?

    def initialize(@clip : Rect, @rect : Rect, @rounding : Float64,
                   @fill : Color32?, @stroke_color : Color32?,
                   @stroke_width : Float64, @fill2 : Color32? = nil,
                   @stroke_sides : StrokeSides? = nil,
                   @corners : CornerRadii? = nil,
                   @replace : Bool = false, @diag : Bool = false,
                   @gradient : Gradient? = nil,
                   @clip_corners : CornerRadii? = nil)
    end

    # Copy with a replaced clip (and its corner radii) — what
    # Painter#clip_apply and the transform pass rewrite subtrees with.
    def with_clip(clip : Rect, clip_corners : CornerRadii?) : self
      RectCmd.new(clip, @rect, @rounding, @fill, @stroke_color,
        @stroke_width, @fill2, @stroke_sides, @corners, @replace, @diag,
        @gradient, clip_corners)
    end
  end

  # The framework's standard border algorithm (the `clipping` demo's
  # LEFT case): a bordered background is a pure OVERLAY of nested
  # rounded fills — no stroke geometry, no clip masks. The outer rect
  # carries the border color; the background rect sits on top, inset
  # by each side's width, its corner radius = outer radius − the
  # widest adjacent border, so the invariant inner + borders = outer
  # holds per axis and the inner curve stays inside the outer arc (a
  # border wider than the radius collapses to a square corner, like
  # CSS). Per-side colors layer the same way: each side's color fills
  # everything not yet revealed, the next inset uncovers its band, the
  # background uncovers the last side.
  #
  # Returns the fill-only RectCmds back-to-front, or nil when there is
  # nothing to decompose: no background under the border, or no side
  # actually on (those keep the plain stroke path — the uniform band /
  # per-side ring the backends tessellate directly).
  def self.border_overlay_layers(cmd : RectCmd) : Array(RectCmd)?
    sides = cmd.stroke_sides
    if !sides && (sc = cmd.stroke_color) && cmd.stroke_width > 0.0
      w = cmd.stroke_width
      sides = StrokeSides.new(
        SideStroke.new(w, sc), SideStroke.new(w, sc),
        SideStroke.new(w, sc), SideStroke.new(w, sc))
    end
    return nil unless sides
    # A side participates only when it is both wide enough and not
    # transparent — an alpha-0 border must not push the background in.
    return nil unless (sides.top.on? && sides.top.color.a > 0) ||
                      (sides.right.on? && sides.right.color.a > 0) ||
                      (sides.bottom.on? && sides.bottom.color.a > 0) ||
                      (sides.left.on? && sides.left.color.a > 0)
    return nil unless cmd.fill || cmd.fill2 || cmd.gradient

    base = cmd.corners || CornerRadii.uniform(cmd.rounding)
    rect = cmd.rect
    tl = base.top_left
    tr = base.top_right
    br = base.bottom_right
    bl = base.bottom_left
    layers = [] of RectCmd

    seq = {sides.top, sides.right, sides.bottom, sides.left}
    on = seq.select { |s| s.on? && s.color.a > 0 }
    mono = on.map(&.color).uniq.size == 1
    if mono
      # One border color: a single outer plate, then inset every side.
      if (l = overlay_layer(cmd, rect, base, on.first.color, nil, nil, false))
        layers << l
      end
    end
    # Top → right → bottom → left. With per-side colors each side
    # first fills everything not yet revealed in its color; the next
    # inset then uncovers its band (the background below uncovers the
    # final side). Insetting moves the edge in by the side's width and
    # clamps its two corner radii to base − width — concentric with
    # the outer arc under a uniform border, the CSS r − w collapse
    # when the width reaches the radius.
    seq.each_with_index do |s, i|
      next unless s.on? && s.color.a > 0
      unless mono
        if (l = overlay_layer(cmd, rect,
              CornerRadii.new(tl, tr, br, bl), s.color, nil, nil, false))
          layers << l
        end
      end
      case i
      when 0 # top
        rect = Rect.new(Pos2.new(rect.min.x, rect.min.y + s.width), rect.max)
        tl = {tl, {base.top_left - s.width, 0.0}.max}.min
        tr = {tr, {base.top_right - s.width, 0.0}.max}.min
      when 1 # right
        rect = Rect.new(rect.min, Pos2.new(rect.max.x - s.width, rect.max.y))
        tr = {tr, {base.top_right - s.width, 0.0}.max}.min
        br = {br, {base.bottom_right - s.width, 0.0}.max}.min
      when 2 # bottom
        rect = Rect.new(rect.min, Pos2.new(rect.max.x, rect.max.y - s.width))
        br = {br, {base.bottom_right - s.width, 0.0}.max}.min
        bl = {bl, {base.bottom_left - s.width, 0.0}.max}.min
      when 3 # left
        rect = Rect.new(Pos2.new(rect.min.x + s.width, rect.min.y), rect.max)
        tl = {tl, {base.top_left - s.width, 0.0}.max}.min
        bl = {bl, {base.bottom_left - s.width, 0.0}.max}.min
      end
    end

    # The background: the original fill inside every border band, its
    # corner radii already shrunk by the adjacent insets above.
    if (l = overlay_layer(cmd, rect, CornerRadii.new(tl, tr, br, bl),
          cmd.fill, cmd.fill2, cmd.gradient, cmd.diag?))
      layers << l
    end
    layers.empty? ? nil : layers
  end

  # One overlay layer as a fill-only RectCmd (nil when degenerate).
  # A uniform radius rides the scalar `rounding` slot so every backend
  # takes its existing uniform path; per-corner values go via `corners`.
  private def self.overlay_layer(cmd : RectCmd, rect : Rect, c : CornerRadii,
                                 fill : Color32?, fill2 : Color32?,
                                 grad : Gradient?, diag : Bool) : RectCmd?
    return nil if rect.width <= 0.0 || rect.height <= 0.0
    if c.uniform?
      RectCmd.new(cmd.clip, rect, {c.top_left, 0.0}.max, fill, nil, 0.0,
        fill2, nil, nil, cmd.replace?, diag, gradient: grad)
    else
      RectCmd.new(cmd.clip, rect, 0.0, fill, nil, 0.0,
        fill2, nil, c, cmd.replace?, diag, gradient: grad)
    end
  end

  struct TextCmd
    getter clip : Rect
    getter pos : Pos2
    getter text : String
    getter size : Float64
    getter color : Color32
    # Named font family the text draws through
    # (`Context#fonts_for`): nil = the primary stack (so every
    # pre-existing command is unaffected), "monospace" → the mono
    # stack, any registered name (`Sokol.register_font`) → that stack.
    getter family : String?
    # Real variant faces: bold/italic shift the primary stack to its
    # installed variant (`Context#fonts_for` — a missing variant draws
    # the base face's own glyphs, no emulation).
    getter? bold : Bool
    getter? italic : Bool
    getter clip_corners : CornerRadii?

    def initialize(@clip : Rect, @pos : Pos2, @text : String,
                   @size : Float64, @color : Color32, @family : String? = nil,
                   @bold : Bool = false, @italic : Bool = false,
                   @clip_corners : CornerRadii? = nil)
    end

    def with_clip(clip : Rect, clip_corners : CornerRadii?) : self
      TextCmd.new(clip, @pos, @text, @size, @color, @family, bold?,
        italic?, clip_corners)
    end
  end

  # egui `epaint::CircleShape` — filled disc and/or stroked ring.
  struct CircleCmd
    getter clip : Rect
    getter center : Pos2
    getter radius : Float64
    getter fill : Color32?
    getter stroke : Color32?
    getter stroke_width : Float64
    getter clip_corners : CornerRadii?

    def initialize(@clip : Rect, @center : Pos2, @radius : Float64,
                   @fill : Color32?, @stroke : Color32?,
                   @stroke_width : Float64,
                   @clip_corners : CornerRadii? = nil)
    end

    def with_clip(clip : Rect, clip_corners : CornerRadii?) : self
      CircleCmd.new(clip, @center, @radius, @fill, @stroke,
        @stroke_width, clip_corners)
    end
  end

  # egui `epaint::PathShape` reduced to a straight segment with a stroke
  # width (the tessellator turns strokes into quads; we do the same in
  # the backend).
  struct LineCmd
    getter clip : Rect
    getter p1 : Pos2
    getter p2 : Pos2
    getter width : Float64
    getter color : Color32
    getter clip_corners : CornerRadii?

    def initialize(@clip : Rect, @p1 : Pos2, @p2 : Pos2,
                   @width : Float64, @color : Color32,
                   @clip_corners : CornerRadii? = nil)
    end

    def with_clip(clip : Rect, clip_corners : CornerRadii?) : self
      LineCmd.new(clip, @p1, @p2, @width, @color, clip_corners)
    end
  end

  # One filled triangle (egui `epaint::Mesh` reduced to a primitive):
  # the building block for shapes composed of straight edges — the
  # slider's pentagon handle paints its roof as one of these.
  struct TriCmd
    getter clip : Rect
    getter a : Pos2
    getter b : Pos2
    getter c : Pos2
    getter fill : Color32
    getter clip_corners : CornerRadii?

    def initialize(@clip : Rect, @a : Pos2, @b : Pos2, @c : Pos2,
                   @fill : Color32, @clip_corners : CornerRadii? = nil)
    end

    def with_clip(clip : Rect, clip_corners : CornerRadii?) : self
      TriCmd.new(clip, @a, @b, @c, @fill, clip_corners)
    end
  end

  # Circular arc (egui `epaint` arc paths; used by Spinner and later the
  # color wheel). Angles in radians, clockwise from the +x axis.
  struct ArcCmd
    getter clip : Rect
    getter center : Pos2
    getter radius : Float64
    getter start_angle : Float64
    getter end_angle : Float64
    getter width : Float64
    getter color : Color32
    getter clip_corners : CornerRadii?

    def initialize(@clip : Rect, @center : Pos2, @radius : Float64,
                   @start_angle : Float64, @end_angle : Float64,
                   @width : Float64, @color : Color32,
                   @clip_corners : CornerRadii? = nil)
    end

    def with_clip(clip : Rect, clip_corners : CornerRadii?) : self
      ArcCmd.new(clip, @center, @radius, @start_angle, @end_angle,
        @width, @color, clip_corners)
    end
  end

  # Textured quad (egui `epaint::ImageShape`): `rect` on screen, `uv`
  # maps into the texture (0..1, origin top-left), `tint` multiplies.
  # Texture handles come from a TextureRegistry (backend-owned).
  # `nearest` picks point sampling — pixel-art surfaces (a Paint
  # canvas) must not blur under fractional scaling.
  struct ImageCmd
    getter clip : Rect
    getter rect : Rect
    getter uv : Rect
    getter texture_id : UInt64
    getter tint : Color32
    getter? nearest : Bool
    getter clip_corners : CornerRadii?

    def initialize(@clip : Rect, @rect : Rect, @uv : Rect,
                   @texture_id : UInt64, @tint : Color32,
                   @nearest : Bool = false,
                   @clip_corners : CornerRadii? = nil)
    end

    def with_clip(clip : Rect, clip_corners : CornerRadii?) : self
      ImageCmd.new(clip, @rect, @uv, @texture_id, @tint, nearest?,
        clip_corners)
    end
  end

  # One batched 3D mesh (egui-cr native — the Viewport3D primitive):
  # SoA-packed vertices (`x,y,z` f32 + `r,g,b,a` u8, 16 bytes each)
  # drawn through a depth-tested sgl pipeline under `mvp`
  # (projection × view × model, column-major Float32) mapped onto
  # `viewport` (points). `primitive` is :triangles or :lines; `blend`
  # picks the no-depth-write translucent pipeline over the opaque one.
  # The backend restores the default 2D pixel-space state afterwards, so
  # ordinary UI painted later is unaffected.
  struct Mesh3DCmd
    getter clip : Rect
    getter viewport : Rect
    getter mvp : StaticArray(Float32, 16)
    getter data : Bytes
    getter primitive : Symbol
    getter? blend : Bool
    getter clip_corners : CornerRadii?

    def initialize(@clip : Rect, @viewport : Rect,
                   @mvp : StaticArray(Float32, 16), @data : Bytes,
                   @primitive : Symbol, @blend : Bool = false,
                   @clip_corners : CornerRadii? = nil)
    end

    def with_clip(clip : Rect, clip_corners : CornerRadii?) : self
      Mesh3DCmd.new(clip, @viewport, @mvp, @data, @primitive, blend?,
        clip_corners)
    end
  end

  # CSS `box-shadow` (no upstream egui counterpart — upstream
  # `epaint::Shadow` has no inset and lives in the tessellator's
  # feathering instead): a blurred band around (outset) or inside
  # (inset) a rounded rect. `blur`/`spread` in points; `offset`
  # shifts the caster rect (outset) or pushes the band towards the
  # opposite edge, CSS-style (`inset 0 1px 0` — y+1 down — paints a
  # band along the TOP edge). The backend approximates the gaussian
  # falloff with per-vertex gradient bands (Gouraud) — the same
  # machinery as `fill2` gradients.
  struct ShadowCmd
    getter clip : Rect
    getter rect : Rect
    getter rounding : Float64
    getter blur : Float64
    getter spread : Float64
    getter offset : Vec2
    getter color : Color32
    getter? inset : Bool
    getter clip_corners : CornerRadii?

    def initialize(@clip : Rect, @rect : Rect, @rounding : Float64,
                   @blur : Float64, @spread : Float64, @offset : Vec2,
                   @color : Color32, @inset : Bool,
                   @clip_corners : CornerRadii? = nil)
    end

    def with_clip(clip : Rect, clip_corners : CornerRadii?) : self
      ShadowCmd.new(clip, @rect, @rounding, @blur, @spread, @offset,
        @color, inset?, clip_corners)
    end
  end

  struct NoopCmd
    def with_clip(clip : Rect, clip_corners : CornerRadii?) : self
      self
    end
  end

  alias PaintCmd = RectCmd | TextCmd | CircleCmd | LineCmd | TriCmd | ArcCmd | ImageCmd | ShadowCmd | Mesh3DCmd | NoopCmd

  class Painter
    # A bracketed subtree transform (plans/NATIVE_HTML_DEMO.md §3.2):
    # everything emitted between #push_transform and #pop_transform is
    # scaled around `pivot`, shifted by an offset and faded by
    # `opacity` — the immediate-mode counterpart of Raven's post-factum
    # `rvn_drawlist_transform` (widget/anim.c). Clip rects are NOT
    # transformed and neither is hit-testing: layout stays in place
    # from the first frame, only the emitted geometry moves (Raven's
    # appear semantics).
    #
    # The pivot may be DEFERRED: a caller that learns its rect only
    # after its children have run (`Ui#box`) pushes without one and
    # supplies it at #pop_transform; the frame then owns a bracket
    # [start, size) of the command list and transforms that range when
    # it pops — a pass scoped to the frame's own commands, never a
    # rewrite of the whole list. A frame pushed WITH a pivot transforms
    # each command as it is emitted. Frames nest; the transforms
    # compose inner-first either way.
    class TransformFrame
      getter scale_x : Float64
      getter scale_y : Float64
      getter offset_x : Float64
      getter offset_y : Float64
      getter opacity : Float64
      property pivot : Pos2?
      property start : Int32
      # True when the frame was pushed WITHOUT a pivot: its bracket is
      # transformed in one pass at #pop_transform (an immediate frame
      # transforms at emit time instead and its pop is a plain pop).
      getter? deferred : Bool
      # `Painter#set` calls whose slot sits BELOW the frame's bracket
      # (a container's back-patched chrome, reserved before the push) —
      # transformed when the frame pops.
      getter deferred_sets : Array(Tuple(Int32, PaintCmd))

      def initialize(pivot : Pos2?, @start : Int32, @scale_x : Float64,
                     @scale_y : Float64, @offset_x : Float64,
                     @offset_y : Float64, @opacity : Float64)
        @pivot = pivot
        @deferred = pivot.nil?
        @deferred_sets = [] of Tuple(Int32, PaintCmd)
      end

      # The average axis scale — what radii, stroke widths, font sizes
      # and blurs scale by (the GPU would scale x and y apart; the CPU
      # transform approximates with one factor).
      def k : Float64
        (@scale_x + @scale_y) / 2.0
      end

      def x(px : Float64) : Float64
        @pivot.not_nil!.x + (px - @pivot.not_nil!.x) * @scale_x + @offset_x
      end

      def y(py : Float64) : Float64
        @pivot.not_nil!.y + (py - @pivot.not_nil!.y) * @scale_y + @offset_y
      end

      def pt(p : Pos2) : Pos2
        Pos2.new(x(p.x), y(p.y))
      end

      def scale_rect(r : Rect) : Rect
        Rect.new(pt(r.min), pt(r.max))
      end

      def fade(c : Color32) : Color32
        return c if @opacity >= 1.0
        Color32.new(c.r, c.g, c.b,
          (c.a.to_f64 * @opacity.clamp(0.0, 1.0)).round.to_u8)
      end

      def fade_opt(c : Color32?) : Color32?
        c && fade(c)
      end

      def apply(cmd : PaintCmd) : PaintCmd
        case cmd
        when RectCmd
          sides = cmd.stroke_sides.try { |s|
            StrokeSides.new(
              SideStroke.new(s.top.width * k, fade(s.top.color)),
              SideStroke.new(s.right.width * k, fade(s.right.color)),
              SideStroke.new(s.bottom.width * k, fade(s.bottom.color)),
              SideStroke.new(s.left.width * k, fade(s.left.color)))
          }
          corners = cmd.corners.try { |c|
            CornerRadii.new(c.top_left * k, c.top_right * k,
              c.bottom_right * k, c.bottom_left * k)
          }
          RectCmd.new(cmd.clip, scale_rect(cmd.rect), cmd.rounding * k,
            fade_opt(cmd.fill), fade_opt(cmd.stroke_color),
            cmd.stroke_width * k, fade_opt(cmd.fill2), sides, corners,
            cmd.replace?, gradient: cmd.gradient,
            clip_corners: cmd.clip_corners)
        when TextCmd
          TextCmd.new(cmd.clip, pt(cmd.pos), cmd.text, cmd.size * k,
            fade(cmd.color), cmd.family, cmd.bold?, cmd.italic?,
            cmd.clip_corners)
        when CircleCmd
          CircleCmd.new(cmd.clip, pt(cmd.center), cmd.radius * k,
            fade_opt(cmd.fill), fade_opt(cmd.stroke), cmd.stroke_width * k,
            cmd.clip_corners)
        when LineCmd
          LineCmd.new(cmd.clip, pt(cmd.p1), pt(cmd.p2), cmd.width * k,
            fade(cmd.color), cmd.clip_corners)
        when TriCmd
          TriCmd.new(cmd.clip, pt(cmd.a), pt(cmd.b), pt(cmd.c),
            fade(cmd.fill), cmd.clip_corners)
        when ArcCmd
          ArcCmd.new(cmd.clip, pt(cmd.center), cmd.radius * k,
            cmd.start_angle, cmd.end_angle, cmd.width * k, fade(cmd.color),
            cmd.clip_corners)
        when ImageCmd
          # `uv` maps into the texture and stays — only the screen rect
          # moves (the same quad, resized).
          ImageCmd.new(cmd.clip, scale_rect(cmd.rect), cmd.uv,
            cmd.texture_id, fade(cmd.tint), cmd.nearest?, cmd.clip_corners)
        when ShadowCmd
          ShadowCmd.new(cmd.clip, scale_rect(cmd.rect), cmd.rounding * k,
            cmd.blur * k, cmd.spread * k,
            Vec2.new(cmd.offset.x * @scale_x, cmd.offset.y * @scale_y),
            fade(cmd.color), cmd.inset?, cmd.clip_corners)
        else
          # Mesh3DCmd carries its own mvp, NoopCmd nothing — untouched.
          cmd
        end
      end
    end

    getter commands : Array(PaintCmd)

    def initialize
      @commands = [] of PaintCmd
      @layers = [] of Int32
      @layer = Order::Background.z
      @clip = Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))
      @xforms = [] of TransformFrame
      # Counting-sort scratch for #commands_in_layer_order — z is
      # clamped into [0, MAX_LAYER_Z] by both layer setters, so the
      # buckets fit a fixed array reused across frames.
      @z_counts = Array(Int32).new(MAX_LAYER_Z + 1, 0)
      @z_cursors = Array(Int32).new(MAX_LAYER_Z + 1, 0)
      # Bumped on every push/pop_transform: the paint cache captures
      # only spans with a stable epoch (a transform bracket inside the
      # span would double-transform the cached commands on replay).
      @xform_epoch = 0
    end

    def clear : Nil
      @commands.clear
      @layers.clear
      @layer = Order::Background.z
      @clip = Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))
      @xforms.clear
    end

    # Which layer subsequently pushed commands belong to (egui
    # `Painter::with_layer_id`): either a named Order or an explicit
    # numeric z (see `LayerId`).
    def layer : Int32
      @layer
    end

    def layer=(order : Order)
      @layer = order.z
    end

    def layer=(z : Int32)
      @layer = z.clamp(0, MAX_LAYER_Z)
    end

    def clip=(rect : Rect)
      @clip = rect
    end

    def clip : Rect
      @clip
    end

    # --- rounded subtree clip (border-radius content clipping) ----------
    #
    # A container with a non-zero border radius must clip everything its
    # subtree paints to the ROUNDED shape, not just the rect bounds —
    # scrolled content otherwise bleeds past the curved corners. The
    # clip cannot be baked while the children run: a #box learns its
    # final rect only after them (the same reason its chrome is
    # back-patched through #set). So the container MARKS the command
    # list before the children, and once the rect exists it re-clips
    # the bracketed range: every command's clip intersects the rect and
    # carries the corner radii (`clip_corners`), which the backends
    # enforce per pixel.
    #
    # Recursion is free by nesting: an inner bracket bakes its tighter
    # clip first, the outer pass then intersects again and merges the
    # radii per corner (CornerRadii#merge). Commands in a DIFFERENT
    # painter layer than the mark (popups riding Foreground) are left
    # alone — a menu opening inside a rounded card must not be cut by
    # the card.

    def clip_mark : Tuple(Int32, Int32)
      {@commands.size, @layer}
    end

    def clip_apply(mark : Tuple(Int32, Int32), rect : Rect,
                   corners : CornerRadii) : Nil
      radii = corners.fit(rect)
      return if radii.max <= 0.0
      start, layer = mark
      (start...@commands.size).each do |i|
        next unless @layers[i] == layer
        cmd = @commands[i]
        next if cmd.is_a?(NoopCmd)
        clip = cmd_clip(cmd)
        next unless clip.intersects?(rect)
        merged = (old = cmd_clip_corners(cmd)) ? old.merge(radii).fit(clip) : radii
        @commands[i] = cmd.with_clip(clip.intersect(rect), merged)
      end
    end

    private def cmd_clip(cmd : PaintCmd) : Rect
      case cmd
      when RectCmd     then cmd.clip
      when TextCmd     then cmd.clip
      when CircleCmd   then cmd.clip
      when LineCmd     then cmd.clip
      when TriCmd      then cmd.clip
      when ArcCmd      then cmd.clip
      when ImageCmd    then cmd.clip
      when ShadowCmd   then cmd.clip
      when Mesh3DCmd   then cmd.clip
      when NoopCmd     then Rect.infinite
      else                  Rect.infinite
      end
    end

    private def cmd_clip_corners(cmd : PaintCmd) : CornerRadii?
      case cmd
      when RectCmd     then cmd.clip_corners
      when TextCmd     then cmd.clip_corners
      when CircleCmd   then cmd.clip_corners
      when LineCmd     then cmd.clip_corners
      when TriCmd      then cmd.clip_corners
      when ArcCmd      then cmd.clip_corners
      when ImageCmd    then cmd.clip_corners
      when ShadowCmd   then cmd.clip_corners
      when Mesh3DCmd   then cmd.clip_corners
      else                  nil
      end
    end

    def add(cmd : PaintCmd) : Int32
      cmd = emit_xform(cmd) unless @xforms.empty?
      @commands << cmd
      @layers << @layer
      @commands.size - 1
    end

    # Command-list length — the paint-cache capture span start.
    def snapshot : Int32
      @commands.size
    end


    # Reserve a slot now, fill it later (egui `Painter::set`).
    def add_noop : Int32
      add(NoopCmd.new)
    end

    # --- paint cache capture (see paint_cache.cr) ------------------------
    #
    # The frame's transform bracket churn counter (capture guard).
    getter xform_epoch : Int32

    # Snapshot the commands (and their layer tags) emitted since index
    # `start` — the paint-cache bucket of a widget span. nil when the
    # range was truncated away (a Flex measure pass cut into it) or
    # the list shrank below `start` for any other reason. COPIES: a
    # later back-patch (#set) inside the range cannot mutate what the
    # cache replays.
    def take_bucket(start : Int32) : Tuple(Array(PaintCmd), Array(Int32))?
      return nil if start > @commands.size
      cmds = Array(PaintCmd).new(@commands.size - start)
      layers = Array(Int32).new(@commands.size - start)
      (start...@commands.size).each do |i|
        cmds << @commands[i]
        layers << @layers[i]
      end
      {cmds, layers}
    end

    # Re-emit a cached command at its recorded layer (paint-cache
    # replay): the layer tag is part of the cached state, so playback
    # restores it exactly even when the ambient layer moved on.
    def replay_add(z : Int32, cmd : PaintCmd) : Nil
      saved = @layer
      @layer = z
      add(cmd)
      @layer = saved
    end

    def set(index : Int32, cmd : PaintCmd) : Nil
      if (top = @xforms.last?)
        if top.pivot
          # Immediate frames transform at emit time.
          @commands[index] = emit_xform(cmd)
        elsif index >= top.start
          # Inside the deferred bracket: written raw, the pop pass
          # transforms it with the rest of the range.
          @commands[index] = cmd
        else
          # Below the bracket (this container's back-patched chrome) —
          # held until the pivot exists, transformed at pop.
          top.deferred_sets << {index, cmd}
        end
      else
        @commands[index] = cmd
      end
    end

    # --- subtree transform (see TransformFrame) -------------------------

    # Begin a transform bracket for everything emitted until the
    # matching #pop_transform. `pivot` may be nil to defer it to the
    # pop (the bracket range is transformed then); a frame pushed with
    # its pivot transforms every command at emit time.
    def push_transform(pivot : Pos2?, scale_x : Float64, scale_y : Float64,
                       offset_x : Float64, offset_y : Float64,
                       opacity : Float64) : Nil
      @xforms << TransformFrame.new(pivot, @commands.size, scale_x,
        scale_y, offset_x, offset_y, opacity)
      @xform_epoch += 1
    end

    # End the innermost transform bracket. A deferred frame must be
    # given its `pivot` here; the commands of its bracket (and its
    # deferred sets) are transformed around it now. An immediate frame
    # already transformed at emit time and only pops.
    def pop_transform(pivot : Pos2? = nil) : Nil
      frame = @xforms.pop
      raise "pop_transform without a matching push_transform" unless frame
      p = pivot || frame.pivot
      raise "pop_transform: a deferred frame needs its pivot here" unless p
      frame.pivot = p
      return unless frame.deferred?
      base = @xforms.size
      (frame.start...@commands.size).each do |i|
        @commands[i] = compose_below(base, frame.apply(@commands[i]))
      end
      frame.deferred_sets.each do |index, cmd|
        @commands[index] = compose_below(base, frame.apply(cmd))
      end
    end

    # Apply the consecutive IMMEDIATE frames from the top of the stack
    # (inner-first), stopping at the first deferred one — its bracket
    # pass catches the command later, and the composition order
    # inner-first stays correct either way.
    private def emit_xform(cmd : PaintCmd) : PaintCmd
      i = @xforms.size - 1
      while i >= 0 && (f = @xforms[i]) && f.pivot
        cmd = f.apply(cmd)
        i -= 1
      end
      cmd
    end

    # A deferred frame's pop pass transforms its range AFTER the frames
    # above it already did at emit time — the frames BELOW it (base =
    # stack size without them) still need their share, applied
    # inner-first, again stopping at the next deferred frame.
    private def compose_below(base : Int32, cmd : PaintCmd) : PaintCmd
      i = base - 1
      while i >= 0 && (f = @xforms[i]) && f.pivot
        cmd = f.apply(cmd)
        i -= 1
      end
      cmd
    end

    def rect(rect : Rect, rounding : Float64 = 0.0,
             fill : Color32? = nil, stroke_color : Color32? = nil,
             stroke_width : Float64 = 1.0,
             fill2 : Color32? = nil,
             stroke_sides : StrokeSides? = nil,
             corners : CornerRadii? = nil,
             gradient : Gradient? = nil) : Nil
      # CSS `border-radius` semantics: the radius is clamped to half
      # the rect's short side, so an oversized value renders the
      # capsule (the classic `border-radius: 9999px` pill trick)
      # instead of the degenerate geometry the raw radius would give
      # the stroke path. The style-system spelling of the same thing
      # is the "capsule" rounding keyword (`StyleVars#rounding_px`).
      r = {rounding, 0.0}.max
      r = {r, {rect.width, rect.height}.min / 2.0}.min
      add(RectCmd.new(@clip, rect, r, fill, stroke_color,
        stroke_width, fill2, stroke_sides, corners, gradient: gradient))
    end

    # Replace-blend rect: instead of blending over the destination, it
    # OVERWRITES it — rgb AND alpha — with `color` given straight
    # (non-premultiplied); the command carries it premultiplied, ready
    # for an alpha-composited (per-pixel-transparent) swapchain. This
    # is the primitive for a widget that must show the desktop through
    # an otherwise opaque UI (the terminal grid): it punches the exact
    # alpha into the framebuffer, no blending needed behind it. In a
    # normal opaque window it degenerates to a plain solid rect.
    def rect_replace(rect : Rect, color : Color32) : Nil
      a = color.a
      pre = Color32.new(
        (color.r.to_f64 * a / 255.0 + 0.5).floor.to_u8,
        (color.g.to_f64 * a / 255.0 + 0.5).floor.to_u8,
        (color.b.to_f64 * a / 255.0 + 0.5).floor.to_u8, a)
      add(RectCmd.new(@clip, rect, 0.0, pre, nil, 0.0, replace: true))
    end

    # CSS `box-shadow` — see `ShadowCmd`. Paint order is the caller's
    # business, mirroring CSS: an outset shadow goes UNDER the widget
    # (call before the fill rect), an inset one over it (after).
    def box_shadow(rect : Rect, color : Color32, blur : Float64 = 4.0,
                   rounding : Float64 = 0.0, spread : Float64 = 0.0,
                   offset : Vec2 = Vec2.new(0.0, 0.0),
                   inset : Bool = false) : Nil
      return if blur <= 0.0 && spread <= 0.0 &&
                offset.x.abs < 0.5 && offset.y.abs < 0.5
      add(ShadowCmd.new(@clip, rect, rounding, blur, spread, offset,
        color, inset))
    end

    # Capsule (stadium): a rect whose ends are semicircles — the
    # rounding is half the short side (the painter/backends clamp to
    # exactly that, this only names the intent; the style-system form
    # is the "capsule" rounding keyword — see `StyleVars#rounding_px`).
    def capsule(rect : Rect, fill : Color32? = nil,
                stroke_color : Color32? = nil,
                stroke_width : Float64 = 1.0) : Nil
      rect(rect, {rect.width, rect.height}.min / 2.0, fill, stroke_color,
        stroke_width)
    end

    # Vertical gradient fill (top `c1` → bottom `c2`).
    def rect_gradient(rect : Rect, rounding : Float64, c1 : Color32,
                      c2 : Color32) : Nil
      rect(rect, rounding, fill: c1, fill2: c2)
    end

    # 135° diagonal gradient (`linear-gradient(135deg, c1, c2)`): c1 at
    # the top-left corner → c2 at the bottom-right, Gouraud per-vertex.
    def rect_gradient_diag(rect : Rect, rounding : Float64, c1 : Color32,
                           c2 : Color32) : Nil
      add(RectCmd.new(@clip, rect, rounding, c1, nil, 0.0, c2, diag: true))
    end

    # Draw text with `pos` as the LEFT-CENTER of the text bounding box
    # (upstream anchors at the galley's left edge + baseline; backends
    # convert using their font metrics — see backend/sokol/fontstash).
    # `family:` draws through that named stack (`Context#fonts_for`);
    # nil uses the primary one. `bold:`/`italic:` draw through the
    # primary stack's REAL variant faces (a missing variant degrades to
    # the base face — no emulation).
    def text(pos : Pos2, text : String, size : Float64, color : Color32,
             family : String? = nil, bold : Bool = false,
             italic : Bool = false) : Nil
      return if text.empty? # nothing to rasterize (Fonts#fit gave up)
      add(TextCmd.new(@clip, pos, text, size, color, family, bold, italic))
    end

    # Paint a laid-out Galley with `pos` as its top-left corner
    # (upstream `Painter::galley`). Emits one TextCmd per row run —
    # that's where per-run colors come from — plus underline lines.
    # `family:` is the stack the galley was laid out with, so the draw
    # commands hit the same font the measurement used; a run carrying
    # its OWN family (inline code) or variant flags (bold/italic)
    # overrides it per run — `resolve` (a `Context#fonts_for` closure)
    # supplies that stack for the underline/strike/chip width
    # measurement, exactly like `Fonts#layout` did for the wrap.
    #
    # `selection` paints per-row highlight strips (row index, x0, x1 in
    # galley coordinates) BETWEEN the chips and the glyphs — an opaque
    # chip painted over the highlight is what made selected inline code
    # look unselectable.
    def paint_galley(pos : Pos2, galley : Galley, fonts : Fonts,
                     default_color : Color32, family : String? = nil,
                     resolve : ((String?, Bool, Bool) -> Fonts)? = nil,
                     selection : Array(Tuple(Int32, Float64, Float64))? = nil,
                     selection_color : Color32? = nil,
                     row_align : Symbol? = nil) : Nil
      # Cull rows outside the clip rect: a scrolled textarea with a
      # multi-megabyte galley must not tessellate (and rasterize) every
      # row of the buffer each frame — only the visible window. Rows
      # are laid out top-to-bottom, so the scan can stop at the bottom.
      clip_top = @clip.min.y
      clip_bottom = @clip.max.y
      galley.rows.each_with_index do |row, ri|
        row_top = pos.y + row.y
        next if row_top + row.height < clip_top
        break if row_top > clip_bottom
        # Per-row horizontal alignment (CSS text-align semantics: each
        # LINE is placed by its own width inside the galley block) —
        # the Label#align plumbing passes :center/:right through here.
        dx = case row_align
             when :center then {galley.size.x - row.width, 0.0}.max / 2.0
             when :right  then {galley.size.x - row.width, 0.0}.max
             else              0.0
             end
        # The row's SHARED baseline (see Galley::Row#ascent): every run
        # aligns on it, whatever stack it draws through. Each run's
        # TextCmd still anchors the em-box CENTER (`#text` semantics the
        # terminal and other direct callers rely on), so the baseline
        # converts back per run through that run's own metrics — for a
        # single-stack row this is exactly the old row-center anchor.
        baseline = row_top + row.ascent
        # Pass 1: chips (backgrounded runs) — under everything else.
        row.runs.each do |run|
          next unless (bg = run.background)
          run_fonts = resolve ? resolve.not_nil!.call(run.family, run.bold?, run.italic?) : fonts
          asc, desc = run_fonts.metrics_at(run.size)
          w = run_fonts.measure(run.text, run.size).x
          pad_x = run.size * 0.4
          chip_h = {run.size * 1.4, row.height}.min
          # The chip centers on the run's em-box (baseline-derived) and
          # clamps into the row box so it never bleeds into
          # neighboring lines or blocks; a roomier line_height (markdown
          # body: 1.5) leaves the leading the chip needs. `Fonts#layout`
          # reserved pad_x of advance on each side (add_margin), so the
          # chip's edges meet the neighbouring text without overlap.
          chip_cy = {baseline - (asc + desc) / 2.0,
                     row_top + row.height - chip_h / 2.0}.min
          chip_cy = {chip_cy, row_top + chip_h / 2.0}.max
          rect(Rect.from_min_size(
            Pos2.new(pos.x + dx + run.x - pad_x, chip_cy - chip_h / 2.0),
            Vec2.new(w + pad_x * 2.0, chip_h)),
            6.0, bg)
        end
        # Selection strips: over the chips, under the glyphs.
        if selection && (color = selection_color)
          selection.each do |sri, x0, x1|
            next unless sri == ri && x1 > x0
            rect(Rect.from_min_size(
              Pos2.new(pos.x + dx + x0, row_top + 1.0),
              Vec2.new(x1 - x0, row.height - 2.0)),
              0.0, color)
          end
        end
        # Pass 2: glyphs + decorations.
        row.runs.each do |run|
          run_fonts = resolve ? resolve.not_nil!.call(run.family, run.bold?, run.italic?) : fonts
          asc, desc = run_fonts.metrics_at(run.size)
          run_pos = Pos2.new(pos.x + dx + run.x, baseline - (asc + desc) / 2.0)
          color = run.color || default_color
          run_family = run.family || family
          text(run_pos, run.text, run.size, color, run_family,
            run.bold?, run.italic?)
          if run.underline?
            w = run_fonts.measure(run.text, run.size).x
            underline_y = baseline + {1.5, run.size * 0.1}.max
            line(Pos2.new(run_pos.x, underline_y),
              Pos2.new(run_pos.x + w, underline_y), 1.0, color)
          end
          if run.strikethrough?
            w = run_fonts.measure(run.text, run.size).x
            strike_y = baseline - run.size * 0.3
            line(Pos2.new(run_pos.x, strike_y),
              Pos2.new(run_pos.x + w, strike_y), 1.0, color)
          end
        end
      end
    end

    def circle(center : Pos2, radius : Float64, fill : Color32? = nil,
               stroke : Color32? = nil, stroke_width : Float64 = 1.0) : Nil
      add(CircleCmd.new(@clip, center, radius, fill, stroke, stroke_width))
    end

    def circle_filled(center : Pos2, radius : Float64, fill : Color32) : Nil
      circle(center, radius, fill: fill)
    end

    def circle_stroke(center : Pos2, radius : Float64, stroke : Color32,
                      stroke_width : Float64 = 1.0) : Nil
      circle(center, radius, stroke: stroke, stroke_width: stroke_width)
    end

    def line(p1 : Pos2, p2 : Pos2, width : Float64, color : Color32) : Nil
      add(LineCmd.new(@clip, p1, p2, width, color))
    end

    # One filled triangle.
    def triangle(a : Pos2, b : Pos2, c : Pos2, fill : Color32) : Nil
      add(TriCmd.new(@clip, a, b, c, fill))
    end

    def arc(center : Pos2, radius : Float64, start_angle : Float64,
            end_angle : Float64, width : Float64, color : Color32) : Nil
      add(ArcCmd.new(@clip, center, radius, start_angle, end_angle,
        width, color))
    end

    # Full quad of the texture by default; `nearest` requests point
    # sampling (pixel-art canvases).
    def image(rect : Rect, texture_id : UInt64,
              uv : Rect? = nil, tint : Color32 = Color32.new(255, 255, 255, 255),
              nearest : Bool = false) : Nil
      uv ||= Rect.from_min_size(Pos2.new(0.0, 0.0), Vec2.new(1.0, 1.0))
      add(ImageCmd.new(@clip, rect, uv, texture_id, tint, nearest))
    end

    # One batched 3D mesh — see `Mesh3DCmd`. `data` is packed SoA
    # (16 bytes per vertex: x,y,z f32 + r,g,b,a u8); `viewport` is the
    # points-space rect the NDC cube maps onto.
    def mesh3d(viewport : Rect, mvp : Mat4, data : Bytes,
               primitive : Symbol = :triangles,
               blend : Bool = false) : Nil
      return if data.empty?
      packed = StaticArray(Float32, 16).new(0.0f32)
      16.times { |i| packed[i] = mvp.to_unsafe[i] }
      add(Mesh3DCmd.new(@clip, viewport, packed, data, primitive, blend))
    end

    # egui `GraphicLayers::drain(order)`: flatten per layer, back to
    # front — ascending z; within one z, push order (registration
    # order) decides, so a container's back-filled frame stays under
    # its contents.
    def commands_in_layer_order : Array(PaintCmd)
      # Counting sort over the clamped z range: count per z, prefix
      # the start offsets, then one stable placement pass — O(n + z),
      # no allocation besides the returned array (the old scan was
      # O(layers × commands), see FPS_OPTIMIZATION.md §7).
      n = @commands.size
      return Array(PaintCmd).new(0) if n.zero?
      counts = @z_counts
      cursors = @z_cursors
      counts.fill(0)
      @layers.each { |z| counts[z] += 1 }
      total = 0
      (0..MAX_LAYER_Z).each do |z|
        cursors[z] = total
        total += counts[z]
      end
      Array(PaintCmd).build(n) do |buffer|
        @commands.each_with_index do |cmd, i|
          z = @layers[i]
          buffer[cursors[z]] = cmd
          cursors[z] += 1
        end
        n
      end
    end
  end
end
