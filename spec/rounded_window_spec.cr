# RoundedWindow specs: the rounded-window shell — the painted backdrop
# (rounded RectCmd under the content), the binary shape mask geometry
# (straight runs, corner cuts, radius clamping), the shape port calls
# (once per geometry change, not per frame) and the anywhere-drag
# strip. Driven headless, like window_frame_spec.

require "spec"
require "../src/egui"

ROUND_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(640.0, 480.0))

class ShapeRecorder < Egui::SystemPorts::Window::Implementation
  getter shapes = [] of {Int32, Int32}

  def set_shape(mask : Bytes, width : Int32, height : Int32) : Nil
    @shapes << {width, height}
  end
end

class DragRecorder < Egui::SystemPorts::Window::Implementation
  getter drags = 0

  def start_drag : Nil
    @drags += 1
  end
end

def rounded_draw(ctx : Egui::Context, rect : Egui::Rect,
                 radius : Float64 = 12.0, drag : Bool = false,
                 events : Array(Egui::Event) = [] of Egui::Event,
                 time : Float64 = 0.016) : Nil
  ctx.begin_frame(Egui::RawInput.new(ROUND_SCREEN, events, time))
  Egui::RoundedWindow.show(ctx, rect, radius: radius,
    fill: Egui::Color32.new(1, 2, 3, 255), drag: drag) do |ui|
    ui.label("content")
  end
  ctx.end_frame
end

describe Egui::RoundedWindow do
  describe ".rounded_mask" do
    it "covers the body and cuts the corners by the radius" do
      rect = Egui::Rect.from_min_size(Egui::Pos2.new(10.0, 10.0),
        Egui::Vec2.new(100.0, 60.0))
      mask = Egui::RoundedWindow.rounded_mask(120, 80, rect, 10.0)

      inside = ->(x : Int32, y : Int32) { mask[y * 120 + x] == 255 }
      # body center and straight-band edges are in
      inside.call(60, 40).should be_true
      inside.call(15, 40).should be_true   # left edge, mid-height
      inside.call(104, 40).should be_true  # right edge, mid-height
      # corner centers are in, the diagonal just outside is not
      inside.call(20, 20).should be_true
      inside.call(12, 12).should be_false
      # outside the rect entirely is not
      inside.call(5, 40).should be_false
      inside.call(60, 75).should be_false
    end

    it "radius 0 is a plain rectangle" do
      rect = Egui::Rect.from_min_size(Egui::Pos2.new(4.0, 4.0),
        Egui::Vec2.new(50.0, 30.0))
      mask = Egui::RoundedWindow.rounded_mask(60, 40, rect, 0.0)
      mask[20 * 60 + 29].should eq(255) # center
      mask[4 * 60 + 4].should eq(255)   # top-left pixel center is in
      mask[3 * 60 + 29].should eq(0)    # above the rect
    end

    it "clamps an oversized radius to half the shorter side" do
      rect = Egui::Rect.from_min_size(Egui::Pos2.zero,
        Egui::Vec2.new(40.0, 20.0))
      mask = Egui::RoundedWindow.rounded_mask(40, 20, rect, 99.0)
      # r clamped to 10: a full pill — the midline spans edge to edge,
      # the extreme corners are still cut.
      mask[10 * 40 + 1].should eq(255)
      mask[10 * 40 + 38].should eq(255)
      mask[0].should eq(0)
      mask[19 * 40 + 39].should eq(0)
    end
  end

  it "paints a rounded backdrop under the content and yields a Ui" do
    ctx = Egui::Context.new
    rounded_draw(ctx, Egui::Rect.from_min_size(Egui::Pos2.new(40.0, 40.0),
      Egui::Vec2.new(560.0, 400.0)), radius: 14.0)

    backdrop = ctx.painter.commands.select(Egui::RectCmd)
      .find { |c| c.fill == Egui::Color32.new(1, 2, 3, 255) }
    backdrop.should_not be_nil
    backdrop.not_nil!.rect.width.should be > 500.0

    ctx.painter.commands.select(Egui::TextCmd)
      .find { |c| c.text == "content" }.should_not be_nil
  end

  it "applies the window shape once per geometry, not per frame" do
    recorder = ShapeRecorder.new
    Egui::SystemPorts::Window.use(recorder)

    ctx = Egui::Context.new
    rect = Egui::Rect.from_min_size(Egui::Pos2.new(40.0, 36.0),
      Egui::Vec2.new(560.0, 300.0))
    rounded_draw(ctx, rect, time: 0.016)
    rounded_draw(ctx, rect, time: 0.032) # same geometry → no new shape
    recorder.shapes.should eq([{640, 480}])

    # a radius change (or a rect change) reapplies the shape
    rounded_draw(ctx, rect, radius: 20.0, time: 0.048)
    recorder.shapes.size.should eq(2)
  end

  it "drag anywhere in the rect hands the move to the native loop" do
    recorder = DragRecorder.new
    Egui::SystemPorts::Window.use(recorder)

    ctx = Egui::Context.new
    rect = Egui::Rect.from_min_size(Egui::Pos2.new(40.0, 36.0),
      Egui::Vec2.new(560.0, 300.0))
    center = Egui::Pos2.new(300.0, 180.0)
    rounded_draw(ctx, rect, drag: true, time: 0.016) # register the strip
    rounded_draw(ctx, rect, drag: true,
      events: [Egui::Event.pointer_pressed(center),
        Egui::Event.pointer_moved(center + Egui::Vec2.new(12.0, 0.0))],
      time: 0.032)
    recorder.drags.should eq(1)
  end

  it "clamps the card into the screen" do
    ctx = Egui::Context.new
    overflowing = Egui::Rect.from_min_size(Egui::Pos2.new(-40.0, -40.0),
      Egui::Vec2.new(560.0, 400.0))
    card = Egui::RoundedWindow.new(ctx, overflowing, 12.0).rect
    card.left.should eq(0.0)
    card.top.should eq(0.0)
    card.width.should be <= 640.0
  end
end
