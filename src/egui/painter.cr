# The paint-list half of egui_upstream/crates/egui/src/painter.rs.
#
# Commands are tagged with the current layer (Order); within a layer,
# insertion order == paint order == stacking. `commands_in_layer_order`
# flattens back-to-front for the backend (egui GraphicLayers::drain).
#
# `add_noop` + `set` reproduce egui's `Frame` trick: reserve an index,
# lay out children, then back-patch the window background under them.

module Egui
  struct RectCmd
    getter clip : Rect
    getter rect : Rect
    getter rounding : Float64
    getter fill : Color32?
    # Optional second fill color: when set, the fill becomes a vertical
    # gradient from `fill` (top) to `fill2` (bottom) — the backend
    # interpolates per-vertex (Gouraud).
    getter fill2 : Color32?
    getter stroke_color : Color32?
    getter stroke_width : Float64
    # Blend-off fill: OVERWRITE dst (rgb AND alpha) instead of blending
    # — see Painter#rect_replace.
    getter? replace : Bool

    def initialize(@clip : Rect, @rect : Rect, @rounding : Float64,
                   @fill : Color32?, @stroke_color : Color32?,
                   @stroke_width : Float64, @fill2 : Color32? = nil,
                   @replace : Bool = false)
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
    # Synthetic styles (no separate faces): bold double-strikes the
    # glyphs, italic shears them — see backend `paint_text`.
    getter? bold : Bool
    getter? italic : Bool

    def initialize(@clip : Rect, @pos : Pos2, @text : String,
                   @size : Float64, @color : Color32, @family : String? = nil,
                   @bold : Bool = false, @italic : Bool = false)
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

    def initialize(@clip : Rect, @center : Pos2, @radius : Float64,
                   @fill : Color32?, @stroke : Color32?,
                   @stroke_width : Float64)
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

    def initialize(@clip : Rect, @p1 : Pos2, @p2 : Pos2,
                   @width : Float64, @color : Color32)
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

    def initialize(@clip : Rect, @center : Pos2, @radius : Float64,
                   @start_angle : Float64, @end_angle : Float64,
                   @width : Float64, @color : Color32)
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

    def initialize(@clip : Rect, @rect : Rect, @uv : Rect,
                   @texture_id : UInt64, @tint : Color32,
                   @nearest : Bool = false)
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

    def initialize(@clip : Rect, @rect : Rect, @rounding : Float64,
                   @blur : Float64, @spread : Float64, @offset : Vec2,
                   @color : Color32, @inset : Bool)
    end
  end

  struct NoopCmd
  end

  alias PaintCmd = RectCmd | TextCmd | CircleCmd | LineCmd | ArcCmd | ImageCmd | ShadowCmd | NoopCmd

  class Painter
    getter commands : Array(PaintCmd)

    def initialize
      @commands = [] of PaintCmd
      @layers = [] of Int32
      @layer = Order::Background.z
      @clip = Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))
    end

    def clear : Nil
      @commands.clear
      @layers.clear
      @layer = Order::Background.z
      @clip = Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))
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

    def add(cmd : PaintCmd) : Int32
      @commands << cmd
      @layers << @layer
      @commands.size - 1
    end

    # Reserve a slot now, fill it later (egui `Painter::set`).
    def add_noop : Int32
      add(NoopCmd.new)
    end

    def set(index : Int32, cmd : PaintCmd) : Nil
      @commands[index] = cmd
    end

    def rect(rect : Rect, rounding : Float64 = 0.0,
             fill : Color32? = nil, stroke_color : Color32? = nil,
             stroke_width : Float64 = 1.0,
             fill2 : Color32? = nil) : Nil
      add(RectCmd.new(@clip, rect, rounding, fill, stroke_color,
        stroke_width, fill2))
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

    # Vertical gradient fill (top `c1` → bottom `c2`).
    def rect_gradient(rect : Rect, rounding : Float64, c1 : Color32,
                      c2 : Color32) : Nil
      rect(rect, rounding, fill: c1, fill2: c2)
    end

    # Draw text with `pos` as the LEFT-CENTER of the text bounding box
    # (upstream anchors at the galley's left edge + baseline; backends
    # convert using their font metrics — see backend/sokol/fontstash).
    # `family:` draws through that named stack (`Context#fonts_for`);
    # nil uses the primary one. `bold:`/`italic:` are synthetic styles
    # applied by the backend (double strike / shear).
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
    # its OWN family (inline code) overrides it per run — `resolve`
    # (a `Context#fonts_for` closure) supplies that stack for the
    # underline width measurement, exactly like `Fonts#layout` did for
    # the wrap.
    def paint_galley(pos : Pos2, galley : Galley, fonts : Fonts,
                     default_color : Color32, family : String? = nil,
                     resolve : ((String?) -> Fonts)? = nil) : Nil
      # Cull rows outside the clip rect: a scrolled textarea with a
      # multi-megabyte galley must not tessellate (and rasterize) every
      # row of the buffer each frame — only the visible window. Rows
      # are laid out top-to-bottom, so the scan can stop at the bottom.
      clip_top = @clip.min.y
      clip_bottom = @clip.max.y
      galley.rows.each do |row|
        row_top = pos.y + row.y
        next if row_top + row.height < clip_top
        break if row_top > clip_bottom
        row_center_y = row_top + row.height / 2.0
        row.runs.each do |run|
          run_pos = Pos2.new(pos.x + run.x, row_center_y)
          color = run.color || default_color
          run_family = run.family || family
          run_fonts = run.family && resolve ? resolve.not_nil!.call(run.family) : fonts
          text(run_pos, run.text, run.size, color, run_family,
            run.bold?, run.italic?)
          if run.underline?
            w = run_fonts.measure(run.text, run.size).x
            underline_y = pos.y + row.y + row.height - 2.0
            line(Pos2.new(run_pos.x, underline_y),
              Pos2.new(run_pos.x + w, underline_y), 1.0, color)
          end
          if run.strikethrough?
            w = run_fonts.measure(run.text, run.size).x
            strike_y = pos.y + row.y + row.height * 0.58
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

    # egui `GraphicLayers::drain(order)`: flatten per layer, back to
    # front — ascending z; within one z, push order (registration
    # order) decides, so a container's back-filled frame stays under
    # its contents.
    def commands_in_layer_order : Array(PaintCmd)
      out = [] of PaintCmd
      @layers.uniq.sort.each do |z|
        @commands.each_with_index do |cmd, i|
          out << cmd if @layers[i] == z
        end
      end
      out
    end
  end
end
