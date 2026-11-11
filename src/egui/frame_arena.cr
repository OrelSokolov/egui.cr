# Frame arena (plans/FPS_OPTIMIZATION.md §3): a bump allocator over one
# reusable byte slab, reset to offset 0 by `Context#end_frame` every
# frame. Scratch data structures allocated here cost nothing in the
# stationary frame — the slab grows to the high-water mark in the first
# frames and is then reused without touching the GC.
#
# Scope (important): POD slices ONLY — Bytes and typed Slice(T) views
# carved out of the slab. Crystal objects (Array, Hash, String) cannot
# live here; the engine-level substitute for those is stage 1's
# id→slot SoA arrays. Data handed out by the arena must be consumed
# WITHIN the frame: nothing arena-allocated may escape into the value
# `end_frame` returns (the paint command list outlives the reset), so
# PaintCmd-carried buffers keep their own allocations.
#
# Single-threaded by design: the frame is built on one thread; no
# locks. `#reset` does not zero memory — stale bytes are simply
# overwritten by the next taker; `#bytes_used` is the telemetry
# high-water readout.

module Egui
  class FrameArena
    INITIAL = 1 << 16 # 64 KiB — covers a frame's scratch by default

    @buf : Bytes
    @off : Int32

    def initialize(capacity : Int32 = INITIAL)
      @buf = Bytes.new({capacity, 8}.max)
      @off = 0
    end

    # Carve `n` raw bytes (8-byte aligned). Growth is geometric: a
    # frame that outgrows the slab doubles it; earlier carvings stay
    # valid (they point into the old slab, which the GC keeps alive
    # through the slice). After a few frames the high-water stabilizes
    # and the stationary frame stops allocating entirely.
    def bytes(n : Int) : Bytes
      raise ArgumentError.new("negative size") if n < 0
      start = (@off + 7) & ~7
      total = start + n
      if total > @buf.size
        cap = @buf.size
        while cap < total
          cap *= 2
        end
        @buf = Bytes.new(cap)
      end
      @off = start + n
      @buf[start, n]
    end

    # Carve a typed view of `n` elements over the slab — the SoA
    # building block for stage 1 (Memory slots).
    def slice(type : T.class, n : Int) : Slice(T) forall T
      raw = bytes(n * sizeof(T))
      Slice(T).new(raw.to_unsafe.as(T*), n)
    end

    # Back to offset 0 (called once per frame from Context#end_frame).
    def reset : Nil
      @off = 0
    end

    # Bytes handed out since the last reset — telemetry readout.
    def bytes_used : Int32
      @off
    end

    # Current slab capacity in bytes.
    def capacity : Int32
      @buf.size
    end
  end
end
