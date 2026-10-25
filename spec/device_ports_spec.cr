require "spec"
require "../src/egui"

# Headless specs for the device ports (Audio, Haptics, Share,
# WakeLock, Badge). Like system_ports_spec, nothing here touches real
# hardware: ports without an installed runner must be honest no-ops,
# and recorder implementations verify the delegation.

class AudioRecorder
  include Egui::SystemPorts::Audio::Runner

  getter plays = [] of {String, Float32, Bool}
  getter stopped = [] of Int32
  property stop_all_count = 0
  @next = 0

  def play(path : String, volume : Float32, loop : Bool) : Int32
    @plays << {path, volume, loop}
    (@next += 1)
  end

  def stop(id : Int32) : Nil
    @stopped << id
  end

  def stop_all : Nil
    @stop_all_count += 1
  end
end

# Full-surface fake for the v2 API: streams, samples, buses, live
# control — records every call so the specs verify delegation and the
# handle semantics (no-op after close, id guards).
class FullAudioRecorder < AudioRecorder
  getter streams = [] of {String, Float32, Bool, String?}
  getter loaded = [] of String
  getter loaded_bytes = 0
  getter sample_plays = [] of {Int32, Float32, Bool, String?}
  getter released = [] of Int32
  getter controls = [] of {Symbol, Int32, Float32}
  getter buses = [] of {String, Symbol, Float32}
  property master_calls = 0
  property pause_all_count = 0
  property resume_all_count = 0
  @next = 10
  @next_sample = 100

  def play(path : String, volume : Float32, loop : Bool,
           stream : Bool, bus : String?) : Int32
    @streams << {path, volume, loop, bus}
    (@next += 1)
  end

  def load_sample(path : String) : Int32
    @loaded << path
    (@next_sample += 1)
  end

  def load_sample_bytes(data : Bytes) : Int32
    @loaded_bytes += data.size
    (@next_sample += 1)
  end

  def play_sample(sid : Int32, volume : Float32, loop : Bool,
                  bus : String?) : Int32
    @sample_plays << {sid, volume, loop, bus}
    (@next += 1)
  end

  def release_sample(sid : Int32) : Nil
    @released << sid
  end

  def set_volume(id : Int32, volume : Float32) : Nil
    @controls << {:volume, id, volume}
  end

  def set_pan(id : Int32, pan : Float32) : Nil
    @controls << {:pan, id, pan}
  end

  def set_pitch(id : Int32, pitch : Float32) : Nil
    @controls << {:pitch, id, pitch}
  end

  def pause(id : Int32) : Nil
    @controls << {:pause, id, 0.0f32}
  end

  def resume(id : Int32) : Nil
    @controls << {:resume, id, 0.0f32}
  end

  def stop(id : Int32, fade_ms : Int32) : Nil
    @controls << {:fade_stop, id, fade_ms.to_f32}
  end

  def fade_out(id : Int32, fade_ms : Int32) : Nil
    @controls << {:fade_out, id, fade_ms.to_f32}
  end

  def playing?(id : Int32) : Bool
    id.odd?
  end

  def cursor(id : Int32) : Float32
    id.to_f32 * 0.5f32
  end

  def length(id : Int32) : Float32
    42.0f32
  end

  def bus_volume(name : String, volume : Float32) : Nil
    @buses << {name, :volume, volume}
  end

  def bus_paused(name : String, paused : Bool) : Nil
    @buses << {name, paused ? :pause : :resume, 0.0f32}
  end

  def bus_stop(name : String) : Nil
    @buses << {name, :stop, 0.0f32}
  end

  def master_volume(volume : Float32) : Nil
    @master_calls += 1
  end

  def pause_all : Nil
    @pause_all_count += 1
  end

  def resume_all : Nil
    @resume_all_count += 1
  end
end

class MicRecorder
  include Egui::SystemPorts::Microphone::Runner

  getter opened = [] of {Int32, Int32, Int32}
  getter reads = [] of {Int32, Int32}
  getter starts = [] of Int32
  getter stops = [] of Int32
  getter closed = [] of Int32
  @next = 7

  def open(sample_rate : Int32, channels : Int32,
           ring_frames : Int32) : Int32
    @opened << {sample_rate, channels, ring_frames}
    (@next += 1)
  end

  def read(id : Int32, buf : Bytes) : Int32
    @reads << {id, buf.size}
    16
  end

  def available_frames(id : Int32) : UInt64
    16u64
  end

  def start(id : Int32) : Nil
    @starts << id
  end

  def stop(id : Int32) : Nil
    @stops << id
  end

  def close(id : Int32) : Nil
    @closed << id
  end
end

describe Egui::SystemPorts do
  describe Egui::SystemPorts::Audio do
    it "without a runner is an honest no-op" do
      Egui::SystemPorts::Audio.supported?.should be_false
      Egui::SystemPorts::Audio.play("x.wav").should be_false
      Egui::SystemPorts::Audio.stop(1) # must not raise
      Egui::SystemPorts::Audio.stop_all
    end

    it "delegates to the installed runner" do
      rec = AudioRecorder.new
      Egui::SystemPorts::Audio.use(rec)
      Egui::SystemPorts::Audio.supported?.should be_true
      Egui::SystemPorts::Audio.play("a.wav", 0.5f32, true).should be_true
      rec.plays.should eq([{"a.wav", 0.5f32, true}])
      id = rec.plays.size
      Egui::SystemPorts::Audio.stop(id)
      rec.stopped.should eq([id])
      Egui::SystemPorts::Audio.stop_all
      rec.stop_all_count.should eq(1)
    ensure
      Egui::SystemPorts::Audio.use
    end

    it "degrades v2 calls on a v1-only runner" do
      rec = AudioRecorder.new
      Egui::SystemPorts::Audio.use(rec)
      # Defaults: play_stream falls back to plain play (a working
      # handle), samples/controls are unsupported no-ops — never a
      # raise.
      music = Egui::SystemPorts::Audio.play_stream("m.ogg")
      music.should_not be_nil
      rec.plays.size.should eq(1)
      Egui::SystemPorts::Audio.sample("s.wav").should be_nil
      Egui::SystemPorts::Audio.sample(Bytes.new(8)).should be_nil
      Egui::SystemPorts::Audio.bus("sfx").volume = 0.5f32
      Egui::SystemPorts::Audio.master_volume = 0.7f32
      Egui::SystemPorts::Audio.pause_all
      Egui::SystemPorts::Audio.resume_all
    ensure
      Egui::SystemPorts::Audio.use
    end

    it "delegates streams, samples, buses and live control" do
      rec = FullAudioRecorder.new
      Egui::SystemPorts::Audio.use(rec)

      music = Egui::SystemPorts::Audio.play_stream("m.ogg", 0.5f32,
        loop: true, bus: "music")
      music.should_not be_nil
      mid = music.not_nil!.id
      rec.streams.should eq([{"m.ogg", 0.5f32, true, "music"}])

      music.not_nil!.volume = 0.2f32
      music.not_nil!.pan = -0.5f32
      music.not_nil!.pitch = 1.5f32
      music.not_nil!.pause
      music.not_nil!.resume
      music.not_nil!.paused = true
      music.not_nil!.fade_out(300)
      music.not_nil!.fade_out_and_stop(500)
      music.not_nil!.playing?.should be_true # fake: odd ids play
      music.not_nil!.cursor.should eq(mid.to_f32 * 0.5f32)
      music.not_nil!.length.should eq(42.0f32)
      rec.controls.should eq([{:volume, mid, 0.2f32}, {:pan, mid, -0.5f32},
        {:pitch, mid, 1.5f32}, {:pause, mid, 0.0f32},
        {:resume, mid, 0.0f32}, {:pause, mid, 0.0f32},
        {:fade_out, mid, 300.0f32}, {:fade_stop, mid, 500.0f32}])

      click = Egui::SystemPorts::Audio.sample("click.wav")
      click.should_not be_nil
      cid = click.not_nil!.id
      rec.loaded.should eq(["click.wav"])

      voice = click.not_nil!.play(volume: 0.8f32, bus: "ui")
      voice.should_not be_nil
      rec.sample_plays.should eq([{cid, 0.8f32, false, "ui"}])

      embedded = Egui::SystemPorts::Audio.sample(Bytes.new(44))
      embedded.should_not be_nil
      rec.loaded_bytes.should eq(44)

      click.not_nil!.close
      rec.released.should eq([cid])
      # Handle after close: id 0 → every call is a no-op, not a crash.
      click.not_nil!.play.should be_nil
      rec.sample_plays.size.should eq(1)

      bus = Egui::SystemPorts::Audio.bus("sfx")
      bus.name.should eq("sfx")
      bus.volume = 0.3f32
      bus.paused = true
      bus.stop_all
      rec.buses.should eq([{"sfx", :volume, 0.3f32},
        {"sfx", :pause, 0.0f32}, {"sfx", :stop, 0.0f32}])

      Egui::SystemPorts::Audio.master_volume = 0.9f32
      Egui::SystemPorts::Audio.pause_all
      Egui::SystemPorts::Audio.resume_all
      rec.master_calls.should eq(1)
      rec.pause_all_count.should eq(1)
      rec.resume_all_count.should eq(1)
    ensure
      Egui::SystemPorts::Audio.use
    end
  end

  describe Egui::SystemPorts::Microphone do
    it "without a runner is an honest no-op" do
      Egui::SystemPorts::Microphone.supported?.should be_false
      Egui::SystemPorts::Microphone.open.should be_nil
      Egui::SystemPorts::Microphone.last_error = "x" # must not raise
    end

    it "delegates to the installed runner" do
      rec = MicRecorder.new
      Egui::SystemPorts::Microphone.use(rec)
      Egui::SystemPorts::Microphone.supported?.should be_true

      mic = Egui::SystemPorts::Microphone.open(22_050, 2, 4096)
      mic.should_not be_nil
      mid = mic.not_nil!.id
      rec.opened.should eq([{22_050, 2, 4096}])

      buf = Bytes.new(4096)
      mic.not_nil!.read(buf).should eq(16)
      rec.reads.should eq([{mid, 4096}])
      mic.not_nil!.available_frames.should eq(16)

      mic.not_nil!.stop
      mic.not_nil!.start
      mic.not_nil!.close
      rec.stops.should eq([mid])
      rec.starts.should eq([mid])
      rec.closed.should eq([mid])

      # Handle after close: dead, reads 0 — never a crash.
      mic.not_nil!.read(buf).should eq(0)
      mic.not_nil!.read(buf).should eq(0)
      rec.reads.size.should eq(1)
    ensure
      Egui::SystemPorts::Microphone.use
    end
  end

  describe Egui::SystemPorts::Haptics do
    it "is a silent no-op on headless builds" do
      {% if flag?(:android) || flag?(:ios) %}
        Egui::SystemPorts::Haptics.supported?.should be_true
      {% else %}
        Egui::SystemPorts::Haptics.supported?.should be_false
      {% end %}
      Egui::SystemPorts::Haptics.vibrate(20) # must not raise on any platform
      Egui::SystemPorts::Haptics.tap(Egui::SystemPorts::Haptics::STYLE_HEAVY)
    end
  end

  describe Egui::SystemPorts::Share do
    it "text never fails outright on desktops (clipboard fallback)" do
      {% if flag?(:android) || flag?(:ios) %}
        Egui::SystemPorts::Share.supported?.should be_true
      {% else %}
        ret = Egui::SystemPorts::Share.text("s", "body")
        ret.should be_true
        Egui::SystemPorts::Clipboard.text.should contain("body")
      {% end %}
    end
  end

  describe Egui::SystemPorts::WakeLock do
    it "release without acquire is safe" do
      Egui::SystemPorts::WakeLock.release # must not raise
    end

    it "delegates to the installed runner" do
      acquired = [] of String
      released = 0
      Egui::SystemPorts::WakeLock.use_runner(
        ->(reason : String) { acquired << reason; true },
        -> { released += 1 })
      Egui::SystemPorts::WakeLock.acquire("demo").should be_true
      acquired.should eq(["demo"])
      Egui::SystemPorts::WakeLock.release
      released.should eq(1)
    ensure
      Egui::SystemPorts::WakeLock.use_runner
    end
  end

  describe Egui::SystemPorts::Badge do
    it "without a runner reports unsupported" do
      {% if flag?(:android) %}
        Egui::SystemPorts::Badge.supported?.should be_false
        Egui::SystemPorts::Badge.set(3).should be_false
      {% else %}
        Egui::SystemPorts::Badge.set(3).should be_false
        Egui::SystemPorts::Badge.clear # must not raise
      {% end %}
    end

    it "delegates to the installed runner" do
      counts = [] of Int32
      Egui::SystemPorts::Badge.use_runner { |c| counts << c }
      Egui::SystemPorts::Badge.supported?.should be_true
      Egui::SystemPorts::Badge.set(7).should be_true
      counts.should eq([7])
      Egui::SystemPorts::Badge.clear
      counts.should eq([7, 0])
    ensure
      Egui::SystemPorts::Badge.use_runner
    end
  end
end
