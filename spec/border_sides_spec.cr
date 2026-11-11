# Per-side borders (CSS `border-style: solid none none none`):
# `stroke_width.<side>` overrides the scalar `stroke_width` per side
# (width 0 = side off), `stroke.<side>` overrides the shared `stroke`
# color — the same key scheme `padding` uses. Resolved by
# `StyleVars#stroke_sides?`, carried by `RectCmd#stroke_sides` and
# painted by the standard two-rect overlay in both backends
# (`Egui.border_overlay_layers`: outer border plate(s) + the inset
# background, corner radius r − adjacent border).

require "spec"
require "../src/egui"

BS_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(400.0, 300.0))

def bs_frame(&block : Egui::Ui ->)
  ctx = Egui::Context.new
  ctx.begin_frame(Egui::RawInput.new(BS_SCREEN, [] of Egui::Event, 0.016))
  ctx.window("w") { |ui| yield ui }
  ctx.end_frame
  ctx
end

describe "StyleVars#stroke_sides?" do
  it "is nil without per-side keys (the uniform path stays)" do
    vars = Egui::StyleVars{
      "stroke"       => Egui::Color32.rgb(1, 2, 3),
      "stroke_width" => 2.0,
    }
    vars.stroke_sides?(Egui::Color32.rgb(9, 9, 9), 1.0).should be_nil
  end

  it "falls back to the scalar keys per side" do
    vars = Egui::StyleVars{
      "stroke_width"        => 2.0,
      "stroke_width.top"    => 0.0,
      "stroke_width.left"   => 3.0,
      "stroke"              => Egui::Color32.rgb(1, 1, 1),
      "stroke.top"          => Egui::Color32.rgb(255, 0, 0),
    }
    s = vars.stroke_sides?(Egui::Color32.rgb(9, 9, 9), 1.0).not_nil!
    s.top.width.should eq(0.0)                 # per-side 0 = side off
    s.top.on?.should be_false
    s.top.color.should eq(Egui::Color32.rgb(255, 0, 0))
    s.right.width.should eq(2.0)               # scalar fallback
    s.right.color.should eq(Egui::Color32.rgb(1, 1, 1))
    s.bottom.width.should eq(2.0)
    s.bottom.color.should eq(Egui::Color32.rgb(1, 1, 1))
    s.left.width.should eq(3.0)
    s.left.color.should eq(Egui::Color32.rgb(1, 1, 1))
  end

  it "uses the caller base when no scalar key is set, clamping negatives" do
    vars = Egui::StyleVars{"stroke_width.bottom" => -5.0}
    s = vars.stroke_sides?(Egui::Color32.rgb(9, 9, 9), 4.0).not_nil!
    s.top.width.should eq(4.0)                 # base_width fallback
    s.top.color.should eq(Egui::Color32.rgb(9, 9, 9))
    s.bottom.width.should eq(0.0)              # clamped, not negative
    s.bottom.on?.should be_false
  end
end

describe "ui.box per-side stroke" do
  it "a StyleBox stroke_width becomes RectCmd stroke_sides" do
    ctx = bs_frame do |ui|
      ui.box(:column, fill: Egui::Color32.rgb(0, 0, 0),
        stroke: Egui::Color32.rgb(5, 5, 5),
        stroke_width: Egui::StyleBox.new(top: 0.0, right: 0.0,
          bottom: 0.0, left: 3.0)) { |b| b.label("x") }
    end
    cmd = ctx.painter.commands.select(Egui::RectCmd)
      .find { |c| c.fill == Egui::Color32.rgb(0, 0, 0) }.not_nil!
    s = cmd.stroke_sides.not_nil!
    s.left.width.should eq(3.0)
    s.left.on?.should be_true
    s.top.on?.should be_false
    s.right.on?.should be_false
    s.bottom.on?.should be_false
    s.left.color.should eq(Egui::Color32.rgb(5, 5, 5))
  end

  it "a scalar stroke_width keeps the uniform path (no stroke_sides)" do
    ctx = bs_frame do |ui|
      ui.box(:column, stroke: Egui::Color32.rgb(5, 5, 5)) { |b| b.label("x") }
    end
    cmd = ctx.painter.commands.select(Egui::RectCmd)
      .find { |c| c.stroke_color == Egui::Color32.rgb(5, 5, 5) }.not_nil!
    cmd.stroke_sides.should be_nil
  end
end

describe "styled frames pick up per-side rules" do
  it "a class rule drives the popup frame's sides" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("panel", Egui::StyleVars{
      "stroke"            => Egui::Color32.rgb(10, 10, 10),
      "stroke_width"      => 1.0,
      "stroke_width.top"  => 0.0,
      "stroke_width.left" => 3.0,
    })
    ctx.begin_frame(Egui::RawInput.new(BS_SCREEN, [] of Egui::Event, 0.016))
    ctx.open_popup("p")
    ctx.popup("p", Egui::Pos2.new(10.0, 10.0), style_class: "panel") { |ui| }
    ctx.end_frame
    cmd = ctx.painter.commands.select(Egui::RectCmd)
      .find { |c| c.stroke_sides }.not_nil!
    cmd.stroke_sides.not_nil!.top.on?.should be_false
    cmd.stroke_sides.not_nil!.left.width.should eq(3.0)
  end

  it "a button rule hides one side of the button border" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("button", Egui::StyleVars{
      "stroke_width"     => 1.0,
      "stroke_width.top" => 0.0,
    })
    ctx.begin_frame(Egui::RawInput.new(BS_SCREEN, [] of Egui::Event, 0.016))
    ctx.window("w") { |ui| ui.button("go") }
    ctx.end_frame
    cmd = ctx.painter.commands.select(Egui::RectCmd)
      .find { |c| c.stroke_sides }.not_nil!
    cmd.stroke_sides.not_nil!.top.on?.should be_false
    cmd.stroke_sides.not_nil!.bottom.on?.should be_true
  end
end

describe "raster per-side border" do
  it "paints only the sides that are on (CPU mirror of sokol bars)" do
    red = Egui::Color32.rgb(255, 0, 0)
    white = Egui::Color32.rgb(255, 255, 255)
    black = Egui::Color32.rgb(0, 0, 0)
    gray = Egui::Color32.rgb(120, 120, 120)
    # top only, like border-style: solid none none none
    sides = Egui::StrokeSides.new(
      top: Egui::SideStroke.new(2.0, red),
      right: Egui::SideStroke.new(0.0, gray),
      bottom: Egui::SideStroke.new(0.0, gray),
      left: Egui::SideStroke.new(0.0, gray))
    cmd = Egui::RectCmd.new(
      Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 300.0)),
      Egui::Rect.from_min_size(Egui::Pos2.new(10.0, 10.0),
        Egui::Vec2.new(60.0, 30.0)),
      0.0, white, black, 1.0, nil, sides)

    raster = Egui::Capybara::Raster.new(80, 50, Egui::Color32.rgb(0, 255, 0))
    raster.render([cmd])

    px = ->(x : Int32, y : Int32) : Egui::Color32
      do
      i = (y * raster.width + x) * 4
      Egui::Color32.new(raster.pixels[i], raster.pixels[i + 1],
        raster.pixels[i + 2], raster.pixels[i + 3])
    end
    # top band centered on y=10 (width 2 → rows ~9..11) is red-ish
    top = px.call(40, 10)
    top.r.should be > 200
    top.g.should be < 80
    # bottom edge carries no border: the white fill shows through
    bottom = px.call(40, 38)
    bottom.r.should be > 200
    bottom.g.should be > 200
    # left edge likewise
    left = px.call(10, 25)
    left.r.should be > 200
    left.g.should be > 200
  end

  it "keeps a uniform stroke rendering untouched (no sides key)" do
    white = Egui::Color32.rgb(255, 255, 255)
    cmd = Egui::RectCmd.new(
      Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 300.0)),
      Egui::Rect.from_min_size(Egui::Pos2.new(10.0, 10.0),
        Egui::Vec2.new(60.0, 30.0)),
      0.0, white, Egui::Color32.rgb(0, 0, 255), 2.0)

    raster = Egui::Capybara::Raster.new(80, 50, Egui::Color32.rgb(0, 255, 0))
    raster.render([cmd])
    i = (10 * raster.width + 40) * 4 # top band row (edge y=10, width 2)
    raster.pixels[i + 2].should be > 200 # blue stroke present
  end
end
