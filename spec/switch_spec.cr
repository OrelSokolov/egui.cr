# Mobile Switch (plans/todo/mobile_widgets.md #1): state flips on
# click, geometry/style keys resolve through the `switch` class, and
# the paint animates without pinning the repaint loop.

require "spec"
require "../src/egui"

SWITCH_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

def switch_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
                 time : Float64 = 0.016, &)
  ctx.begin_frame(Egui::RawInput.new(SWITCH_SCREEN, events, time))
  yield ctx
  ctx.end_frame
end

describe Egui::Switch do
  it "reports the flip through Response#changed?" do
    ctx = Egui::Context.new
    checked = false
    rect = nil
    switch_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.switch(checked, id: "sw") { |v| checked = v }
        r.changed?.should be_false
        rect = r.rect
      end
    end
    at = rect.not_nil!.center
    events = [
      Egui::Event.pointer_moved(at),
      Egui::Event.pointer_pressed(at),
      Egui::Event.pointer_released(at),
    ] of Egui::Event
    switch_frame(ctx, events) do
      ctx.window("demo") do |ui|
        r = ui.switch(checked, id: "sw") { |v| checked = v }
        r.changed?.should be_true
      end
    end
    checked.should be_true
    # A second frame with the same (now settled) state: no flip.
    switch_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.switch(checked, id: "sw") { |v| checked = v }
        r.changed?.should be_false
      end
    end
    checked.should be_true
  end

  it "lays out at the Material 52×32 geometry" do
    ctx = Egui::Context.new
    switch_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.switch(false, id: "sw2")
        r.rect.width.should eq 52.0
        r.rect.height.should eq 32.0
      end
    end
  end

  it "resolves the switch class style keys" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("switch", Egui::StyleVars{
      "track_width"  => 64.0,
      "tumbler_size" => 36.0,
    })
    switch_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.switch(false, id: "sw3")
        r.rect.width.should eq 64.0
        r.rect.height.should eq 36.0
      end
    end
  end
end
