require "spec"
require "../src/egui"

# Egui::Icon specs: `from_file` embeds a vendored provider icon at
# compile time (lucide), caches the parse per tint, and paints the
# flattened paths as tinted line commands. All headless.

ICON_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(200.0, 100.0))

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

  it "paints a real lucide icon as tinted line commands" do
    ctx = Egui::Context.new
    ctx.begin_frame(Egui::RawInput.new(ICON_SCREEN,
      [] of Egui::Event, 0.016))
    tint = Egui::Color32.rgb(200, 30, 30)
    ctx.window("icons") do |ui|
      icon = Egui::Icon.from_file(:lucide, :save, tint: tint)
      icon.paint(ui, Egui::Rect.from_min_size(
        Egui::Pos2.new(10.0, 10.0), Egui::Vec2.new(20.0, 20.0)))
    end
    ctx.end_frame

    # lucide's save icon is three flattened stroke paths
    lines = ctx.painter.commands.select(Egui::LineCmd)
      .select { |l| l.color == tint }
    lines.size.should be > 5
  end

  it "centers an icon-only button's icon" do
    # a square outline filling the whole 24×24 viewBox: the painted
    # line bbox == the icon box, so its center must match the
    # button's center (both axes)
    src = %(<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M2 2H22V22H2Z"/></svg>)
    ctx = Egui::Context.new
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

    lines = ctx.painter.commands.select(Egui::LineCmd)
      .select { |l| l.color == tint }
    lines.size.should be >= 4
    xs = lines.flat_map { |l| [l.p1.x, l.p2.x] }.minmax
    ys = lines.flat_map { |l| [l.p1.y, l.p2.y] }.minmax
    center = rect.not_nil!.center
    ((xs[0] + xs[1]) / 2.0).should be_close(center.x, 0.6)
    ((ys[0] + ys[1]) / 2.0).should be_close(center.y, 0.6)
  end
end
