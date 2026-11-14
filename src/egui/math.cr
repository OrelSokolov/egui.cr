# Port of the `emath` crate (egui_upstream/crates/emath): the small
# value types every other part of egui is written against.

module Egui

  # Explicit math-domain failure: a NaN reached a point where geometry
  # must be finite — a comparison (`Rect#union`) or an extent
  # computation (`Rect#width`: `Inf - Inf`). Raised INSTEAD of letting
  # the NaN flow on and detonate inside Crystal's `{a, b}.min` as an
  # opaque ArgumentError from deep in Enumerable: the framework's math
  # never fails with implicit exceptions. Uncaught, it aborts the app
  # with the operation and the operands on STDERR — pointing at where
  # the NaN entered the geometry, not at whichever comparison happened
  # to trip on it later.
  class NaNError < Exception
  end

  struct Vec2
    property x : Float64
    property y : Float64

    def initialize(@x = 0.0, @y = 0.0)
    end

    def nan? : Bool
      x.nan? || y.nan?
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
      Egui.nan_guard("Vec2#max", self, other)
      Vec2.new({x, other.x}.max, {y, other.y}.max)
    end

    def min(other : Vec2) : Vec2
      Egui.nan_guard("Vec2#min", self, other)
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

    def nan? : Bool
      x.nan? || y.nan?
    end

    def inspect(io : IO) : Nil
      io << "Pos2(" << x << ", " << y << ")"
    end
  end

  # NOTE on layout (the "phantom NaN" hunt, Nov 2026): an all-float
  # 4×f64 struct is RETURNED by the codegen partly on the x87 stack
  # (fldl in the callee epilogue). x87 holds only 8 slots, and a
  # closure stored as `Proc(…, Nil)` whose body implicitly returns a
  # Rect never gets its st(0)/st(1) parts popped at `.call` — 2 leaked
  # slots per call, and after four calls every later struct return
  # yields QNaN indefinite (0xFFF8…). That is what crashed stress_scroll
  # case «карточка» (see crystal_bug_reports/ for the upstream bug
  # report and a pure-stdlib repro; examples/stress_scroll.cr — the
  # CASES procs end with explicit `nil` for exactly this reason).
  # Do NOT make these procs return structs implicitly; and do not
  # "fix" the leak by changing Rect's layout to non-float fields: an
  # sret-returning closure under the same Nil-covariance crashes
  # harder — the caller does not pass the hidden return buffer,
  # shifting every argument (crystal_bug_reports/, variant 2).
  struct Rect
    property min : Pos2
    property max : Pos2

    def initialize(@min : Pos2, @max : Pos2)
    end

    def self.from_min_size(min : Pos2, size : Vec2) : Rect
      Egui.nan_guard("Rect.from_min_size (NaN size or min)", min, size)
      r = Rect.new(min, min + size)
      Egui.finite_guard("Rect.from_min_size", r.size, r)
      r
    end

    def self.zero : Rect
      Rect.new(Pos2.zero, Pos2.zero)
    end

    # A rect containing every practical point — the default interaction
    # clip for Uis that are not inside a clipping container.
    def self.infinite : Rect
      Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))
    end

    def nan? : Bool
      min.nan? || max.nan?
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
      w = max.x - min.x
      Egui.finite_guard("Rect#width", w, self)
      w
    end

    def height : Float64
      h = max.y - min.y
      Egui.finite_guard("Rect#height", h, self)
      h
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

    # Axis-aligned intersection (an empty result renders nothing —
    # callers treat min > max as "no overlap").
    def intersect(other : Rect) : Rect
      Egui.nan_guard("Rect#intersect", self, other)
      Rect.new(
        Pos2.new({min.x, other.min.x}.max, {min.y, other.min.y}.max),
        Pos2.new({max.x, other.max.x}.min, {max.y, other.max.y}.min)
      )
    end

    def union(other : Rect) : Rect
      Egui.nan_guard("Rect#union", self, other)
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

  # Extra per-callsite geometry checks (`EGUI_STRICT_MATH=1`) — a debug
  # switch for hunting future phantom NaNs; off (one bool read) by
  # default because the sites it covers are hot.
  @@strict_math = ENV["EGUI_STRICT_MATH"]? ? ENV["EGUI_STRICT_MATH"] != "0" : false

  def self.strict_math? : Bool
    @@strict_math
  end

  # Guard for comparison chokepoints (`Rect#union`, `Vec2#min`/`#max`):
  # both operands must be NaN-free before any `{a, b}.min/max` runs.
  # Happy path: two `nan?` checks, no allocation.
  def self.nan_guard(op : String, a : Vec2 | Pos2 | Rect,
                     b : Vec2 | Pos2 | Rect | Nil = nil) : Nil
    return unless a.nan? || b.try(&.nan?)
    raise NaNError.new(
      "#{op}: NaN operand — self=#{a.inspect}#{b ? " other=#{b.inspect}" : ""}")
  end

  # Guard for extent chokepoints (`Rect#width`/`#height`,
  # `Ui#available_*`, `Ui#allocate_space`): the RESULT is what's
  # checked. Both NaN and Inf are rejected: a NaN aborts at its birth
  # (`Inf - Inf`), and a bare Inf — which sails through every
  # comparison unnoticed — is caught BEFORE it turns into `Inf - Inf`
  # somewhere downstream. Happy path: `finite?` checks, no allocation.
  def self.finite_guard(op : String, v : Float64 | Vec2,
                        subject : Vec2 | Pos2 | Rect | Nil = nil) : Nil
    return if v.is_a?(Vec2) ? v.x.finite? && v.y.finite? : v.finite?
    raise NaNError.new(
      "#{op}: non-finite value #{v.inspect} — #{subject.inspect}")
  end
end
