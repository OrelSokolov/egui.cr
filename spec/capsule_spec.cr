# Capsule (stadium) rounding specs: the "capsule" rounding keyword in
# the style cascade (`StyleVars#rounding_px`), the `Painter#capsule`
# helper, the ecss bare-keyword parse, and the widget wiring (the
# toggle's rounded-rect knob, the progressbar's capsule fill).

require "spec"
require "../src/egui"

CAPSULE_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

def capsule_frame(ctx : Egui::Context, time : Float64 = 0.016)
  raw = Egui::RawInput.new(CAPSULE_SCREEN, [] of Egui::Event, time)
  ctx.begin_frame(raw)
end

describe Egui::StyleVars do
  it "rounding_px passes numbers through and coerces ints" do
    rect = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(200.0, 20.0))
    Egui::StyleVars{"rounding" => 6.0}.rounding_px("rounding", rect, 4.0).should eq 6.0
    Egui::StyleVars{"rounding" => 6}.rounding_px("rounding", rect, 4.0).should eq 6.0
  end

  it "rounding_px resolves the capsule keyword to half the short side" do
    vars = Egui::StyleVars{"rounding" => "capsule"}
    wide = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(200.0, 20.0))
    tall = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(20.0, 200.0))
    vars.rounding_px("rounding", wide, 4.0).should eq 10.0
    vars.rounding_px("rounding", tall, 4.0).should eq 10.0
  end

  it "rounding_px falls back on unset or unknown values" do
    rect = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(200.0, 20.0))
    Egui::StyleVars.new.rounding_px("rounding", rect, 4.0).should eq 4.0
    Egui::StyleVars{"rounding" => "nope"}.rounding_px("rounding", rect, 4.0).should eq 4.0
    Egui::StyleVars{"rounding" => true}.rounding_px("rounding", rect, 4.0).should eq 4.0
  end
end

describe Egui::Painter do
  it "capsule emits a rect rounded by half the short side" do
    painter = Egui::Painter.new
    rect = Egui::Rect.from_min_size(Egui::Pos2.new(1.0, 2.0), Egui::Vec2.new(54.0, 24.0))
    painter.capsule(rect, Egui::Color32.rgb(255, 255, 255))
    cmd = painter.commands.first.as(Egui::RectCmd)
    cmd.rect.should eq rect
    cmd.rounding.should eq 12.0
  end

  it "clamps an oversized radius to the capsule (CSS 9999px trick)" do
    painter = Egui::Painter.new
    rect = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(40.0, 20.0))
    painter.rect(rect, 9999.0, Egui::Color32.rgb(255, 0, 0))
    painter.commands.first.as(Egui::RectCmd).rounding.should eq 10.0
    # Negative rounding is just square.
    painter.rect(rect, -5.0, Egui::Color32.rgb(255, 0, 0))
    painter.commands[1].as(Egui::RectCmd).rounding.should eq 0.0
  end
end

describe Egui::Ecss do
  it "parses the bare capsule keyword (and keeps quoting families)" do
    doc = Egui::Ecss::Doc.parse(<<-ECSS)
      toggle_button { rounding: capsule; }
      label { font_family: "SF Pro"; }
      ECSS
    bag = doc.classes["toggle_button"].vars
    bag["rounding"].should eq "capsule"
    doc.classes["label"].vars["font_family"].should eq "SF Pro"
  end
end

describe "ToggleButton knob" do
  it "paints the knob as a rounded rect inside a capsule track" do
    ctx = Egui::Context.new
    capsule_frame(ctx)
    ctx.window("demo") do |ui|
      ui.add(Egui::ToggleButton.new(false, id: "t"))
    end
    ctx.end_frame

    cmds = ctx.painter.commands
    cmds.select(Egui::CircleCmd).size.should eq 0 # the knob is no disc
    # Window chrome paints wide rects; the toggle's are the small ones:
    # the capsule fill, the knob's shadow ring, then the knob fill —
    # first vs last.
    small = cmds.select(Egui::RectCmd)
      .reject { |c| c.rect.width > 100.0 }
    track, knob = small.first, small.last
    track.rounding.should eq track.rect.height / 2.0
    # Default knob: square, rounding 9999 clamps to h/2 — reads
    # exactly as the old circle.
    knob.rect.height.should be_close(knob.rect.width, 0.01)
    knob.rounding.should be_close(knob.rect.height / 2.0, 0.01)
    # The knob rides inside the track with the 2px inset.
    knob.rect.height.should be_close(track.rect.height - 4.0, 0.01)
    knob.rect.top.should be_close(track.rect.top + 2.0, 0.01)
  end

  it "takes the macOS geometry from knob_width/knob_rounding rules" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("toggle_button", Egui::StyleVars{
      "sync_with_text" => false,
      "tumbler_size"   => 24.0,
      "track_width"    => 54.0,
      "knob_width"     => 30.0,
      "knob_rounding"  => 7.0,
    })
    capsule_frame(ctx)
    ctx.window("demo") do |ui|
      ui.add(Egui::ToggleButton.new(false, id: "t"))
    end
    ctx.end_frame

    small = ctx.painter.commands.select(Egui::RectCmd)
      .reject { |c| c.rect.width > 100.0 }
    track, knob = small.first, small.last
    track.rect.width.should be_close(54.0, 0.01)
    track.rect.height.should be_close(24.0, 0.01)
    track.rounding.should eq 12.0
    knob.rect.width.should be_close(30.0, 0.01)
    knob.rect.height.should be_close(20.0, 0.01)
    knob.rounding.should eq 7.0
  end
end

describe "ProgressBar capsule" do
  it "caps the fill rounding at its own half-height" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("progressbar", Egui::StyleVars{
      "rounding" => "capsule",
      "height"   => 9.0,
    })
    capsule_frame(ctx)
    ctx.window("demo") do |ui|
      ui.add(Egui::ProgressBar.new(0.5, id: "p"))
    end
    ctx.end_frame

    # Window chrome paints tall rects; the bar's are the short ones.
    track, fill = ctx.painter.commands.select(Egui::RectCmd)
      .reject { |c| c.rect.height > 20.0 }
    track.rounding.should eq track.rect.height / 2.0
    fill.rounding.should eq fill.rect.height / 2.0 # capsule fill end
  end
end
