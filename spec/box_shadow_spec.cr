# box-shadow specs: the painter command, the `shadow.*` style keys, and
# the Button wiring (outset under the fill, inset over it, states flip
# through the cascade).

require "spec"
require "../src/egui"

SHADOW_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

def shadow_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event, time : Float64 = 0.016)
  raw = Egui::RawInput.new(SHADOW_SCREEN, events, time)
  ctx.begin_frame(raw)
end

describe Egui::Painter do
  it "box_shadow pushes a ShadowCmd with the given geometry" do
    painter = Egui::Painter.new
    rect = Egui::Rect.from_min_size(Egui::Pos2.new(1.0, 2.0), Egui::Vec2.new(30.0, 10.0))
    color = Egui::Color32.rgba(0, 0, 0, 64)
    painter.box_shadow(rect, color, blur: 5.0, rounding: 4.0,
      spread: 1.0, offset: Egui::Vec2.new(0.0, 3.0), inset: true)

    painter.commands.size.should eq 1
    cmd = painter.commands.first.as(Egui::ShadowCmd)
    cmd.rect.should eq rect
    cmd.rounding.should eq 4.0
    cmd.blur.should eq 5.0
    cmd.spread.should eq 1.0
    cmd.offset.should eq Egui::Vec2.new(0.0, 3.0)
    cmd.color.should eq color
    cmd.inset?.should be_true
  end

  it "box_shadow skips shadows with nothing to show" do
    painter = Egui::Painter.new
    rect = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(10.0, 10.0))
    painter.box_shadow(rect, Egui::Color32.rgba(0, 0, 0, 50), blur: 0.0)
    painter.commands.size.should eq 0
  end
end

describe Egui::StyleVars do
  it "shadow? is nil without a color, defaults otherwise" do
    vars = Egui::StyleVars{"shadow.blur" => 6.0}
    vars.shadow?.should be_nil

    vars = Egui::StyleVars{"shadow.color" => Egui::Color32.rgb(1, 2, 3)}
    shadow = vars.shadow?.not_nil!
    shadow.blur.should eq 0.0
    shadow.spread.should eq 0.0
    shadow.offset.should eq Egui::Vec2.new(0.0, 0.0)
    shadow.inset?.should be_false
  end

  it "shadow? reads every key" do
    vars = Egui::StyleVars{
      "shadow.color"  => Egui::Color32.rgb(1, 2, 3),
      "shadow.blur"   => 5,
      "shadow.spread" => 1.5,
      "shadow.x"      => -1.0,
      "shadow.y"      => 3.0,
      "shadow.inset"  => true,
    }
    shadow = vars.shadow?.not_nil!
    shadow.blur.should eq 5.0 # Int32 coerces (CSS vibes)
    shadow.spread.should eq 1.5
    shadow.offset.should eq Egui::Vec2.new(-1.0, 3.0)
    shadow.inset?.should be_true
  end

  it "an :active overlay flips only shadow.inset over the class defaults" do
    sheet = Egui::StyleSheet.new
    sheet.rule("button", Egui::StyleVars{
      "shadow.color" => Egui::Color32.rgb(9, 9, 9),
      "shadow.blur"  => 6.0,
    })
    sheet.rule("button:active", Egui::StyleVars{"shadow.inset" => true})

    base = sheet.resolve("button").shadow?.not_nil!
    base.inset?.should be_false
    base.blur.should eq 6.0

    active = sheet.resolve("button", "active").shadow?.not_nil!
    active.inset?.should be_true
    active.blur.should eq 6.0
    active.color.should eq Egui::Color32.rgb(9, 9, 9)
  end
end

describe "Button box-shadow" do
  it "paints the class outset shadow under the fill, and inset over it when pressed" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("button", Egui::StyleVars{
      "shadow.color" => Egui::Color32.rgba(0, 0, 0, 70),
      "shadow.blur"  => 6.0,
      "shadow.y"     => 2.0,
    })
    ctx.stylesheet.rule("button:active", Egui::StyleVars{
      "shadow.inset" => true,
      "shadow.blur"  => 5.0,
      "shadow.y"     => 3.0,
    })

    center = nil
    shadow_frame(ctx)
    ctx.window("demo") do |ui|
      center = ui.button("Shadowed").rect.center
    end
    ctx.end_frame

    cmds = ctx.painter.commands
    shadows = cmds.select(Egui::ShadowCmd)
    shadows.size.should eq 1
    shadow = shadows.first
    shadow.inset?.should be_false
    shadow.blur.should eq 6.0
    shadow.offset.y.should eq 2.0
    # outset rides UNDER the button's fill rect
    fill_index = cmds.index(cmds.select(Egui::RectCmd).last).not_nil!
    (cmds.index(shadow).not_nil! < fill_index).should be_true

    # press over the button → the :active overlay turns the shadow inset
    shadow_frame(ctx, events: [
      Egui::Event.pointer_moved(center.not_nil!),
      Egui::Event.pointer_pressed(center.not_nil!),
    ], time: 0.032)
    ctx.window("demo") do |ui|
      ui.button("Shadowed").active?.should be_true
    end
    ctx.end_frame

    shadows = ctx.painter.commands.select(Egui::ShadowCmd)
    shadows.size.should eq 1
    shadows.first.inset?.should be_true
    shadows.first.blur.should eq 5.0
  end
end
