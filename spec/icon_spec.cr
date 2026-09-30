require "spec"
require "../src/egui"

# Egui::Icon specs: `from_file` embeds a vendored provider icon at
# compile time (lucide), caches the parse per tint, and paints as a
# raster-texture quad through the Svg bake. All headless (the
# NanoSvgCr fallback needs no native backend).

ICON_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(200.0, 100.0))

# Graphical stand-in: register_rgba hands out real ids so Svg#paint
# takes its texture path headless.
class IconRegistry < Egui::DummyTextureRegistry
  def graphical? : Bool
    true
  end
end

describe Egui::Icon do
  it "embeds a vendored provider icon and caches parses per tint" do
    svg = Egui::Icon.from_file(:lucide, :save)
    svg.should be_a(Egui::Svg)
    # the same (provider, name, tint) reuses the parsed instance
    Egui::Icon.from_file(:lucide, :save).should be(svg)
    # a tint parses a separate, tinted instance
    tinted = Egui::Icon.from_file(:lucide, :save,
      tint: Egui::Color32.rgb(1, 2, 3))
    tinted.should_not be(svg)
    Egui::Icon.from_file(:lucide, :save,
      tint: Egui::Color32.rgb(1, 2, 3)).should be(tinted)
    # string names and the `_` → `-` file-name mapping
    Egui::Icon.from_file(:lucide, "arrow-up").should be_a(Egui::Svg)
    Egui::Icon.from_file(:lucide, :arrow_up).should be_a(Egui::Svg)
    # the bootstrap provider (MIT, fill-based 16×16 set) embeds the
    # same way
    Egui::Icon.from_file(:bootstrap, :house).should be_a(Egui::Svg)
    Egui::Icon.from_file(:bootstrap, "box-seam").should be_a(Egui::Svg)
  end

  it "paints a real lucide icon as a baked texture quad" do
    ctx = Egui::Context.new
    ctx.textures = IconRegistry.new
    ctx.begin_frame(Egui::RawInput.new(ICON_SCREEN,
      [] of Egui::Event, 0.016))
    tint = Egui::Color32.rgb(200, 30, 30)
    ctx.window("icons") do |ui|
      icon = Egui::Icon.from_file(:lucide, :save, tint: tint)
      icon.paint(ui, Egui::Rect.from_min_size(
        Egui::Pos2.new(10.0, 10.0), Egui::Vec2.new(20.0, 20.0)))
    end
    ctx.end_frame

    imgs = ctx.painter.commands.select(Egui::ImageCmd)
    imgs.size.should eq(1)
    imgs.first.texture_id.should_not eq(0)
    imgs.first.rect.width.should be_close(20.0, 0.001)
    imgs.first.rect.height.should be_close(20.0, 0.001)
  end

  it "centers an icon-only button's icon" do
    # a square outline filling the whole 24×24 viewBox: the painted
    # quad == the icon box, so its center must match the button's
    # center (both axes; whole-pixel snapping allows a sub-pixel off)
    src = %(<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M2 2H22V22H2Z"/></svg>)
    ctx = Egui::Context.new
    ctx.textures = IconRegistry.new
    ctx.begin_frame(Egui::RawInput.new(ICON_SCREEN,
      [] of Egui::Event, 0.016))
    tint = Egui::Color32.rgb(9, 9, 9)
    rect = nil
    ctx.window("icon-only") do |ui|
      r = ui.add(Egui::Button.new("")
        .icon(Egui::Svg.new(src, Egui::Vec2.new(24.0, 24.0), tint)))
      rect = r.rect
    end
    ctx.end_frame

    img = ctx.painter.commands.select(Egui::ImageCmd).first
    center = rect.not_nil!.center
    img.rect.center.x.should be_close(center.x, 0.6)
    img.rect.center.y.should be_close(center.y, 0.6)
    # the quad fills the button's glyph-height icon box
    img.rect.width.should be_close(img.rect.height, 0.001)
  end
end
