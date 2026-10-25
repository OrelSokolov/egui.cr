# Lottie playback core — the clock/state half of the animated-vector
# pipeline, symmetric to what examples/video/player.cr does for decoded
# video. Platform-pure: NO FFI here, so `crystal spec` and headless
# builds stay dependency-free; the pixels come from a Renderer seam
# (backend/rlottie.cr installs the C shim twin behind `require
# "egui/backend/rlottie"`; a pure-Crystal interpreter is the planned
# phase-2 twin, the NanoSvgCr pattern).
#
# The Player is app-owned and long-lived (like VideoPlayer): it drives
# a monotonic master clock against the asset's own frame grid —
# #current_frame is quantized to whole source frames, so a 30 fps
# asset in a 60 fps UI re-renders every other UI frame, not every
# frame. LottieWidget (widgets/lottie.cr) turns that frame number
# into a stream-texture blit.

module Egui
  module Lottie
    # Monotonic clock epoch — the codebase's Time.instant pattern
    # (spans against a fixed start, not wall-clock seconds).
    CLOCK_START = Time.instant

    def self.now : Float64
      (Time.instant - CLOCK_START).total_seconds
    end

    # Pixel source for a Player: viewport metadata + frame
    # rasterization into a straight-alpha RGBA8 buffer (the NanoSVG
    # bake contract — premultiplied sources convert at the seam).
    abstract class Renderer
      abstract def width : Int32
      abstract def height : Int32
      abstract def frame_count : Int32
      abstract def fps : Float64

      # Rasterize `frame` into `buf` (w*h*4 straight-alpha RGBA8,
      # aspect-preserved and letterboxed to w×h by the source).
      # False = render failed (the widget keeps the previous frame).
      abstract def render(frame : Int32, buf : Bytes,
                          w : Int32, h : Int32) : Bool

      def duration : Float64
        fps > 0 ? frame_count / fps : 0.0
      end
    end

    class Player
      enum State
        Stopped
        Playing
        Paused
        Eof
      end

      getter renderer : Renderer
      getter state : State = State::Stopped
      property? loop : Bool = true

      @speed : Float64 = 1.0
      # Playback position in seconds while paused/stopped/eof; while
      # playing the master clock is authoritative and this is stale.
      @frame_time : Float64 = 0.0
      # Playback-clock zero: elapsed = (now - @clock_origin) * speed.
      @clock_origin : Float64
      # Injectable for specs (deterministic clock math without sleep).
      @now : -> Float64

      def initialize(@renderer : Renderer, @now : -> Float64 = ->Lottie.now)
        @clock_origin = @now.call
      end

      def playing? : Bool
        @state == State::Playing
      end

      def speed : Float64
        @speed
      end

      # Re-anchors the clock so the change applies from NOW instead of
      # retroactively stretching the already-elapsed span.
      def speed=(value : Float64) : Nil
        return if value <= 0.0 || value == @speed
        @frame_time = elapsed if playing?
        @speed = value
        @clock_origin = @now.call - @frame_time / @speed
      end

      def duration : Float64
        @renderer.duration
      end

      # Playback position in seconds (wraps while looping — the
      # scrubber stays live; non-looping clamps at the end).
      def position : Float64
        pos = playing? ? elapsed : @frame_time
        dur = duration
        return pos if dur <= 0.0 || pos <= dur
        loop? ? pos % dur : dur
      end

      def progress : Float64
        dur = duration
        dur > 0.0 ? position / dur : 0.0
      end

      def play : Nil
        @frame_time = 0.0 if @state.eof? # play-from-end restarts
        return if playing?
        @state = State::Playing
        @clock_origin = @now.call - @frame_time / @speed
      end

      def pause : Nil
        return unless playing?
        @frame_time = elapsed
        @state = State::Paused
      end

      def toggle : Nil
        playing? ? pause : play
      end

      def stop : Nil
        @state = State::Stopped
        @frame_time = 0.0
      end

      # Jump to a position in seconds (clamped to the duration; a
      # playing player keeps playing from there).
      def seek(seconds : Float64) : Nil
        dur = duration
        seconds = 0.0 if seconds < 0.0
        @frame_time = dur > 0.0 && seconds > dur ? dur : seconds
        @clock_origin = @now.call - @frame_time / @speed
      end

      # Once-per-UI-frame tick (LottieWidget#ui calls it): lands in
      # Eof when a non-looping animation passes its last frame — the
      # widget freezes on the final frame, play() then restarts.
      def advance : Nil
        return unless playing?
        dur = duration
        return if dur <= 0.0 || loop?
        if elapsed >= dur
          @frame_time = dur
          @state = State::Eof
        end
      end

      # Source frame due at the master clock right now. Quantized with
      # floor (frame N covers [N/fps, (N+1)/fps)) and wrapped at the
      # loop point; the Eof state freezes on the last frame.
      def current_frame : Int32
        total = @renderer.frame_count
        return 0 if total <= 0
        fps = @renderer.fps
        return 0 if fps <= 0
        pos = playing? ? elapsed : @frame_time
        dur = duration
        pos = pos % dur if dur > 0.0 && loop? && pos >= dur
        ((pos * fps).floor.to_i).clamp(0, total - 1)
      end

      private def elapsed : Float64
        (@now.call - @clock_origin) * @speed
      end
    end
  end
end
