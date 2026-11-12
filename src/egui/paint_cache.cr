# Retained paint cache (FPS_OPTIMIZATION.md §1, stage 2): a widget's
# paint output — commands + layer tags — memoized by a key the widget
# computes from everything its output depends on (content, resolved
# style identity, constraints). The API stays immediate: `Ui#add`
# replays a hit transparently (allocate + interact + re-emit the
# recorded commands) and only runs the widget on a miss. A stationary
# frame rebuilds nothing; a hover changes two widgets' keys (the
# state bag identity changes with :hover/:active), everything else
# comes back from the cache — "retained paint under immediate API".
#
# Key identity is OBJECT identity wherever possible: the resolved
# StyleVars bags are shared immutable objects (one per class set ×
# state until a rule changes), the base Style is the theme/container
# object — so a style/rule/theme change issues fresh objects, misses
# every affected key, and NO explicit invalidation wiring is needed.
# The widget folds those objects (plus its content fields, the
# available size and the focus flag) into one UInt64 key hash; a
# 64-bit collision between two live keys replays wrong pixels with
# probability 2⁻⁶⁴ per pair — accepted (same trade as the Svg raster
# key).
#
# Replay correctness:
#   * ids — the cached entry records how many child ids the widget
#     minted; replay re-mints the same span so LATER widgets keep
#     their ids (an id shift would corrupt every Memory state);
#   * position — recorded commands are absolute; a moved widget
#     replays through a translate-only TransformFrame (scale 1);
#   * clip — each command's recorded clip is translated and
#     re-intersected with the ambient clip (`with_clip` exists on
#     every command struct);
#   * captures are only taken with NO transform frame active
#     (xform-emitted or deferred commands would double-transform on
#     replay) and discarded wholesale when a Flex measure pass
#     truncates into them.
module Egui
  class PaintCache
    # One interaction registration inside a captured subtree: replayed
    # (translated) on a subtree hit so hit-testing, hover and clicks
    # keep working when the block doesn't run.
    struct Interact
      getter id : Id
      getter rect : Rect
      getter sense : Sense
      getter layer : LayerId

      def initialize(@id, @rect, @sense, @layer)
      end
    end

    class Entry
      getter id : Id
      # Child-counter span the widget consumed (see replay above).
      getter ids_consumed : Int32
      getter size : Vec2
      getter sense : Sense
      # rect.min of the recorded frame — replay's translation origin.
      getter origin : Pos2
      # The painter's ambient clip at capture (per-command clips are
      # embedded in the commands themselves).
      getter ambient_clip : Rect
      getter commands : Array(PaintCmd)
      getter layers : Array(Int32)
      # Subtree entries (Ui#cached_subtree): the interaction
      # registrations the block made, and its layout effects on the Ui
      # (cursor + min_rect after the block) — replayed translated.
      # Leaf entries leave these empty/nil.
      getter interacts : Array(Interact)
      getter cursor : Pos2?
      getter min_rect : Rect?
      property last_gen : Int32

      def initialize(@id : Id, @ids_consumed : Int32, @size : Vec2,
                     @sense : Sense, @origin : Pos2,
                     @ambient_clip : Rect, @commands : Array(PaintCmd),
                     @layers : Array(Int32), @last_gen : Int32,
                     @interacts : Array(Interact) = [] of Interact,
                     @cursor : Pos2? = nil, @min_rect : Rect? = nil)
      end
    end

    # Command-count budget (≈ sizeof(PaintCmd) × 100k ≈ tens of MB
    # worst case; the working sets measured are far below — lucide
    # ~750 commands, html gallery ~4k). Overflow clears the cache
    # whole, like the measure cache's clear-on-overflow.
    BUDGET_COMMANDS = 100_000

    def initialize
      @entries = {} of UInt64 => Entry
      @gen = 1
      @hits = 0
      @misses = 0
      @real_misses = 0
    end

    def lookup(key : UInt64, measuring : Bool = false) : Entry?
      if (e = @entries[key]?)
        e.last_gen = @gen
        @hits += 1
        Egui::Bench.count("paintcache.hit")
        e
      else
        @misses += 1
        # Misses of MEASURE-only lookups (a Flex measure cell wider
        # than the real slot) are routine, not content changes — the
        # flex memo invalidates on REAL misses only.
        @real_misses += 1 unless measuring
        Egui::Bench.count("paintcache.miss")
        nil
      end
    end

    def store(key : UInt64, entry : Entry) : Nil
      @entries.clear if @entries.size >= BUDGET_COMMANDS
      @entries[key] = entry
    end

    # Frame clock (Context#end_frame): stale entries (unused for
    # STALE frames) are evicted first, so a scrolled-away screen
    # doesn't pin memory.
    STALE = 3

    def tick : Nil
      @gen += 1
      return if @entries.size < BUDGET_COMMANDS // 2
      @entries.reject! { |_, e| @gen - e.last_gen > STALE }
    end

    def size : Int32
      @entries.size
    end

    getter hits : Int32
    getter misses : Int32
    getter real_misses : Int32

    def clear : Nil
      @entries.clear
    end

    # Re-emit an entry's commands at `rect` (translated, re-clipped
    # against the painter's current ambient clip, layers restored).
    def self.replay(entry : Entry, rect : Rect, painter : Painter) : Nil
      dx = rect.min.x - entry.origin.x
      dy = rect.min.y - entry.origin.y
      ambient = painter.clip
      moved = dx != 0.0 || dy != 0.0
      reclipped = moved || ambient != entry.ambient_clip
      frame = moved ? Painter::TransformFrame.new(Pos2.zero, 0,
        1.0, 1.0, dx, dy, 1.0) : nil
      entry.commands.each_with_index do |cmd, i|
        unless cmd.is_a?(NoopCmd)
          cmd = frame.try(&.apply(cmd)) || cmd
          if reclipped
            rec = cmd.clip
            want = if moved
                     # The recorded clip moved with the widget; the
                     # ambient clip did not — intersect both.
                     shifted = Rect.new(Pos2.new(rec.min.x + dx, rec.min.y + dy),
                       Pos2.new(rec.max.x + dx, rec.max.y + dy))
                     intersect(shifted, ambient)
                   else
                     intersect(rec, ambient)
                   end
            cmd = cmd.with_clip(want, cmd.clip_corners) unless want == rec
          end
        end
        painter.replay_add(entry.layers[i], cmd)
      end
    end

    # Re-emit a SUBTREE entry's commands translated by (dx, dy) and
    # re-clipped against the painter's current ambient clip (the
    # Ui#cached_subtree replay path — no single widget rect, the whole
    # span moves together).
    def self.replay_subtree(entry : Entry, dx : Float64, dy : Float64,
                            painter : Painter) : Nil
      ambient = painter.clip
      moved = dx != 0.0 || dy != 0.0
      reclipped = moved || ambient != entry.ambient_clip
      frame = moved ? Painter::TransformFrame.new(Pos2.zero, 0,
        1.0, 1.0, dx, dy, 1.0) : nil
      entry.commands.each_with_index do |cmd, i|
        unless cmd.is_a?(NoopCmd)
          cmd = frame.try(&.apply(cmd)) || cmd
          if reclipped
            rec = cmd.clip
            want = if moved
                     shifted = Rect.new(Pos2.new(rec.min.x + dx, rec.min.y + dy),
                       Pos2.new(rec.max.x + dx, rec.max.y + dy))
                     intersect(shifted, ambient)
                   else
                     intersect(rec, ambient)
                   end
            cmd = cmd.with_clip(want, cmd.clip_corners) unless want == rec
          end
        end
        painter.replay_add(entry.layers[i], cmd)
      end
    end

    # Rect intersection (axis-aligned): nil-clip commands (infinite)
    # intersect to the ambient clip; disjoint to a degenerate empty
    # rect (matches the painter's clip arithmetic — containment tests
    # against an empty rect just fail).
    private def self.intersect(a : Rect, b : Rect) : Rect
      min_x = {a.min.x, b.min.x}.max
      min_y = {a.min.y, b.min.y}.max
      max_x = {a.max.x, b.max.x}.min
      max_y = {a.max.y, b.max.y}.min
      if max_x < min_x
        min_x = max_x
      end
      if max_y < min_y
        min_y = max_y
      end
      Rect.new(Pos2.new(min_x, min_y), Pos2.new(max_x, max_y))
    end
  end
end
