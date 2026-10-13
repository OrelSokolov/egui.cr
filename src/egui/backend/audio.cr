# backend/audio.cr — installs the SystemPorts::Audio runner on top of
# the minaudio shard (OrelSokolov/minaudio.cr, vendored miniaudio).
# Opt-in: `require "egui/backend/audio"` — apps without it keep the
# headless no-op port and link no audio code.
#
# Works everywhere miniaudio does: macOS/Windows/Linux desktops
# (static lib from the shard's `rake build`) and Android/iOS builds
# (per-target objects from `rake build:android` / `build:ios`, linked
# by the APK / iOS build scripts).

require "minaudio"

module Egui
  module Backend
    # One shared engine: opening a playback device per sound would
    # exhaust the device quickly. Lazy: the engine opens the default
    # device on first play. On Android OpenSL ES is pinned first and
    # AAudio is the fallback: on some vendor builds (seen on Xiaomi/
    # HyperOS) an AAudio stream opens fine and reports playing, but
    # delivers silence — OpenSL has no such failure mode. After both
    # fail the failure is remembered and Audio.play returns false
    # forever instead of retrying the device on every click.
    class AudioRunner
      include SystemPorts::Audio::Runner

      @engine : MinAudio::Engine?
      @failed : Bool = false
      @sounds = {} of Int32 => MinAudio::Sound
      @next_id = 1
      @lock = Thread::Mutex.new

      {% if flag?(:android) %}
        # Audio route diagnostics (JNI → EguiCrActivity.audioDiag):
        # media-stream volume + ringer mode — the "play() true but
        # silent" case is almost always a zeroed media volume.
        lib LibAndroidAudioDiag
          fun audio_diag = egui_cr_android_audio_diag : UInt8*
          fun mem_free = egui_cr_mem_free(p : Void*) : Void
        end

        private def log_audio_route : Nil
          ptr = LibAndroidAudioDiag.audio_diag
          return if ptr.null?
          begin
            puts "[audio] route: #{String.new(ptr)}"
          ensure
            LibAndroidAudioDiag.mem_free(ptr.as(Void*))
          end
        end
      {% end %}

      private def open_engine : MinAudio::Engine?
        {% if flag?(:android) %}
          [{LibMinAudio::BACKEND_OPENSL, "opensl"},
           {LibMinAudio::BACKEND_AAUDIO, "aaudio"}].each do |backend, name|
            begin
              eng = MinAudio::Engine.new(backends: [backend.as(Int32)])
              SystemPorts::Audio.last_error = nil
              puts "[audio] engine up (#{name}): " \
                   "#{eng.channels}ch @ #{eng.sample_rate}Hz"
              log_audio_route
              return eng
            rescue ex : MinAudio::Error
              SystemPorts::Audio.last_error = "engine (#{name}): #{ex.message}"
              puts "[audio] engine init failed (#{name}): #{ex.message}"
            end
          end
          nil
        {% else %}
          begin
            eng = MinAudio::Engine.new
            SystemPorts::Audio.last_error = nil
            puts "[audio] engine up (default backends): " \
                 "#{eng.channels}ch @ #{eng.sample_rate}Hz"
            eng
          rescue ex : MinAudio::Error
            SystemPorts::Audio.last_error = "engine: #{ex.message}"
            puts "[audio] default engine init failed: #{ex.message}"
            nil
          end
        {% end %}
      end

      private def engine : MinAudio::Engine?
        return nil if @failed
        @engine ||= begin
          eng = open_engine
          @failed = true unless eng
          eng
        end
      end

      def play(path : String, volume : Float32, loop : Bool) : Int32
        @lock.synchronize do
          eng = engine
          unless eng
            SystemPorts::Audio.last_error ||= "engine unavailable"
            return 0
          end
          sound = eng.play(path, volume: volume, loop: loop)
          id = @next_id
          @next_id += 1
          @sounds[id] = sound
          # Reap finished one-shots so long sessions don't accumulate.
          @sounds.reject! { |_, s| s.closed? || (!s.looping? && s.at_end?) }
          # Post-start state — the "play() said true but silent" case
          # separates decode/route problems from a too-quiet file:
          # playing? false right away = device started muted/paused.
          puts "[audio] play id=#{id} #{path.inspect} vol=#{volume} " \
               "loop=#{loop} → playing=#{sound.playing?} " \
               "len=#{sound.length}s cursor=#{sound.cursor}s"
          # Cursor probe: if the position advances but nothing is
          # audible the backend is dropping samples (the vendor-AAudio
          # silence case); a frozen cursor means the stream never
          # started. Locked so a concurrent stop can't free the sound
          # under us.
          probe_id = id
          # A real thread, not a fiber: the sokol run loop is driven
          # from C and never pumps the Crystal scheduler, so spawn +
          # fiber sleep would never fire.
          Thread.new do
            [0.7, 1.3].each do |delay|
              sleep delay
              @lock.synchronize do
                if (s = @sounds[probe_id]?)
                  puts "[audio] probe id=#{probe_id} t=#{delay} " \
                       "cursor=#{s.cursor}s playing=#{s.playing?}"
                else
                  puts "[audio] probe id=#{probe_id} t=#{delay}: " \
                       "sound gone (stopped/reaped)"
                end
              end
            end
          end
          SystemPorts::Audio.last_error = nil
          id
        end
      rescue ex : MinAudio::Error
        # Unplayable file / dead device: never crash the frame loop —
        # but leave a breadcrumb (stdout → logcat on Android) and the
        # port-visible reason.
        SystemPorts::Audio.last_error = ex.message.to_s
        puts "[audio] play #{path.inspect} failed: #{ex.message}"
        0
      end

      def stop(id : Int32) : Nil
        @lock.synchronize do
          if (s = @sounds.delete(id))
            s.stop rescue nil
            s.close
          end
        end
      end

      def stop_all : Nil
        @lock.synchronize do
          @sounds.each_value do |s|
            s.stop rescue nil
            s.close
          end
          @sounds.clear
        end
      end
    end

    # Installed at require time — audio is stateless to set up; the
    # device itself opens lazily on first play.
    SystemPorts::Audio.use(AudioRunner.new)
  end
end
