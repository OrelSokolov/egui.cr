# gradient.cr — a CSS-like background gradient value for the style
# system (`background-gradient` in ECSS; a deliberate deviation from
# CSS, which packs gradients into `background-image` layers — here it
# is a first-class property of its own).
#
# Supported spellings (subset of CSS, hex colors only):
#
#   linear-gradient(135deg, #E92236, #571DC6 60%, #ffffffcc)
#   linear-gradient(to bottom right, #a, #b)
#   radial-gradient(circle at 30% 20%, #a, #b 80%)
#
# Linear angles follow CSS: 0deg points UP, growing clockwise (180deg
# = `to bottom`, 135deg = top-left → bottom-right). Stop positions are
# percentages; missing positions distribute evenly between the
# specified neighbors (the CSS rule). Radial radius = one of the four
# CSS extent keywords against the painted rect (`circle` and `ellipse`
# paint the same — the radius basis IS the extent).
#
# The geometry is RELATIVE to the rect being painted (fractions /
# degrees), so a Gradient survives rect changes and painter transforms
# without recompute; `#color_at(x, y, rect)` is the single evaluation
# entry both backends (CPU raster, sokol Gouraud) share.

module Egui
  struct Gradient
    # One color stop: position 0..1 along the gradient axis (mono-
    # tonic, ensured at parse) and its color.
    record Stop, pos : Float64, color : Color32 do
      def to_s(io : IO) : Nil
        c = color
        if c.a == 255
          io << sprintf("#%02x%02x%02x", c.r, c.g, c.b)
        else
          io << sprintf("#%02x%02x%02x%02x", c.r, c.g, c.b, c.a)
        end
        p = pos * 100.0
        io << ' ' << (p % 1 == 0 ? p.to_i64.to_s : p.round(2).to_s) << '%'
      end
    end

    getter kind : Symbol          # :linear | :radial
    getter angle_deg : Float64    # linear only (CSS semantics)
    getter stops : Array(Stop)
    # Radial only: center as fractions of the rect (0..1) and the
    # extent keyword (:closest_side | :closest_corner | :farthest_side
    # | :farthest_corner).
    getter cx : Float64
    getter cy : Float64
    getter extent : Symbol

    def initialize(@kind : Symbol, @stops : Array(Stop),
                   @angle_deg : Float64 = 180.0,
                   @cx : Float64 = 0.5, @cy : Float64 = 0.5,
                   @extent : Symbol = :farthest_corner)
    end

    # ── parsing ───────────────────────────────────────────────────

    def self.parse?(s : String) : Gradient?
      src = s.strip
      lower = src.downcase
      if lower.starts_with?("linear-gradient(") && src.ends_with?(')')
        parse_linear(src[16...src.size - 1].strip)
      elsif lower.starts_with?("radial-gradient(") && src.ends_with?(')')
        parse_radial(src[16...src.size - 1].strip)
      else
        nil
      end
    end

    private def self.parse_linear(body : String) : Gradient?
      return nil if body.empty?
      args = split_args(body)
      return nil if args.size < 2 # 2 stops minimum (direction optional)

      angle = 180.0
      first = args[0].downcase
      rest = args
      if first.ends_with?("deg")
        angle = first[0...first.size - 3].strip.to_f? || return nil
        rest = args[1..] # the angle token is consumed
      elsif (dir = direction_angle(first))
        angle = dir
        rest = args[1..] # the direction token is consumed
      end
      stops = parse_stops(rest) || return nil
      Gradient.new(:linear, stops, angle)
    end

    private def self.parse_radial(body : String) : Gradient?
      return nil if body.empty?
      args = split_args(body)

      cx = 0.5
      cy = 0.5
      extent = :farthest_corner
      rest = args
      # Leading configuration tokens: shape (`circle`/`ellipse`), an
      # extent keyword, and `at x% y%` — any order before the stops,
      # possibly packed into one comma-free token (the CSS spelling
      # `circle at 30% 20%`). All optional.
      while rest.size > 1
        tok = rest[0].downcase
        if tok == "circle" || tok == "ellipse"
          rest = rest[1..]
        elsif (kw = extent_keyword(tok))
          extent = kw
          rest = rest[1..]
        elsif (at = parse_at_clause(tok))
          cx, cy, ext = at
          extent = ext if ext
          rest = rest[1..]
        else
          break
        end
      end
      stops = parse_stops(rest) || return nil
      Gradient.new(:radial, stops, cx: cx, cy: cy, extent: extent)
    end

    EXTENT_KEYWORDS = {
      "closest-side"    => :closest_side,
      "closest-corner"  => :closest_corner,
      "farthest-side"   => :farthest_side,
      "farthest-corner" => :farthest_corner,
    }

    private def self.extent_keyword(w : String) : Symbol?
      EXTENT_KEYWORDS[w]?
    end

    # "circle at 30% 20%" / "ellipse farthest-side at 50% 0%" / "at
    # 50% 50%" — an `at` clause with optional shape/extent words in
    # front. Returns {cx, cy, extent?} fractions or nil.
    private def self.parse_at_clause(tok : String) : {Float64, Float64, Symbol?}?
      words = tok.split
      at = words.index("at") || return nil
      return nil unless words.size == at + 3
      extent = nil
      head_ok = words[0...at].all? do |w|
        case w
        when "circle", "ellipse" then true
        else
          if (kw = extent_keyword(w))
            extent = kw
            true
          else
            false
          end
        end
      end
      return nil unless head_ok
      cx = parse_frac(words[at + 1]) || return nil
      cy = parse_frac(words[at + 2]) || return nil
      {cx, cy, extent}
    end

    private def self.direction_angle(s : String) : Float64?
      words = s.split
      return nil if words.empty?
      return nil unless words.shift == "to"
      dx = 0.0
      dy = 0.0
      words.each do |w|
        case w
        when "top"    then dy -= 1.0
        when "bottom" then dy += 1.0
        when "left"   then dx -= 1.0
        when "right"  then dx += 1.0
        else               return nil
        end
      end
      return nil if dx.zero? && dy.zero?
      # Angle from UP, clockwise (screen y grows down): the direction
      # the gradient line points TO.
      (Math.atan2(dx, -dy) * 180.0 / Math::PI).round(4)
    end

    # Split "a, b, c" on top-level commas (no nested parens in the
    # supported subset — hex colors carry none).
    private def self.split_args(body : String) : Array(String)
      body.split(',').map(&.strip).reject(&.empty?)
    end

    private def self.parse_stops(args : Array(String)) : Array(Stop)?
      return nil unless args.size >= 2
      stops = [] of {Float64?, Color32}
      args.each do |arg|
        parts = arg.split
        color = parse_hex_color(parts[0]? || "") || return nil
        pos = nil
        if (p1 = parts[1]?)
          return nil unless parts.size == 2
          pos = parse_frac(p1) || return nil
        end
        stops << {pos, color}
      end
      distribute_positions(stops)
    end

    # The CSS rule: specified positions stay; the first defaults to 0,
    # the last to 1, and each run of unspecified interior stops spaces
    # evenly between its nearest specified neighbors.
    private def self.distribute_positions(
      raw : Array({Float64?, Color32})
    ) : Array(Stop)?
      n = raw.size
      return nil if n < 2
      pos = Array.new(n) { |i| raw[i][0] }
      pos[0] = 0.0 if pos[0].nil?
      pos[n - 1] = 1.0 if pos[n - 1].nil?
      i = 1
      while i < n - 1
        if pos[i].nil?
          j = i
          while j < n - 1 && pos[j].nil?
            j += 1
          end
          lo = pos[i - 1].not_nil!
          hi = pos[j].not_nil!
          span = j - (i - 1)
          (i...j).each do |k| pos[k] = lo + (hi - lo) * (k - i + 1) / span end
          i = j
        else
          i += 1
        end
      end
      out = [] of Stop
      prev = -1.0
      n.times do |k|
        # Clamp into 0..1 and keep monotonic (a stop never slides
        # before its neighbor): out-of-order percentages degrade to a
        # hard edge instead of a broken gradient.
        p = pos[k].not_nil!.clamp(0.0, 1.0)
        p = {p, prev}.max
        prev = p
        out << Stop.new(p, raw[k][1])
      end
      out
    end

    # "60%" → 0.6; a bare "0.6"/"1" is accepted too (ECSS spells
    # numbers without units).
    private def self.parse_frac(s : String) : Float64?
      if s.ends_with?('%') && (n = s[0...s.size - 1].to_f?)
        n / 100.0
      else
        s.to_f?
      end
    end

    private def self.parse_hex_color(s : String) : Color32?
      return nil unless s.starts_with?('#')
      hex = s[1..]
      hex = hex.chars.map { |c| "#{c}#{c}" }.join if hex.size == 3
      return nil unless hex.size == 6 || hex.size == 8
      pair = ->(i : Int32) { hex[i, 2].to_i?(16) }
      r = pair.call(0) || return nil
      g = pair.call(2) || return nil
      b = pair.call(4) || return nil
      a = hex.size == 8 ? (pair.call(6) || return nil) : 255
      Color32.new(r.to_u8, g.to_u8, b.to_u8, a.to_u8)
    end

    # ── canonical spelling (Doc#to_s round-trip) ───────────────────

    def to_s(io : IO) : Nil
      case kind
      when :linear
        io << "linear-gradient(" << angle_deg.to_i64 << "deg"
      when :radial
        io << "radial-gradient(circle"
        unless extent == :farthest_corner
          io << ' ' << EXTENT_KEYWORDS.key_for?(extent).not_nil!
        end
        io << " at "
        io << (cx * 100).round.to_i << "% " << (cy * 100).round.to_i << "%"
      end
      stops.each { |st| io << ", " << st }
      io << ')'
    end

    private def self.pos_to_s(pos : Float64) : String
      p = pos * 100.0
      p % 1 == 0 ? p.to_i64.to_s : p.round(2).to_s
    end

    private def self.color_to_s(c : Color32, io : IO) : Nil
      if c.a == 255
        io << sprintf("#%02x%02x%02x", c.r, c.g, c.b)
      else
        io << sprintf("#%02x%02x%02x%02x", c.r, c.g, c.b, c.a)
      end
    end

    # ── evaluation ─────────────────────────────────────────────────

    # The gradient's color at a point of `rect` (screen coords).
    def color_at(x : Float64, y : Float64, rect : Rect) : Color32
      t = t_at(x, y, rect)
      eval(t)
    end

    # The gradient axis position (0..1, clamped) of a point — public
    # for backends that color per-vertex and need the raw projection.
    def t_at(x : Float64, y : Float64, rect : Rect) : Float64
      if kind == :radial
        px = rect.left + cx * rect.width
        py = rect.top + cy * rect.height
        dist = Math.sqrt((x - px) ** 2 + (y - py) ** 2)
        r = radial_radius(rect, px, py)
        t = r > 0 ? dist / r : 1.0
      else
        rad = angle_deg * Math::PI / 180.0
        dx = Math.sin(rad)
        dy = -Math.cos(rad)
        # Gradient line length through the rect center along (dx, dy):
        # the CSS |W·sinθ| + |H·cosθ| projection.
        len = rect.width * dx.abs + rect.height * dy.abs
        ctr = rect.center
        t = len > 0 ? ((x - ctr.x) * dx + (y - ctr.y) * dy) / len + 0.5 : 0.0
      end
      t.clamp(0.0, 1.0)
    end

    # The gradient color at axis position t (0..1): the stop colors
    # piecewise-lerped (sRGB channels, like the legacy fill/fill2
    # paths — CSS's fancy color interpolation is out of scope).
    def eval(t : Float64) : Color32
      return stops.first.color if t <= stops.first.pos
      return stops.last.color if t >= stops.last.pos
      (1...stops.size).each do |i|
        a = stops[i - 1]
        b = stops[i]
        next if b.pos <= a.pos
        if t <= b.pos
          f = (t - a.pos) / (b.pos - a.pos)
          c1 = a.color
          c2 = b.color
          return Color32.new(
            (c1.r.to_i32 + (c2.r.to_i32 - c1.r.to_i32) * f).to_u8,
            (c1.g.to_i32 + (c2.g.to_i32 - c1.g.to_i32) * f).to_u8,
            (c1.b.to_i32 + (c2.b.to_i32 - c1.b.to_i32) * f).to_u8,
            (c1.a.to_i32 + (c2.a.to_i32 - c1.a.to_i32) * f).to_u8)
        end
      end
      stops.last.color
    end

    private def radial_radius(rect : Rect, px : Float64, py : Float64) : Float64
      case extent
      when :closest_side
        {px - rect.left, rect.right - px, py - rect.top,
         rect.bottom - py}.min
      when :farthest_side
        {px - rect.left, rect.right - px, py - rect.top,
         rect.bottom - py}.max
      when :closest_corner
        corners = {rect.min, Pos2.new(rect.right, rect.top),
                   Pos2.new(rect.left, rect.bottom), rect.max}
        corners.min_of { |c| Math.sqrt((c.x - px) ** 2 + (c.y - py) ** 2) }
      else # farthest_corner (the CSS default)
        corners = {rect.min, Pos2.new(rect.right, rect.top),
                   Pos2.new(rect.left, rect.bottom), rect.max}
        corners.max_of { |c| Math.sqrt((c.x - px) ** 2 + (c.y - py) ** 2) }
      end
    end

    # The legacy fast path: a plain two-stop `to bottom` gradient is
    # exactly what RectCmd's fill/fill2 Gouraud paints — backends map
    # it onto the old code instead of the general path.
    def simple_vertical? : {Color32, Color32}?
      if @kind == :linear && @stops.size == 2 &&
         (@angle_deg - 180.0).abs < 0.01
        {@stops[0].color, @stops[1].color}
      else
        nil
      end
    end
  end
end
