# Mobile system widgets (plans/todo/mobile_widgets.md Phase 7):
# Tooltip — nothing before the delay, the bubble after it (hover on a
# mouse, long-press on touch), gone when the trigger drops; SafeArea —
# the block's children lay out inset by the given insets and the
# parent flow continues past content + padding.

require "spec"
require "../src/egui"
require "../src/egui/widgets/tooltip"
require "../src/egui/containers/safe_area"

TOOLTIP_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

def sys_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
              time : Float64 = 0.016, &)
  ctx.begin_frame(Egui::RawInput.new(TOOLTIP_SCREEN, events, time))
  yield ctx
  ctx.end_frame
end

def tip_texts(ctx : Egui::Context) : Array(String)
  ctx.painter.commands.select(Egui::TextCmd).map(&.text)
end

def bubble_rects(ctx : Egui::Context) : Array(Egui::Rect)
  ctx.painter.commands.select(Egui::RectCmd)
    .select { |c| c.fill == Egui::Tooltip::DEFAULT_BACKGROUND }
    .map(&.rect)
end

describe Egui::Tooltip do
  it "does not show before the hover delay, shows after it" do
    ctx = Egui::Context.new
    rect = nil
    sys_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.tooltip("tt", "Saves the document") { |u| u.button("Save") }
        rect = r.rect
      end
    end
    # The returned Response is the body's: same rect as the button.
    at = rect.not_nil!.center

    # Arm frame (pointer arrives), then part-way through the 0.7 s
    # countdown: still nothing.
    sys_frame(ctx, [Egui::Event.pointer_moved(at)], 0.016) do
      ctx.window("demo") do |ui|
        ui.tooltip("tt", "Saves the document") { |u| u.button("Save") }
      end
    end
    tip_texts(ctx).should_not contain("Saves the document")

    sys_frame(ctx, [] of Egui::Event, 0.5) do
      ctx.window("demo") do |ui|
        ui.tooltip("tt", "Saves the document") { |u| u.button("Save") }
      end
    end
    tip_texts(ctx).should_not contain("Saves the document")

    # Past the delay the bubble is up, near the widget (below it).
    sys_frame(ctx, [] of Egui::Event, 0.75) do
      ctx.window("demo") do |ui|
        ui.tooltip("tt", "Saves the document") { |u| u.button("Save") }
      end
    end
    tip_texts(ctx).should contain("Saves the document")
    bubbles = bubble_rects(ctx)
    bubbles.size.should eq 1
    bubble = bubbles.first
    bubble.min.y.should be > rect.not_nil!.bottom
    # Clamped inside the screen region.
    bubble.min.x.should be >= TOOLTIP_SCREEN.min.x
    bubble.max.x.should be <= TOOLTIP_SCREEN.max.x
    bubble.max.y.should be <= TOOLTIP_SCREEN.max.y

    # Pointer leaves: the bubble goes away (and stays away).
    sys_frame(ctx, [Egui::Event.pointer_moved(Egui::Pos2.new(5.0, 5.0))],
      0.8) do
      ctx.window("demo") do |ui|
        ui.tooltip("tt", "Saves the document") { |u| u.button("Save") }
      end
    end
    tip_texts(ctx).should_not contain("Saves the document")
  end

  it "honors an explicit delay override" do
    ctx = Egui::Context.new
    at = nil
    sys_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.tooltip("fast", "Quick tip", delay: 0.1) { |u| u.button("Q") }
        at = r.rect.center
      end
    end
    sys_frame(ctx, [Egui::Event.pointer_moved(at.not_nil!)], 0.016) do
      ctx.window("demo") do |ui|
        ui.tooltip("fast", "Quick tip", delay: 0.1) { |u| u.button("Q") }
      end
    end
    tip_texts(ctx).should_not contain("Quick tip")
    sys_frame(ctx, [] of Egui::Event, 0.15) do
      ctx.window("demo") do |ui|
        ui.tooltip("fast", "Quick tip", delay: 0.1) { |u| u.button("Q") }
      end
    end
    tip_texts(ctx).should contain("Quick tip")
  end

  it "shows on touch long-press and hides on release" do
    ctx = Egui::Context.new
    at = nil
    sys_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.tooltip("lp", "Held down") { |u| u.button("Press") }
        at = r.rect.center
      end
    end
    # Touch events flip pointer_coarse automatically (begin_frame
    # latches it from the touch_pointer flag) — the long-press branch
    # with the shorter 0.5 s delay is what runs below.
    press = [
      Egui::Event.pointer_moved(at.not_nil!, from_touch: true),
      Egui::Event.pointer_pressed(at.not_nil!, from_touch: true),
    ] of Egui::Event
    sys_frame(ctx, press, 0.016) do
      ctx.window("demo") do |ui|
        ui.tooltip("lp", "Held down") { |u| u.button("Press") }
      end
    end
    tip_texts(ctx).should_not contain("Held down")

    # Held but short of 0.5 s.
    sys_frame(ctx, [] of Egui::Event, 0.3) do
      ctx.window("demo") do |ui|
        ui.tooltip("lp", "Held down") { |u| u.button("Press") }
      end
    end
    tip_texts(ctx).should_not contain("Held down")

    # Long enough: the bubble is up while the finger stays down
    # (no events — the press state latches across frames).
    sys_frame(ctx, [] of Egui::Event, 0.55) do
      ctx.window("demo") do |ui|
        ui.tooltip("lp", "Held down") { |u| u.button("Press") }
      end
    end
    tip_texts(ctx).should contain("Held down")

    # Finger lifts: gone again.
    sys_frame(ctx, [Egui::Event.pointer_released(at.not_nil!, from_touch: true)],
      0.6) do
      ctx.window("demo") do |ui|
        ui.tooltip("lp", "Held down") { |u| u.button("Press") }
      end
    end
    tip_texts(ctx).should_not contain("Held down")
  end

  it "reads the delay from the tooltip class ECSS rule" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("tooltip", Egui::StyleVars{"delay" => 0.2})
    at = nil
    sys_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.tooltip("css", "Styled delay") { |u| u.button("C") }
        at = r.rect.center
      end
    end
    sys_frame(ctx, [Egui::Event.pointer_moved(at.not_nil!)], 0.016) do
      ctx.window("demo") do |ui|
        ui.tooltip("css", "Styled delay") { |u| u.button("C") }
      end
    end
    sys_frame(ctx, [] of Egui::Event, 0.1) do
      ctx.window("demo") do |ui|
        ui.tooltip("css", "Styled delay") { |u| u.button("C") }
      end
    end
    tip_texts(ctx).should_not contain("Styled delay")
    sys_frame(ctx, [] of Egui::Event, 0.25) do
      ctx.window("demo") do |ui|
        ui.tooltip("css", "Styled delay") { |u| u.button("C") }
      end
    end
    tip_texts(ctx).should contain("Styled delay")
  end

  it "paints the bubble in the class background color" do
    ctx = Egui::Context.new
    red = Egui::Color32.rgb(200, 10, 10)
    ctx.stylesheet.rule("tooltip", Egui::StyleVars{"background" => red})
    at = nil
    sys_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.tooltip("bg", "Red bubble") { |u| u.button("R") }
        at = r.rect.center
      end
    end
    sys_frame(ctx, [Egui::Event.pointer_moved(at.not_nil!)], 0.016) do
      ctx.window("demo") do |ui|
        ui.tooltip("bg", "Red bubble") { |u| u.button("R") }
      end
    end
    sys_frame(ctx, [] of Egui::Event, 0.75) do
      ctx.window("demo") do |ui|
        ui.tooltip("bg", "Red bubble") { |u| u.button("R") }
      end
    end
    ctx.painter.commands.select(Egui::RectCmd)
      .any? { |c| c.fill == red }.should be_true
  end

  it "clamps the bubble inside the region at the screen edge" do
    ctx = Egui::Context.new
    at = nil
    # Park the body flush against the region's right edge: an unclamped
    # centered bubble would run off the screen. Every frame must build
    # the SAME layout, so the shift is part of the shared block below.
    park = ->(ui : Egui::Ui) do
      ui.cursor = Egui::Pos2.new(ui.max_rect.right - 46.0, ui.cursor.y + 40.0)
    end
    sys_frame(ctx) do
      ctx.window("demo") do |ui|
        park.call(ui)
        r = ui.tooltip("edge", "Way out right") { |u| u.button("Go") }
        at = r.rect.center
      end
    end
    sys_frame(ctx, [Egui::Event.pointer_moved(at.not_nil!)], 0.016) do
      ctx.window("demo") do |ui|
        park.call(ui)
        ui.tooltip("edge", "Way out right") { |u| u.button("Go") }
      end
    end
    sys_frame(ctx, [] of Egui::Event, 0.75) do
      ctx.window("demo") do |ui|
        park.call(ui)
        ui.tooltip("edge", "Way out right") { |u| u.button("Go") }
      end
    end
    bubbles = bubble_rects(ctx)
    bubbles.size.should eq 1
    bubbles.first.max.x.should be <= TOOLTIP_SCREEN.max.x
  end
end

describe Egui::SafeAreaContainer do
  it "pads the children rect by the given insets" do
    ctx = Egui::Context.new
    inner_max = nil
    btn = nil
    flow_after = 0.0
    exp_left = 0.0
    exp_top = 0.0
    exp_right = 0.0
    exp_flow = 0.0
    sys_frame(ctx) do
      ctx.window("demo") do |ui|
        cur = ui.cursor
        mr = ui.max_rect
        ui.safe_area(top: 10.0, bottom: 20.0, left: 5.0, right: 7.0,
          id: "sa") do |inner|
          inner_max = inner.max_rect
          btn = inner.button("B").rect
        end
        spacing = ui.style.spacing.item_spacing.y
        exp_left = cur.x + 5.0
        exp_top = cur.y + 10.0
        exp_right = mr.right - 7.0
        exp_flow = btn.not_nil!.bottom + 20.0 + spacing
        flow_after = ui.cursor.y
      end
    end
    im = inner_max.not_nil!
    b = btn.not_nil!
    # The child region starts left+top-inset from where the flow was.
    im.min.x.should eq exp_left
    im.min.y.should eq exp_top
    # ...and ends right-inset before the region's far edge.
    im.max.x.should eq exp_right
    # The first child lays out exactly at the padded origin.
    b.min.x.should eq im.min.x
    b.min.y.should eq im.min.y
    # The flow continues below content + bottom inset (+ item spacing).
    flow_after.should eq exp_flow
  end

  it "defaults to zero insets (a pass-through)" do
    ctx = Egui::Context.new
    inner_max = nil
    cur = Egui::Pos2.zero
    right = 0.0
    bottom = 0.0
    sys_frame(ctx) do
      ctx.window("demo") do |ui|
        cur = ui.cursor
        right = ui.max_rect.right
        bottom = ui.max_rect.bottom
        ui.safe_area(id: "sa0") do |inner|
          inner_max = inner.max_rect
        end
      end
    end
    im = inner_max.not_nil!
    im.min.x.should eq cur.x
    im.min.y.should eq cur.y
    im.max.x.should eq right
    im.max.y.should eq bottom
  end

  it "reads the insets from the safe_area class ECSS rule" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("safe_area",
      Egui::StyleVars{"inset_top" => 12.0, "inset_left" => 9.0})
    inner_min = Egui::Pos2.zero
    exp_left = 0.0
    exp_top = 0.0
    sys_frame(ctx) do
      ctx.window("demo") do |ui|
        cur = ui.cursor
        exp_left = cur.x + 9.0
        exp_top = cur.y + 12.0
        ui.safe_area(id: "sacss") do |inner|
          inner_min = inner.max_rect.min
        end
      end
    end
    inner_min.x.should eq exp_left
    inner_min.y.should eq exp_top
  end
end
