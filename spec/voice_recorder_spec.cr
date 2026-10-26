require "spec"
require "../src/egui"

# Headless specs for the VoiceRecorder seam (src/egui/voice_recorder.cr):
# nothing here opens real hardware — the default implementation must be
# an honest no-op, a fake implementation drives the delegation, and
# Wav.encode is checked byte-for-byte (it feeds SystemPorts::Audio.play).

# Synthetic microphone: poll hands out successive sine chunks.
class FakeMic < Egui::VoiceRecorder::Implementation
  getter started = [] of {Bytes?, Int32, Int32}
  getter stop_count = 0
  getter requested = 0
  property granted = true
  @chunks = [Bytes.new(0), Bytes[1, 2, 3, 4]]
  @poll_i = 0
  @recording = false

  def available? : Bool
    true
  end

  def permission_granted? : Bool
    @granted
  end

  def request_permission! : Nil
    @requested += 1
  end

  def devices : Array(Egui::VoiceRecorder::Device)
    [Egui::VoiceRecorder::Device.new(Bytes.new(8, 1_u8), "Fake Mic"),
     Egui::VoiceRecorder::Device.new(Bytes.new(8, 2_u8), "Fake USB Mic")]
  end

  def start(device_id : Bytes?, sample_rate : Int32, channels : Int32) : Bool
    return false unless permission_granted?
    @started << {device_id, sample_rate, channels}
    @recording = true
    @poll_i = 0
    true
  end

  def recording? : Bool
    @recording
  end

  def poll : Bytes?
    return nil unless @recording
    chunk = @chunks[@poll_i]? || @chunks[-1]
    @poll_i += 1
    chunk.empty? ? nil : chunk
  end

  def stop : Nil
    @stop_count += 1
    @recording = false
  end
end

describe Egui::VoiceRecorder do
  it "defaults to an honest not-implemented port" do
    Egui::VoiceRecorder.available?.should be_false
    Egui::VoiceRecorder.unavailable_reason.should_not be_nil
    Egui::VoiceRecorder.permission_granted?.should be_false
    Egui::VoiceRecorder.devices.should be_empty
    Egui::VoiceRecorder.recording?.should be_false
    Egui::VoiceRecorder.start.should be_false
    Egui::VoiceRecorder.poll.should be_nil
    Egui::VoiceRecorder.stop # must not raise
  end

  it "delegates to the installed implementation" do
    mic = FakeMic.new
    Egui::VoiceRecorder.use(mic)
    begin
      Egui::VoiceRecorder.available?.should be_true
      Egui::VoiceRecorder.devices.size.should eq(2)
      Egui::VoiceRecorder.devices[1].name.should eq("Fake USB Mic")
      Egui::VoiceRecorder.devices[0].to_s.should eq("Fake Mic")

      mic.granted = false
      Egui::VoiceRecorder.start.should be_false
      mic.started.should be_empty
      Egui::VoiceRecorder.request_permission!
      mic.requested.should eq(1)

      mic.granted = true
      dev = Egui::VoiceRecorder.devices[1]
      Egui::VoiceRecorder.start(dev.id, 22050, 2).should be_true
      mic.started.should eq([{dev.id, 22050, 2}])
      Egui::VoiceRecorder.recording?.should be_true
      Egui::VoiceRecorder.poll.should be_nil      # nothing new yet
      Egui::VoiceRecorder.poll.should eq(Bytes[1, 2, 3, 4])
      Egui::VoiceRecorder.stop
      mic.stop_count.should eq(1)
      Egui::VoiceRecorder.recording?.should be_false
    ensure
      Egui::VoiceRecorder.use(Egui::VoiceRecorder::Implementation.new)
    end
  end

  describe Egui::VoiceRecorder::Wav do
    it "wraps PCM in a canonical 44-byte header" do
      pcm = Bytes.new(1600) { |i| (i % 251).to_u8 }
      wav = Egui::VoiceRecorder::Wav.encode(pcm, 16000, 1)
      wav.size.should eq(44 + 1600)
      le = IO::ByteFormat::LittleEndian
      wav[0, 4].should eq("RIFF".to_slice)
      le.decode(UInt32, wav[4, 4]).should eq(36 + 1600)
      wav[8, 4].should eq("WAVE".to_slice)
      wav[12, 4].should eq("fmt ".to_slice)
      le.decode(UInt16, wav[16, 2]).should eq(16)   # fmt chunk size
      le.decode(UInt16, wav[20, 2]).should eq(1)    # PCM
      le.decode(UInt16, wav[22, 2]).should eq(1)    # mono
      le.decode(UInt32, wav[24, 4]).should eq(16000)
      le.decode(UInt32, wav[28, 4]).should eq(32000) # byte rate
      le.decode(UInt16, wav[32, 2]).should eq(2)    # block align
      le.decode(UInt16, wav[34, 2]).should eq(16)   # bits
      wav[36, 4].should eq("data".to_slice)
      le.decode(UInt32, wav[40, 4]).should eq(1600)
      wav[44..].should eq(pcm)
    end

    it "encodes stereo byte rates" do
      wav = Egui::VoiceRecorder::Wav.encode(Bytes.new(800), 44100, 2)
      le = IO::ByteFormat::LittleEndian
      le.decode(UInt16, wav[22, 2]).should eq(2)
      le.decode(UInt32, wav[28, 4]).should eq(44100 * 2 * 2)
      le.decode(UInt16, wav[32, 2]).should eq(4)
    end
  end
end
