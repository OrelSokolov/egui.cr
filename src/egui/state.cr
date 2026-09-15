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
      # nil-check, not `||`: a stored `false` cell is falsy (get_bool note).
      v = @cells[id]?
      v.nil? ? default : v
    end

    def get_bool(id : Id, default : Bool = false) : Bool
      # NOTE: must not be `v.as?(Bool) || default` — a stored `false`
      # is falsy and would read back as the default (a TreeView node
      # with default_open: true could never be collapsed).
      v = @cells[id]?
      v.is_a?(Bool) ? v : default
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
    end

    def pos_for(id : Id, default : Pos2) : Pos2
      @positions[id] ||= default
    end

    def set_pos(id : Id, pos : Pos2) : Nil
      @positions[id] = pos
    end

    def move_by(id : Id, delta : Vec2) : Nil
      @positions[id] = pos_for(id, Pos2.zero) + delta
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
  # them; latched one frame like the focus id itself.
  class Focus
    @id : Id?
    @id_previous_frame : Id?
    @id_next_frame : Id?

    @lock_h : Bool
    @lock_v : Bool
    @lock_h_next : Bool
    @lock_v_next : Bool

    def initialize
      @id = nil
      @id_previous_frame = nil
      @id_next_frame = nil
      @lock_h = false
      @lock_v = false
      @lock_h_next = false
      @lock_v_next = false
    end

    def begin_frame : Nil
      @id_previous_frame = @id
      @id = @id_next_frame
      @id_next_frame = nil
      @lock_h = @lock_h_next
      @lock_v = @lock_v_next
      @lock_h_next = false
      @lock_v_next = false
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

    private def value_at(a : Anim, time : Float64) : Float64
      return a.target if a.duration <= 0.0
      t = ((time - a.start) / a.duration).clamp(0.0, 1.0)
      eased = t * t * (3.0 - 2.0 * t) # smoothstep
      a.from + (a.target - a.from) * eased
    end
  end
end
