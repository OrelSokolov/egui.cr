require "spec"
require "../src/egui"
require "../examples/logo_variants"

# Egui::Svg specs: subset parsing (gradients, shapes, text anchors)
# and end-to-end painting — the icon-twin logo must produce a rounded
# gradient RectCmd plus a white "E" TextCmd. All headless.

SVG_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(800.0, 600.0))

def svg_frame(ctx : Egui::Context)
  ctx.begin_frame(Egui::RawInput.new(SVG_SCREEN, [] of Egui::Event, 0.016))
end

# Lucide-style icon: root-inherited paint attrs, currentColor, spaced
# arc flags, relative commands, implicit linetos.
LUCIDE_SQUARE = %(<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2z"/></svg>)

# A graphical TextureRegistry stand-in: counts #register_rgba calls
# so the specs can assert the raster cache bakes once per size, and
# captures the baked pixels for rasterizer-dispatch asserts.
class CountingRegistry < Egui::TextureRegistry
  property count = 0
  property last_data : Bytes? = nil

  def graphical? : Bool
    true
  end

  def register_rgba(width, height, data) : UInt64
    @count += 1
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
  it "parses the icon-twin variant into shapes + viewBox" do
    shapes, view = Egui::Svg.parse(LOGO_VARIANTS["icon"])

    view.width.should eq 512.0
    view.height.should eq 512.0

    rect = shapes.select(Egui::Svg::RectShape).first
    rect.x.should eq 16.0
    rect.w.should eq 480.0
    rect.rx.should eq 96.0
    gradient = rect.fill.should be_a(Egui::Svg::LinearGradient)

    text = shapes.select(Egui::Svg::TextShape).first
    text.text.should eq "E"
    text.anchor.should eq :middle
    text.central.should be_true
    text.color.r.should eq 255
  end

  it "maps vertical gradients to fill/fill2 and falls back on others" do
    shapes = Egui::Svg.parse(LOGO_VARIANTS["icon"]).first
    rect = shapes.select(Egui::Svg::RectShape).first
    gradient = rect.fill.as(Egui::Svg::LinearGradient)
    gradient.vertical.should be_true
    gradient.first.should eq Egui::Color32.rgb(0x4F, 0xA8, 0xE8)
    gradient.last.should eq Egui::Color32.rgb(0x16, 0x68, 0xC4)

    # horizontal gradient (x1→x2): the orientation flag flips
    flat = Egui::Svg.parse(%(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
      <defs><linearGradient id="h" x1="0" y1="0" x2="1" y2="0">
        <stop offset="0" stop-color="#000000"/><stop offset="1" stop-color="#FFFFFF"/>
      </linearGradient></defs>
      <rect x="0" y="0" width="10" height="10" fill="url(#h)"/>
    </svg>)).first.select(Egui::Svg::RectShape).first
    flat.fill.as(Egui::Svg::LinearGradient).vertical.should be_false
  end

  it "parses circle, line and stroke attributes" do
    shapes = Egui::Svg.parse(LOGO_VARIANTS["circle"]).first
    shapes.select(Egui::Svg::CircleShape).first.r.should eq 240.0

    shapes = Egui::Svg.parse(LOGO_VARIANTS["sketch"]).first
    line = shapes.select(Egui::Svg::LineShape).first
    line.x1.should eq 120.0
    line.color.should eq Egui::Color32.rgb(0xF0, 0xA0, 0x30)
    outline = shapes.select(Egui::Svg::RectShape).first
    outline.fill.should be_nil
    outline.stroke.not_nil!.should eq Egui::Color32.rgb(0x9A, 0xA0, 0xA6)
    outline.stroke_width.should eq 10.0
  end

  it "paints the logo as gradient rect + E text commands" do
    ctx = Egui::Context.new
    svg_frame(ctx)
    ctx.window("logos") do |ui|
      ui.svg(LOGO_VARIANTS["icon"], Egui::Vec2.new(128.0, 128.0))
    end
    ctx.end_frame

    cmds = ctx.painter.commands
    rects = cmds.select(Egui::RectCmd)
    rects.any? { |c| c.fill2 && c.fill == Egui::Color32.rgb(0x4F, 0xA8, 0xE8) }
      .should be_true
    texts = cmds.select(Egui::TextCmd)
    texts.any? { |c| c.text == "E" && c.color.r == 255 }.should be_true
  end

  it "scales the viewBox to the widget size" do
    ctx = Egui::Context.new
    svg_frame(ctx)
    rect = nil
    ctx.window("logos") do |ui|
      rect = ui.svg(LOGO_VARIANTS["icon"], Egui::Vec2.new(64.0, 64.0)).rect
    end
    ctx.end_frame

    # 512-unit viewBox fitted into 64 px: the 480-wide inner rect maps
    # to 60 px (aspect 1:1, no letterboxing).
    inner = ctx.painter.commands
      .select(Egui::RectCmd)
      .find(&.fill2)
      .not_nil!
    inner.rect.width.should be_close(60.0, 0.001)
    inner.rect.left.should be_close(rect.not_nil!.left + 2.0, 0.001)
  end

  # Lucide-style icon root-inheritance/currentColor/arc specs use the
  # LUCIDE_SQUARE constant above.

  it "parses paths with root-inherited stroke and currentColor" do
    shapes, view = Egui::Svg.parse(LUCIDE_SQUARE,
      Egui::Color32.rgb(10, 20, 30))
    view.width.should eq 24.0

    pl = shapes.select(Egui::Svg::PolylineShape).first
    stroke = pl.stroke.not_nil!
    stroke.r.should eq 10
    stroke.g.should eq 20
    stroke.b.should eq 30
    pl.stroke_width.should eq 2.0 # inherited from the root
    pl.closed?.should be_true     # the `z`
    pl.points.size.should be > 10 # arcs flattened to segments
    pl.points.first.should eq Egui::Vec2.new(19.0, 21.0)
    pl.points.last.should eq Egui::Vec2.new(19.0, 21.0)

    # without a tint currentColor falls back to black
    plain = Egui::Svg.parse(LUCIDE_SQUARE).first
      .select(Egui::Svg::PolylineShape).first
    plain.stroke.not_nil!.r.should eq 0
  end

  it "flattens cubic/quadratic beziers and relative implicit linetos" do
    shapes = Egui::Svg.parse(%(<svg viewBox="0 0 24 24"><path stroke="black" d="M0 0C0 6 6 12 12 12"/></svg>)).first
    pl = shapes.select(Egui::Svg::PolylineShape).first
    pl.points.first.should eq Egui::Vec2.new(0.0, 0.0)
    pl.points.last.should eq Egui::Vec2.new(12.0, 12.0)
    # t=0.5 of the curve is (3.75, 8.25); some sample lands near it
    pl.points.any? { |p|
      (p.x - 3.75).abs < 0.5 && (p.y - 8.25).abs < 0.5
    }.should be_true

    # lowercase m: first pair is a moveto, following pairs are relative
    # implicit linetos (12,5) → (19,12) → (12,19)
    shapes = Egui::Svg.parse(%(<svg viewBox="0 0 24 24"><path stroke="black" d="m12 5 7 7-7 7"/></svg>)).first
    pl = shapes.select(Egui::Svg::PolylineShape).first
    pl.points.should eq [Egui::Vec2.new(12.0, 5.0),
      Egui::Vec2.new(19.0, 12.0), Egui::Vec2.new(12.0, 19.0)]
  end

  it "samples elliptical arcs via the center parameterization" do
    # half circle from (4,12) up over (12,4) to (20,12), sweep=1
    shapes = Egui::Svg.parse(%(<svg viewBox="0 0 24 24"><path stroke="black" d="M4 12a8 8 0 0 1 16 0"/></svg>)).first
    pl = shapes.select(Egui::Svg::PolylineShape).first
    pl.points.last.should eq Egui::Vec2.new(20.0, 12.0)
    pl.points.any? { |p|
      (p.x - 12.0).abs < 0.1 && (p.y - 4.0).abs < 0.1
    }.should be_true
  end

  it "parses polyline and polygon (fill degrades to stroke)" do
    shapes = Egui::Svg.parse(%(<svg viewBox="0 0 10 10"><polyline points="1,1 9,1 9,9" stroke="red" fill="none"/><polygon points="1,1 9,1 5,9" fill="blue"/></svg>)).first
    pls = shapes.select(Egui::Svg::PolylineShape)
    pls.size.should eq 2
    pls[0].closed?.should be_false
    red = pls[0].stroke.not_nil!
    red.r.should eq 220 # named "red"
    pls[1].closed?.should be_true
    # filled polygon: no polygon tessellation yet → outline in fill color
    blue = pls[1].stroke.not_nil!
    blue.r.should eq 50
    blue.b.should eq 220
  end

  it "paints path icons as tinted line commands" do
    src = %(<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M5 12h14"/><path d="m12 5 7 7-7 7"/></svg>)
    ctx = Egui::Context.new
    svg_frame(ctx)
    tint = Egui::Color32.rgb(0x33, 0x66, 0x99)
    ctx.window("icons") do |ui|
      ui.svg(src, Egui::Vec2.new(24.0, 24.0), tint)
    end
    ctx.end_frame

    lines = ctx.painter.commands.select(Egui::LineCmd)
    # the h-line is 1 segment, the arrow 2, both at the tint color —
    # plus whatever frame the window itself paints
    tinted = lines.select { |l| l.color == tint }
    tinted.size.should be >= 3
    # 24-unit viewBox at 24 px: stroke 2 → 2 px on screen
    tinted.each { |l| l.width.should eq 2.0 }
  end

  # -- rasterize + raster-texture cache ---------------------------------

  it "rasterizes with analytic anti-aliasing (coverage ramp)" do
    src = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M5 12h14"/></svg>)
    svg = Egui::Svg.new(src, current_color: Egui::Color32.rgb(200, 200, 200))
    buf = svg.rasterize(24, 24)
    buf.size.should eq(24 * 24 * 4)

    alphas = (0...24 * 24).map { |i| buf[i * 4 + 3] }
    # stroke center is fully covered
    alphas.should contain(255_u8)
    # the one-pixel coverage ramp on the edge → intermediate values
    alphas.any? { |a| a > 1 && a < 254 }.should be_true
    # outside the stroke: fully transparent
    alphas.first.should eq(0_u8)
    # color carries the tint, alpha-weighted pixels only
    i = alphas.index(255_u8).not_nil! * 4
    buf[i].should eq(200)
    buf[i + 3].should eq(255)
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

  # -- external rasterizer dispatch (NanoSVG primary, built-in fallback) --

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

      # nil from the external rasterizer → the built-in software bake
      Egui::Svg.external_rasterizer = ->(_src : String, _tint : Egui::Color32,
        _w : Int32, _h : Int32) : Bytes? { nil }
      svg_frame(ctx)
      ctx.window("icons2") do |ui|
        ui.svg(src_fallback, Egui::Vec2.new(32.0, 32.0))
      end
      ctx.end_frame
      expected = Egui::Svg.new(src_fallback).rasterize(32, 32)
      registry.last_data.not_nil!.should eq(expected)
    ensure
      Egui::Svg.external_rasterizer = nil
    end
  end
end
