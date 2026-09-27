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
end
