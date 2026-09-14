require "spec"
require "../src/egui"

SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

def raw_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event, time : Float64 = 0.016)
  raw = Egui::RawInput.new(SCREEN, events, time)
  ctx.begin_frame(raw)
end

describe Egui::Context do
  it "runs a frame: window + label + button produce paint commands" do
    ctx = Egui::Context.new
    button_rect = nil

    raw_frame(ctx, time: 0.016)
    ctx.window("demo") do |ui|
      ui.label("Hello World!")
      r = ui.button("Click me")
      button_rect = r.rect
    end
    ctx.end_frame

    cmds = ctx.painter.commands
    cmds.size.should be > 0
    texts = cmds.select(Egui::TextCmd)
    texts.map(&.text).should contain("Hello World!")
    texts.map(&.text).should contain("demo")
    # window background must be *under* the contents (reserved index)
    cmds.first.should be_a(Egui::RectCmd)
    rects = cmds.select(Egui::RectCmd)
    rects.any? { |c| c.fill == ctx.style.visuals.window_fill }.should be_true
    button_rect.not_nil!.width.should be > 0
  end

  it "reports hover over the button" do
    ctx = Egui::Context.new
    center = nil

    2.times do |i|
      events = i == 1 ? [Egui::Event.pointer_moved(center.not_nil!)] : [] of Egui::Event
      raw_frame(ctx, events: events, time: 0.016 * (i + 1))
      hovered = false
      ctx.window("demo") do |ui|
        ui.label("Hello World!")
        r = ui.button("Click me")
        center = r.rect.center
        hovered = r.hovered?
      end
      ctx.end_frame
      hovered.should be_true if i == 1
    end
  end

  it "reports a click on press+release over the button" do
    ctx = Egui::Context.new
    center = nil

    # frame 1: layout only, learn where the button is
    raw_frame(ctx, time: 0.016)
    ctx.window("demo") do |ui|
      ui.label("Hello World!")
      center = ui.button("Click me").rect.center
    end
    ctx.end_frame

    # frame 2: move + press
    raw_frame(ctx, events: [Egui::Event.pointer_moved(center.not_nil!), Egui::Event.pointer_pressed(center.not_nil!)], time: 0.032)
    clicked = pressed = false
    ctx.window("demo") do |ui|
      ui.label("Hello World!")
      r = ui.button("Click me")
      clicked = r.clicked?
      pressed = r.pressed?
    end
    ctx.end_frame
    clicked.should be_false
    pressed.should be_true

    # frame 3: release — the click lands
    raw_frame(ctx, events: [Egui::Event.pointer_released(center.not_nil!)], time: 0.048)
    ctx.window("demo") do |ui|
      ui.label("Hello World!")
      clicked = ui.button("Click me").clicked?
    end
    ctx.end_frame
    clicked.should be_true
  end

  it "does not click when press started outside the widget" do
    ctx = Egui::Context.new
    center = nil

    raw_frame(ctx, time: 0.016)
    ctx.window("demo") do |ui|
      center = ui.button("Click me").rect.center
    end
    ctx.end_frame

    outside = center.not_nil! + Egui::Vec2.new(-80.0, 0.0)
    # press outside, release over the button — must NOT count as a click
    raw_frame(ctx, events: [Egui::Event.pointer_pressed(outside)], time: 0.032)
    ctx.window("demo") { |ui| ui.button("Click me") }
    ctx.end_frame
    raw_frame(ctx, events: [Egui::Event.pointer_released(center.not_nil!)], time: 0.048)
    clicked = false
    ctx.window("demo") do |ui|
      clicked = ui.button("Click me").clicked?
    end
    ctx.end_frame
    clicked.should be_false
  end

  it "keeps hover on a frame with no pointer events (no flicker)" do
    ctx = Egui::Context.new
    center = nil

    # frame 1: layout, learn the button rect
    raw_frame(ctx, time: 0.016)
    ctx.window("demo") do |ui|
      center = ui.button("Click me").rect.center
    end
    ctx.end_frame

    # frame 2: move over the button → hovered
    raw_frame(ctx, events: [Egui::Event.pointer_moved(center.not_nil!)], time: 0.032)
    hovered = false
    ctx.window("demo") do |ui|
      hovered = ui.button("Click me").hovered?
    end
    ctx.end_frame
    hovered.should be_true

    # frame 3: NO events at all (pointer idle) — hover must persist
    raw_frame(ctx, time: 0.048)
    ctx.window("demo") do |ui|
      hovered = ui.button("Click me").hovered?
    end
    ctx.end_frame
    hovered.should be_true
  end

  it "keeps the button pressed-down state across eventless frames" do
    ctx = Egui::Context.new
    center = nil

    raw_frame(ctx, time: 0.016)
    ctx.window("demo") do |ui|
      center = ui.button("Click me").rect.center
    end
    ctx.end_frame

    raw_frame(ctx, events: [Egui::Event.pointer_pressed(center.not_nil!)], time: 0.032)
    ctx.window("demo") { |ui| ui.button("Click me") }
    ctx.end_frame

    # frame with no events while still holding the button
    raw_frame(ctx, time: 0.048)
    active = false
    ctx.window("demo") do |ui|
      active = ui.button("Click me").active?
    end
    ctx.end_frame
    active.should be_true
  end

  it "changes label text from app state between frames" do
    ctx = Egui::Context.new
    count = 0

    2.times do |i|
      raw_frame(ctx, time: 0.016 * (i + 1))
      ctx.window("counter") do |ui|
        ui.label("Hello World!")
        if ui.button("Click me").clicked?
          count += 1
        end
        ui.label("count: #{count}")
      end
      ctx.end_frame
    end
    count.should eq(0)

    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("count: 0")
  end
end

# A raw drag-sensing box for interaction specs.
class DragBox
  include Egui::Widget

  def ui(ui : Egui::Ui) : Egui::Response
    rect = ui.allocate_at_least(Egui::Vec2.new(100.0, 30.0))
    ui.interact(rect, ui.next_widget_id, Egui::Sense.drag)
  end
end

describe "system state" do
  it "IdTypeMap persists across frames and prunes dead widgets" do
    ctx = Egui::Context.new
    id = Egui::Id.from("widget/state")
    cell = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(10.0, 10.0))

    # write state from an used widget (that's the real pattern — widgets
    # write while they run; pruning keys off this frame's used ids)
    raw_frame(ctx, time: 0.016)
    ctx.window("demo") { |ui| ui.label("hi") }
    ctx.memory.interact(id, cell, Egui::Sense.click)
    ctx.memory.data.set_string(id, "persist-me")
    ctx.end_frame
    ctx.memory.data.get_string(id).should eq("persist-me")

    # next frame the widget still exists → kept
    raw_frame(ctx, time: 0.032)
    ctx.memory.interact(id, cell, Egui::Sense.click)
    ctx.end_frame
    ctx.memory.data.get_string(id).should eq("persist-me")

    # frame without the widget → pruned (egui end_pass(used_ids))
    raw_frame(ctx, time: 0.048)
    ctx.window("demo") { |ui| ui.label("hi") }
    ctx.end_frame
    ctx.memory.data.get_string(id, "gone").should eq("gone")
  end

  it "classifies double and triple clicks" do
    ctx = Egui::Context.new
    center = nil
    counts = [] of Int32

    raw_frame(ctx, time: 0.016)
    ctx.window("demo") { |ui| center = ui.button("B").rect.center }
    ctx.end_frame

    t = 0.032
    4.times do
      raw_frame(ctx, events: [Egui::Event.pointer_pressed(center.not_nil!)], time: t += 0.016)
      ctx.window("demo") { |ui| ui.button("B") }
      ctx.end_frame
      raw_frame(ctx, events: [Egui::Event.pointer_released(center.not_nil!)], time: t += 0.016)
      ctx.window("demo") do |ui|
        r = ui.button("B")
        counts << r.click_count if r.clicked?
      end
      ctx.end_frame
    end
    counts.should eq([1, 2, 3, 1])
  end

  it "drags a drag-sensing widget and reports drag_delta" do
    ctx = Egui::Context.new
    center = nil

    raw_frame(ctx, time: 0.016)
    ctx.window("demo") { |ui| center = DragBox.new.ui(ui).rect.center }
    ctx.end_frame

    # press
    raw_frame(ctx, events: [Egui::Event.pointer_pressed(center.not_nil!)], time: 0.032)
    ctx.window("demo") { |ui| DragBox.new.ui(ui) }
    ctx.end_frame

    # move 12px — beyond CLICK_MAX_DIST, becomes a drag
    moved = center.not_nil! + Egui::Vec2.new(12.0, 0.0)
    raw_frame(ctx, events: [Egui::Event.pointer_moved(moved)], time: 0.048)
    dragged = false
    delta = Egui::Vec2.zero
    ctx.window("demo") do |ui|
      r = DragBox.new.ui(ui)
      dragged = r.dragged?
      delta = r.drag_delta
    end
    ctx.end_frame
    dragged.should be_true
    delta.x.should be > 0

    # release → drag_stopped
    raw_frame(ctx, events: [Egui::Event.pointer_released(moved)], time: 0.064)
    stopped = false
    ctx.window("demo") { |ui| stopped = DragBox.new.ui(ui).drag_stopped? }
    ctx.end_frame
    stopped.should be_true
  end

  it "suppresses a click when the pointer moved too much" do
    ctx = Egui::Context.new
    center = nil

    raw_frame(ctx, time: 0.016)
    ctx.window("demo") { |ui| center = ui.button("B").rect.center }
    ctx.end_frame

    raw_frame(ctx, events: [Egui::Event.pointer_pressed(center.not_nil!)], time: 0.032)
    ctx.window("demo") { |ui| ui.button("B") }
    ctx.end_frame

    moved = center.not_nil! + Egui::Vec2.new(8.0, 0.0)
    raw_frame(ctx, events: [Egui::Event.pointer_moved(moved)], time: 0.048)
    ctx.window("demo") { |ui| ui.button("B") }
    ctx.end_frame

    raw_frame(ctx, events: [Egui::Event.pointer_released(moved)], time: 0.064)
    clicked = false
    ctx.window("demo") { |ui| clicked = ui.button("B").clicked? }
    ctx.end_frame
    clicked.should be_false
  end

  it "CollapsingHeader keeps open state in system state, not app state" do
    ctx = Egui::Context.new
    header_center = nil

    # closed by default: body not laid out
    raw_frame(ctx, time: 0.016)
    ctx.window("demo") do |ui|
      Egui::CollapsingHeader.new("Head").show(ui) do |body|
        body.label("INSIDE")
      end
    end
    ctx.end_frame
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).should_not contain("INSIDE")

    # learn header rect, then click it open
    raw_frame(ctx, time: 0.032)
    ctx.window("demo") do |ui|
      Egui::CollapsingHeader.new("Head").show(ui) { |body| body.label("INSIDE") }
      header_center = ui.cursor # unused placeholder
    end
    ctx.end_frame

    # learn the header rect from memory: the full-width content row
    # (width ≈ 360-2*pad = 340; the title bar is 380 wide — skip it)
    rects = ctx.memory.widget_rects
    header_rect = rects.values.find do |r|
      r.width > 100 && r.width < 370 && r.height < 40
    end.not_nil!
    center = header_rect.center

    raw_frame(ctx, events: [Egui::Event.pointer_pressed(center)], time: 0.048)
    ctx.window("demo") do |ui|
      Egui::CollapsingHeader.new("Head").show(ui) { |body| body.label("INSIDE") }
    end
    ctx.end_frame
    raw_frame(ctx, events: [Egui::Event.pointer_released(center)], time: 0.064)
    ctx.window("demo") do |ui|
      Egui::CollapsingHeader.new("Head").show(ui) { |body| body.label("INSIDE") }
    end
    ctx.end_frame

    # now open: body laid out this frame (click took effect last frame)
    raw_frame(ctx, time: 0.080)
    ctx.window("demo") do |ui|
      Egui::CollapsingHeader.new("Head").show(ui) { |body| body.label("INSIDE") }
    end
    ctx.end_frame
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).should contain("INSIDE")
  end

  it "moves the window when its title bar is dragged (Areas state)" do
    ctx = Egui::Context.new
    win_id = Egui::Id.from("window/demo")
    # title bar geometry: pos (24,24), width 380, title_h = 16*1.25+8 = 28
    title_pos = Egui::Pos2.new(100.0, 35.0)

    raw_frame(ctx, time: 0.016)
    ctx.window("demo") { |ui| ui.label("hi") }
    ctx.end_frame

    raw_frame(ctx, events: [Egui::Event.pointer_pressed(title_pos)], time: 0.032)
    ctx.window("demo") { |ui| ui.label("hi") }
    ctx.end_frame

    raw_frame(ctx, events: [Egui::Event.pointer_moved(title_pos + Egui::Vec2.new(20.0, 0.0))], time: 0.048)
    ctx.window("demo") { |ui| ui.label("hi") }
    ctx.end_frame

    pos = ctx.memory.areas.pos_for(win_id, Egui::Pos2.new(24.0, 24.0))
    pos.x.should be_close(44.0, 0.01)

    # and the painted window actually moved with it
    raw_frame(ctx, time: 0.064)
    ctx.window("demo") { |ui| ui.label("hi") }
    ctx.end_frame
    bg = ctx.painter.commands.first.as(Egui::RectCmd)
    bg.rect.min.x.should be_close(44.0, 0.01)
  end

  it "opens a popup and closes it on outside click" do
    ctx = Egui::Context.new
    btn_center = nil

    raw_frame(ctx, time: 0.016)
    ctx.window("demo") do |ui|
      btn_center = ui.button("menu").rect.center
    end
    ctx.end_frame

    # closed popup renders nothing
    raw_frame(ctx, time: 0.032)
    ctx.popup("menu", Egui::Pos2.new(100.0, 100.0)) { |ui| ui.label("POPUP") }
    ctx.end_frame
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).should_not contain("POPUP")

    # open → renders
    ctx.open_popup("menu")
    raw_frame(ctx, time: 0.048)
    ctx.window("demo") { |ui| ui.button("menu") }
    ctx.popup("menu", Egui::Pos2.new(100.0, 100.0)) { |ui| ui.label("POPUP") }
    ctx.end_frame
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).should contain("POPUP")

    # click the button (outside the popup) → popup closes next frame
    raw_frame(ctx, events: [Egui::Event.pointer_pressed(btn_center.not_nil!)], time: 0.064)
    ctx.window("demo") { |ui| ui.button("menu") }
    ctx.popup("menu", Egui::Pos2.new(100.0, 100.0)) { |ui| ui.label("POPUP") }
    ctx.end_frame
    raw_frame(ctx, events: [Egui::Event.pointer_released(btn_center.not_nil!)], time: 0.080)
    ctx.window("demo") { |ui| ui.button("menu") }
    ctx.popup("menu", Egui::Pos2.new(100.0, 100.0)) { |ui| ui.label("POPUP") }
    ctx.end_frame

    raw_frame(ctx, time: 0.096)
    ctx.window("demo") { |ui| ui.button("menu") }
    ctx.popup("menu", Egui::Pos2.new(100.0, 100.0)) { |ui| ui.label("POPUP") }
    ctx.end_frame
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).should_not contain("POPUP")
  end

  it "detects duplicate widget ids" do
    ctx = Egui::Context.new
    id = Egui::Id.from("dup")

    raw_frame(ctx, time: 0.016)
    ctx.window("demo") do |ui|
      rect = ui.allocate_at_least(Egui::Vec2.new(50.0, 20.0))
      ui.interact(rect, id, Egui::Sense.click)
      rect2 = ui.allocate_at_least(Egui::Vec2.new(50.0, 20.0))
      ui.interact(rect2, id, Egui::Sense.click)
    end
    ctx.end_frame
    ctx.memory.duplicate_ids.should contain(id)
  end

  it "animates values by id and focus has a dead-man's switch" do
    ctx = Egui::Context.new
    anim_id = Egui::Id.from("anim")

    # first sighting: value appears instantly (egui semantics)
    raw_frame(ctx, time: 0.0)
    v0 = ctx.animate_value_with_time(anim_id, 0.0, 0.1)
    ctx.end_frame
    v0.should eq(0.0)

    # target changes → animation eases from the current value
    raw_frame(ctx, time: 0.05)
    v1 = ctx.animate_value_with_time(anim_id, 1.0, 0.1)
    ctx.end_frame
    v1.should be >= 0.0
    v1.should be < 1.0

    raw_frame(ctx, time: 0.10)
    v2 = ctx.animate_value_with_time(anim_id, 1.0, 0.1)
    ctx.end_frame
    v2.should be > v1
    v2.should be < 1.0

    # focus: request → has_focus next frame; widget disappears → focus drops
    fid = Egui::Id.from("focus/me")
    raw_frame(ctx, time: 0.1)
    ctx.memory.focus.request(fid)
    ctx.end_frame
    raw_frame(ctx, time: 0.15)
    ctx.memory.focus.has_focus?(fid).should be_true
    ctx.end_frame
    # not requested again → dead-man's switch clears it
    raw_frame(ctx, time: 0.2)
    ctx.memory.focus.has_focus?(fid).should be_false
    ctx.end_frame
  end
end
