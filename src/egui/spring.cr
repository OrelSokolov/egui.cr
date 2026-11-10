# Spring — a damped-oscillator animation primitive, a port of Raven's
# `widget/anim.c` (Apache-2.0), the "liveliness" layer of
# plans/NATIVE_HTML_DEMO.md §3.2.
#
# A spring is a value + a velocity pulled toward a target:
#
#     x'' = -w² (x - target) - 2·ζ·w·x'
#
# `response` (seconds) is the period without friction — how fast it
# answers; `damping` ζ is how much it bounces: at 1 it lands without
# overshoot, below 1 it runs past the target and swings back. The
# motion is computed from the EXACT solution of the equation (the
# closed form of `rvn_spring_step`), so it does not depend on the
# frame rate and never explodes after a long frame.
#
# The key property is velocity continuity: retargeting mid-flight
# keeps the current velocity — no jump, unlike an easing curve that
# restarts from zero derivative.

module Egui
  class Spring
    # Settle thresholds (Raven): at rest when the value is this close
    # to the target or the velocity is this small. Units are those of
    # the animated value (progress-like 0..1 for normalized uses).
    SETTLE_POS = 0.0015
    SETTLE_VEL = 0.02

    property value : Float64
    property velocity : Float64
    getter? started : Bool

    def initialize(@value : Float64 = 0.0)
      @velocity = 0.0
      @started = false
    end

    # Snap: jump to `v` and forget the velocity (`rvn_spring_set`).
    def set(v : Float64) : Nil
      @value = v
      @velocity = 0.0
      @started = true
    end

    # Add an impulse to the velocity (`rvn_spring_kick`).
    def kick(v : Float64) : Nil
      @velocity += v
      @started = true
    end

    # True while the spring has not settled at `target` yet
    # (`rvn_spring_moving`).
    def moving?(target : Float64) : Bool
      @started && ((@value - target).abs > SETTLE_POS ||
                   @velocity.abs > SETTLE_VEL)
    end

    # Advance by `dt` seconds towards `target` — the exact closed-form
    # solution of the damped oscillator (port of `rvn_spring_step`).
    def step(dt : Float64, target : Float64, response : Float64,
             damping : Float64) : Nil
      return if dt <= 0.0
      omega = 6.2831853 / {response, 0.01}.max
      zeta = damping
      x = @value - target
      v = @velocity
      decay = Math.exp(-zeta * omega * dt)

      if zeta < 0.999
        # underdamped: decaying oscillation
        omega_d = omega * Math.sqrt(1.0 - zeta * zeta)
        c = Math.cos(omega_d * dt)
        s = Math.sin(omega_d * dt)
        b = (v + zeta * omega * x) / omega_d
        @value = target + decay * (x * c + b * s)
        @velocity = decay * ((b * omega_d - zeta * omega * x) * c -
                             (x * omega_d + zeta * omega * b) * s)
      else
        # critically damped (Raven routes ζ ≥ 0.999 here)
        b = v + omega * x
        @value = target + decay * (x + b * dt)
        @velocity = decay * (b - omega * (x + b * dt))
      end
      @started = true
    end

    # The `rvn_paint_spring_from` driver: step while moving, snap once
    # settled (the exact target, zero velocity — no residual jitter).
    def track(dt : Float64, target : Float64, response : Float64,
              damping : Float64) : Float64
      if moving?(target)
        step(dt, target, response, damping)
        unless moving?(target)
          set(target)
        end
      else
        set(target)
      end
      @value
    end

    # Parameters of a spring + the ECSS spelling (`transition:
    # spring(…)` — see StyleAnimations' spring flavors). `response` is
    # the undamped period in seconds, `damping` the ratio ζ, `delay`
    # the transition delay in seconds (held before the motion starts).
    struct Spec
      getter response : Float64
      getter damping : Float64
      getter delay : Float64

      # Raven's motion presets (`rvn_motion_params`); `snappy` is the
      # default motion.
      PRESETS = {
        "smooth" => {0.30, 1.00},
        "bouncy" => {0.38, 0.52},
        "wobbly" => {0.50, 0.32},
        "snappy" => {0.16, 0.90},
      }

      def initialize(@response : Float64 = 0.16, @damping : Float64 = 0.90,
                     @delay : Float64 = 0.0)
        @response = {@response, 0.01}.max
        @damping = @damping.clamp(0.05, 4.0)
        @delay = {@delay, 0.0}.max
      end

      def self.default : Spec
        snappy
      end

      def self.smooth : Spec
        new(*PRESETS["smooth"])
      end

      def self.bouncy : Spec
        new(*PRESETS["bouncy"])
      end

      def self.wobbly : Spec
        new(*PRESETS["wobbly"])
      end

      def self.snappy : Spec
        new(*PRESETS["snappy"])
      end

      def ==(other : Spec) : Bool
        response == other.response && damping == other.damping &&
          delay == other.delay
      end

      # "spring" / "spring(bouncy)" / "spring(0.3, 0.8)" with an
      # optional trailing delay ("spring(bouncy) 100ms" / "… 0.1s" /
      # "… 100" — milliseconds like every other transition value).
      # nil when the string is not a spring value (the caller falls
      # back to its other spellings).
      def self.parse?(s : String) : Spec?
        return nil unless s == "spring" || s.starts_with?("spring(")
        rest = s[6..]
        delay = 0.0
        body = ""
        if rest.empty?
          body = "snappy" # the bare `spring` — the default preset
        else
          close = rest.index(')') || return nil
          body = rest[1...close]
          trailing = rest[(close + 1)..].strip
          unless trailing.empty?
            delay = parse_delay?(trailing) || return nil
          end
        end
        if body.empty?
          spec = snappy
        elsif PRESETS[body]?
          spec = new(*PRESETS[body])
        else
          parts = body.split(',').map(&.strip)
          nums = parts.map(&.to_f64?)
          return nil unless nums.all? && (1..2).covers?(nums.size)
          spec = new(nums[0].not_nil!,
            nums[1]? || snappy.damping)
        end
        delay > 0.0 ? Spec.new(spec.response, spec.damping, delay) : spec
      end

      # "100ms" / "0.1s" / "100" (plain numbers are milliseconds,
      # like the `transition` style key) → seconds.
      private def self.parse_delay?(s : String) : Float64?
        if s.ends_with?("ms") && (n = s[0...s.size - 2].to_f64?)
          {n / 1000.0, 0.0}.max
        elsif s.ends_with?('s') && (n = s[0...s.size - 1].to_f64?)
          {n, 0.0}.max
        else
          (n = s.to_f64?) ? {n / 1000.0, 0.0}.max : nil
        end
      end

      # The `transition: background spring(bouncy)` CSS-shorthand
      # spelling: a bare leading identifier names the key the spring
      # applies to (recorded as `transition.<key>`). Returns nil for
      # per-key spellings that already start with `spring`.
      def self.split_shorthand(s : String) : {String, String}?
        return nil if s.empty? || s.starts_with?("spring")
        sp = s.index(' ') || return nil
        name = s[0...sp]
        return nil if name.empty? || name[0].number?
        name.each_char do |c|
          next if c.ascii_letter? || c.number? || c == '-' || c == '_'
          return nil
        end
        rest = s[(sp + 1)..].strip
        parse?(rest) ? {name, rest} : nil
      end

      # Canonical spelling (round-trips through #parse?); the value
      # StyleVars carries for `transition`/`transition.<key>` keys.
      def to_s(io : IO) : Nil
        io << "spring("
        if preset = PRESETS.find { |_n, p| p[0] == @response && p[1] == @damping }
          io << preset[0]
        else
          io << (@response % 1 == 0 ? @response.to_i64.to_s : @response.to_s)
          io << ", " << (@damping % 1 == 0 ? @damping.to_i64.to_s : @damping.to_s)
        end
        io << ')'
        return if @delay <= 0.0
        ms = @delay * 1000.0
        io << ' ' << (ms % 1 == 0 ? ms.to_i64.to_s : ms.to_s) << "ms"
      end
    end
  end
end
