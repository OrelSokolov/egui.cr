# exml_nav specs — page transitions (velour-components.md, этап 6):
# slot change seeds the spring, offsets slide, pop returns, the
# transition settles without external nudging.

require "spec"
require "../src/egui"

NAV_BOX = [0.0]

def nav_frame(ctx : Egui::Context) : Nil
  NAV_BOX[0] += 1.0 / 60.0
  ctx.begin_frame(Egui::RawInput.new(
    Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(390.0, 844.0)),
    ([] of Egui::Event), NAV_BOX[0]))
end

describe Egui::Exml::Nav do
  it "starts settled on the current slot value" do
    rt = Egui::Exml::Runtime.new
    rt.strings["page"] = "root"
    ctx = Egui::Context.new
    nav = Egui::Exml::Nav.new(rt, slot: "page")
    nav_frame(ctx)
    nav.update(ctx)
    ctx.end_frame
    nav.current.should eq("root")
    nav.transitioning?.should be_false
    nav.offsets(390.0).should eq({0.0, 0.0})
  end

  it "a slot change starts a push: the incoming page slides from the right" do
    rt = Egui::Exml::Runtime.new
    rt.strings["page"] = "root"
    ctx = Egui::Context.new
    nav = Egui::Exml::Nav.new(rt, slot: "page", response: 0.3)
    nav_frame(ctx)
    nav.update(ctx)
    rt.strings["page"] = "wifi" # the nav= write (mid-frame in real use)
    nav.update(ctx)
    ctx.end_frame
    nav.current.should eq("wifi")
    nav.previous.should eq("root")
    nav.direction.push?.should be_true
    nav.transitioning?.should be_true

    win, out = nav.offsets(390.0)
    win.should be > 0.0   # entering from the right
    out.should be < 0.0   # leaving to the left
  end

  it "the transition settles on its own (spring flies, then previous clears)" do
    rt = Egui::Exml::Runtime.new
    rt.strings["page"] = "root"
    ctx = Egui::Context.new
    nav = Egui::Exml::Nav.new(rt, slot: "page", response: 0.3)
    2.times do
      nav_frame(ctx)
      nav.update(ctx)
      ctx.end_frame
    end
    rt.strings["page"] = "wifi"
    nav_frame(ctx)
    nav.update(ctx) # this frame STARTS the transition
    ctx.end_frame
    frames = 0
    while nav.transitioning? && frames < 200
      nav_frame(ctx)
      nav.update(ctx)
      ctx.end_frame
      frames += 1
    end
    nav.transitioning?.should be_false
    frames.should be > 1        # it actually animated, not snapped
    nav.offsets(390.0).should eq({0.0, 0.0})
  end

  it "back to root is a pop: the outgoing page leaves to the right" do
    rt = Egui::Exml::Runtime.new
    rt.strings["page"] = "wifi"
    ctx = Egui::Context.new
    nav = Egui::Exml::Nav.new(rt, slot: "page")
    nav_frame(ctx)
    nav.update(ctx)
    ctx.end_frame
    rt.strings["page"] = "root" # the back= write
    nav_frame(ctx)
    nav.update(ctx)
    ctx.end_frame
    nav.direction.pop?.should be_true
    win, out = nav.offsets(390.0)
    win.should be >= 0.0
    out.should be <= 0.0
  end
end
