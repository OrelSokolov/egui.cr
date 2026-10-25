require "spec"
require "../src/egui"

# Lottie playback core: the Player's master-clock math (frame
# quantization, loop wrap, speed re-anchoring, pause/seek, Eof) and
# the widget's stream-texture flow — render only on frame change,
# one GPU update per UI frame. Headless: a fake Renderer plus a
# recording TextureRegistry (the real one is the rlottie C shim, see
# spec/lottie_smoke.cr).

LOTTIE_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

# Deterministic 60-frame/60fps renderer: records rendered frame
# numbers, paints the frame number into the first pixel.
class FakeLottieRenderer < Egui::Lottie::Renderer
  property rendered = [] of Int32

  def initialize(@frames : Int32 = 60, @fps_v : Float64 = 60.0)
  end

  def width : Int32
    100
  end

  def height : Int32
    100
  end

  def frame_count : Int32
    @frames
  end

  def fps : Float64
    @fps_v
  end

  def render(frame : Int32, buf : Bytes, w : Int32, h : Int32) : Bool
    @rendered << frame
    buf.fill(0_u8)
    buf[0] = frame.to_u8
    buf[3] = 255_u8
    true
  end
end

# Graphical registry stub: records create_stream/update traffic.
class RecRegistry < Egui::TextureRegistry
  getter creates = [] of Tuple(Int32, Int32)
  getter updates = [] of UInt8 # first pixel of each update payload

  def graphical? : Bool
    true
  end

  def register_rgba(width : Int32, height : Int32, data : Bytes) : UInt64
    creates << {width, height}
    creates.size.to_u64
  end

  def load(path : String) : UInt64
    0_u64
  end

  def create_stream(width : Int32, height : Int32) : UInt64
    creates << {width, height}
    (creates.size + 100).to_u64
  end

  def update(id : UInt64, width : Int32, height : Int32, data : Bytes) : Nil
    updates << data[0]
  end

  def destroy(id : UInt64) : Nil
  end
end

describe Egui::Lottie::Player do
  it "quantizes the clock to whole source frames" do
    t = 0.0
    player = Egui::Lottie::Player.new(FakeLottieRenderer.new, -> { t })
    player.play
    t = 0.5 # 60 fps -> frame 30
    player.current_frame.should eq 30
  end

  it "wraps at the loop point" do
    t = 0.0
    player = Egui::Lottie::Player.new(FakeLottieRenderer.new, -> { t })
    player.play
    t = 2.25 # duration 1.0, loop -> 0.25 -> frame 15
    player.current_frame.should eq 15
    player.position.should be_close(0.25, 1e-9)
    player.progress.should be_close(0.25, 1e-9)
  end

  it "re-anchors the clock on speed change (no retroactive stretch)" do
    t = 10.0
    player = Egui::Lottie::Player.new(FakeLottieRenderer.new, -> { t })
    player.play
    t = 10.5 # frame 30
    player.current_frame.should eq 30
    player.speed = 2.0
    player.current_frame.should eq 30 # unchanged at the switch
    t = 10.75 # +0.25s at 2x -> +0.5s anim -> 1.0 total -> wrap -> frame 0
    player.current_frame.should eq 0
  end

  it "freezes on pause and jumps on seek" do
    t = 0.0
    player = Egui::Lottie::Player.new(FakeLottieRenderer.new, -> { t })
    player.play
    t = 0.25
    player.pause
    t = 5.0 # clock runs on, the player must not
    player.current_frame.should eq 15
    player.seek(0.5)
    player.current_frame.should eq 30
    player.position.should be_close(0.5, 1e-9)
  end

  it "lands in Eof past the end when not looping, restarts on play" do
    t = 0.0
    player = Egui::Lottie::Player.new(FakeLottieRenderer.new, -> { t })
    player.loop = false
    player.play
    t = 1.5
    player.current_frame.should eq 59 # clamped to the last frame
    player.advance
    player.state.eof?.should be_true
    player.position.should be_close(1.0, 1e-9)
    player.play # play-from-end restarts
    player.current_frame.should eq 0
  end

  it "reports the renderer's duration" do
    player = Egui::Lottie::Player.new(FakeLottieRenderer.new)
    player.duration.should be_close(1.0, 1e-9)
  end
end

describe Egui::LottieWidget do
  it "renders only when the frame changes and updates once per UI frame" do
    t = 0.0
    renderer = FakeLottieRenderer.new
    player = Egui::Lottie::Player.new(renderer, -> { t })
    player.play
    registry = RecRegistry.new
    ctx = Egui::Context.new
    ctx.textures = registry

    frame = ->(time : Float64) do
      t = time
      ctx.begin_frame(Egui::RawInput.new(LOTTIE_SCREEN, [] of Egui::Event, 0.016))
      ctx.window("demo") do |ui|
        ui.lottie(player, Egui::Vec2.new(100.0, 100.0))
      end
      ctx.end_frame
    end

    frame.call(0.0) # frame 0 renders, uploads
    renderer.rendered.should eq [0]
    registry.updates.should eq [0_u8]

    frame.call(0.0) # same frame: no re-render, no upload
    renderer.rendered.should eq [0]
    registry.updates.size.should eq 1

    frame.call(0.01) # 60 fps: next whole frame is 1... 0.01*60 = 0.6 -> frame 0 still
    frame.call(0.02) # frame 1
    renderer.rendered.should eq [0, 1]
    registry.updates.should eq [0_u8, 1_u8]
    registry.creates.size.should eq 1 # one stream texture, no churn
  end
end
