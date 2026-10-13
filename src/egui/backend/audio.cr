# backend/audio.cr — installs the SystemPorts::Audio and Microphone
# runners on top of the minaudio shard (OrelSokolov/minaudio.cr,
# vendored miniaudio). Opt-in: `require "egui/backend/audio"` — apps
# without it keep the headless no-op ports and link no audio code.
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
    #
    # Verbose route diagnostics (per-play probes, the audio_diag dump)
    # print only with EG_AUDIO_DEBUG set — the default frame loop stays
    # quiet.
    class AudioRunner
      include SystemPorts::Audio::Runner

      @engine : MinAudio::Engine?
      @failed : Bool = false
      @sounds = {} of Int32 => MinAudio::Sound
      # sound id → the sample it plays through (release_sample stops
      # dependents before freeing the buffer's memory).
      @sample_of = {} of Int32 => Int32
      @samples = {} of Int32 => MinAudio::AudioBuffer
      @groups = {} of String => MinAudio::SoundGroup
      @next_id = 1
      @next_sample_id = 1
      @lock = Thread::Mutex.new
      @debug = !ENV["EG_AUDIO_DEBUG"]?.nil?

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
                   "#{eng.channels}ch @ #{eng.sample_rate}Hz" if @debug
              log_audio_route if @debug
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
                 "#{eng.channels}ch @ #{eng.sample_rate}Hz" if @debug
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

      # The named bus, created on first use (nil = the master group).
      private def group_for(name : String?) : MinAudio::SoundGroup?
        return nil unless name
        eng = engine
        return nil unless eng
        @groups[name] ||= eng.group
      end

      # Register a started sound under a fresh id (locked by callers).
      private def register(sound : MinAudio::Sound,
                           sample_id : Int32 = 0) : Int32
        id = @next_id
        @next_id += 1
        @sounds[id] = sound
        @sample_of[id] = sample_id if sample_id > 0
        # Reap finished one-shots so long sessions don't accumulate.
        reap_locked
        id
      end

      private def reap_locked : Nil
        # Hash#reject! returns self (the SURVIVORS) — collecting the
        # doomed entries first is the only correct shape here. Close
        # them explicitly (deterministic ma_sound_uninit instead of GC
        # finalizers); Sound#close is idempotent.
        doomed = @sounds.select { |_, s| s.closed? || (!s.looping? && s.at_end?) }
        return if doomed.empty?
        doomed.each_key do |sid|
          @sounds.delete(sid)
          @sample_of.delete(sid)
        end
        doomed.each_value(&.close)
      end

      def play(path : String, volume : Float32, loop : Bool) : Int32
        play(path, volume, loop, false, nil)
      end

      def play(path : String, volume : Float32, loop : Bool,
               stream : Bool, bus : String?) : Int32
        @lock.synchronize do
          eng = engine
          unless eng
            SystemPorts::Audio.last_error ||= "engine unavailable"
            return 0
          end
          sound = eng.play(path, volume: volume, loop: loop,
            stream: stream, group: group_for(bus))
          id = register(sound)
          if @debug
            puts "[audio] play id=#{id} #{path.inspect} vol=#{volume} " \
                 "loop=#{loop} stream=#{stream} bus=#{bus.inspect} → " \
                 "playing=#{sound.playing?} len=#{sound.length}s"
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

      # Samples decode headless (ma_decoder only) — no playback device
      # is opened until something actually plays, so sample loading
      # works on machines without an output device too.
      def load_sample(path : String) : Int32
        @lock.synchronize do
          register_sample(MinAudio::AudioBuffer.from_file(path))
        end
      rescue ex : MinAudio::Error
        SystemPorts::Audio.last_error = ex.message.to_s
        puts "[audio] load_sample #{path.inspect} failed: #{ex.message}"
        0
      end

      def load_sample_bytes(data : Bytes) : Int32
        @lock.synchronize do
          register_sample(MinAudio::AudioBuffer.from_memory(data))
        end
      rescue ex : MinAudio::Error
        SystemPorts::Audio.last_error = ex.message.to_s
        puts "[audio] load_sample(bytes) failed: #{ex.message}"
        0
      end

      def play_sample(sid : Int32, volume : Float32, loop : Bool,
                      bus : String?) : Int32
        @lock.synchronize do
          eng = engine
          buffer = @samples[sid]?
          unless eng && buffer
            SystemPorts::Audio.last_error ||= "unknown sample id #{sid}"
            return 0
          end
          sound = eng.sound(buffer, group: group_for(bus))
          sound.looping = true if loop
          sound.volume = volume unless volume == 1.0f32
          sound.start
          register(sound, sample_id: sid)
        end
      rescue ex : MinAudio::Error
        SystemPorts::Audio.last_error = ex.message.to_s
        puts "[audio] play_sample #{sid} failed: #{ex.message}"
        0
      end

      def release_sample(sid : Int32) : Nil
        @lock.synchronize do
          buffer = @samples.delete(sid)
          next unless buffer
          # Stop and uninit every voice playing through the buffer
          # before freeing its memory (a live Sound reading freed PCM
          # would crash the audio thread). Collect first — mutating a
          # Hash inside #each is undefined in Crystal.
          doomed = @sample_of.select { |_, sample_id| sample_id == sid }
          doomed.each_key do |sound_id|
            if (s = @sounds.delete(sound_id))
              s.stop rescue nil
              s.close
            end
            @sample_of.delete(sound_id)
          end
          buffer.close
        end
      end

      def set_volume(id : Int32, volume : Float32) : Nil
        @lock.synchronize { @sounds[id]?.try(&.volume = volume) }
      end

      def set_pan(id : Int32, pan : Float32) : Nil
        @lock.synchronize { @sounds[id]?.try(&.pan = pan) }
      end

      def set_pitch(id : Int32, pitch : Float32) : Nil
        @lock.synchronize { @sounds[id]?.try(&.pitch = pitch) }
      end

      # ma_sound_stop keeps the cursor — start replays from it, i.e.
      # this is a real pause, not a reset.
      def pause(id : Int32) : Nil
        @lock.synchronize { @sounds[id]?.try { |s| s.stop rescue nil } }
      end

      def resume(id : Int32) : Nil
        @lock.synchronize { @sounds[id]?.try { |s| s.start rescue nil } }
      end

      def stop(id : Int32) : Nil
        @lock.synchronize do
          if (s = @sounds.delete(id))
            s.stop rescue nil
            s.close
          end
          @sample_of.delete(id)
        end
      end

      def stop(id : Int32, fade_ms : Int32) : Nil
        @lock.synchronize do
          if (s = @sounds[id]?)
            begin
              # With a fade the sound stays registered until the regular
              # reap collects it (closing now would cut the fade off).
              fade_ms > 0 ? s.stop(fade_ms) : s.stop
            rescue MinAudio::Error
            end
            if fade_ms <= 0
              s.close
              @sounds.delete(id)
              @sample_of.delete(id)
            end
          end
        end
      end

      def fade_out(id : Int32, fade_ms : Int32) : Nil
        @lock.synchronize do
          @sounds[id]?.try(&.fade(-1.0f32, 0.0f32, fade_ms))
        end
      end

      # The natural poll point for fade-stopped and fire-and-forget
      # sounds — reaping here keeps @sounds bounded even when nothing
      # new is played for a long time.
      def playing?(id : Int32) : Bool
        @lock.synchronize do
          reap_locked
          @sounds[id]?.try(&.playing?) || false
        end
      end

      def cursor(id : Int32) : Float32
        @lock.synchronize { @sounds[id]?.try(&.cursor) || 0.0f32 }
      end

      def length(id : Int32) : Float32
        @lock.synchronize { @sounds[id]?.try(&.length) || 0.0f32 }
      end

      def bus_volume(name : String, volume : Float32) : Nil
        @lock.synchronize { group_for(name).try(&.volume = volume) }
      end

      def bus_paused(name : String, paused : Bool) : Nil
        @lock.synchronize do
          group_for(name).try { |g| paused ? g.stop : g.start }
        end
      end

      def bus_stop(name : String) : Nil
        @lock.synchronize { group_for(name).try(&.stop) }
      end

      def master_volume(volume : Float32) : Nil
        @lock.synchronize { engine.try(&.volume = volume) }
      end

      def pause_all : Nil
        @lock.synchronize { engine.try(&.pause) }
      end

      def resume_all : Nil
        @lock.synchronize { engine.try(&.resume) }
      end

      def stop_all : Nil
        @lock.synchronize do
          @sounds.each_value do |s|
            s.stop rescue nil
            s.close
          end
          @sounds.clear
          @sample_of.clear
        end
      end

      private def register_sample(buffer : MinAudio::AudioBuffer) : Int32
        sid = @next_sample_id
        @next_sample_id += 1
        @samples[sid] = buffer
        SystemPorts::Audio.last_error = nil
        sid
      end
    end

    # Microphone runner over MinAudio::Capture (ma_device + C ring:
    # the audio-thread callback never enters Crystal). Pull model —
    # read() is called from the frame loop, never blocks.
    #
    # On Android the RECORD_AUDIO gate mirrors the camera port: open
    # checks the permission through the JNI helper and requests it when
    # not yet granted; the first open returns 0 with a "requested — try
    # again" error, the next one (after the user answers the dialog)
    # succeeds.
    class MicRunner
      include SystemPorts::Microphone::Runner

      @captures = {} of Int32 => MinAudio::Capture
      @next_id = 1
      @lock = Thread::Mutex.new

      # egui_cr_mic_perm/egui_cr_mic_perm_request: the Android JNI
      # helpers (EguiCrActivity) and the macOS AVFoundation helpers
      # (sokol_shim.c) share the C names and the 1/0/-1 protocol. The
      # symbols live in libegui_cr_sokol — on macOS the gate compiles in
      # only when the sokol backend is part of the program, so headless
      # audio consumers (no window, no shim) still link; Android always
      # links the shim with the APK.
      {% if flag?(:android) || (flag?(:darwin) && !flag?(:ios) && @top_level.has_constant?("Egui::Backend::Sokol")) %}
        lib LibMicPerm
          fun perm = egui_cr_mic_perm : Int32
          fun perm_request = egui_cr_mic_perm_request : Void
        end
      {% end %}
      # The platform permission gate (no-op where TCC doesn't exist —
      # Windows/Linux desktops, and macOS builds without the sokol
      # backend). 1 granted / 0 not decided yet (request it; the first
      # open reports "try again" while the dialog is up) / -1 denied.
      # macOS: the request is a no-op for bare binaries — TCC would
      # abort the process — and the status carries the make_audio_app.sh
      # hint instead.
      private def permission_ok? : Bool
        {% if flag?(:android) || (flag?(:darwin) && !flag?(:ios) && @top_level.has_constant?("Egui::Backend::Sokol")) %}
          case LibMicPerm.perm
          when 1
            true
          when 0
            LibMicPerm.perm_request
            SystemPorts::Microphone.last_error =
              "разрешение микрофона запрошено — разрешите и нажмите снова " \
              "(macOS без бандла: scripts/make_audio_app.sh)"
            false
          else
            SystemPorts::Microphone.last_error =
              "микрофон запрещён (системные настройки → Конфиденциальность)"
            false
          end
        {% else %}
          true
        {% end %}
      end

      def open(sample_rate : Int32, channels : Int32,
               ring_frames : Int32) : Int32
        return 0 unless permission_ok?
        backends =
          {% if flag?(:android) %}
            [LibMinAudio::BACKEND_OPENSL, LibMinAudio::BACKEND_AAUDIO]
          {% else %}
            nil
          {% end %}
        cap = MinAudio::Capture.new(sample_rate: sample_rate,
          channels: channels, ring_frames: ring_frames, backends: backends)
        cap.start
        @lock.synchronize do
          id = @next_id
          @next_id += 1
          @captures[id] = cap
          SystemPorts::Microphone.last_error = nil
          id
        end
      rescue ex : MinAudio::Error
        SystemPorts::Microphone.last_error = ex.message.to_s
        puts "[audio] mic open failed: #{ex.message}"
        0
      end

      def read(id : Int32, buf : Bytes) : Int32
        @lock.synchronize { @captures[id]?.try(&.read(buf)) } || 0
      end

      def available_frames(id : Int32) : UInt64
        @lock.synchronize { @captures[id]?.try(&.available_frames) } || 0u64
      end

      def start(id : Int32) : Nil
        @lock.synchronize { @captures[id]?.try { |c| c.start rescue nil } }
      end

      def stop(id : Int32) : Nil
        @lock.synchronize { @captures[id]?.try { |c| c.stop rescue nil } }
      end

      def close(id : Int32) : Nil
        cap = @lock.synchronize { @captures.delete(id) }
        return unless cap
        cap.stop rescue nil
        cap.close
      end
    end

    # Installed at require time — audio is stateless to set up; the
    # device itself opens lazily on first play.
    SystemPorts::Audio.use(AudioRunner.new)
    SystemPorts::Microphone.use(MicRunner.new)
  end
end
