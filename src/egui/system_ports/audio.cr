# System port Audio: sound playback. The port API stays headless —
# the actual playback lives in the minaudio shard (OrelSokolov/
# minaudio.cr) and is installed as a runner by `require
# "egui/backend/audio"`, so apps that never play a sound link no
# audio code at all (the Notification.use_native pattern).
#
# `Audio.play` returns a Bool like the other fire-and-forget ports;
# handles/looping/music are available through the returned port-level
# sound id when the native runner supports them:
#
#   Audio.play("click.wav")                 # UI click, fire-and-forget
#   Audio.play("music.ogg", loop: true)     # background track
#   Audio.stop_all                          # everything off
#
# Returns false when no runner is installed (headless builds, specs)
# or the file cannot be played. Errors never crash the frame loop.

module Egui
  module SystemPorts
    module Audio
      # Native playback runner installed by backend/audio.cr.
      @@runner : Runner?

      # The last failure's stage+reason ("engine init failed: ..."),
      # surfaced by UI so a refused playback is diagnosable on a device
      # without adb. Nil after a successful play.
      @@last_error : String?

      def self.last_error : String?
        @@last_error
      end

      # Runner-internal: record/clear the failure reason.
      def self.last_error=(message : String?) : Nil
        @@last_error = message
      end

      # The port's native surface: play returns 0 on refusal, a
      # positive id otherwise; ids mean nothing without the runner
      # that produced them.
      module Runner
        abstract def play(path : String, volume : Float32,
                          loop : Bool) : Int32
        abstract def stop(id : Int32) : Nil
        abstract def stop_all : Nil
      end

      def self.use(runner : Runner) : Nil
        @@runner = runner
      end

      # Drop the installed runner (spec hygiene).
      def self.use : Nil
        @@runner = nil
      end

      # True when playback is wired (runner installed and its engine
      # opened a device) — for UI that wants to hide sound options.
      def self.supported? : Bool
        !!@@runner
      end

      # Play a file. Returns false when unsupported or the file is
      # unplayable; the sound plays to completion on its own.
      def self.play(path : String, volume : Float32 = 1.0f32,
                    loop : Bool = false) : Bool
        runner = @@runner
        return false unless runner
        runner.play(path, volume, loop) > 0
      end

      # Stop one sound by the id `play` returned (nil-safe no-op when
      # no runner is installed).
      def self.stop(id : Int32) : Nil
        @@runner.try(&.stop(id))
      end

      # Stop everything this port started.
      def self.stop_all : Nil
        @@runner.try(&.stop_all)
      end
    end
  end
end
