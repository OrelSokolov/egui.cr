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
  module Backend
    module LottieCr
      # A parsed Bodymovin animation (the shard is long-lived and
      # immutable once parsed — nothing to free).
      class Animation < Lottie::Renderer
        def initialize(@anim : ::Lottie::Animation)
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

        # The shard's viewport is Float64 (Bodymovin allows fractional
        # w/h); the seam reports whole pixels (the rlottie shim's
        # size_t contract).
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
          @anim.render(frame, buf, w, h)
        end

        @@animations = {} of String => Animation
      end
    end
  end
end
