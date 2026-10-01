# Port of egui_upstream/crates/egui/src/id.rs.
#
# `Id` is the stable identity of a widget across frames: it keys the
# interaction state in `Memory` (hover, click origin, …). Upstream uses
# `ahash` with a per-process random seed; we use FNV-1a, which is
# deterministic per process — the property egui relies on.

module Egui
  struct Id
    getter value : UInt64

    def initialize(@value : UInt64)
    end

    def self.from(source : String, salt : String = "") : Id
      h = FNV_OFFSET
      source.each_byte do |b|
        h = (h ^ b) &* FNV_PRIME
      end
      # The plain FNV-1a over the bytes is deterministic ACROSS
      # processes too — auto ids (`#0x…`) then address the same widget
      # after a restart, which the .ecss style diff relies on. Only an
      # explicit salt mixes in `String#hash`, and that one is
      # deliberately per-process-seeded (unstable) — never use a salt
      # for an id that must survive a restart.
      unless salt.empty?
        h = h ^ salt.hash.to_u64! &+ 0x9e3779b97f4a7c15_u64
      end
      Id.new(h)
    end

    # A child id: used by `Ui` to mint per-widget ids from the parent
    # id + an incrementing counter (egui: `Id.with` / `ui.next_auto_id`).
    def child(salt : UInt64) : Id
      Id.from("#{@value}:#{salt}")
    end

    def inspect(io : IO) : Nil
      io << "Id(0x" << @value.to_s(16) << ")"
    end

    # A random-looking 6-char [A-Za-z] name for display and debug
    # (inspector): deterministic per id value, so the same widget shows
    # the same name frame after frame. Collisions are possible in this
    # encoding (52^6 < 2^64) and harmless — identity stays the full
    # value; this is only a label.
    def short_label : String
      chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
      v = @value
      String.build(6) do |io|
        6.times do
          io << chars[(v % 52_u64).to_i32]
          v = v // 52_u64
        end
      end
    end

    FNV_OFFSET = 0xcbf29ce484222325_u64
    FNV_PRIME  = 0x100000001b3_u64
  end
end
