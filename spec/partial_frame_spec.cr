# Partial-frame work (plans/FPS_OPTIMIZATION.md §2/§5): the multi-run
# galley cache, the whole-subtree retained paint for data-driven
# flexes, per-frame damage/rebuild telemetry and the Slider cache key.

require "spec"
require "../src/egui"

PARTIAL_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(400.0, 300.0))

# Counts how many times #ui actually ran (cache hits skip it).
class CallsCountingButton < Egui::Button
  property calls = 0

  def ui(ui : Egui::Ui) : Egui::Response
    @calls += 1
    super
  end
end

describe "partial frame" do
  it "caches a multi-run galley (fresh equal runs hit the same galley)" do
    ctx = Egui::Context.new
    runs = ->{
      [Egui::TextRun.new("hello ", 14.0),
       Egui::TextRun.new("world", 14.0, Egui::Color32.rgb(255, 0, 0))]
    }
    g1 = ctx.fonts.layout(runs.call, 300.0)
    # A fresh-but-equal run array (the immediate-mode reality: apps
    # rebuild run arrays every frame) hits the same entry.
    g2 = ctx.fonts.layout(runs.call, 300.0)
    g2.should be(g1)
    # Any run's baked style changes → a different galley.
    g3 = ctx.fonts.layout([Egui::TextRun.new("hello ", 14.0),
      Egui::TextRun.new("world", 14.0, Egui::Color32.rgb(0, 0, 255))], 300.0)
    g3.should_not be(g1)
    # So does the wrap width.
    ctx.fonts.layout(runs.call, 250.0).should_not be(g1)
  end

  it "replays a whole data-driven flex without running its children" do
    ctx = Egui::Context.new
    btns = [CallsCountingButton.new("one"),
            CallsCountingButton.new("two"),
            CallsCountingButton.new("three")]
    btns[1].calls = 0

    draw = ->(time : Float64) do
      raw = Egui::RawInput.new(PARTIAL_SCREEN, [] of Egui::Event, time)
      ctx.begin_frame(raw)
      ctx.central_panel do |ui|
        ui.flex do |f|
          btns.each { |b| f.add(b) }
        end
      end
      ctx.end_frame
    end

    draw.call(0.016)
    total = btns.sum(&.calls)
    total.should be > 0 # the capture frame ran the children
    frame1 = ctx.painter.commands_in_layer_order.dup
    draw.call(0.032)
    btns.sum(&.calls).should eq total # the subtree hit: nothing re-ran
    ctx.painter.commands_in_layer_order.size.should eq frame1.size
  end

  it "re-runs the flex subtree when a child's content changes" do
    ctx = Egui::Context.new
    text = "one"
    texts = nil
    draw = ->(time : Float64) do
      raw = Egui::RawInput.new(PARTIAL_SCREEN, [] of Egui::Event, time)
      ctx.begin_frame(raw)
      ctx.central_panel do |ui|
        ui.flex do |f|
          f.add(Egui::Label.new(text, userselect: false))
          f.add(Egui::Label.new("two", userselect: false))
        end
      end
      ctx.end_frame
      texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    end
    draw.call(0.016)
    draw.call(0.032) # settle the subtree entry
    texts.not_nil!.should contain("one")
    text = "CHANGED"
    draw.call(0.048)
    # The label wrapped into rows inside the narrow cell — the joined
    # row text spells the new content, and the old one is gone.
    joined = texts.not_nil!.join
    joined.should contain("CHANGED")
    joined.should_not contain("one")
  end

  it "keeps hit-testing alive on subtree-replayed frames" do
    ctx = Egui::Context.new
    rect = nil
    step = ->(events : Array(Egui::Event), time : Float64) do
      raw = Egui::RawInput.new(PARTIAL_SCREEN, events, time)
      ctx.begin_frame(raw)
      ctx.central_panel do |ui|
        resp = nil
        ui.flex do |f|
          f.add(CallsCountingButton.new("hit"))
        end
        rect = ctx.memory.widget_rects.values.first?
      end
      ctx.end_frame
    end
    step.call([] of Egui::Event, 0.016)
    step.call([] of Egui::Event, 0.032) # subtree hit frame
    center = rect.not_nil!.center
    # The replayed interact registration answers hover: the next
    # frame's mirror state must report the child as hovered.
    step.call([Egui::Event.pointer_moved(center)], 0.048)
    id = ctx.memory.widget_rects.keys.first
    ctx.memory.interaction_state(id).should eq("hover")
  end

  it "reports per-frame damage (stationary frame = no damage)" do
    ctx = Egui::Context.new
    step = ->(events : Array(Egui::Event), time : Float64) do
      raw = Egui::RawInput.new(PARTIAL_SCREEN, events, time)
      ctx.begin_frame(raw)
      ctx.central_panel do |ui|
        ui.add(Egui::Button.new("OK"))
      end
      ctx.end_frame
    end
    step.call([] of Egui::Event, 0.016)
    # First frame: everything captured — the misses mark the damage.
    ctx.frame_damage.should_not be_nil
    ctx.frame_rebuilt.should be > 0
    step.call([] of Egui::Event, 0.032)
    # Stationary frame: full replay, nothing changed.
    ctx.frame_damage.should be_nil
    ctx.frame_rebuilt.should eq 0
    ctx.frame_replayed.should be > 0
  end

  it "bounds the damage to the changed widget on a hover frame" do
    ctx = Egui::Context.new
    btn_rect = nil
    step = ->(events : Array(Egui::Event), time : Float64) do
      raw = Egui::RawInput.new(PARTIAL_SCREEN, events, time)
      ctx.begin_frame(raw)
      ctx.central_panel do |ui|
        btn_rect = ui.add(Egui::Button.new("OK")).rect
      end
      ctx.end_frame
    end
    step.call([] of Egui::Event, 0.016)
    step.call([] of Egui::Event, 0.032) # settle (damage nil)
    step.call([Egui::Event.pointer_moved(btn_rect.not_nil!.center)], 0.048)
    damage = ctx.frame_damage.should_not be_nil
    # The only key that changed is the hovered button's — the damage
    # region covers its rect and stays small.
    damage.contains?(btn_rect.not_nil!.center).should be_true
    damage.width.should be < 200.0
    ctx.frame_rebuilt.should eq 1
  end

  it "caches a stationary slider and rebuilds on value change" do
    ctx = Egui::Context.new
    value = 3.0
    texts = nil
    step = ->(time : Float64) do
      raw = Egui::RawInput.new(PARTIAL_SCREEN, [] of Egui::Event, time)
      ctx.begin_frame(raw)
      ctx.central_panel do |ui|
        resp = ui.add(Egui::Slider.new(value, 0.0..10.0, "vol"))
        value = resp.widget_value.not_nil!
      end
      ctx.end_frame
      texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    end
    step.call(0.016)
    step.call(0.032) # replayed from the cache
    texts.not_nil!.any?(&.includes?("3.0")).should be_true
    value = 7.0
    step.call(0.048)
    texts.not_nil!.any?(&.includes?("7.0")).should be_true
  end
end
