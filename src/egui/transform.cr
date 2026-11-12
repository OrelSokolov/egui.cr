# CSS `transform` — the full 2D affine.
#
#   x' = a·x + c·y + e
#   y' = b·x + d·y + f
#
# Three layers live here:
#
#   Affine2          the plain matrix (+ translation). What the painter
#                    stamps onto a command (`PaintCmd#xform`) and what
#                    the backend folds into an sgl modelview matrix at
#                    draw time; also the interpolation unit of the
#                    `transition.transform` animation.
#   CssTransform     a parsed CSS function list (`rotate(8deg)
#                    translateY(-6px)` …) — kept UNRESOLVED because
#                    percentage translations and `transform-origin` need
#                    the element's own size, known only when the box's
#                    rect exists (after its children ran).
#   TransformOrigin  the `transform-origin` value — fractions + px
#                    offsets of the box.
#
# Semantics follow the appear transitions (plans/NATIVE_HTML_DEMO.md
# §3.2): the transform is PAINT-ONLY. The subtree is laid out at its
# final place from the first frame — neighbors, clip rects and
# hit-testing see it in place; only the emitted geometry moves. An
# axis-aligned transform (translate/scale, no rotate/skew) rewrites the
# commands on the CPU exactly like the appear path always did; anything
# with rotation or skew stamps the affine onto each command and the
# backend applies it as a modelview matrix (the GPU rotates, so text
# stays crisp — the CPU approximation only fades colors).

module Egui
  struct Affine2
    getter a : Float64
    getter b : Float64
    getter c : Float64
    getter d : Float64
    getter e : Float64
    getter f : Float64

    def initialize(@a = 1.0, @b = 0.0, @c = 0.0, @d = 1.0,
                   @e = 0.0, @f = 0.0)
    end

    def self.identity : Affine2
      Affine2.new
    end

    def identity? : Bool
      a == 1.0 && b == 0.0 && c == 0.0 && d == 1.0 && e == 0.0 && f == 0.0
    end

    # No rotation/skew — the CPU rewrite path of the painter can move
    # rects/points exactly (a scaled axis-aligned rect stays one).
    def axis_aligned? : Bool
      b.abs < 1e-9 && c.abs < 1e-9
    end

    # Uniform-ish scale factor — what stroke widths and radii scale by
    # on the CPU path. For a rotated matrix the area scale (sqrt of the
    # determinant) is the closest one-number summary.
    def k : Float64
      axis_aligned? ? (a.abs + d.abs) / 2.0
                    : Math.sqrt((a * d - b * c).abs)
    end

    def *(p : Pos2) : Pos2
      Pos2.new(a * p.x + c * p.y + e, b * p.x + d * p.y + f)
    end

    # self ∘ other — apply `other` FIRST, then self (matrix multiply).
    def compose(other : Affine2) : Affine2
      Affine2.new(
        a * other.a + c * other.b,
        b * other.a + d * other.b,
        a * other.c + c * other.d,
        b * other.c + d * other.d,
        a * other.e + c * other.f + e,
        b * other.e + d * other.f + f)
    end

    def translate(dx : Float64, dy : Float64) : Affine2
      Affine2.new(a, b, c, d, e + dx, f + dy)
    end

    # Rotation around a pivot (radians).
    def self.rotation(rad : Float64, pivot : Pos2) : Affine2
      cos = Math.cos(rad)
      sin = Math.sin(rad)
      Affine2.new(cos, sin, -sin, cos, 0.0, 0.0)
        .around(pivot)
    end

    # Fold a pivot in: the returned affine maps absolute coordinates
    # (self maps pivot-RELATIVE ones) — L∘T(-pivot) then +pivot.
    def around(pivot : Pos2) : Affine2
      Affine2.new(a, b, c, d,
        pivot.x - (a * pivot.x + c * pivot.y),
        pivot.y - (b * pivot.x + d * pivot.y))
    end

    # Entry-wise lerp (the `transition.transform` interpolation — for
    # the simple cases this engine targets — rotate 0→180deg, scale
    # 1→0.8, translate — identical to the decomposed CSS interpolation).
    def lerp(other : Affine2, t : Float64) : Affine2
      Affine2.new(
        a + (other.a - a) * t,
        b + (other.b - b) * t,
        c + (other.c - c) * t,
        d + (other.d - d) * t,
        e + (other.e - e) * t,
        f + (other.f - f) * t)
    end

    def ==(other : Affine2) : Bool
      a == other.a && b == other.b && c == other.c && d == other.d &&
        e == other.e && f == other.f
    end

    # Column-major mat4 for the sgl modelview (the backend's
    # egui_cr_xform_push).
    def mat4 : StaticArray(Float32, 16)
      m = StaticArray(Float32, 16).new(0.0f32)
      m[0] = a.to_f32; m[1] = b.to_f32; m[4] = c.to_f32; m[5] = d.to_f32
      m[10] = 1.0f32; m[15] = 1.0f32
      m[12] = e.to_f32; m[13] = f.to_f32
      m
    end

    def to_s : String
      "matrix(#{a}, #{b}, #{c}, #{d}, #{e}, #{f})"
    end
  end

  # A parsed CSS `transform` value — the function list, unresolved
  # (percentage translations need the element size at apply time).
  class CssTransform
    # One function of the list: name, raw arg spellings ("90deg",
    # "-6px", "50%") — units stay until #resolve, where percentages
    # need the element size and angle units convert differently.
    private struct Func
      getter name : String
      getter raw : Array(String)

      def initialize(@name, @raw)
      end

      # Numeric value with the unit stripped.
      def num(i : Int32) : Float64
        raw[i]?.try { |s| s.delete("%radturndegpx").to_f64? } || 0.0
      end

      def pct?(i : Int32) : Bool
        !!(raw[i]? =~ /%$/)
      end

      # An angle argument → radians ("90deg" bare number = degrees,
      # "1.5rad", "0.5turn").
      def angle(i : Int32 = 0) : Float64
        s = raw[i]?.to_s.strip
        return 0.0 if s.empty?
        if s.ends_with?("rad")
          s.delete("rad").to_f64? || 0.0
        elsif s.ends_with?("turn")
          (s.delete("turn").to_f64? || 0.0) * 2.0 * Math::PI
        else
          (s.delete("deg").to_f64? || 0.0) * Math::PI / 180.0
        end
      end
    end

    getter funcs : Array(Func)
    @cached : {Vec2, Affine2}?

    def initialize(@funcs = [] of Func)
    end

    def self.parse?(s : String) : CssTransform?
      return nil if s.blank? || s == "none"
      funcs = [] of Func
      pos = 0
      size = s.size
      while pos < size
        while pos < size && s[pos].ascii_whitespace?
          pos += 1
        end
        break if pos >= size
        open = s.index('(', pos)
        return nil unless open
        name = s[pos...open].strip.downcase
        close = s.index(')', open)
        return nil unless close
        args = [] of Float64
        raw = [] of String
        s[(open + 1)...close].split(',').each do |part|
          part = part.strip
          next if part.empty?
          num = part.delete("%radturndegpx").to_f64?
          return nil unless num
          args << num
          raw << part
        end
        return nil unless valid_func?(name, args)
        funcs << Func.new(name, raw)
        pos = close + 1
      end
      return nil if funcs.empty?
      CssTransform.new(funcs)
    end

    FUNCS = {"translate", "translatex", "translatey", "rotate", "scale",
             "scalex", "scaley", "skew", "skewx", "skewy", "matrix"}

    private def self.valid_func?(name : String, args : Array(Float64)) : Bool
      return false unless FUNCS.includes?(name)
      case name
      when "translate", "scale", "skew" then args.size >= 1 && args.size <= 2
      when "matrix"                     then args.size == 6
      else                                   args.size == 1
      end
    end

    def none? : Bool
      funcs.empty?
    end

    # Compose to a plain affine, resolving `%` translations against the
    # element's own size (CSS: percentages of the border box).
    def resolve(w : Float64 = 0.0, h : Float64 = 0.0) : Affine2
      if (c = @cached) && c[0] == Vec2.new(w, h)
        return c[1]
      end
      xf = Affine2.identity
      funcs.each do |fn|
        one =
          case fn.name
          when "translate"
            # Omitted ty defaults to 0 (CSS — unlike scale, where the
            # second factor defaults to the first).
            px = fn.pct?(0) ? fn.num(0) * w / 100.0 : fn.num(0)
            py = fn.raw[1]? ? (fn.pct?(1) ? fn.num(1) * h / 100.0 : fn.num(1)) : 0.0
            Affine2.new(1.0, 0.0, 0.0, 1.0, px, py)
          when "translatex"
            Affine2.new(1.0, 0.0, 0.0, 1.0,
              fn.pct?(0) ? fn.num(0) * w / 100.0 : fn.num(0), 0.0)
          when "translatey"
            Affine2.new(1.0, 0.0, 0.0, 1.0, 0.0,
              fn.pct?(0) ? fn.num(0) * h / 100.0 : fn.num(0))
          when "rotate"
            Affine2.rotation(fn.angle, Pos2.zero)
          when "scale"
            sx = fn.num(0)
            sy = fn.raw[1]? ? fn.num(1) : sx
            Affine2.new(sx, 0.0, 0.0, sy, 0.0, 0.0)
          when "scalex" then Affine2.new(fn.num(0), 0.0, 0.0, 1.0, 0.0, 0.0)
          when "scaley" then Affine2.new(1.0, 0.0, 0.0, fn.num(0), 0.0, 0.0)
          when "skew"
            ax = Math.tan(fn.angle(0))
            ay = fn.raw[1]? ? Math.tan(fn.angle(1)) : 0.0
            Affine2.new(1.0, ay, ax, 1.0, 0.0, 0.0)
          when "skewx" then Affine2.new(1.0, 0.0, Math.tan(fn.angle), 1.0, 0.0, 0.0)
          when "skewy" then Affine2.new(1.0, Math.tan(fn.angle), 0.0, 1.0, 0.0, 0.0)
          when "matrix"
            Affine2.new(fn.num(0), fn.num(1), fn.num(2), fn.num(3),
              fn.num(4), fn.num(5))
          else Affine2.identity
          end
        xf = xf.compose(one)
      end
      @cached = {Vec2.new(w, h), xf}
      xf
    end

    def to_s : String
      funcs.map { |f| "#{f.name}(#{f.raw.join(", ")})" }.join(" ")
    end
  end

  # `transition.transform` animation state (Memory-owned): per box id,
  # the lerp from the last target to the current one. Entry-wise affine
  # lerp — for the simple cases this engine targets (rotate 0→180deg,
  # scale 1→0.8, translate) identical to CSS's decomposed interpolation.
  # Retargeting mid-flight re-anchors at the CURRENT value, so hover
  # wiggling never jumps.
  class TransformAnims
    private class Run
      property from : Affine2
      property to : Affine2
      property t0 : Float64
      getter dur : Float64 # seconds

      def initialize(@from : Affine2, @to : Affine2, @t0 : Float64,
                     @dur : Float64)
      end
    end

    @runs = {} of Id => Run

    def initialize
    end

    # The interpolated affine for `id` at `now` (seconds). `dur` <= 0
    # (no `transition.transform` configured) jumps straight to the
    # target and drops any run. Returns {affine, animating?}.
    def drive(id : Id, target : Affine2, dur : Float64,
              now : Float64) : Tuple(Affine2, Bool)
      return {target, false} if dur <= 0.0
      if (r = @runs[id]?)
        if r.to != target
          r.from = sample(r, now)
          r.to = target
          r.t0 = now
        end
      else
        # First sighting: no FROM to animate — hold the target.
        r = Run.new(target, target, now, dur)
        @runs[id] = r
      end
      xf = sample(r, now)
      {xf, now < r.t0 + r.dur}
    end

    private def sample(r : Run, now : Float64) : Affine2
      t = r.dur > 0.0 ? ((now - r.t0) / r.dur).clamp(0.0, 1.0) : 1.0
      ease = 1.0 - (1.0 - t) ** 3 # ease-out cubic
      r.from.lerp(r.to, ease)
    end

    def select_used!(used : Set(Id)) : Nil
      @runs.select! { |id, _| used.includes?(id) }
    end

    def reset : Nil
      @runs.clear
    end
  end

  # The `transform-origin` value: fractions (0..1) plus px offsets of
  # the box. "center" (the CSS default), "top left", "50% 50%",
  # "10px 20px" all parse.
  struct TransformOrigin
    getter fx : Float64
    getter fy : Float64
    getter px : Float64
    getter py : Float64

    def initialize(@fx = 0.5, @fy = 0.5, @px = 0.0, @py = 0.0)
    end

    def self.center : TransformOrigin
      TransformOrigin.new
    end

    def self.parse?(s : String) : TransformOrigin?
      return nil if s.blank?
      fx = fy : Float64? = nil
      px = py : Float64? = nil
      s.split.each do |tok|
        t = tok.downcase
        frac : Float64? = nil
        off : Float64? = nil
        vertical = false
        if t == "left" || t == "center" || t == "right"
          frac = {"left" => 0.0, "center" => 0.5, "right" => 1.0}[t]
        elsif t == "top" || t == "bottom"
          frac = t == "top" ? 0.0 : 1.0
          vertical = true
        elsif t.ends_with?('%')
          n = t.delete('%').to_f64?
          return nil unless n
          frac = n / 100.0
        else
          n = t.delete("px").to_f64?
          return nil unless n
          off = n
        end
        # vertical keywords/first-y go to y; anything else fills x
        # first (CSS: one non-vertical value sets x, y stays center).
        if vertical
          return nil if fy || py
          fy = frac if frac
          py = off if off
        elsif fx.nil? && px.nil?
          fx = frac if frac
          px = off if off
        elsif fy.nil? && py.nil?
          fy = frac if frac
          py = off if off
        else
          return nil
        end
      end
      # An explicit px offset replaces the axis's default 50% with 0%
      # (CSS: `10px 20px` is measured from the top-left corner, only a
      # MISSING axis keeps the 50% default).
      fx = fx || (px ? 0.0 : 0.5)
      fy = fy || (py ? 0.0 : 0.5)
      TransformOrigin.new(fx, fy, px || 0.0, py || 0.0)
    end

    def resolve(rect : Rect) : Pos2
      Pos2.new(rect.min.x + rect.width * fx + px,
        rect.min.y + rect.height * fy + py)
    end

    def to_s : String
      "#{(fx * 100).round(1)}% #{(fy * 100).round(1)}%" +
        (px != 0 || py != 0 ? " #{px}px #{py}px" : "")
    end
  end
end
