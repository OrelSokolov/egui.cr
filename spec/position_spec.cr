# CSS `position` specs (Ui#box / ui.div): `absolute`/`fixed` take a
# box out of the flow (cursor and parent bounds untouched) and place
# it from `top/right/bottom/left` offsets against the containing
# block (viewport for `fixed`, the nearest positioned ancestor for
# `absolute`); `relative` shifts the in-flow rect with space still
# reserved; both-offset axes stretch; `%` resolves against the
# containing block; values also cascade from ECSS class rules and the
# div inline `style:`.

require "spec"
require "../src/egui"
require "../src/egui/html"

POSITION_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

def position_frame(ctx : Egui::Context, &app : Egui::Context ->)
  ctx.begin_frame(Egui::RawInput.new(POSITION_SCREEN, [] of Egui::Event, 0.016))
  yield ctx
  ctx.end_frame
end

describe "Ui#box position" do
  it "absolute does not advance the parent flow" do
    ctx = Egui::Context.new
    bx = by = ax = ay = 0.0
    bottom_before = bottom_after = 0.0
    position_frame(ctx) do |c|
      c.window("w") do |ui|
        ui.label("first")
        bx = ui.cursor.x
        by = ui.cursor.y
        bottom_before = ui.min_rect.bottom
        ui.box(position: :absolute, top: 10, left: 10) { |b| b.button("HUD") }
        ax = ui.cursor.x
        ay = ui.cursor.y
        bottom_after = ui.min_rect.bottom
      end
    end
    ax.should eq bx
    ay.should eq by
    bottom_after.should eq bottom_before
  end

  it "fixed places against the viewport, ignoring the window" do
    ctx = Egui::Context.new
    rect = nil
    position_frame(ctx) do |c|
      c.window("w", default_pos: Egui::Pos2.new(300.0, 200.0)) do |ui|
        ui.label("flow")
        rect = ui.box(position: :fixed, top: 10, left: 10) { |b| b.label("hud") }
      end
    end
    r = rect.not_nil!
    r.left.should be_close(10.0, 0.5)
    r.top.should be_close(10.0, 0.5)
  end

  it "absolute uses the nearest positioned ancestor as the containing block" do
    ctx = Egui::Context.new
    origin = inner = nil
    position_frame(ctx) do |c|
      c.window("w") do |ui|
        origin = Egui::Pos2.new(ui.cursor.x, ui.cursor.y)
        ui.box(position: :relative) do |r|
          r.label("flow content")
          inner = r.box(position: :absolute, top: 20, left: 30) { |b| b.label("corner") }
        end
      end
    end
    o = origin.not_nil!
    inner.not_nil!.min.x.should be_close(o.x + 30.0, 0.5)
    inner.not_nil!.min.y.should be_close(o.y + 20.0, 0.5)
  end

  it "both offsets on an axis stretch the box between them" do
    ctx = Egui::Context.new
    rect = nil
    position_frame(ctx) do |c|
      c.window("w") do |ui|
        rect = ui.box(position: :fixed, left: 100, right: 100) { |b| b.label("bar") }
      end
    end
    rect.not_nil!.width.should be_close(600.0, 0.5) # 800 - 100 - 100
  end

  it "percent offsets resolve against the containing block" do
    ctx = Egui::Context.new
    rect = nil
    position_frame(ctx) do |c|
      c.window("w") do |ui|
        rect = ui.box(position: :fixed, top: "50%", left: "25%") { |b| b.label("pct") }
      end
    end
    r = rect.not_nil!
    r.left.should be_close(200.0, 0.5) # 25% of 800
    r.top.should be_close(300.0, 0.5)  # 50% of 600
  end

  it "right alone anchors on the measured size (settles on frame two)" do
    ctx = Egui::Context.new
    rect = nil
    2.times do
      position_frame(ctx) do |c|
        c.window("w") do |ui|
          rect = ui.box(position: :fixed, top: 10, right: 10) { |b| b.button(" corner ") }
        end
      end
    end
    r = rect.not_nil!
    r.right.should be_close(790.0, 0.5) # 800 - 10
    r.top.should be_close(10.0, 0.5)
  end

  it "relative shifts the box but keeps the flow space reserved" do
    plain_flow_top = plain_after = shifted_rect = shifted_after = nil
    ctx = Egui::Context.new
    position_frame(ctx) do |c|
      c.window("w") do |ui|
        ui.box { |b| b.label("one") }
        plain_flow_top = ui.box { |b| b.label("two") }.top
        ui.box { |b| b.label("three") }
        plain_after = Egui::Pos2.new(ui.cursor.x, ui.cursor.y)
      end
    end
    ctx2 = Egui::Context.new
    position_frame(ctx2) do |c|
      c.window("w") do |ui|
        ui.box { |b| b.label("one") }
        shifted_rect = ui.box(position: :relative, top: 40) { |b| b.label("two") }.top
        ui.box { |b| b.label("three") }
        shifted_after = Egui::Pos2.new(ui.cursor.x, ui.cursor.y)
      end
    end
    # The shifted box sits 40px below its flow slot…
    shifted_rect.not_nil!.should be_close(plain_flow_top.not_nil! + 40.0, 0.5)
    # …and the NEXT widget's flow position is unchanged (space stayed
    # reserved — siblings never move).
    shifted_after.not_nil!.y.should be_close(plain_after.not_nil!.y, 0.5)
  end
end

describe "position through styles" do
  it "cascades from an ECSS class rule" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("hud", Egui::StyleVars{
      "position" => "fixed",
      "top"      => 5,
      "left"     => 5,
    })
    rect = nil
    position_frame(ctx) do |c|
      c.window("w") do |ui|
        rect = ui.box(style_class: "hud") { |b| b.label("hud") }
      end
    end
    r = rect.not_nil!
    r.left.should be_close(5.0, 0.5)
    r.top.should be_close(5.0, 0.5)
  end

  it "parses from a div inline style" do
    ctx = Egui::Context.new
    rect = nil
    position_frame(ctx) do |c|
      c.window("w") do |ui|
        rect = ui.div(style: "position: fixed; top: 10; left: 20") { |b| b.label("hud") }
      end
    end
    r = rect.not_nil!
    r.left.should be_close(20.0, 0.5)
    r.top.should be_close(10.0, 0.5)
  end
end
