# Appear transitions (plans/NATIVE_HTML_DEMO.md §3.2, increment 2):
# the named set a widget plays when it FIRST shows up — a port of
# Raven's transition table (`widget/anim.c`, `rvn_transition_begin`;
# Apache-2.0). A single progress spring runs 0 → 1 and the per-kind
# curve derives scale/offset/opacity from it, exactly like Raven:
#
#   kind        motion      curve (t = progress, away = 1 - t)
#   fade        smooth      opacity = clamp(t·2.2)
#   pop         bouncy      scale 0.55 + 0.45·t
#   zoom        smooth      scale 1 + 0.22·away
#   fly-up/…    bouncy      offset 56px (vertical) / 72px (horizontal),
#                           scale 1 - 0.08·clamp(away, 0, 1)
#   drop        wobbly      dy = -140·away, squash sy = 1 + 0.25·cl,
#                           stretch sx = 1 - 0.12·cl (cl = away clamped
#                           to ±0.6 — the overshoot below the target is
#                           the squash-and-wobble on landing)
#   slide-left/ snappy      dx = ±28·away (a page replacing another)
#   slide-right
#
# The widget is laid out at its FINAL place from the first frame; the
# transform is paint-only (`Painter#push_transform`), so neighbors,
# clip rects and hit-testing see it in place immediately — Raven's
# "instances transformed post-factum" semantics.
#
# The ECSS spelling: `appear: fly-right` names the kind (`none`
# disables), `appear-delay: 0.08s` staggers a group (during the delay
# the widget holds its start state — with opacity starting at 0 it is
# invisible, like Raven which skips painting entirely).

module Egui
  class AppearAnims
    # One widget's run: the kind playing, the delay countdown and the
    # progress spring. The run lives in Memory until the widget stops
    # being emitted (end-frame pruning) — a re-appearance replays.
    class Run
      getter kind : Symbol
      property delay : Float64
      getter progress : Spring
      property last_time : Float64?

      def initialize(@kind : Symbol, delay : Float64, time : Float64)
        @delay = {delay, 0.0}.max
        @progress = Spring.new(0.0)
        @progress.set(0.0)
        @last_time = time
      end
    end

    # Raven's motion preset per kind (`rvn_transition_begin`: fade/zoom
    # smooth, pop/fly bouncy, drop wobbly, slide snappy). `rise` is the
    # CSS card-in curve (opacity + 10px translateY over .4s ease) — a
    # smooth, slower fade.
    MOTION = {
      :fade        => Spring::Spec.smooth,
      :pop         => Spring::Spec.bouncy,
      :zoom        => Spring::Spec.smooth,
      :fly_up      => Spring::Spec.bouncy,
      :fly_down    => Spring::Spec.bouncy,
      :fly_left    => Spring::Spec.bouncy,
      :fly_right   => Spring::Spec.bouncy,
      :drop        => Spring::Spec.wobbly,
      :slide_left  => Spring::Spec.snappy,
      :slide_right => Spring::Spec.snappy,
      :rise        => Spring::Spec.new(0.40, 1.00),
    }

    @runs = {} of Id => Run

    def initialize
    end

    # The named kind from its ECSS spelling — kebab-case ("fly-right",
    # "slide-left") or Raven's PascalCase ("FlyRight") both parse;
    # nil for "none" or an unknown name.
    def self.kind?(name : String) : Symbol?
      case name.downcase.delete("-_ ")
      when "none"       then nil
      when "fade"       then :fade
      when "pop"        then :pop
      when "zoom"       then :zoom
      when "rise", "cardin" then :rise
      when "flyup"      then :fly_up
      when "flydown"    then :fly_down
      when "flyleft"    then :fly_left
      when "flyright"   then :fly_right
      when "drop"       then :drop
      when "slideleft"  then :slide_left
      when "slideright" then :slide_right
      else
        nil
      end
    end

    # `appear-delay` from the cascade: a plain number is milliseconds
    # (the `transition` convention), a string may spell "80ms" or
    # "0.08s". Unparsable/absent → 0.
    def self.delay_from(vars : StyleVars) : Float64
      case v = vars["appear-delay"]?
      when Float64 then {v / 1000.0, 0.0}.max
      when Int32   then {v.to_f64 / 1000.0, 0.0}.max
      when String  then parse_time?(v) || 0.0
      else
        0.0
      end
    end

    def self.parse_time?(s : String) : Float64?
      if s.ends_with?("ms") && (n = s[0...s.size - 2].to_f64?)
        {n / 1000.0, 0.0}.max
      elsif s.ends_with?('s') && (n = s[0...s.size - 1].to_f64?)
        {n, 0.0}.max
      else
        nil
      end
    end

    # Advance the run for `id` by one frame and return the transform
    # to paint it with (nil once settled — the widget is plain again).
    # A missing/stale run starts over: a fresh appearance, or the style
    # switched the kind mid-flight (replays the new one).
    def drive(id : Id, kind : Symbol, delay : Float64,
              time : Float64) : NamedTuple(sx: Float64, sy: Float64,
                                           dx: Float64, dy: Float64,
                                           opacity: Float64)?
      run = @runs[id]?
      if run.nil? || run.kind != kind
        run = @runs[id] = Run.new(kind, delay, time)
      end
      dt = run.last_time ? (time - run.last_time.not_nil!).clamp(0.0, 1.0 / 30.0) : 0.0
      run.last_time = time
      # Waiting for its turn in a stagger: hold the start state (every
      # kind starts at opacity 0, i.e. invisible — Raven's "not shown
      # before its turn").
      if run.delay > 0.0
        run.delay = {run.delay - dt, 0.0}.max
        return AppearAnims.curves(kind, 0.0)
      end
      spec = MOTION[kind]
      spring = run.progress
      if spring.moving?(1.0)
        spring.step(dt, 1.0, spec.response, spec.damping)
        return AppearAnims.curves(kind, spring.value) if spring.moving?(1.0)
        spring.set(1.0)
      end
      nil
    end

    # Drop runs of widgets not emitted this frame (a re-appearance
    # replays). Called from Memory#end_frame with the used-id set.
    def select_used!(used : Set(Id)) : Nil
      @runs.select! { |id, _| used.includes?(id) }
    end

    # A run exists for `id` (paint-cache gate: an appearing widget's
    # output is time-dependent and must not be replayed from cache).
    def run?(id : Id) : Bool
      @runs.has_key?(id)
    end

    # True while any run is still waiting out its delay or springing
    # (the subtree-cache gate — liveness, not presence: a settled run
    # lingering in Memory does not block).
    def any_running? : Bool
      @runs.any? { |_, r| r.delay > 0.0 || r.progress.moving?(1.0) }
    end

    def reset : Nil
      @runs.clear
    end

    # Raven's per-kind curve (`rvn_transition_begin`): "visible well
    # before it lands — the motion is what should be seen", hence the
    # 2.2× opacity ramp.
    def self.curves(kind : Symbol, t : Float64) : NamedTuple(sx: Float64, sy: Float64,
                                                             dx: Float64, dy: Float64,
                                                             opacity: Float64)
      away = 1.0 - t
      opacity = (t * 2.2).clamp(0.0, 1.0)
      sx = sy = 1.0
      dx = dy = 0.0
      case kind
      when :pop
        sx = sy = 0.55 + 0.45 * t
      when :zoom
        sx = sy = 1.0 + 0.22 * away
      when :fly_up
        dy = 56.0 * away
        sx = sy = 1.0 - 0.08 * away.clamp(0.0, 1.0)
      when :fly_down
        dy = -56.0 * away
        sx = sy = 1.0 - 0.08 * away.clamp(0.0, 1.0)
      when :fly_left
        dx = 72.0 * away
        sx = sy = 1.0 - 0.08 * away.clamp(0.0, 1.0)
      when :fly_right
        dx = -72.0 * away
        sx = sy = 1.0 - 0.08 * away.clamp(0.0, 1.0)
      when :drop
        # Falls from above and lands with a squash: the clamped away
        # also runs NEGATIVE on the wobbly overshoot — sy dips below 1
        # (squash) while sx runs past it (stretch), the landing wobble.
        cl = away.clamp(-0.6, 0.6)
        dy = -140.0 * away
        sy = 1.0 + 0.25 * cl
        sx = 1.0 - 0.12 * cl
      when :slide_left
        dx = 28.0 * away
      when :slide_right
        dx = -28.0 * away
      when :rise
        # CSS `card-in`: fade in while sliding up 10px.
        dy = 10.0 * away
      end
      {sx: sx, sy: sy, dx: dx, dy: dy, opacity: opacity}
    end
  end
end
