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
