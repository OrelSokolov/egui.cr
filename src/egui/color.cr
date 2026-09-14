# Port of the `ecolor` crate: sRGB color with alpha, 1 byte per channel.

module Egui
  struct Color32
    property r : UInt8
    property g : UInt8
    property b : UInt8
    property a : UInt8

    def initialize(@r = 0u8, @g = 0u8, @b = 0u8, @a = 255u8)
    end

    def self.rgba(r : Int, g : Int, b : Int, a : Int = 255) : Color32
      new(r.to_u8, g.to_u8, b.to_u8, a.to_u8)
    end

    def self.rgb(r : Int, g : Int, b : Int) : Color32
      rgba(r, g, b, 255)
    end

    def self.transparent : Color32
      rgba(0, 0, 0, 0)
    end

    # Linear multiplier, alpha preserved.
    def mul_color(s : Float64) : Color32
      f = ->(c : UInt8) { (c.to_f64 * s).round.clamp(0.0, 255.0).to_u8.as(UInt8) }
      Color32.new(f.call(r), f.call(g), f.call(b), a)
    end

    def ==(other : Color32) : Bool
      r == other.r && g == other.g && b == other.b && a == other.a
    end

    def inspect(io : IO) : Nil
      io << "Color32(" << r << "," << g << "," << b << "," << a << ")"
    end
  end
end
