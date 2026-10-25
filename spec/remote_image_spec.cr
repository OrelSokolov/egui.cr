require "spec"
require "../src/egui"

# Egui::Http + RemoteImage specs: the fetch-decode-upload pipeline of
# Context#load_image_url. The transport is faked through
# Http.use_fetcher (no network in specs), the codec through
# ImageCodec.use; the worker fiber is advanced manually (Fiber.yield —
# under a real backend that is on_frame's pump slot). All headless.

RI_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(800.0, 600.0))

# Graphical TextureRegistry stand-in: register_rgba records uploads.
class RIRegistry < Egui::TextureRegistry
  property uploads = [] of Tuple(Int32, Int32)

  def graphical? : Bool
    true
  end

  def register_rgba(width, height, data) : UInt64
    @uploads << {width, height}
    id = @uploads.size.to_u64 + 100_u64
    id
  end

  def load(path) : UInt64
    0_u64
  end

  def create_stream(width, height) : UInt64
    0_u64
  end

  def update(id, width, height, data) : Nil
  end

  def destroy(id : UInt64) : Nil
  end
end

# Codec stand-in: every "image" decodes to a 4×2 frame.
class RICodec < Egui::ImageCodec::Implementation
  def decode(bytes : Bytes) : Egui::ImageCodec::Frame?
    Egui::ImageCodec::Frame.new(4, 2, Bytes.new(4 * 2 * 4))
  end

  def image_size(bytes : Bytes) : Egui::Vec2?
    Egui::Vec2.new(4.0, 2.0)
  end
end

def ri_frame(ctx : Egui::Context) : Nil
  ctx.begin_frame(Egui::RawInput.new(RI_SCREEN, [] of Egui::Event, 0.016))
end

# Advance the Crystal scheduler so Http worker fibers run to
# completion (the on_frame pump slot under a real backend).
def ri_pump : Nil
  8.times { Fiber.yield }
end

def ri_restore : Nil
  # Drain any fetch fiber a failed assertion left un-run, then reset
  # the seams (the fetcher is still the fake at this point — safe).
  ri_pump
  Egui::Http.use_fetcher { |url, headers| Egui::Http.default_fetch(url, headers) }
  Egui::ImageCodec.use(Egui::ImageCodec::Implementation.new)
  Egui::Http.take_delivered
end

describe Egui::RemoteImage do
  it "shows a placeholder, then the texture once bytes land — one fetch" do
    Egui::ImageCodec.use(RICodec.new)
    fetches = [] of String
    Egui::Http.use_fetcher do |url, _headers|
      fetches << url
      Egui::Http::Result.new(200, Bytes.new(8), nil)
    end
    registry = RIRegistry.new
    ctx = Egui::Context.new
    ctx.textures = registry
    begin
      # Frame 1: fetch STARTED (entry :loading), placeholder, no ImageCmd.
      ri_frame(ctx)
      ctx.window("w") { |ui| ui.remote_image("https://x.test/a.png") }
      ctx.end_frame
      Egui::Http.pending?.should be_true
      ctx.painter.commands.select(Egui::ImageCmd).should be_empty
      ctx.url_image_state("https://x.test/a.png").should eq(:loading)
      ctx.url_image_size("https://x.test/a.png").should be_nil

      # Worker fiber delivers between frames; the backend counts it.
      ri_pump
      fetches.should eq(["https://x.test/a.png"])
      Egui::Http.take_delivered.should eq(1)
      Egui::Http.pending?.should be_false

      # Frame 2: decode + upload in-frame, ImageCmd with the id.
      ri_frame(ctx)
      ctx.window("w") { |ui| ui.remote_image("https://x.test/a.png") }
      ctx.end_frame
      fetches.size.should eq(1) # cached — no refetch
      registry.uploads.should eq([{4, 2}])
      ctx.url_image_state("https://x.test/a.png").should eq(:ready)
      ctx.url_image_size("https://x.test/a.png").should eq(
        Egui::Vec2.new(4.0, 2.0))
      img = ctx.painter.commands.select(Egui::ImageCmd).first
      img.texture_id.should eq(registry.uploads.size.to_u64 + 100_u64)
      # no explicit size → the decoded size
      img.rect.width.should be_close(4.0, 0.001)
      img.rect.height.should be_close(2.0, 0.001)
    ensure
      ri_restore
    end
  end

  it "keeps an explicit size (upstream Image semantics)" do
    Egui::ImageCodec.use(RICodec.new)
    Egui::Http.use_fetcher do |_url, _headers|
      Egui::Http::Result.new(200, Bytes.new(8), nil)
    end
    ctx = Egui::Context.new
    ctx.textures = RIRegistry.new
    begin
      ri_frame(ctx)
      ctx.window("w") do |ui|
        ui.remote_image("https://x.test/b.png", Egui::Vec2.new(40.0, 20.0))
      end
      ctx.end_frame
      ri_pump
      ri_frame(ctx)
      ctx.window("w") do |ui|
        ui.remote_image("https://x.test/b.png", Egui::Vec2.new(40.0, 20.0))
      end
      ctx.end_frame
      img = ctx.painter.commands.select(Egui::ImageCmd).first
      img.rect.width.should be_close(40.0, 0.001)
      img.rect.height.should be_close(20.0, 0.001)
    ensure
      ri_restore
    end
  end

  it "contains the decoded aspect inside the box, centered" do
    Egui::ImageCodec.use(RICodec.new) # decodes to 4×2 (aspect 2:1)
    Egui::Http.use_fetcher do |_url, _headers|
      Egui::Http::Result.new(200, Bytes.new(8), nil)
    end
    ctx = Egui::Context.new
    ctx.textures = RIRegistry.new
    begin
      box = Egui::Vec2.new(40.0, 30.0) # aspect 4:3 — narrower than 2:1
      response = nil
      2.times do
        ri_frame(ctx)
        ctx.window("w") do |ui|
          response = ui.remote_image("https://x.test/fit.png", box)
        end
        ctx.end_frame
        ri_pump
      end
      img = ctx.painter.commands.select(Egui::ImageCmd).first
      # contain: 40×20 (width-bound), centered in the 40×30 box
      img.rect.width.should be_close(40.0, 0.001)
      img.rect.height.should be_close(20.0, 0.001)
      img.rect.center.y.should be_close(
        response.not_nil!.rect.center.y, 0.001)
    ensure
      ri_restore
    end
  end

  it "stretches to the whole box with fit: false" do
    Egui::ImageCodec.use(RICodec.new)
    Egui::Http.use_fetcher do |_url, _headers|
      Egui::Http::Result.new(200, Bytes.new(8), nil)
    end
    ctx = Egui::Context.new
    ctx.textures = RIRegistry.new
    begin
      2.times do
        ri_frame(ctx)
        ctx.window("w") do |ui|
          ui.remote_image("https://x.test/stretch.png",
            Egui::Vec2.new(40.0, 30.0), fit: false)
        end
        ctx.end_frame
        ri_pump
      end
      img = ctx.painter.commands.select(Egui::ImageCmd).first
      img.rect.width.should be_close(40.0, 0.001)
      img.rect.height.should be_close(30.0, 0.001)
    ensure
      ri_restore
    end
  end

  it "degrades to a failed placeholder on transport error, no refetch" do
    Egui::ImageCodec.use(RICodec.new)
    fetches = 0
    Egui::Http.use_fetcher do |_url, _headers|
      fetches += 1
      Egui::Http::Result.new(0, Bytes.empty, "dns boom")
    end
    registry = RIRegistry.new
    ctx = Egui::Context.new
    ctx.textures = registry
    begin
      2.times do
        ri_frame(ctx)
        ctx.window("w") { |ui| ui.remote_image("https://x.test/c.png") }
        ctx.end_frame
        ri_pump
      end
      fetches.should eq(1)
      registry.uploads.should be_empty
      ctx.url_image_state("https://x.test/c.png").should eq(:failed)
      ctx.painter.commands.select(Egui::ImageCmd).should be_empty
      ctx.url_images["https://x.test/c.png"].error.should eq("dns boom")
    ensure
      ri_restore
    end
  end

  it "fails on a non-2xx answer without uploading" do
    Egui::ImageCodec.use(RICodec.new)
    Egui::Http.use_fetcher do |_url, _headers|
      Egui::Http::Result.new(404, Bytes.new(8), nil)
    end
    registry = RIRegistry.new
    ctx = Egui::Context.new
    ctx.textures = registry
    begin
      ri_frame(ctx)
      ctx.window("w") { |ui| ui.remote_image("https://x.test/d.png") }
      ctx.end_frame
      ri_pump
      ri_frame(ctx)
      ctx.window("w") { |ui| ui.remote_image("https://x.test/d.png") }
      ctx.end_frame
      ctx.url_image_state("https://x.test/d.png").should eq(:failed)
      registry.uploads.should be_empty
      ctx.url_images["https://x.test/d.png"].error.should eq("HTTP 404")
    ensure
      ri_restore
    end
  end

  it "fails on undecodable bytes even after a 200" do
    Egui::ImageCodec.use(Egui::ImageCodec::Implementation.new) # headless no-op
    Egui::Http.use_fetcher do |_url, _headers|
      Egui::Http::Result.new(200, Bytes.new(8), nil)
    end
    ctx = Egui::Context.new
    ctx.textures = RIRegistry.new
    begin
      ri_frame(ctx)
      ctx.window("w") { |ui| ui.remote_image("https://x.test/e.png") }
      ctx.end_frame
      ri_pump
      ri_frame(ctx)
      ctx.window("w") { |ui| ui.remote_image("https://x.test/e.png") }
      ctx.end_frame
      ctx.url_image_state("https://x.test/e.png").should eq(:failed)
    ensure
      ri_restore
    end
  end

  it "shares one fetch between widgets on the same URL" do
    Egui::ImageCodec.use(RICodec.new)
    fetches = [] of String
    Egui::Http.use_fetcher do |url, _headers|
      fetches << url
      Egui::Http::Result.new(200, Bytes.new(8), nil)
    end
    registry = RIRegistry.new
    ctx = Egui::Context.new
    ctx.textures = registry
    begin
      ri_frame(ctx)
      ctx.window("w") do |ui|
        ui.remote_image("https://x.test/shared.png")
        ui.remote_image("https://x.test/shared.png")
        ui.remote_image("https://x.test/other.png")
      end
      ctx.end_frame
      Egui::Http.pending?.should be_true
      ri_pump
      fetches.sort.should eq(
        ["https://x.test/other.png", "https://x.test/shared.png"])
      fetches.size.should eq(2) # shared.png fetched ONCE
      ri_frame(ctx)
      ctx.window("w") do |ui|
        ui.remote_image("https://x.test/shared.png")
        ui.remote_image("https://x.test/shared.png")
      end
      ctx.end_frame
      registry.uploads.should eq([{4, 2}]) # one texture for both
      ctx.painter.commands.select(Egui::ImageCmd).size.should eq(2)
    ensure
      ri_restore
    end
  end
end

describe Egui::Http do
  it "delivers the callback between frames and counts it" do
    results = [] of Egui::Http::Result
    Egui::Http.use_fetcher do |_url, _headers|
      Egui::Http::Result.new(200, Bytes.new(3), nil)
    end
    begin
      Egui::Http.pending?.should be_false
      Egui::Http.get("https://x.test/unit") { |r| results << r }
      Egui::Http.pending?.should be_true
      results.should be_empty # not before the scheduler runs
      ri_pump
      results.size.should eq(1)
      results.first.success?.should be_true
      results.first.body.size.should eq(3)
      Egui::Http.pending?.should be_false
      Egui::Http.take_delivered.should eq(1)
      Egui::Http.take_delivered.should eq(0)
    ensure
      ri_restore
    end
  end

  it "Result marks errors and non-2xx as unsuccessful" do
    Egui::Http::Result.new(200, Bytes.empty, nil).success?.should be_true
    Egui::Http::Result.new(302, Bytes.empty, nil).success?.should be_false
    Egui::Http::Result.new(500, Bytes.empty, nil).success?.should be_false
    Egui::Http::Result.new(0, Bytes.empty, "timeout").success?.should be_false
  end
end
