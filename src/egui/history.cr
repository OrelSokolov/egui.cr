# Port of egui_upstream/crates/emath/src/history.rs (Float64 specialized:
# that's the only series the port tracks — offset over time for kinetic
# scrolling velocity estimation).
#
# Tracks recent values of a time series: a minimum length (enough data
# for an estimate), a maximum length and a maximum age (the estimate is
# never outdated). Times are monotonically increasing seconds; the time
# difference between values can be zero, never negative.

module Egui
  class History
    getter max_len : Int32
    getter max_age : Float64
    getter total_count : UInt64

    @values : Deque(Tuple(Float64, Float64)) # (time, value), oldest front

    def initialize(length_range : Range(Int32, Int32), @max_age : Float64)
      @min_len = length_range.begin
      @max_len = length_range.end
      @total_count = 0_u64
      @values = Deque(Tuple(Float64, Float64)).new
    end

    def empty? : Bool
      @values.empty?
    end

    def size : Int32
      @values.size.to_i32
    end

    def latest : Float64?
      @values.last?.try(&.[1])
    end

    # Time contained from the first to the last sample.
    def duration : Float64
      if (first = @values.first?) && (last = @values.last?)
        last[0] - first[0]
      else
        0.0
      end
    end

    def clear : Nil
      @values.clear
    end

    # Values must be added with a non-decreasing time.
    def add(now : Float64, value : Float64) : Nil
      @total_count += 1
      @values << {now, value}
      flush(now)
    end

    # Drop samples that are too old / too many.
    def flush(now : Float64) : Nil
      while @values.size > @max_len
        @values.shift
      end
      oldest_allowed = now - @max_age
      while @min_len < @values.size &&
            (front = @values.first?) && front[0] < oldest_allowed
        @values.shift
      end
    end

    # Smooth velocity (per second) over the time span: last value minus
    # first value over the elapsed time between them.
    def velocity : Float64?
      if (first = @values.first?) && (last = @values.last?)
        dt = last[0] - first[0]
        (last[1] - first[1]) / dt if dt > 0.0
      end
    end
  end

  # Kinetic scrolling state machine (one per scrollable axis, driven by
  # a `History` of the offset): while direct input arrives (wheel,
  # scrollbar thumb) the offset moves immediately and the history
  # estimates the release velocity; once input stops, the offset keeps
  # gliding by that velocity with exponential decay (half-life
  # HALF_LIFE seconds), stopping dead at the content edges.
  #
  # Stateless across frames: the owner persists `offset`/`velocity`
  # (IdTypeMap cells) and the History (Memory#scroll_history) and
  # rebuilds the scroller each frame.
  class KineticScroller
    MAX_VELOCITY = 1500.0 # px/s — fling clamp
    STOP_VELOCITY = 15.0  # px/s — below this the glide ends
    HALF_LIFE = 0.12      # s — velocity halves every HALF_LIFE seconds

    getter velocity : Float64

    def initialize(@offset : Float64, @velocity : Float64,
                   @history : History)
    end

    def offset : Float64
      @offset
    end

    # Direct input this frame (wheel notch, scrollbar drag): apply now,
    # latch a sample for the release-velocity estimate. A lone sample
    # (one isolated notch) estimates nothing — no fling.
    def input(delta : Float64, time : Float64, max_offset : Float64) : Nil
      @offset = (@offset + delta).clamp(0.0, max_offset)
      @history.add(time, @offset)
      @velocity = if @history.size >= 2
                    v = @history.velocity || 0.0
                    v.clamp(-MAX_VELOCITY, MAX_VELOCITY)
                  else
                    0.0
                  end
    end

    # No input this frame: glide by the latched velocity, decaying it.
    # `request_repaint` keeps frames coming while the glide lives.
    def glide(dt : Float64, max_offset : Float64, ctx : Context) : Nil
      return if @velocity.zero? || dt <= 0.0
      @history.clear
      target = (@offset + @velocity * dt).clamp(0.0, max_offset)
      # Hitting either edge kills the glide (content can't compress).
      if target == @offset && (max_offset.zero? || @offset == 0.0 ||
                               @offset == max_offset)
        @velocity = 0.0
        return
      end
      @offset = target
      @velocity *= 0.5 ** (dt / HALF_LIFE)
      if @velocity.abs < STOP_VELOCITY
        @velocity = 0.0
      else
        ctx.request_repaint
      end
    end

    # The scrollbar thumb takes over: direct control, no inertia.
    def takeover : Nil
      @velocity = 0.0
      @history.clear
    end
  end
end

