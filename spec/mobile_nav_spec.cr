# Mobile screen scaffold (plans/todo/mobile_widgets.md #4–6): the
# bottom nav switches items (callback + changed?), the app bar fires
# back/action callbacks, the FAB clicks and reads its size/shadow/color
# ECSS keys — all headless, same frame-driver as spec/switch_spec.cr.

require "spec"
require "../src/egui"
require "../src/egui/containers/bottom_nav"
require "../src/egui/containers/app_bar"
require "../src/egui/widgets/fab"

MOBILE_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(800.0, 600.0))

def mobile_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
                 time : Float64 = 0.016, &)
  ctx.begin_frame(Egui::RawInput.new(MOBILE_SCREEN, events, time))
  yield ctx
  ctx.end_frame
end

def click_events(at : Egui::Pos2) : Array(Egui::Event)
  [
    Egui::Event.pointer_moved(at),
    Egui::Event.pointer_pressed(at),
    Egui::Event.pointer_released(at),
  ] of Egui::Event
end

describe Egui::BottomNav do
  it "switches the selected item and fires the callback" do
    ctx = Egui::Context.new
    items = ["Home", "Search", "Profile"].map { |l| Egui::BottomNav::Item.new(:check, l) }
    selected = 0
    rect = nil
    mobile_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.bottom_nav(items, selected) { |i| selected = i }
        r.changed?.should be_false
        rect = r.rect
      end
    end
    bar = rect.not_nil!
    at = Egui::Pos2.new(bar.min.x + bar.width / 3.0 * 1.5, bar.center.y)
    mobile_frame(ctx, click_events(at)) do
      ctx.window("demo") do |ui|
        r = ui.bottom_nav(items, selected) { |i| selected = i }
        r.changed?.should be_true
      end
    end
    selected.should eq 1
    # Same state next frame: no re-report.
    mobile_frame(ctx) do
      ctx.window("demo") do |ui|
        ui.bottom_nav(items, selected) { |i| selected = i }.changed?.should be_false
      end
    end
    selected.should eq 1
  end

  it "keeps the item ids stable between frames" do
    ctx = Egui::Context.new
    items = ["A", "B", "C"].map { |l| Egui::BottomNav::Item.new(:plus, l) }
    widget = Egui::BottomNav.new(items)
    mobile_frame(ctx) { ctx.window("demo") { |ui| ui.add(widget) } }
    ids1 = widget.item_ids.dup
    mobile_frame(ctx) { ctx.window("demo") { |ui| ui.add(widget) } }
    widget.item_ids.should eq ids1
  end

  it "refuses fewer than 3 and more than 5 items" do
    one = [Egui::BottomNav::Item.new(:check, "Solo")]
    six = (1..6).map { |i| Egui::BottomNav::Item.new(:check, "n#{i}") }
    expect_raises(ArgumentError) { Egui::BottomNav.new(one) }
    expect_raises(ArgumentError) { Egui::BottomNav.new(six) }
  end

  it "resolves the bottom_nav style keys (height, item/active colors)" do
    ctx = Egui::Context.new
    bar_h = 88.0
    item_red = Egui::Color32.rgb(255, 0, 0)
    active_blue = Egui::Color32.rgb(0, 0, 255)
    pill_green = Egui::Color32.rgb(0, 128, 0)
    ctx.stylesheet.rule("bottom_nav", Egui::StyleVars{
      "height"       => bar_h,
      "item_color"   => item_red,
      "active_color" => active_blue,
    })
    ctx.stylesheet.rule("bottom_nav.item:selected", Egui::StyleVars{
      "background" => pill_green,
    })

    items = ["Home", "Search", "Profile"].map { |l| Egui::BottomNav::Item.new(:check, l) }
    widget = Egui::BottomNav.new(items)
    bar = nil
    mobile_frame(ctx) do
      ctx.window("demo") do |ui|
        bar = ui.add(widget).rect
      end
    end
    bar = bar.not_nil!
    bar.height.should eq bar_h

    # The selected item's icons stroke in the active tint…
    icon = ctx.painter.commands.select(Egui::LineCmd).find do |c|
      c.color == active_blue && bar.contains?(c.p1)
    end
    icon.should_not be_nil
    # …an unselected item's icon in the item tint…
    faded = ctx.painter.commands.select(Egui::LineCmd).find do |c|
      c.color == item_red && bar.contains?(c.p1)
    end
    faded.should_not be_nil
    # …and the :selected pill paints under the active cell.
    pill = ctx.painter.commands.select(Egui::RectCmd).find do |c|
      c.fill == pill_green && bar.contains?(c.rect.center)
    end
    pill.should_not be_nil
  end
end

describe Egui::AppBar do
  it "fires the back callback and reports it" do
    ctx = Egui::Context.new
    backed = false
    rect = nil
    mobile_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.app_bar("Inbox", back: true, on_back: ->{ backed = true; nil })
        rect = r.rect
      end
    end
    at = Egui::Pos2.new(rect.not_nil!.min.x + 20.0, rect.not_nil!.center.y)
    mobile_frame(ctx, click_events(at)) do
      ctx.window("demo") do |ui|
        r = ui.app_bar("Inbox", back: true, on_back: ->{ backed = true; nil })
        r.changed?.should be_true
      end
    end
    backed.should be_true
  end

  it "fires action callbacks with the right index" do
    ctx = Egui::Context.new
    hits = [] of Int32
    rect = nil
    draw = ->do
      mobile_frame(ctx) do
        ctx.window("demo") do |ui|
          r = ui.app_bar("List", id: "acts") do |bar|
            bar.action(:monitor) { hits << 0 }
            bar.action(:plus) { hits << 1 }
          end
          rect = r.rect
        end
      end
    end
    draw.call
    bar = rect.not_nil!
    # Actions sit flush right in declaration order: action 0 is the
    # left 40pt square of the pair, action 1 the innermost-right one.
    at0 = Egui::Pos2.new(bar.max.x - 64.0, bar.center.y)
    at1 = Egui::Pos2.new(bar.max.x - 20.0, bar.center.y)
    mobile_frame(ctx, click_events(at0)) do
      ctx.window("demo") do |ui|
        ui.app_bar("List", id: "acts") do |bar|
          bar.action(:monitor) { hits << 0 }
          bar.action(:plus) { hits << 1 }
        end
      end
    end
    mobile_frame(ctx, click_events(at1)) do
      ctx.window("demo") do |ui|
        ui.app_bar("List", id: "acts") do |bar|
          bar.action(:monitor) { hits << 0 }
          bar.action(:plus) { hits << 1 }
        end
      end
    end
    hits.should eq [0, 1]
  end

  it "lays out at 56pt and refuses a fourth action" do
    ctx = Egui::Context.new
    mobile_frame(ctx) do
      ctx.window("demo") do |ui|
        ui.app_bar("Title").rect.height.should eq 56.0
      end
    end
    bar = Egui::AppBar.new("Title")
    bar.action(:check) { }.action(:close) { }.action(:plus) { }
    expect_raises(ArgumentError) { bar.action(:minus) { } }
  end
end

describe Egui::Fab do
  it "clicks and fires the callback" do
    ctx = Egui::Context.new
    clicked = false
    rect = nil
    mobile_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.fab(:plus, id: "fab") { clicked = true }
        r.changed?.should be_false
        rect = r.rect
      end
    end
    at = rect.not_nil!.center
    mobile_frame(ctx, click_events(at)) do
      ctx.window("demo") do |ui|
        r = ui.fab(:plus, id: "fab") { clicked = true }
        r.changed?.should be_true
      end
    end
    clicked.should be_true
  end

  it "resolves the fab style keys (size, color, shadow)" do
    ctx = Egui::Context.new
    red = Egui::Color32.rgb(255, 0, 0)
    shadow_c = Egui::Color32.rgba(0, 0, 0, 90)
    ctx.stylesheet.rule("fab", Egui::StyleVars{
      "size"         => 64.0,
      "color"        => red,
      "shadow_color" => shadow_c,
      "shadow_blur"  => 8.0,
    })
    rect = nil
    mobile_frame(ctx) do
      ctx.window("demo") do |ui|
        rect = ui.fab(:plus, id: "styled").rect
      end
    end
    rect.not_nil!.width.should eq 64.0
    rect.not_nil!.height.should eq 64.0
    # The button face is the rounded rect painted over the shadow.
    face = ctx.painter.commands.select(Egui::RectCmd).find do |c|
      c.fill == red && c.rect == rect.not_nil!
    end
    face.should_not be_nil
    shadow = ctx.painter.commands.select(Egui::ShadowCmd).find do |c|
      c.color == shadow_c && c.blur == 8.0
    end
    shadow.should_not be_nil
  end

  it "grows into the extended icon+text variant" do
    ctx = Egui::Context.new
    mobile_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.fab(:plus, "New")
        r.rect.height.should eq 56.0
        r.rect.width.should be > 56.0
      end
    end
  end

  it "does not catch clicks that land on its shadow" do
    ctx = Egui::Context.new
    rect = nil
    mobile_frame(ctx) do
      ctx.window("demo") do |ui|
        rect = ui.fab(:plus, id: "shadow_fab").rect
      end
    end
    # 6pt below the button — inside the default 12pt blur, outside the
    # interact rect.
    at = Egui::Pos2.new(rect.not_nil!.center.x, rect.not_nil!.max.y + 6.0)
    mobile_frame(ctx, click_events(at)) do
      ctx.window("demo") do |ui|
        ui.fab(:plus, id: "shadow_fab").changed?.should be_false
      end
    end
  end
end
