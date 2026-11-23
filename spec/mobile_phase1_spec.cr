# Phase 1 stragglers of plans/todo/mobile_widgets.md: Snackbar (#2)
# paints nothing while invisible, bar+action geometry while visible,
# tap fires the action; ListTile (#3) floors, click reporting, and
# the trailing-block strip staying individually tappable.

require "spec"
require "../src/egui"
require "../src/egui/widgets/snackbar"
require "../src/egui/widgets/list_tile"

MOB_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 700.0))

def mob_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
              time : Float64 = 0.016, &)
  ctx.begin_frame(Egui::RawInput.new(MOB_SCREEN, events, time))
  yield ctx
  ctx.end_frame
end

describe Egui::Snackbar do
  it "reserves nothing while invisible" do
    ctx = Egui::Context.new
    mob_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.add(Egui::Snackbar.new("hi", visible: false, id: "sn"))
        r.rect.should eq Egui::Rect.zero
      end
    end
  end

  it "lays out a full-width 48pt bar when visible" do
    ctx = Egui::Context.new
    rect = nil
    mob_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.add(Egui::Snackbar.new("Saved", id: "sn2"))
        rect = r.rect
      end
    end
    rect.not_nil!.height.should eq 48.0
    rect.not_nil!.width.should be > 48.0
  end

  it "fires the action on tap" do
    ctx = Egui::Context.new
    rect = nil
    mob_frame(ctx) do
      ctx.window("demo") do |ui|
        rect = ui.add(Egui::Snackbar.new("Deleted", action_text: "UNDO",
          id: "sn3")).rect
      end
    end
    at = rect.not_nil!.center
    events = [
      Egui::Event.pointer_moved(at),
      Egui::Event.pointer_pressed(at),
      Egui::Event.pointer_released(at),
    ] of Egui::Event
    fired = false
    mob_frame(ctx, events) do
      ctx.window("demo") do |ui|
        r = ui.add(Egui::Snackbar.new("Deleted", action_text: "UNDO",
          id: "sn3"))
        r.changed?.should be_true
      end
    end
    fired.should be_false # block-based sugar is covered via ui.snackbar
  end

  it "ui.snackbar pins an overlay and fires the action block" do
    ctx = Egui::Context.new
    bar_rect = nil
    mob_frame(ctx) do
      ctx.window("demo") do |ui|
        ui.snackbar("toast", "Saved", true, action_text: "UNDO") { }
        bar_rect = ctx.memory.widget_rects[Egui::Id.from("toast")]?
      end
    end
    bar_rect.should_not be_nil
    at = bar_rect.not_nil!.center
    events = [
      Egui::Event.pointer_moved(at),
      Egui::Event.pointer_pressed(at),
      Egui::Event.pointer_released(at),
    ] of Egui::Event
    fired = false
    mob_frame(ctx, events) do
      ctx.window("demo") do |ui|
        ui.snackbar("toast", "Saved", true, action_text: "UNDO") { fired = true }
      end
    end
    fired.should be_true
  end
end

describe Egui::ListTile do
  it "floors at 48 text-only / 56 with subtitle" do
    ctx = Egui::Context.new
    mob_frame(ctx) do
      ctx.window("demo") do |ui|
        ui.list_tile("Just title", id: "lt1").rect.height.should eq 48.0
        ui.list_tile("With sub", subtitle: "details", id: "lt2")
          .rect.height.should eq 56.0
        ui.list_tile("With icon", leading_icon: :wifi, id: "lt3")
          .rect.height.should eq 56.0
      end
    end
  end

  it "fills the available width and reports row taps" do
    ctx = Egui::Context.new
    rect = nil
    avail = 0.0
    mob_frame(ctx) do
      ctx.window("demo") do |ui|
        avail = ui.available_width
        rect = ui.list_tile("Tap me", id: "lt4").rect
      end
    end
    rect.not_nil!.width.should eq avail
    at = rect.not_nil!.center
    events = [
      Egui::Event.pointer_moved(at),
      Egui::Event.pointer_pressed(at),
      Egui::Event.pointer_released(at),
    ] of Egui::Event
    tapped = false
    mob_frame(ctx, events) do
      ctx.window("demo") do |ui|
        r = ui.list_tile("Tap me", id: "lt4")
        r.changed?.should be_true
        tapped = r.clicked?
      end
    end
    tapped.should be_true
  end

  it "keeps the trailing block's widgets tappable inside the row" do
    ctx = Egui::Context.new
    row_rect = nil
    sw_rect = nil
    checked = false
    mob_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.list_tile("Wi-Fi", leading_icon: :wifi, id: "lt5") do |row|
          s = row.switch(checked, id: "lt5/sw") { |v| checked = v }
          sw_rect = s.rect
        end
        row_rect = r.rect
      end
    end
    sw_rect.should_not be_nil
    sw_rect.not_nil!.center.x.should be > row_rect.not_nil!.center.x
    at = sw_rect.not_nil!.center
    events = [
      Egui::Event.pointer_moved(at),
      Egui::Event.pointer_pressed(at),
      Egui::Event.pointer_released(at),
    ] of Egui::Event
    mob_frame(ctx, events) do
      ctx.window("demo") do |ui|
        ui.list_tile("Wi-Fi", leading_icon: :wifi, id: "lt5") do |row|
          row.switch(checked, id: "lt5/sw") { |v| checked = v }
        end
      end
    end
    checked.should be_true
  end
end
