require "spec"
require "../src/egui"

# Egui::Svg specs: the NanoSvgCr bake (anti-aliased coverage, tint,
# currentColor, nil on unusable sources), the raster-texture cache
# contract (one bake per size, re-bake on change, letterboxed aspect
# fit) and the external-rasterizer dispatch. All headless — the
# Crystal port needs no native backend.

SVG_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(800.0, 600.0))

def svg_frame(ctx : Egui::Context)
  ctx.begin_frame(Egui::RawInput.new(SVG_SCREEN, [] of Egui::Event, 0.016))
end

# Lucide-style icon: root-inherited paint attrs, currentColor, spaced
# arc flags, relative commands, implicit linetos.
LUCIDE_SQUARE = %(<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2z"/></svg>)

# A graphical TextureRegistry stand-in: counts #register_rgba calls
# (and their sizes) so the specs can assert the raster cache bakes
# once per size, and captures the baked pixels for
# rasterizer-dispatch asserts.
class CountingRegistry < Egui::TextureRegistry
  property count = 0
  property last_data : Bytes? = nil
  property sizes = [] of Tuple(Int32, Int32)

  def graphical? : Bool
    true
  end

  def register_rgba(width, height, data) : UInt64
    @count += 1
    @sizes << {width, height}
    @last_data = data
    @count.to_u64
  end

  def load(path) : UInt64
    0_u64
  end

  def create_stream(width, height) : UInt64
    0_u64
  end

  def update(id, width, height, data) : Nil
  end

  def destroy(id) : Nil
  end
end

describe Egui::Svg do
  describe Egui::NanoSvgCr do
    it "rasterizes with anti-aliasing (coverage ramp) and tint" do
      src = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M5 12h14"/></svg>)
      tint = Egui::Color32.rgb(200, 200, 200)
      buf = Egui::NanoSvgCr.rasterize(src, tint, 24, 24).not_nil!
      buf.size.should eq(24 * 24 * 4)

      alphas = (0...24 * 24).map { |i| buf[i * 4 + 3] }
      # stroke center is fully covered
      alphas.should contain(255_u8)
      # the coverage ramp on the edge → intermediate values
      alphas.any? { |a| a > 1 && a < 254 }.should be_true
      # outside the stroke: fully transparent
      alphas.first.should eq(0_u8)
      # color carries the tint, alpha-weighted pixels only
      i = alphas.index(255_u8).not_nil! * 4
      buf[i].should eq(200)
      buf[i + 3].should eq(255)
    end

    it "rounds caps and joins like the C rasterizer" do
      # Lucide square: rounded joins at every corner — the bake must
      # stay inside the 24×24 grid (no missing corner coverage).
      buf = Egui::NanoSvgCr.rasterize(LUCIDE_SQUARE,
        Egui::Color32.rgb(10, 20, 30), 48, 48).not_nil!
      # 4 corners of the stroked square (inset ~2 units of 24 → 4px
      # at 48px) must have coverage.
      [[8, 8], [40, 8], [8, 40], [40, 40]].each do |(x, y)|
        buf[(y * 48 + x) * 4 + 3].should be > 100
      end
    end

    it "returns nil for a source without intrinsic size" do
      Egui::NanoSvgCr.rasterize("not an svg at all",
        Egui::Color32.new(0, 0, 0, 255), 24, 24).should be_nil
    end
  end

  it "bakes letterboxed to the viewBox aspect through the cache" do
    src = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 12" fill="none" stroke="black" stroke-width="2"><path d="M2 6h20"/></svg>)
    registry = CountingRegistry.new
    ctx = Egui::Context.new
    ctx.textures = registry
    rect = nil
    svg_frame(ctx)
    ctx.window("wide") do |ui|
      rect = ui.svg(src, Egui::Vec2.new(48.0, 48.0)).rect
    end
    ctx.end_frame

    # 24×12 viewBox fitted into a 48×48 widget: 48×24 bake
    # (aspect preserved, letterboxed top/bottom).
    registry.sizes.should eq([{48, 24}])
    img = ctx.painter.commands.select(Egui::ImageCmd).first
    img.rect.width.should be_close(48.0, 0.001)
    img.rect.height.should be_close(24.0, 0.001)
    center = rect.not_nil!.center
    img.rect.center.x.should be_close(center.x, 0.001)
    img.rect.center.y.should be_close(center.y, 0.001)
  end

  it "paints through the raster-texture cache on a graphical registry" do
    registrations = [] of Tuple(Int32, Int32)

    src = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2"><path d="M5 12h14"/></svg>)
    registry = CountingRegistry.new
    ctx = Egui::Context.new
    ctx.textures = registry
    svg_frame(ctx)
    3.times do
      ctx.window("icons") do |ui|
        ui.svg(src, Egui::Vec2.new(48.0, 48.0))
      end
      ctx.end_frame
    end

    # one bake for three frames at the same size…
    registry.count.should eq(1)
    ctx.painter.commands.select(Egui::ImageCmd).size.should be >= 1

    # …and a new size re-bakes (font-atlas invalidation contract)
    svg_frame(ctx)
    ctx.window("icons") do |ui|
      ui.svg(src, Egui::Vec2.new(96.0, 96.0))
    end
    ctx.end_frame
    registry.count.should eq(2)
  end

  it "paints nothing headless (no vector fallback)" do
    ctx = Egui::Context.new
    svg_frame(ctx)
    ctx.window("headless") do |ui|
      ui.svg(LUCIDE_SQUARE, Egui::Vec2.new(48.0, 48.0))
    end
    ctx.end_frame
    ctx.painter.commands.select(Egui::ImageCmd).should be_empty
  end

  # -- external rasterizer dispatch (dev builds route through C) ------

  it "bakes through external_rasterizer and falls back on nil" do
    # Distinct sources per phase: the raster cache is keyed by source,
    # so a cached texture from phase 1 must not shadow phase 2's bake.
    src_external = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2"><path d="M5 12h14"/></svg>)
    src_fallback = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2"><path d="M12 5v14"/></svg>)

    Egui::Svg.external_rasterizer = ->(_src : String, _tint : Egui::Color32,
      w : Int32, h : Int32) : Bytes? { Bytes.new(w * h * 4, 0x7F) }
    registry = CountingRegistry.new
    ctx = Egui::Context.new
    ctx.textures = registry
    begin
      svg_frame(ctx)
      ctx.window("icons") do |ui|
        ui.svg(src_external, Egui::Vec2.new(32.0, 32.0))
      end
      ctx.end_frame
      data = registry.last_data.not_nil!
      data.size.should eq(32 * 32 * 4)
      data.all?(&.==(0x7F_u8)).should be_true

      # nil from the external rasterizer → the Crystal-port bake
      Egui::Svg.external_rasterizer = ->(_src : String, _tint : Egui::Color32,
        _w : Int32, _h : Int32) : Bytes? { nil }
      svg_frame(ctx)
      ctx.window("icons2") do |ui|
        ui.svg(src_fallback, Egui::Vec2.new(32.0, 32.0))
      end
      ctx.end_frame
      expected = Egui::NanoSvgCr.rasterize(src_fallback,
        Egui::Color32.new(0, 0, 0, 255), 32, 32)
      registry.last_data.not_nil!.should eq(expected)
    ensure
      Egui::Svg.external_rasterizer = nil
    end
  end
end
