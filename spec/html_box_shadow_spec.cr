require "spec"
require "../src/egui/html"

SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 300.0))

describe "box-shadow vocabulary" do
  it "Html.shadow parses the CSS shorthand" do
    s = Egui::Html.shadow("0 4px 12px rgba(0,0,0,.5)").not_nil!
    s.color.a.should eq 128
    s.blur.should eq 12.0
    s.offset.y.should eq 4.0
    s.inset?.should be_false
    i = Egui::Html.shadow("inset 0 2px 8px #10203040").not_nil!
    i.inset?.should be_true
    i.color.r.should eq 0x10
    i.blur.should eq 8.0
    Egui::Html.shadow("none").should be_nil
    Egui::Html.shadow("bogus").should be_nil
  end

  it "div style: box-shadow emits a ShadowCmd under the fill" do
    ctx = Egui::Context.new
    raw = Egui::RawInput.new(SCREEN, [] of Egui::Event, 0.016)
    ctx.begin_frame(raw)
    ctx.central_panel do |ui|
      ui.div(style: "background: #26262d; border-radius: 8; box-shadow: 0 4px 12px rgba(0,0,0,.5)") do |d|
        d.p("floating")
      end
    end
    ctx.end_frame
    cmds = ctx.painter.commands
    shas = cmds.select(Egui::ShadowCmd)
    shas.size.should eq 1
    shas.first.blur.should eq 12.0
    shas.first.inset?.should be_false
    # order: shadow UNDER the fill rect
    i_sha = cmds.index(shas.first).not_nil!
    fill = cmds.select(Egui::RectCmd).index(&.fill.== Egui::Color32.rgb(0x26, 0x26, 0x2d)).not_nil!
    i_fill = cmds.index(cmds.select(Egui::RectCmd)[fill]).not_nil!
    i_sha.should be < i_fill
  end

  it "div style: inset shadow paints over the fill" do
    ctx = Egui::Context.new
    raw = Egui::RawInput.new(SCREEN, [] of Egui::Event, 0.016)
    ctx.begin_frame(raw)
    ctx.central_panel do |ui|
      ui.div(style: "background: #1e1e24; box-shadow: inset 0 2px 8px rgba(0,0,0,.6)") do |d|
        d.p("well")
      end
    end
    ctx.end_frame
    cmds = ctx.painter.commands
    shas = cmds.select(Egui::ShadowCmd)
    shas.size.should eq 1
    shas.first.inset?.should be_true
    i_sha = cmds.index(shas.first).not_nil!
    rects = cmds.select(Egui::RectCmd)
    i_fill = cmds.index(rects.find { |r| r.fill == Egui::Color32.rgb(0x1e, 0x1e, 0x24) }.not_nil!).not_nil!
    i_sha.should be > i_fill
  end

  it "ECSS shadow.* keys on a box class chain" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("floaty", Egui::StyleVars{
      "shadow.color" => Egui::Color32.rgba(0, 0, 0, 128),
      "shadow.blur"  => 12.0,
      "shadow.y"     => 4.0,
    })
    raw = Egui::RawInput.new(SCREEN, [] of Egui::Event, 0.016)
    ctx.begin_frame(raw)
    ctx.central_panel do |ui|
      ui.div(classes: "floaty") { |d| d.p("x") }
    end
    ctx.end_frame
    shas = ctx.painter.commands.select(Egui::ShadowCmd)
    shas.size.should eq 1
    shas.first.blur.should eq 12.0
    shas.first.offset.y.should eq 4.0
  end
end
