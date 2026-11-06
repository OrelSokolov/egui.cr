# Pure-Crystal Lottie backend — the lottie.cr shard (a faithful twin
# of rlottie's evaluation model, verified against its render-tree
# dumps) behind the Egui::Lottie::Renderer seam. This is the DEFAULT
# pixel source for `ui.lottie`: pure Crystal, no LOTTIE feature
# flag, no C++ runtime — it builds everywhere Crystal does, mobile
# included. The rlottie C shim (backend/rlottie.cr) stays in the
# tree as the dev A/B reference (the external_rasterizer pattern).
#
# Parsed animations are memoized per source (backend/rlottie.cr
# pattern): `ui.lottie` builds a fresh Player-feeding widget every
# frame, and the parse is the expensive step. Entries live for the
# process lifetime — bounded by the set of distinct sources an app
# uses.

require "lottie"

module Egui
  module Driver
    module LottieCr
      # A parsed Bodymovin animation (the shard is long-lived and
      # immutable once parsed — nothing to free).
      class Animation < Lottie::Renderer
        # Frame cache: the animation is immutable and the shard's
        # rasterizer deterministic, so frame N at size W×H renders to
        # the same pixels every time — and looping players re-ask for
        # the same frames forever. A hit is a memcpy instead of a
        # full re-raster (~1 ms/frame in pure Crystal vs ~0.1 ms for
        # the C shim). Bounded: when the cache passes MAX_CACHE_BYTES
        # it drops everything and refills (loop restart rebuilds it).
        MAX_CACHE_BYTES = 8 * 1024 * 1024

        def initialize(@anim : ::Lottie::Animation)
          @frame_cache = {} of Int32 => NamedTuple(w: Int32, h: Int32, data: Bytes)
          @cache_bytes = 0
        end

        # Parse (or fetch the memoized) animation for a JSON source;
        # nil when the shard rejects it.
        def self.from_json(source : String) : Animation?
          unless (anim = @@animations[source]?)
            parsed = ::Lottie::Animation.parse(source)
            return nil unless parsed
            anim = new(parsed)
            @@animations[source] = anim
          end
          anim
        end

        def width : Int32
          @anim.width.to_i32
        end

        def height : Int32
          @anim.height.to_i32
        end

        def frame_count : Int32
          @anim.frame_count.to_i32
        end

        def fps : Float64
          @anim.fps
        end

        def render(frame : Int32, buf : Bytes,
                   w : Int32, h : Int32) : Bool
          if (c = @frame_cache[frame]?)
            if c[:w] == w && c[:h] == h
              c[:data].copy_to(buf)
              return true
            end
          end
          return false unless @anim.render(frame, buf, w, h)
          if @cache_bytes + buf.size > MAX_CACHE_BYTES
            @frame_cache.clear
            @cache_bytes = 0
          end
          data = Bytes.new(buf.size)
          buf.copy_to(data)
          @frame_cache[frame] = {w: w, h: h, data: data}
          @cache_bytes += buf.size
          true
        end

        @@animations = {} of String => Animation
      end
    end
  end
end
