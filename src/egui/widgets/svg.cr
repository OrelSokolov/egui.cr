# A minimal SVG viewer widget — no rasterizer, no dependencies: SVG
# source is parsed once (a small subset) and painted as vector
# primitives through the regular Painter commands, so it stays crisp
# at any size.
#
# Supported subset (enough for logo-style artwork like
# assets/icon.svg): `<svg>` width/height/viewBox, `<defs>` with
# `<linearGradient>` + `<stop>`, and the shape elements `<rect>`
# (incl. `rx` rounding), `<circle>`, `<line>` and `<text>` (fill,
# stroke, stroke-width, font-size, text-anchor,
# dominant-baseline). The viewBox is fitted into the widget rect with
# the aspect preserved and centered (like `<img>` object-fit).
#
# Painter limitations shape the mapping: gradients are per-vertex
# vertical only (`RectCmd#fill2`), so a vertical gradient maps to
# fill→fill2 and any other orientation falls back to the blended
# midpoint; circles/lines/text take flat colors.

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

    alias Shape = RectShape | CircleShape | LineShape | TextShape

    # Square widget by default — the common logo shape.
    property size : Vec2

    @shapes : Array(Shape)
    @view : ViewBox

    def initialize(source : String, @size : Vec2 = Vec2.new(128.0, 128.0))
      @shapes, @view = Svg.parse(source)
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
    def paint(ui : Ui, rect : Rect) : Nil
      painter = ui.painter
      scale = {rect.width / @view.width, rect.height / @view.height}.min
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
        end
      end
    end

    # -- parsing ----------------------------------------------------------

    # Parse `source` into (shapes, viewBox). Comments, the XML decl and
    # anything outside the supported tags are ignored.
    def self.parse(source : String) : {Array(Shape), ViewBox}
      src = source.gsub(/<!--.*?-->/m, "").gsub(/<\?.*?\?>/, "")

      gradients = {} of String => LinearGradient
      src.scan(/<linearGradient\b([^>]*)>(.*?)<\/linearGradient>/m) do |m|
        gattrs = attrs(m[1])
        id = gattrs["id"]?
        colors = m[2].scan(/<stop\b([^>]*?)\/?>/).compact_map do |sm|
          color(attrs(sm[1])["stop-color"]?)
        end
        next unless id && !colors.empty?
        x1 = num(gattrs, "x1", 0.0)
        y1 = num(gattrs, "y1", 0.0)
        x2 = num(gattrs, "x2", 1.0)
        y2 = num(gattrs, "y2", 0.0)
        gradients[id] = LinearGradient.new(id, colors.first, colors.last,
          (y2 - y1).abs >= (x2 - x1).abs)
      end

      view = parse_view(src)

      shapes = [] of Shape
      src.scan(/<rect\b([^>]*?)\/?>/) do |m|
        a = attrs(m[1])
        shapes << RectShape.new(num(a, "x", 0.0), num(a, "y", 0.0),
          num(a, "width", 0.0), num(a, "height", 0.0), num(a, "rx", 0.0),
          paint(a["fill"]?, gradients), color(a["stroke"]?),
          num(a, "stroke-width", 1.0))
      end
      src.scan(/<circle\b([^>]*?)\/?>/) do |m|
        a = attrs(m[1])
        shapes << CircleShape.new(num(a, "cx", 0.0), num(a, "cy", 0.0),
          num(a, "r", 0.0), paint(a["fill"]?, gradients),
          color(a["stroke"]?), num(a, "stroke-width", 1.0))
      end
      src.scan(/<line\b([^>]*?)\/?>/) do |m|
        a = attrs(m[1])
        shapes << LineShape.new(num(a, "x1", 0.0), num(a, "y1", 0.0),
          num(a, "x2", 0.0), num(a, "y2", 0.0), num(a, "stroke-width", 1.0),
          color(a["stroke"]?) || WHITE)
      end
      src.scan(/<text\b([^>]*)>(.*?)<\/text>/m) do |m|
        a = attrs(m[1])
        anchor = case a["text-anchor"]?
                 when "middle" then :middle
                 when "end"    then :end
                 else               :start
                 end
        shapes << TextShape.new(num(a, "x", 0.0), num(a, "y", 0.0),
          num(a, "font-size", 16.0), m[2].strip,
          color(a["fill"]?) || BLACK, anchor,
          {"central", "middle"}.includes?(a["dominant-baseline"]?))
      end

      {shapes, view}
    end

    private def self.parse_view(src : String) : ViewBox
      root = src.match(/<svg\b([^>]*)>/)
      a = root ? attrs(root[1]) : {} of String => String
      if (vb = a["viewBox"]? || a["viewbox"]?)
        p = vb.split(/\s+/).map(&.to_f64?)
        if p.size == 4 && p.all?
          return ViewBox.new(p[0].not_nil!, p[1].not_nil!, p[2].not_nil!, p[3].not_nil!)
        end
      end
      w = num(a, "width", 100.0)
      h = num(a, "height", 100.0)
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

    # `nil` for "none"/unknown; `url(#id)` resolves through `gradients`
    # (an unknown id degrades to no fill).
    private def self.paint(value : String?,
                           gradients : Hash(String, LinearGradient)) : Paint?
      return nil unless value
      v = value.strip
      if v.starts_with?("url(")
        id = v[4..].split(')').first?.try(&.lchop('#'))
        return id ? gradients[id]? : nil
      end
      color(v)
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

    # `#RGB`, `#RRGGBB`, `#RRGGBBAA`, the named set above; nil = none.
    private def self.color(value : String?) : Color32?
      return nil unless value
      v = value.strip.downcase
      return nil if v.empty? || v == "none"
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
