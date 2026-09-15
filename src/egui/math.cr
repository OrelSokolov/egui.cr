# Port of the `emath` crate (egui_upstream/crates/emath): the small
# value types every other part of egui is written against.

module Egui
  struct Vec2
    property x : Float64
    property y : Float64

    def initialize(@x = 0.0, @y = 0.0)
    end

    def self.zero : Vec2
      Vec2.new(0.0, 0.0)
    end

    def +(other : Vec2) : Vec2
      Vec2.new(x + other.x, y + other.y)
    end

    def -(other : Vec2) : Vec2
      Vec2.new(x - other.x, y - other.y)
    end

    def *(s : Float64) : Vec2
      Vec2.new(x * s, y * s)
    end

    def *(s : Int32) : Vec2
      self * s.to_f64
    end

    def /(s : Float64) : Vec2
      Vec2.new(x / s, y / s)
    end

    def max(other : Vec2) : Vec2
      Vec2.new({x, other.x}.max, {y, other.y}.max)
    end

    def min(other : Vec2) : Vec2
      Vec2.new({x, other.x}.min, {y, other.y}.min)
    end

    def ==(other : Vec2) : Bool
      x == other.x && y == other.y
    end

    def length : Float64
      Math.sqrt(x * x + y * y)
    end

    def inspect(io : IO) : Nil
      io << "Vec2(" << x << ", " << y << ")"
    end
  end

  struct Pos2
    property x : Float64
    property y : Float64

    def initialize(@x = 0.0, @y = 0.0)
    end

    def self.zero : Pos2
      Pos2.new(0.0, 0.0)
    end

    def +(v : Vec2) : Pos2
      Pos2.new(x + v.x, y + v.y)
    end

    def -(v : Vec2) : Pos2
      Pos2.new(x - v.x, y - v.y)
    end

    def -(other : Pos2) : Vec2
      Vec2.new(x - other.x, y - other.y)
    end

    def to_vec2 : Vec2
      Vec2.new(x, y)
    end

    def inspect(io : IO) : Nil
      io << "Pos2(" << x << ", " << y << ")"
    end
  end

  struct Rect
    property min : Pos2
    property max : Pos2

    def initialize(@min : Pos2, @max : Pos2)
    end

    def self.from_min_size(min : Pos2, size : Vec2) : Rect
      Rect.new(min, min + size)
    end

    def self.zero : Rect
      Rect.new(Pos2.zero, Pos2.zero)
    end

    # A rect containing every practical point — the default interaction
    # clip for Uis that are not inside a clipping container.
    def self.infinite : Rect
      Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))
    end

    def left : Float64
      min.x
    end

    def top : Float64
      min.y
    end

    def right : Float64
      max.x
    end

    def bottom : Float64
      max.y
    end

    def width : Float64
      max.x - min.x
    end

    def height : Float64
      max.y - min.y
    end

    def size : Vec2
      Vec2.new(width, height)
    end

    def center : Pos2
      Pos2.new((min.x + max.x) / 2.0, (min.y + max.y) / 2.0)
    end

    def left_center : Pos2
      Pos2.new(min.x, (min.y + max.y) / 2.0)
    end

    def center_top : Pos2
      Pos2.new((min.x + max.x) / 2.0, min.y)
    end

    def contains?(p : Pos2) : Bool
      min.x <= p.x && p.x <= max.x && min.y <= p.y && p.y <= max.y
    end

    def intersects?(other : Rect) : Bool
      min.x <= other.max.x && other.min.x <= max.x &&
        min.y <= other.max.y && other.min.y <= max.y
    end

    def translate(v : Vec2) : Rect
      Rect.new(min + v, max + v)
    end

    def union(other : Rect) : Rect
      Rect.new(
        Pos2.new({min.x, other.min.x}.min, {min.y, other.min.y}.min),
        Pos2.new({max.x, other.max.x}.max, {max.y, other.max.y}.max)
      )
    end

    # egui `Rect::expand(amount)`: grow symmetrically in all directions.
    def expand(amount : Float64) : Rect
      v = Vec2.new(amount, amount)
      Rect.new(min - v, max + v)
    end

    def shrink(amount : Float64) : Rect
      expand(-amount)
    end

    def inspect(io : IO) : Nil
      io << "Rect(" << min.inspect << "…" << max.inspect << ")"
    end
  end
end
