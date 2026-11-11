# Retained paint cache (plans/FPS_OPTIMIZATION.md §1, stage 2):
# a cached widget replays instead of running — paint output and
# interaction semantics must be identical to the uncached path.
require "spec"
require "../src/egui"

# Counts how many times #ui actually ran (a cache hit skips it).
class PaintCountingButton < Egui::Button
  property calls = 0

  def ui(ui : Egui::Ui) : Egui::Response
    @calls += 1
    super
  end
end

describe "paint cache" do
  it "replays a stationary button instead of running it" do
    ctx = Egui::Context.new
    btn = PaintCountingButton.new("OK")

    draw = ->(time : Float64) do
      raw = Egui::RawInput.new(
        Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(300.0, 300.0)),
        [] of Egui::Event, time)
      ctx.begin_frame(raw)
      ctx.central_panel do |ui|
        ui.add(btn)
      end
      ctx.end_frame
    end

    draw.call(0.016)
    btn.calls.should eq 1
    frame1 = ctx.painter.commands_in_layer_order.dup
    btn_rect1 = ctx.memory.widget_rects.values.first.dup
    draw.call(0.032)
    btn.calls.should eq 1 # second frame replayed, #ui never ran
    frame2 = ctx.painter.commands_in_layer_order.dup
    btn_rect2 = ctx.memory.widget_rects.values.first.dup

    # Second frame: the button was captured; interaction geometry
    # (re-registered via the replay path) and paint output identical.
    ctx.paint_cache.size.should be > 0
    btn_rect2.should eq btn_rect1
    frame2.size.should eq frame1.size
    frame2.zip(frame1).each do |a, b|
      a.class.should eq b.class
    end
  end

  it "rebuilds when the content changes (key miss)" do
    ctx = Egui::Context.new
    text = "AAAA"
    draw = ->(time : Float64) do
      raw = Egui::RawInput.new(
        Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(300.0, 300.0)),
        [] of Egui::Event, time)
      ctx.begin_frame(raw)
      ctx.central_panel do |ui|
        ui.add(Egui::Button.new(text))
      end
      ctx.end_frame
    end
    draw.call(0.016)
    draw.call(0.032)
    texts = ->{ ctx.painter.commands_in_layer_order
      .select(Egui::TextCmd).map(&.text) }
    texts.call.should contain("AAAA")
    text = "BBBB"
    draw.call(0.048)
    texts.call.should contain("BBBB")
    texts.call.should_not contain("AAAA")
  end

  it "keeps click and hover semantics on cached frames" do
    ctx = Egui::Context.new
    clicked = 0
    btn_rect = nil
    clicked_btn = nil

    step = ->(events : Array(Egui::Event), time : Float64) do
      raw = Egui::RawInput.new(
        Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(300.0, 300.0)),
        events, time)
      ctx.begin_frame(raw)
      ctx.central_panel do |ui|
        btn_rect = ui.add(Egui::Button.new("OK")).rect
      end
      ctx.end_frame
    end

    step.call([] of Egui::Event, 0.016) # capture
    step.call([] of Egui::Event, 0.032) # replay (stationary)

    center = btn_rect.not_nil!.center
    # Hover over the replayed button: state changes the key → the
    # hover fill rebuilds; the verdict itself comes from the replayed
    # interact registration and must be live.
    step.call([Egui::Event.pointer_moved(center)] of Egui::Event, 0.048)
    step.call([Egui::Event.pointer_pressed(center)] of Egui::Event, 0.064)
    resp = nil
    raw = Egui::RawInput.new(
      Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(300.0, 300.0)),
      [Egui::Event.pointer_released(center)] of Egui::Event, 0.080)
    ctx.begin_frame(raw)
    ctx.central_panel do |ui|
      resp = ui.add(Egui::Button.new("OK"))
      clicked += 1 if resp.not_nil!.clicked?
    end
    ctx.end_frame
    clicked.should eq 1
    resp.not_nil!.rect.should eq btn_rect.not_nil!
  end

  it "clears on theme swap" do
    ctx = Egui::Context.new
    draw = ->(time : Float64) do
      raw = Egui::RawInput.new(
        Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(300.0, 300.0)),
        [] of Egui::Event, time)
      ctx.begin_frame(raw)
      ctx.central_panel do |ui|
        ui.add(Egui::Button.new("OK"))
      end
      ctx.end_frame
    end
    draw.call(0.016)
    ctx.paint_cache.size.should be > 0
    ctx.theme = Egui::Theme.light
    ctx.paint_cache.size.should eq 0
  end

  it "translates the replayed paint when the widget moved" do
    ctx = Egui::Context.new
    spacer_h = 10.0
    btn_rect = nil

    draw = ->(time : Float64) do
      raw = Egui::RawInput.new(
        Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(300.0, 300.0)),
        [] of Egui::Event, time)
      ctx.begin_frame(raw)
      ctx.central_panel do |ui|
        ui.allocate_space(Egui::Vec2.new(0.0, spacer_h))
        btn_rect = ui.add(Egui::Button.new("OK")).rect
      end
      ctx.end_frame
    end

    draw.call(0.016)
    top1 = btn_rect.not_nil!.min.y
    spacer_h = 42.0 # same button key, different position → translated replay
    draw.call(0.032)
    btn_rect.not_nil!.min.y.should be_close(top1 + 32.0, 0.5)

    # The painted background follows the widget rect exactly.
    rects = ctx.painter.commands_in_layer_order
      .select(Egui::RectCmd).select(&.fill)
    rects.any? { |r| (r.rect.min.y - (top1 + 32.0)).abs < 0.5 }.should be_true
    # ... and nothing was painted at the stale position.
    rects.any? { |r| (r.rect.min.y - top1).abs < 0.5 &&
                     r.rect.width > 20.0 }.should be_false
  end
end
