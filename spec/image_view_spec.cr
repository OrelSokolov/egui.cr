require "spec"
require "../src/egui"

# Egui::ImageView specs: the pan/zoom viewer widget. SVG sources
# prewarm the full raster-bucket set over their first frames (the
# bake-not-mid-gesture contract from examples/multitouch_demo) and
# then never re-bake across the whole gesture range; raster sources
# draw one loaded texture and bake nothing. All headless.

IV_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(800.0, 600.0))

# A graphical TextureRegistry stand-in: register_rgba counts bucket
# bakes (raster sources load through the ImageCodec seam now — see
# the IVCodec stand-in and widgets/image_view.cr raster path).
class IVRegistry < Egui::TextureRegistry
  property bakes = [] of Tuple(Int32, Int32)

  def graphical? : Bool
    true
  end

  def register_rgba(width, height, data) : UInt64
    @bakes << {width, height}
    1_u64
  end

  def create_stream(width, height) : UInt64
    0_u64
  end

  def update(id, width, height, data) : Nil
  end

  def destroy(id) : Nil
  end
end

# An ImageCodec stand-in: every input decodes to a 64×48 frame and
# probes as 64×48 (pixel content is irrelevant to the cache contract).
class IVCodec < Egui::ImageCodec::Implementation
  property decodes = 0

  def decode(bytes) : Egui::ImageCodec::Frame?
    @decodes += 1
    Egui::ImageCodec::Frame.new(width: 64, height: 48,
      rgba: Bytes.new(64 * 48 * 4))
  end

  def image_size(bytes) : Egui::Vec2?
    Egui::Vec2.new(64.0, 48.0)
  end
end

IV_SVG = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2"><path d="M5 12h14"/></svg>)

def iv_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event)
  ctx.begin_frame(Egui::RawInput.new(IV_SCREEN, events, 0.016))
end

describe Egui::ImageView do
  it "prewarms every bucket, then never re-bakes across the zoom range" do
    # Pixel content is irrelevant to the cache contract — stub the bake
    # (a real 2048² bake costs seconds in the dev-built spec runner).
    Egui::Svg.external_rasterizer = ->(_s : String, _t : Egui::Color32,
      w : Int32, h : Int32) : Bytes? { Bytes.new(w * h * 4) }
    registry = IVRegistry.new
    ctx = Egui::Context.new
    ctx.textures = registry
    svg = Egui::Svg.new(IV_SVG, Egui::Vec2.new(300.0, 300.0))
    view = Egui::ImageView.new("art", svg, Egui::Vec2.new(300.0, 300.0))
    begin
      # One bucket bakes per frame (the prewarm drain) — after enough
      # frames the full reachable set {256,512,1024,2048} is warm.
      8.times do
        iv_frame(ctx)
        ctx.window("w") { |ui| view.ui(ui) }
        ctx.end_frame
      end
      registry.bakes.sort.should eq(
        [{256, 256}, {512, 512}, {1024, 1024}, {2048, 2048}])

      # Walk the gesture range: pinch in to max_scale, back out below
      # 1.0 to the floor — every frame is a cache hit, no new bakes.
      focal = Egui::Pos2.new(400.0, 300.0)
      zooms = Array.new(24, Egui::Event.zoom(1.25, focal)) +
              Array.new(40, Egui::Event.zoom(0.8, focal))
      zooms.each do |e|
        iv_frame(ctx, [e])
        ctx.window("w") { |ui| view.ui(ui) }
        ctx.end_frame
      end
      view.scale.should be_close(0.1, 0.001) # clamped at min_scale
      registry.bakes.size.should eq(4)
      ctx.painter.commands.select(Egui::ImageCmd).size.should be >= 1
    ensure
      Egui::Svg.external_rasterizer = nil
    end
  end

  it "draws a raster source as one texture and bakes nothing" do
    # Context#load_image reads the file itself (the codec is bytes-in),
    # so the raster source needs a real (content-irrelevant) file.
    path = File.tempname("iv_raster", ".png")
    File.write(path, Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] +
      Bytes.new(16, 0))
    codec = IVCodec.new
    Egui::ImageCodec.use(codec)
    registry = IVRegistry.new
    ctx = Egui::Context.new
    ctx.textures = registry
    begin
      view = Egui::ImageView.new("photo", path)
      focal = Egui::Pos2.new(400.0, 300.0)
      Array.new(6, Egui::Event.zoom(1.5, focal)).each do |e|
        iv_frame(ctx, [e])
        ctx.window("w") { |ui| view.ui(ui) }
        ctx.end_frame
      end

      codec.decodes.should eq(1) # decoded once (Context#load_image cache)
      # one raster upload of the probed size — no SVG bucket bakes
      # (those would be 256+ squares from the prewarm set)
      registry.bakes.should eq([{64, 48}])
      ctx.painter.commands.select(Egui::ImageCmd).size.should be >= 1
      view.scale.should be_close(1.5 ** 6, 0.001) # zoom applied
      view.base.should eq(Egui::Vec2.new(64.0, 48.0)) # probed size adopted
    ensure
      Egui::ImageCodec.use(Egui::ImageCodec::Implementation.new)
      File.delete(path)
    end
  end
end
