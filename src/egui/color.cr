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

  # A two-stop vertical gradient (CSS
  # `background: linear-gradient(top, bottom)`): the fill of gradient
  # buttons, set as the `background_gradient` style key.
  struct Gradient
    getter top : Color32
    getter bottom : Color32

    def initialize(@top : Color32, @bottom : Color32)
    end

    # Both stops darkened by `factor` — the Bootstrap-2 hover/active
    # shade of a gradient button (hover ≈ 0.85, active ≈ 0.70).
    def mul(factor : Float64) : Gradient
      Gradient.new(@top.mul_color(factor), @bottom.mul_color(factor))
    end

    def ==(other : Gradient) : Bool
      @top == other.top && @bottom == other.bottom
    end

    def inspect(io : IO) : Nil
      io << "Gradient(" << @top << " → " << @bottom << ")"
    end
  end

  # egui `ecolor::Hsva` — hue/saturation/value with alpha, all 0..=1
  # (hue wraps). Conversions ported from crates/ecolor/src/color.rs
  # (sRGB space, no gamma gymnastics — matches upstream behavior for
  # the color picker).
  struct Hsva
    getter h : Float64
    getter s : Float64
    getter v : Float64
    getter a : Float64

    def initialize(@h, @s, @v, @a)
    end

    def self.from_color(color : Color32) : Hsva
      r = color.r.to_f64 / 255.0
      g = color.g.to_f64 / 255.0
      b = color.b.to_f64 / 255.0
      a = color.a.to_f64 / 255.0

      max_c = {r, g, b}.max
      min_c = {r, g, b}.min
      chroma = max_c - min_c

      h = if chroma <= 0.0
        0.0
      elsif max_c == r
        60.0 * (g - b) / chroma
      elsif max_c == g
        60.0 * (2.0 + (b - r) / chroma)
      else
        60.0 * (4.0 + (r - g) / chroma)
      end
      h += 360.0 if h < 0.0

      s = max_c <= 0.0 ? 0.0 : chroma / max_c
      Hsva.new(h / 360.0, s, max_c, a)
    end

    def to_color : Color32
      h = (@h % 1.0) * 6.0 # 0..6
      sector = h.floor.to_i
      fraction = h - sector
      p = @v * (1.0 - @s)
      q = @v * (1.0 - @s * fraction)
      t = @v * (1.0 - @s * (1.0 - fraction))

      r8, g8, b8 = case sector % 6
      when 0 then {@v, t, p}
      when 1 then {q, @v, p}
      when 2 then {p, @v, t}
      when 3 then {p, q, @v}
      when 4 then {t, p, @v}
      else        {@v, p, q}
      end

      Color32.new(
        (r8 * 255.0).round.clamp(0.0, 255.0).to_u8,
        (g8 * 255.0).round.clamp(0.0, 255.0).to_u8,
        (b8 * 255.0).round.clamp(0.0, 255.0).to_u8,
        (@a * 255.0).round.clamp(0.0, 255.0).to_u8)
    end
  end
end
