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

    def initialize(@clip : Rect, @rect : Rect, @rounding : Float64,
                   @fill : Color32?, @stroke_color : Color32?,
                   @stroke_width : Float64, @fill2 : Color32? = nil)
    end
  end

  struct TextCmd
    getter clip : Rect
    getter pos : Pos2
    getter text : String
    getter size : Float64
    getter color : Color32

    def initialize(@clip : Rect, @pos : Pos2, @text : String,
                   @size : Float64, @color : Color32)
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

  struct NoopCmd
  end

  alias PaintCmd = RectCmd | TextCmd | CircleCmd | LineCmd | ArcCmd | NoopCmd

  class Painter
    getter commands : Array(PaintCmd)

    def initialize
      @commands = [] of PaintCmd
      @layers = [] of Order
      @layer = Order::Background
      @clip = Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))
    end

    def clear : Nil
      @commands.clear
      @layers.clear
      @layer = Order::Background
      @clip = Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))
    end

    # Which layer subsequently pushed commands belong to (egui
    # `Painter::with_layer_id`).
    def layer=(order : Order)
      @layer = order
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

    # Vertical gradient fill (top `c1` → bottom `c2`).
    def rect_gradient(rect : Rect, rounding : Float64, c1 : Color32,
                      c2 : Color32) : Nil
      rect(rect, rounding, fill: c1, fill2: c2)
    end

    # Draw text with `pos` as the LEFT-CENTER of the text bounding box
    # (upstream anchors at the galley's left edge + baseline; backends
    # convert using their font metrics — see backend/sokol/fontstash).
    def text(pos : Pos2, text : String, size : Float64, color : Color32) : Nil
      add(TextCmd.new(@clip, pos, text, size, color))
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

    # egui `GraphicLayers::drain(order)`: flatten per layer, back to
    # front (Background → Middle → Foreground → Tooltip).
    def commands_in_layer_order : Array(PaintCmd)
      out = [] of PaintCmd
      Order.each do |order|
        @commands.each_with_index do |cmd, i|
          out << cmd if @layers[i] == order
        end
      end
      out
    end
  end
end
