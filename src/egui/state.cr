# System state containers (ports of egui_upstream/crates/egui/src/memory/):
#
# - IdTypeMap  — persistent per-widget state (`Memory::data`)
# - Areas      — floating-window positions + z-order
# - Focus      — focused widget with dead-man's switch
# - AnimationManager — Id-keyed value animations
#
# Everything here must survive frames in which the owning widget is not
# created (collapsed header contents, hidden windows) — that is the whole
# point of system state vs app state.

module Egui
  # egui `IdTypeMap`: Id → typed cell. Crystal has no stable TypeId
  # storage, so the value vocabulary is a closed union covering what
  # widgets persist (bool/int/float/vec/point/string). Pruned each frame
  # against the used ids (see Memory#end_frame).
  class IdTypeMap
    alias Cell = Bool | Int32 | Float64 | Vec2 | Pos2 | String

    def initialize
      @cells = {} of Id => Cell
    end

    def []?(id : Id) : Cell?
      @cells[id]?
    end

    def set(id : Id, value : Cell) : Nil
      @cells[id] = value
    end

    def get(id : Id, default : Cell) : Cell
      @cells[id]? || default
    end

    def get_bool(id : Id, default : Bool = false) : Bool
      v = @cells[id]?
      case v
      when Bool then v
      else default
      end
    end

    def set_bool(id : Id, value : Bool) : Nil
      @cells[id] = value
    end

    def get_int(id : Id, default : Int32 = 0) : Int32
      v = @cells[id]?
      case v
      when Int32 then v
      else default
      end
    end

    def set_int(id : Id, value : Int32) : Nil
      @cells[id] = value
    end

    def get_f64(id : Id, default : Float64 = 0.0) : Float64
      v = @cells[id]?
      case v
      when Float64 then v
      when Int32   then v.to_f64
      else default
      end
    end

    def set_f64(id : Id, value : Float64) : Nil
      @cells[id] = value
    end

    def get_vec2(id : Id, default : Vec2 = Vec2.zero) : Vec2
      v = @cells[id]?
      v.as?(Vec2) || default
    end

    def set_vec2(id : Id, value : Vec2) : Nil
      @cells[id] = value
    end

    def get_string(id : Id, default : String = "") : String
      v = @cells[id]?
      v.as?(String) || default
    end

    def set_string(id : Id, value : String) : Nil
      @cells[id] = value
    end

    # egui `Memory::end_pass(used_ids)`: drop state of widgets that no
    # longer exist. Callers pass the ids used this frame.
    def keep_only(ids : Enumerable(Id)) : Nil
      @cells.select! { |id, _| ids.includes?(id) }
    end

    def size : Int32
      @cells.size
    end
  end

  # egui `Areas` (memory/area.rs + layers): where floating windows sit
  # and in which order they stack. Positions persist across frames even
  # when the window is not shown (that's what makes windows draggable).
  class Areas
    def initialize
      @positions = {} of Id => Pos2
      @order = [] of LayerId
      @user_moved = Set(Id).new
    end

    def pos_for(id : Id, default : Pos2) : Pos2
      @positions[id] ||= default
    end

    def set_pos(id : Id, pos : Pos2) : Nil
      @positions[id] = pos
    end

    def move_by(id : Id, delta : Vec2) : Nil
      @user_moved << id
      @positions[id] = pos_for(id, Pos2.zero) + delta
    end

    # Has the user ever dragged this window away? Until then the owner
    # may keep re-centering it (embedded windows re-center on their
    # measured size); after a drag the stored position wins.
    def user_moved?(id : Id) : Bool
      @user_moved.includes?(id)
    end

    def bring_to_top(layer : LayerId) : Nil
      @order.reject! { |l| l == layer }
      @order << layer
    end

    def order : Array(LayerId)
      @order
    end
  end

  # egui `Focus` (memory/mod.rs): which widget owns the keyboard.
  # `begin_frame` lags one frame (`id_previous_frame`) — that is the
  # dead-man's switch: if the focused widget stops being created, focus
  # drops instead of pointing at a stale id.
  #
  # Arrow locks (upstream `FocusLockFilter`): a focused slider/drag
  # value claims the arrows in its own direction so navigation skips
  # them; latched one frame like the focus id itself. A focused widget
  # can additionally claim the WHOLE keyboard (upstream `EventFilter`
  # — a terminal passes Tab/arrows to its child process): focus
  # navigation (Tab cycling, geometric arrows) stands down entirely
  # while the lock is held.
  class Focus
    @id : Id?
    @id_previous_frame : Id?
    @id_next_frame : Id?

    @lock_h : Bool
    @lock_v : Bool
    @lock_h_next : Bool
    @lock_v_next : Bool
    @lock_kb : Bool
    @lock_kb_next : Bool
    @text : Bool
    @text_next : Bool

    def initialize
      @id = nil
      @id_previous_frame = nil
      @id_next_frame = nil
      @lock_h = false
      @lock_v = false
      @lock_h_next = false
      @lock_v_next = false
      @lock_kb = false
      @lock_kb_next = false
      @text = false
      @text_next = false
    end

    def begin_frame : Nil
      @id_previous_frame = @id
      @id = @id_next_frame
      @id_next_frame = nil
      @lock_h = @lock_h_next
      @lock_v = @lock_v_next
      @lock_h_next = false
      @lock_v_next = false
      @lock_kb = @lock_kb_next
      @lock_kb_next = false
      @text = @text_next
      @text_next = false
    end

    def request(id : Id) : Nil
      @id_next_frame = id
    end

    # Keep-alive (called by interact for the currently focused focusable):
    # never overrides a pending navigation request made this frame.
    def keep_alive(id : Id) : Nil
      @id_next_frame = id if @id_next_frame.nil?
    end

    def clear : Nil
      @id_next_frame = nil
    end

    def id : Id?
      @id
    end

    def lock_arrows(horizontal : Bool = false, vertical : Bool = false) : Nil
      @lock_h_next = true if horizontal
      @lock_v_next = true if vertical
    end

    # Claim every navigation key (Tab, arrows) for the focused widget —
    # e.g. a terminal emulator forwarding them to its child process.
    def lock_keyboard : Nil
      @lock_kb_next = true
    end

    def lock_keyboard? : Bool
      @lock_kb
    end

    # Claim text entry for the focused widget (egui's wants_text_input):
    # text widgets set this every focused frame, mirroring the lock_*
    # flags above — the backend uses it to raise the on-screen keyboard
    # on touch platforms.
    def text_input! : Nil
      @text_next = true
    end

    def wants_text_input? : Bool
      !@id.nil? && @text
    end

    def lock_h? : Bool
      @lock_h
    end

    def lock_v? : Bool
      @lock_v
    end

    def has_focus?(id : Id) : Bool
      @id == id
    end

    def gained_focus?(id : Id) : Bool
      @id == id && @id_previous_frame != id
    end

    def lost_focus?(id : Id) : Bool
      @id_previous_frame == id && @id != id
    end
  end

  # egui `AnimationManager`: smooth Id-keyed scalar animation. When the
  # target changes mid-flight, the animation restarts from its current
  # value (used for hover/fade transitions, sliders easing, …).
  class AnimationManager
    # Reference type on purpose: stored in a Hash and mutated in place
    # (a struct would be returned as a copy and changes would be lost).
    private class Anim
      property from : Float64
      property target : Float64
      property start : Float64
      property duration : Float64

      def initialize(@from : Float64, @target : Float64, @start : Float64,
                     @duration : Float64)
      end
    end

    def initialize
      @anims = {} of Id => Anim
    end

    def animate(id : Id, target : Float64, duration : Float64, time : Float64) : Float64
      anim = @anims[id]?
      if anim.nil?
        @anims[id] = Anim.new(target, target, time, duration)
        return target
      end
      if anim.target != target
        anim.from = value_at(anim, time)
        anim.target = target
        anim.start = time
        anim.duration = duration
      end
      value_at(anim, time)
    end

    # True while the animation for `id` is still easing towards its
    # target (used to keep requesting repaints until it settles).
    def running?(id : Id, time : Float64) : Bool
      anim = @anims[id]?
      return false if anim.nil?
      anim.duration > 0.0 && (time - anim.start) < anim.duration
    end

    private def value_at(a : Anim, time : Float64) : Float64
      return a.target if a.duration <= 0.0
      t = ((time - a.start) / a.duration).clamp(0.0, 1.0)
      eased = t * t * (3.0 - 2.0 * t) # smoothstep
      a.from + (a.target - a.from) * eased
    end
  end

  # Animated style values (plans/animations.md Ур.1): the cascade's
  # `transition` keys (`transition.background: 120`, or the `transition`
  # shorthand for every key — milliseconds) drive per-widget
  # interpolation of colors and scalars. Keyed by widget id + key salt;
  # retargeting mid-flight restarts from the current value, the same
  # semantics `AnimationManager` gives hand-coded animations. The
  # smoothstep easing matches it, so transitions and hand-rolled
  # animations ease alike.
  # Named easing curves for cascade transitions (`easing` /
  # `easing.<key>` style keys, plans/animations.md Ур.2). The default
  # (`smoothstep`) matches `AnimationManager`, so hand-rolled and
  # declared animations ease alike; unknown names fall back to it.
  module Easing
    def self.apply(name : String?, t : Float64) : Float64
      tt = t.clamp(0.0, 1.0)
      case name
      when nil, "", "smoothstep" then tt * tt * (3.0 - 2.0 * tt)
      when "linear"     then tt
      when "ease"       then -(Math.cos(Math::PI * tt) - 1.0) / 2.0
      when "ease-in"    then tt * tt * tt
      when "ease-out"   then 1.0 - (1.0 - tt) ** 3
      when "ease-in-out"
        tt < 0.5 ? 4.0 * tt * tt * tt : 1.0 - ((-2.0 * tt + 2.0) ** 3) / 2.0
      else tt * tt * (3.0 - 2.0 * tt)
      end
    end
  end

  # @keyframes playback state (plans/NativeHTML.md §7): per-widget-id
  # start times and pause bookkeeping. The track data and the timing
  # live in the rule (`Keyframes::Spec`); this only remembers WHEN a
  # given id started playing it (a spec change restarts, like CSS).
  class KeyframeAnims
    private class Run
      property spec : Keyframes::Spec
      property start : Float64
      property paused_at : Float64?

      def initialize(@spec : Keyframes::Spec, @start : Float64)
        @paused_at = nil
      end
    end

    @runs = {} of Id => Run

    def initialize
    end

    # Where the animation stands for `id` at `time` (seconds):
    # `running` is true while a future frame changes something (the
    # caller requests repaints); `progress` is the eased,
    # direction-applied track position in 0..1, nil while in delay or
    # after a finite run finished (CSS fill-mode none — the base
    # cascade values apply again).
    def evaluate(id : Id, spec : Keyframes::Spec,
                 time : Float64) : Keyframes::Eval
      run = @runs[id]?
      if run.nil? || !run.spec.same_run?(spec)
        run = @runs[id] = Run.new(spec, time)
      else
        # A play-state toggle or easing retune refreshes in place —
        # no restart (see Spec#same_run?).
        run.spec = spec
      end
      # Pause bookkeeping: while paused the clock reads the FROZEN
      # moment (progress holds); resuming shifts the start so the
      # paused span never counts as elapsed time.
      if spec.paused
        run.paused_at = time if run.paused_at.nil?
        clock = run.paused_at.not_nil!
      else
        if (pa = run.paused_at)
          run.start += time - pa
          run.paused_at = nil
        end
        clock = time
      end
      active = clock - run.start - spec.delay
      return Keyframes::Eval.new(true, nil) if active < 0.0
      return Keyframes::Eval.new(false, nil) if spec.duration <= 0.0
      cycle = active / spec.duration
      if spec.iterations >= 0.0 && cycle >= spec.iterations
        return Keyframes::Eval.new(false, nil)
      end
      raw = cycle - cycle.floor
      eased = Easing.apply(spec.easing, raw)
      prog = case spec.direction
             when "reverse"          then 1.0 - eased
             when "alternate"        then cycle.floor.to_i.even? ? eased : 1.0 - eased
             when "alternate-reverse" then cycle.floor.to_i.even? ? 1.0 - eased : eased
             else eased
             end
      Keyframes::Eval.new(true, prog.clamp(0.0, 1.0))
    end

    def reset : Nil
      @runs.clear
    end
  end

  class StyleAnimations
    # Spring-interpolated state (plans/NATIVE_HTML_DEMO.md §3.2): one
    # oscillator per channel of the animated value (1 for scalars, 4
    # for colors), the target, the live spec and the delay countdown.
    # A reference class for the same reason as Cell — stored in a Hash
    # and mutated in place. Retargeting keeps value AND velocity (the
    # easing cells above restart from the current value with a zero
    # derivative; the spring glides on — no jump).
    class SpringCell
      property channels : Array(Spring)
      property targets : Array(Float64)
      property spec : Spring::Spec
      property delay : Float64
      property last_time : Float64?

      def initialize(targets : Array(Float64), @spec : Spring::Spec,
                     time : Float64)
        # First sighting snaps (CSS: no transition on the initial
        # style application) — the oscillators start settled.
        @channels = targets.map { |t| s = Spring.new(t); s.set(t); s }
        @targets = targets
        @delay = 0.0
        @last_time = time
      end

      # Still animating: waiting out a delay or an oscillator has not
      # settled at its target yet.
      def running? : Bool
        @delay > 0.0 ||
          @channels.zip(@targets).any? { |s, t| s.moving?(t) }
      end

      # The clamped frame delta since the last step (Raven's
      # `rvn_animation_dt`: after a pause the motion resumes gently
      # instead of fast-forwarding through the missed time).
      def tick(time : Float64) : Float64
        dt = @last_time ? (time - @last_time.not_nil!) : 0.0
        @last_time = time
        dt.clamp(0.0, 1.0 / 30.0)
      end
    end

    private class Cell(T)
      property from : T
      property target : T
      property start : Float64
      property duration : Float64
      property easing : String?

      def initialize(@from : T, @target : T, @start : Float64,
                     @duration : Float64, @easing : String? = nil)
      end
    end

    @colors = {} of Id => Cell(Color32)
    @scalars = {} of Id => Cell(Float64)
    @vec2s = {} of Id => Cell(Vec2)
    @spring_scalars = {} of Id => SpringCell
    @spring_colors = {} of Id => SpringCell

    # Smoothly move the color for `id` towards `target` over
    # `duration` seconds; the first sighting jumps (CSS: no transition
    # on the initial style application). `easing` names an
    # `Easing.apply` curve (nil = smoothstep).
    def color(id : Id, target : Color32, duration : Float64,
              time : Float64, easing : String? = nil) : Color32
      if duration <= 0.0
        @colors.delete(id)
        @spring_colors.delete(id)
        return target
      end
      anim = @colors[id]?
      if anim.nil?
        @colors[id] = Cell.new(target, target, time, duration, easing)
        return target
      end
      if anim.target != target
        anim.from = color_at(anim, time)
        anim.target = target
        anim.start = time
        anim.duration = duration
      end
      anim.easing = easing
      color_at(anim, time)
    end

    def scalar(id : Id, target : Float64, duration : Float64,
               time : Float64, easing : String? = nil) : Float64
      if duration <= 0.0
        @scalars.delete(id)
        @spring_scalars.delete(id)
        return target
      end
      anim = @scalars[id]?
      if anim.nil?
        @scalars[id] = Cell.new(target, target, time, duration, easing)
        return target
      end
      if anim.target != target
        anim.from = scalar_at(anim, time)
        anim.target = target
        anim.start = time
        anim.duration = duration
      end
      anim.easing = easing
      scalar_at(anim, time)
    end

    def vec2(id : Id, target : Vec2, duration : Float64,
             time : Float64, easing : String? = nil) : Vec2
      if duration <= 0.0
        @vec2s.delete(id)
        return target
      end
      anim = @vec2s[id]?
      if anim.nil?
        @vec2s[id] = Cell.new(target, target, time, duration, easing)
        return target
      end
      if anim.target != target
        anim.from = vec2_at(anim, time)
        anim.target = target
        anim.start = time
        anim.duration = duration
      end
      anim.easing = easing
      vec2_at(anim, time)
    end

    # True while any flavor for `id` is still easing or springing (the
    # Context requests repaints until everything settles).
    def running?(id : Id, time : Float64) : Bool
      anim = @colors[id]? || @scalars[id]? || @vec2s[id]?
      return true if anim &&
                     anim.duration > 0.0 && (time - anim.start) < anim.duration
      spring = @spring_scalars[id]? || @spring_colors[id]?
      spring ? spring.running? : false
    end

    # --- spring flavors (plans/NATIVE_HTML_DEMO.md §3.2) ---------------
    #
    # `transition.<key>: spring(…)` / `transition: spring(…)` — a
    # damped oscillator (Egui::Spring) instead of duration+easing: the
    # value keeps its velocity across retargets (no jump), and while
    # it moves #running? stays true so the next frame is requested.

    # Smoothly spring a style SCALAR towards `target`; the first
    # sighting snaps, a retarget glides on with the current velocity,
    # an optional `spec.delay` holds the value first (like a CSS
    # transition delay).
    def spring_scalar(id : Id, target : Float64, spec : Spring::Spec,
                      time : Float64) : Float64
      cell = @spring_scalars[id]?
      if cell.nil?
        @scalars.delete(id) # a key animates by ONE flavor at a time
        @spring_scalars[id] = SpringCell.new([target], spec, time)
        return target
      end
      retarget = cell.targets[0] != target
      cell.spec = spec # retune in place; motion continues
      cell.targets[0] = target
      cell.delay = spec.delay if retarget
      step_cell(cell, time)
      cell.channels[0].value
    end

    # Same for a style COLOR — one oscillator per channel (normalized
    # 0..1, the scale the settle thresholds are tuned for).
    def spring_color(id : Id, target : Color32, spec : Spring::Spec,
                     time : Float64) : Color32
      t4 = [target.r, target.g, target.b, target.a].map { |c| c / 255.0 }
      cell = @spring_colors[id]?
      if cell.nil?
        @colors.delete(id)
        @spring_colors[id] = SpringCell.new(t4, spec, time)
        return target
      end
      retarget = cell.targets != t4
      cell.spec = spec
      4.times { |i| cell.targets[i] = t4[i] }
      cell.delay = spec.delay if retarget
      step_cell(cell, time)
      Color32.new(
        chan_byte(cell, 0), chan_byte(cell, 1),
        chan_byte(cell, 2), chan_byte(cell, 3))
    end

    # Advance one cell by the clamped frame delta: count down an
    # active delay (value holds), otherwise track every channel and
    # snap the ones that settled.
    private def step_cell(cell : SpringCell, time : Float64) : Nil
      dt = cell.tick(time)
      if cell.delay > 0.0
        cell.delay = {cell.delay - dt, 0.0}.max
        return
      end
      cell.channels.zip(cell.targets) do |s, t|
        s.track(dt, t, cell.spec.response, cell.spec.damping)
      end
    end

    private def chan_byte(cell : SpringCell, i : Int32) : UInt8
      (cell.channels[i].value * 255.0).round.clamp(0.0, 255.0).to_u8
    end

    private def color_at(a : Cell(Color32), time : Float64) : Color32
      a.from.lerp(a.target, eased_t(a, time))
    end

    private def scalar_at(a : Cell(Float64), time : Float64) : Float64
      a.from + (a.target - a.from) * eased_t(a, time)
    end

    private def vec2_at(a : Cell(Vec2), time : Float64) : Vec2
      Vec2.new(
        a.from.x + (a.target.x - a.from.x) * eased_t(a, time),
        a.from.y + (a.target.y - a.from.y) * eased_t(a, time))
    end

    private def eased_t(a : Cell, time : Float64) : Float64
      t = ((time - a.start) / a.duration).clamp(0.0, 1.0)
      Easing.apply(a.easing, t)
    end
  end
end
