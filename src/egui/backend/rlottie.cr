# rlottie C shim binding (backend/rlottie_shim.c + the CMake-built
# librlottie.a) — the Renderer seam implementation for Lottie::Player.
#
# OPT-IN: apps require this file explicitly ("egui/backend/rlottie"),
# the pty/audio pattern — everything else links neither the archive
# nor the C++ runtime. Builds need LOTTIE=1 (see Rakefile and
# .env.example): `rake download:rlottie` once, then `LOTTIE=1 rake
# build:native` produces lib/libegui_cr_rlottie.a + lib/rlottie/
# librlottie.a; the link line gains -Llib/rlottie -lc++/-lstdc++.
#
# Parsed animations are memoized per source (NanoSvgCr.@@images
# pattern): `ui.lottie` builds a fresh Player-feeding widget every
# frame, and the parse is the expensive step. Entries live for the
# process lifetime — bounded by the set of distinct sources an app
# uses (rlottie's own model cache is compiled out).

@[Link("egui_cr_rlottie")]
@[Link("rlottie")]
lib LibRlottie
  fun from_data = egui_cr_lottie_from_data(data : UInt8*, key : UInt8*) : Void*
  fun free = egui_cr_lottie_free(animation : Void*) : Nil
  fun size = egui_cr_lottie_size(animation : Void*,
                                 w : LibC::SizeT*, h : LibC::SizeT*) : Nil
  fun duration = egui_cr_lottie_duration(animation : Void*) : Float64
  fun framerate = egui_cr_lottie_framerate(animation : Void*) : Float64
  fun total_frames = egui_cr_lottie_total_frames(animation : Void*) : LibC::SizeT
  fun render = egui_cr_lottie_render(animation : Void*, frame : LibC::SizeT,
                                     dst : UInt8*, w : Int32,
                                     h : Int32) : Int32
end

module Egui
  module Backend
    module Rlottie
      # A parsed Bodymovin animation behind the C shim. The handle is
      # never freed (see the memoization note above).
      class Animation < Lottie::Renderer
        @handle : Void*

        def initialize(@handle : Void*)
        end

        # Parse (or fetch the memoized) animation for a JSON source;
        # nil when rlottie rejects it or reports no viewport.
        def self.from_json(source : String) : Animation?
          unless (anim = @@animations[source]?)
            key = "egui-cr-lottie-#{source.hash}"
            handle = LibRlottie.from_data(source.to_unsafe,
              key.to_unsafe)
            return nil if handle.null?
            w = uninitialized LibC::SizeT
            h = uninitialized LibC::SizeT
            LibRlottie.size(handle, pointerof(w), pointerof(h))
            if w.zero? || h.zero?
              LibRlottie.free(handle)
              return nil
            end
            anim = new(handle)
            @@animations[source] = anim
          end
          anim
        end

        def width : Int32
          w = uninitialized LibC::SizeT
          h = uninitialized LibC::SizeT
          LibRlottie.size(@handle, pointerof(w), pointerof(h))
          w.to_i32
        end

        def height : Int32
          w = uninitialized LibC::SizeT
          h = uninitialized LibC::SizeT
          LibRlottie.size(@handle, pointerof(w), pointerof(h))
          h.to_i32
        end

        def frame_count : Int32
          LibRlottie.total_frames(@handle).to_i32
        end

        def fps : Float64
          LibRlottie.framerate(@handle)
        end

        def render(frame : Int32, buf : Bytes,
                   w : Int32, h : Int32) : Bool
          LibRlottie.render(@handle, frame.to_u64, buf.to_unsafe,
            w, h) == 1
        end

        @@animations = {} of String => Animation
      end
    end
  end
end
