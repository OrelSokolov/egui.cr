# System port Audio: sound playback. The port API stays headless —
# the actual playback lives in the minaudio shard (OrelSokolov/
# minaudio.cr) and is installed as a runner by `require
# "egui/backend/audio"`, so apps that never play a sound link no
# audio code at all (the Notification.use_native pattern).
#
# Three playback flavors (the raylib Sound-vs-Music split):
#
#   Audio.play("click.wav")                    # fire-and-forget file
#   click = Audio.sample("click.wav")          # decoded once, replayed
#   click.play(volume: 0.8f32, bus: "ui")      # cheap overlaid replays
#   music = Audio.play_stream("music.ogg",     # streamed handle
#     loop: true, bus: "music")
#   music.try &.fade_out_and_stop(500)
#
# Buses are named volume/stop groups (SDL_mixer channels, one level
# deep): `Audio.bus("sfx").volume = 0.5f32`. Without a runner installed
# everything is an honest no-op (headless builds, specs) and errors
# never crash the frame loop — check `Audio.last_error` for the reason.

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

      # The port's native surface. The v1 trio (play/stop/stop_all) is
      # abstract; everything else defaults to "unsupported" so partial
      # runners (spec fakes, alternative backends) keep compiling — the
      # port degrades to the fire-and-forget surface instead of raising.
      module Runner
        abstract def play(path : String, volume : Float32,
                          loop : Bool) : Int32
        abstract def stop(id : Int32) : Nil
        abstract def stop_all : Nil

        # v2: streamed playback — same id space as play. Default falls
        # back to the fully-decoded path (short files play
        # identically); caveat: a large file then decodes into memory
        # up front instead of streaming — runners that support
        # SOUND_FLAG_STREAM don't have that spike.
        def play(path : String, volume : Float32, loop : Bool,
                 stream : Bool, bus : String?) : Int32
          play(path, volume, loop)
        end

        # v2: in-memory samples — load returns a sample id (0 = fail),
        # play_sample returns a sound id like play.
        def load_sample(path : String) : Int32
          0
        end

        def load_sample_bytes(data : Bytes) : Int32
          0
        end

        def play_sample(sid : Int32, volume : Float32, loop : Bool,
                        bus : String?) : Int32
          0
        end

        def release_sample(sid : Int32) : Nil
        end

        # v2: live control of a playing sound (no-ops when the id is
        # unknown to the runner).
        def set_volume(id : Int32, volume : Float32) : Nil
        end

        def set_pan(id : Int32, pan : Float32) : Nil
        end

        def set_pitch(id : Int32, pitch : Float32) : Nil
        end

        def pause(id : Int32) : Nil
        end

        def resume(id : Int32) : Nil
        end

        # Stop with a fade-out over fade_ms milliseconds (0 = hard stop
        # — the v1 stop behavior).
        def stop(id : Int32, fade_ms : Int32) : Nil
          stop(id)
        end

        def fade_out(id : Int32, fade_ms : Int32) : Nil
        end

        def playing?(id : Int32) : Bool
          false
        end

        def cursor(id : Int32) : Float32
          0.0f32
        end

        def length(id : Int32) : Float32
          0.0f32
        end

        # v2: named buses (created on first use by the runner).
        def bus_volume(name : String, volume : Float32) : Nil
        end

        def bus_paused(name : String, paused : Bool) : Nil
        end

        def bus_stop(name : String) : Nil
        end

        # v2: master surface.
        def master_volume(volume : Float32) : Nil
        end

        def pause_all : Nil
        end

        def resume_all : Nil
        end
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

      # Play a file as a stream (music: decoded in chunks instead of up
      # front) and return a handle for live control. Nil when
      # unsupported or unplayable.
      def self.play_stream(path : String, volume : Float32 = 1.0f32,
                           loop : Bool = false,
                           bus : String? = nil) : Sound?
        runner = @@runner
        return nil unless runner
        id = runner.play(path, volume, loop, true, bus)
        id > 0 ? Sound.new(id) : nil
      end

      # Decode a file once into a replay-cheap sample (UI clicks). The
      # runner owns the decoded memory; Nil when unsupported/undecodable.
      # Decoding is synchronous — fine for short clicks, may hitch the
      # frame loop on large files (no async load yet).
      def self.sample(path : String) : Sample?
        runner = @@runner
        return nil unless runner
        sid = runner.load_sample(path)
        sid > 0 ? Sample.new(sid) : nil
      end

      # Same, from an in-memory file image (embedded assets) — WAV/MP3/
      # FLAC, whatever the backend decodes.
      def self.sample(data : Bytes) : Sample?
        runner = @@runner
        return nil unless runner
        sid = runner.load_sample_bytes(data)
        sid > 0 ? Sample.new(sid) : nil
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

      # Master volume for every sound and bus (0.0..1.0 and beyond is
      # the backend's business; 1.0 = untouched).
      def self.master_volume=(volume : Float32) : Nil
        @@runner.try(&.master_volume(volume))
      end

      # Silence/resume everything without stopping individual sounds.
      def self.pause_all : Nil
        @@runner.try(&.pause_all)
      end

      def self.resume_all : Nil
        @@runner.try(&.resume_all)
      end

      # A named volume/stop bus (created on first use). Sounds attach by
      # passing `bus:` at play time; without a runner the handle is an
      # honest no-op.
      def self.bus(name : String) : Bus
        Bus.new(name)
      end

      # A playing sound: live volume/pan/pitch, pause, fade, position.
      # Methods are no-ops after #stop (and when no runner is installed)
      # — the frame loop may hold a Sound for a sound that already ended.
      class Sound
        getter id : Int32

        # Internal: built by Audio.play_stream / Sample#play.
        def initialize(@id : Int32)
        end

        def volume=(volume : Float32) : Nil
          runner.try(&.set_volume(@id, volume))
        end

        def pan=(pan : Float32) : Nil
          runner.try(&.set_pan(@id, pan))
        end

        def pitch=(pitch : Float32) : Nil
          runner.try(&.set_pitch(@id, pitch))
        end

        def pause : Nil
          runner.try(&.pause(@id))
        end

        def resume : Nil
          runner.try(&.resume(@id))
        end

        def paused=(paused : Bool) : Nil
          r = runner
          return unless r
          paused ? r.pause(@id) : r.resume(@id)
        end

        # Fade the volume to zero over fade_ms but keep "playing" —
        # for ducking; see #fade_out_and_stop for the usual exit.
        def fade_out(fade_ms : Int32) : Nil
          runner.try(&.fade_out(@id, fade_ms))
        end

        # The usual music exit: fade then stop.
        def fade_out_and_stop(fade_ms : Int32) : Nil
          runner.try(&.stop(@id, fade_ms))
        end

        def stop : Nil
          runner.try(&.stop(@id))
        end

        def playing? : Bool
          runner.try(&.playing?(@id)) || false
        end

        # Current position / total duration in seconds (0 when unknown,
        # e.g. an unsupported runner).
        def cursor : Float32
          runner.try(&.cursor(@id)) || 0.0f32
        end

        def length : Float32
          runner.try(&.length(@id)) || 0.0f32
        end

        private def runner : Runner?
          Audio.runner_for(@id)
        end
      end

      # A decoded, replay-cheap sample (the UI-click path). #play spawns
      # independent overlaid voices; control them through the returned
      # Sound (or fire and forget).
      class Sample
        getter id : Int32

        # Internal: built by Audio.sample.
        def initialize(@id : Int32)
        end

        def play(volume : Float32 = 1.0f32, loop : Bool = false,
                 bus : String? = nil) : Sound?
          r = runner
          return nil unless r
          id = r.play_sample(@id, volume, loop, bus)
          id > 0 ? Sound.new(id) : nil
        end

        # Drop the decoded memory (plays of it that already started
        # finish on their own).
        def close : Nil
          runner.try(&.release_sample(@id))
          @id = 0
        end

        private def runner : Runner?
          Audio.runner_for(@id)
        end
      end

      # A named volume/stop bus. Handles are cheap — Audio.bus("sfx")
      # may be called every frame; the runner creates the bus on first
      # actual use.
      class Bus
        getter name : String

        def initialize(@name : String)
        end

        def volume=(volume : Float32) : Nil
          Audio.runner.try(&.bus_volume(@name, volume))
        end

        def paused=(paused : Bool) : Nil
          Audio.runner.try(&.bus_paused(@name, paused))
        end

        # Stop every sound playing on this bus.
        def stop_all : Nil
          Audio.runner.try(&.bus_stop(@name))
        end
      end

      # Internal: the live runner for handle delegation, with the
      # id > 0 guard (0 = released/never created).
      def self.runner_for(id : Int32) : Runner?
        return nil if id <= 0
        @@runner
      end

      # Internal: the installed runner (bus handles have no id).
      def self.runner : Runner?
        @@runner
      end
    end
  end
end
