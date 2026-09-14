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

describe "painter primitives (phase 0)" do
  it "emits line/circle/arc commands carrying the current clip" do
    ctx = Egui::Context.new
    raw_frame(ctx)
    clip = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(10.0, 10.0))
    ctx.painter.clip = clip
    ctx.painter.line(Egui::Pos2.zero, Egui::Pos2.new(5.0, 5.0), 2.0,
      Egui::Color32.rgb(1, 2, 3))
    ctx.painter.circle_stroke(Egui::Pos2.new(5.0, 5.0), 3.0,
      Egui::Color32.rgb(4, 5, 6))
    ctx.painter.arc(Egui::Pos2.new(5.0, 5.0), 3.0, 0.0, 1.0, 2.0,
      Egui::Color32.rgb(7, 8, 9))
    ctx.end_frame

    cmds = ctx.painter.commands
    cmds.select(Egui::LineCmd).size.should eq(1)
    cmds.select(Egui::CircleCmd).size.should eq(1)
    cmds.select(Egui::ArcCmd).size.should eq(1)
    cmds.each do |cmd|
      case cmd
      when Egui::LineCmd, Egui::CircleCmd, Egui::ArcCmd
        cmd.clip.should eq(clip)
      end
    end
  end
end

describe "phase 1 widgets" do
  it "checkbox toggles the value through the block on click" do
    ctx = Egui::Context.new
    value = false
    center = nil

    # frame 1: learn the rect
    raw_frame(ctx, time: 0.016)
    widget_ui(ctx).checkbox(value, "check") { |v| value = v }
    ctx.end_frame
    raw_frame(ctx, time: 0.016)
    ui = widget_ui(ctx)
    resp = ui.checkbox(value, "check") { |v| value = v }
    center = resp.rect.center
    ctx.end_frame

    # frame 3: press
    raw_frame(ctx, events: [Egui::Event.pointer_moved(center.not_nil!),
      Egui::Event.pointer_pressed(center.not_nil!)], time: 0.032)
    widget_ui(ctx).checkbox(value, "check") { |v| value = v }
    ctx.end_frame
    value.should be_false

    # frame 4: release — the click lands and the block fires
    raw_frame(ctx, events: [Egui::Event.pointer_released(center.not_nil!)], time: 0.048)
    resp = widget_ui(ctx).checkbox(value, "check") { |v| value = v }
    ctx.end_frame
    resp.changed?.should be_true
    value.should be_true
  end

  it "radio reports changed only when a new option is selected" do
    ctx = Egui::Context.new
    first_center = nil
    second_center = nil

    raw_frame(ctx, time: 0.016)
    ui = widget_ui(ctx)
    first_center = ui.radio(true, "first").rect.center
    second_center = ui.radio(false, "second").rect.center
    ctx.end_frame

    # click the unselected one → changed
    raw_frame(ctx, events: [Egui::Event.pointer_moved(second_center.not_nil!),
      Egui::Event.pointer_pressed(second_center.not_nil!)], time: 0.032)
    ui = widget_ui(ctx)
    ui.radio(true, "first")
    ui.radio(false, "second")
    ctx.end_frame
    raw_frame(ctx, events: [Egui::Event.pointer_released(second_center.not_nil!)], time: 0.048)
    ui = widget_ui(ctx)
    ui.radio(true, "first")
    changed = ui.radio(false, "second").changed?
    ctx.end_frame
    changed.should be_true

    # the app now renders second as selected; clicking it again → no change
    raw_frame(ctx, events: [Egui::Event.pointer_moved(second_center.not_nil!),
      Egui::Event.pointer_pressed(second_center.not_nil!)], time: 0.064)
    ui = widget_ui(ctx)
    ui.radio(false, "first")
    ui.radio(true, "second")
    ctx.end_frame
    raw_frame(ctx, events: [Egui::Event.pointer_released(second_center.not_nil!)], time: 0.080)
    ui = widget_ui(ctx)
    ui.radio(false, "first")
    changed = ui.radio(true, "second").changed?
    ctx.end_frame
    changed.should be_false
  end

  it "separator draws a line spanning the available width" do
    ctx = Egui::Context.new
    raw_frame(ctx)
    widget_ui(ctx).separator
    ctx.end_frame

    line = ctx.painter.commands.select(Egui::LineCmd).first
    line.p1.x.should eq(0.0)
    line.p2.x.should eq(300.0)
    (line.p1.y - line.p2.y).abs.should be < 0.01
  end

  it "progress bar paints a track and a fraction-sized fill" do
    ctx = Egui::Context.new
    raw_frame(ctx)
    widget_ui(ctx).progress_bar(0.5)
    ctx.end_frame

    fill = ctx.painter.commands.select(Egui::RectCmd)
      .find { |c| c.fill == ctx.style.visuals.selection_fill }.not_nil!
    (fill.rect.width - 150.0).abs.should be < 0.01
    fill.rect.height.should be > 0
  end

  it "spinner emits an arc and requests a repaint" do
    ctx = Egui::Context.new
    raw_frame(ctx, time: 0.016)
    widget_ui(ctx).spinner
    ctx.end_frame

    ctx.painter.commands.select(Egui::ArcCmd).size.should eq(1)
    ctx.needs_repaint?.should be_true
  end

  it "hyperlink paints colored underlined text and is clickable" do
    ctx = Egui::Context.new
    center = nil

    raw_frame(ctx, time: 0.016)
    center = widget_ui(ctx).hyperlink_to("egui", "https://egui.rs").rect.center
    ctx.end_frame

    raw_frame(ctx, events: [Egui::Event.pointer_moved(center.not_nil!)], time: 0.032)
    hovered = widget_ui(ctx).hyperlink_to("egui", "https://egui.rs").hovered?
    ctx.end_frame
    hovered.should be_true

    text = ctx.painter.commands.select(Egui::TextCmd).first
    text.color.should eq(ctx.style.visuals.hyperlink_color)
    ctx.painter.commands.select(Egui::LineCmd).size.should eq(1)
  end
end

def widget_ui(ctx : Egui::Context) : Egui::Ui
  Egui::Ui.new(ctx, Egui::Id.from("spec"),
    Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(300.0, 300.0)))
end

describe "smart_aim (phase 2)" do
  it "picks the roundest number in the range" do
    a = Egui::SmartAim
    a.best_in_range_f64(0.0799999999999996, 0.09999999999999995).should eq(0.08)
    a.best_in_range_f64(-0.2, 0.0).should eq(0.0) # prefer zero
    a.best_in_range_f64(-10_004.23, 3.14).should eq(0.0)
    a.best_in_range_f64(7.8, 17.8).should eq(10.0)
    a.best_in_range_f64(99.0, 300.0).should eq(100.0)
    a.best_in_range_f64(-99.0, -300.0).should eq(-100.0)
    a.best_in_range_f64(0.4, 0.9).should eq(0.5) # prefer ending on 5
    a.best_in_range_f64(14.1, 19.99).should eq(15.0)
    a.best_in_range_f64(12.3, 65.9).should eq(50.0) # prefer leading 5
    a.best_in_range_f64(493.0, 879.0).should eq(500.0)
    a.best_in_range_f64(0.37, 0.48).should eq(0.40)
    a.best_in_range_f64(7.5, 123_456.0).should eq(1000.0) # geometric mean
    a.best_in_range_f64(12345, 12780).should eq(12500)
    a.best_in_range_f64(12371, 12376).should eq(12375)
    a.best_in_range_f64(300, 99).should eq(100.0) # order-insensitive
  end
end

describe "phase 2 widgets" do
  it "slider maps a pointer drag to the value range" do
    ctx = Egui::Context.new
    value = 0.0
    rect = nil

    # frame 1: layout only
    raw_frame(ctx, time: 0.016)
    rect = widget_ui(ctx).slider(value, 0.0..100.0, "v") { |v| value = v }.rect
    ctx.end_frame

    # frame 2: press near the left end of the rail
    cy = rect.not_nil!.center.y
    press = Egui::Pos2.new(rect.not_nil!.min.x + 15.0, cy)
    raw_frame(ctx, events: [Egui::Event.pointer_moved(press),
      Egui::Event.pointer_pressed(press)], time: 0.032)
    widget_ui(ctx).slider(value, 0.0..100.0, "v") { |v| value = v }
    ctx.end_frame
    value.should eq(0.0) # no value change before the pointer moves

    # frame 3: drag past the click threshold; the slider fills the
    # available width (≈270pt here), so 60px in ≈ 20% of the range
    mid = Egui::Pos2.new(rect.not_nil!.min.x + 60.0, cy)
    raw_frame(ctx, events: [Egui::Event.pointer_moved(mid)], time: 0.048)
    widget_ui(ctx).slider(value, 0.0..100.0, "v") { |v| value = v }
    ctx.end_frame
    value.should be > 10.0
    value.should be < 35.0 # smart_aim keeps it round

    # frame 4: drag to the far right → near max
    right = Egui::Pos2.new(rect.not_nil!.max.x, cy)
    raw_frame(ctx, events: [Egui::Event.pointer_moved(right)], time: 0.064)
    widget_ui(ctx).slider(value, 0.0..100.0, "v") { |v| value = v }
    ctx.end_frame
    value.should be > 95.0
  end

  it "drag_value changes by drag_delta * speed" do
    ctx = Egui::Context.new
    value = 10.0
    center = nil

    raw_frame(ctx, time: 0.016)
    center = widget_ui(ctx).drag_value(value) { |v| value = v }.rect.center
    ctx.end_frame

    # press, then drag right by 20 px at speed 0.5 → +10
    raw_frame(ctx, events: [Egui::Event.pointer_moved(center.not_nil!),
      Egui::Event.pointer_pressed(center.not_nil!)], time: 0.032)
    widget_ui(ctx).drag_value(value) { |v| value = v }
    ctx.end_frame
    moved = center.not_nil! + Egui::Vec2.new(20.0, 0.0)
    raw_frame(ctx, events: [Egui::Event.pointer_moved(moved)], time: 0.048)
    widget_ui(ctx).drag_value(value, speed: 0.5) { |v| value = v }
    ctx.end_frame

    value.should eq(20.0)
  end

  it "combo box opens, selects and closes" do
    ctx = Egui::Context.new
    selected = "First"

    raw_frame(ctx, time: 0.016)
    widget_ui(ctx).combo_box("spec_combo", selected, ["First", "Second"]) { |s| selected = s }
    ctx.end_frame

    # open it: find the button rect via the frame's geometry
    btn_center = ctx.memory.widget_rects.values.first.center
    raw_frame(ctx, events: [Egui::Event.pointer_moved(btn_center),
      Egui::Event.pointer_pressed(btn_center),
      Egui::Event.pointer_released(btn_center)], time: 0.032)
    widget_ui(ctx).combo_box("spec_combo", selected, ["First", "Second"]) { |s| selected = s }
    ctx.end_frame

    # popup is open: click the second item (registered in the frame
    # above — read widget_rects, which still holds that frame's rects)
    item_center = ctx.memory.widget_rects.values.last.center
    raw_frame(ctx, events: [Egui::Event.pointer_moved(item_center),
      Egui::Event.pointer_pressed(item_center),
      Egui::Event.pointer_released(item_center)], time: 0.048)
    picked = false
    ui = widget_ui(ctx)
    picked = ui.combo_box("spec_combo", selected, ["First", "Second"]) { |s| selected = s }
    ctx.end_frame

    picked.should be_true
    selected.should eq("Second")
    ctx.memory.open_popups.should be_empty
  end

  it "menu bar opens a dropdown and menu_item closes it" do
    ctx = Egui::Context.new
    clicked_item = false

    run_frame = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events: events, time: time)
      ctx.menu_bar do |bar|
        bar.menu_button("File") do |menu|
          menu.menu_item("Open") { clicked_item = true }
        end
      end
      ctx.end_frame
    end

    # frame 1: layout; frame 2: click File
    run_frame.call([] of Egui::Event, 0.016)
    file_center = ctx.memory.widget_rects.values.first.center
    run_frame.call([Egui::Event.pointer_moved(file_center),
      Egui::Event.pointer_pressed(file_center),
      Egui::Event.pointer_released(file_center)], 0.032)

    ctx.memory.open_popups.should_not be_empty

    # frame 3: click the menu item (rect from the frame that rendered it)
    item_center = ctx.memory.widget_rects.values.last.center
    run_frame.call([Egui::Event.pointer_moved(item_center),
      Egui::Event.pointer_pressed(item_center),
      Egui::Event.pointer_released(item_center)], 0.048)

    clicked_item.should be_true
    ctx.memory.open_popups.should be_empty
  end

  it "modal blocks interaction with lower layers" do
    ctx = Egui::Context.new
    btn_center = nil

    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events: events, time: time)
      hovered = false
      ctx.window("demo") do |ui|
        r = ui.button("below modal")
        btn_center = r.rect.center
        hovered = r.hovered?
      end
      ctx.modal { |ui| ui.button("close") }
      ctx.end_frame
      hovered
    end

    # frames 1-2 without pointer: modal latches blocking
    draw.call([] of Egui::Event, 0.016)
    draw.call([] of Egui::Event, 0.032)

    # frame 3: hover the covered button — must be blocked
    blocked_hover = draw.call(
      [Egui::Event.pointer_moved(btn_center.not_nil!)], 0.048)
    blocked_hover.should be_false

    # the modal's own button still works
    modal_btn = ctx.memory.widget_rects.values.last.center
    hovered_modal = draw.call(
      [Egui::Event.pointer_moved(modal_btn)], 0.064)
    hovered_modal.should be_false # window button, not modal
    modal_hover = false
    raw_frame(ctx, events: [Egui::Event.pointer_moved(modal_btn)], time: 0.080)
    ctx.window("demo") { |ui| ui.button("below modal") }
    ctx.modal { |ui| modal_hover = ui.button("close").hovered? }
    ctx.end_frame
    modal_hover.should be_true
  end

  it "gradient rect carries fill2 and button icon emits line commands" do
    ctx = Egui::Context.new
    raw_frame(ctx)
    ui = widget_ui(ctx)
    ui.add(Egui::Button.new("OK").icon(:check)
      .gradient(Egui::Color32.rgb(60, 150, 90), Egui::Color32.rgb(24, 80, 48)))
    ctx.end_frame

    grad = ctx.painter.commands.select(Egui::RectCmd)
      .find(&.fill2.not_nil!).not_nil!
    grad.fill2.not_nil!.should eq(Egui::Color32.rgb(24, 80, 48))
    # icon checkmark = 2 line segments
    ctx.painter.commands.select(Egui::LineCmd).size.should eq(2)
  end

  it "tooltip appears after the hover delay" do
    ctx = Egui::Context.new
    center = nil

    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events: events, time: time)
      widget_ui(ctx).button("hover me").on_hover_text("tip")
      ctx.end_frame
      ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    end

    draw.call([] of Egui::Event, 0.016)
    center = ctx.memory.widget_rects.values.first.center

    # first hovered frame at t=0.232 starts the delay clock
    texts = draw.call([Egui::Event.pointer_moved(center.not_nil!)], 0.232)
    texts.should_not contain("tip")

    # 0.368s of hover: still hidden
    texts = draw.call([] of Egui::Event, 0.600)
    texts.should_not contain("tip")

    # past the 0.5s delay: tooltip appears
    texts = draw.call([] of Egui::Event, 0.800)
    texts.should contain("tip")
  end
end

describe "keyboard input (phase 3)" do
  it "Tab cycles focus between widgets, Shift+Tab goes back" do
    ctx = Egui::Context.new
    ids = [] of Egui::Id

    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events, time)
      ui = widget_ui(ctx)
      ids = [ui.button("one").id, ui.button("two").id, ui.button("three").id]
      ctx.end_frame
    end

    draw.call([] of Egui::Event, 0.016)
    # frame 2: Tab focuses the first (none focused before → index -1 +1 = 0).
    # Focus lags one frame (dead-man's switch): request in frame 2,
    # has_focus? true from frame 3 on — kept alive by interact.
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Tab)], 0.032)
    draw.call([] of Egui::Event, 0.048)
    ctx.memory.focus.has_focus?(ids[0]).should be_true

    # Tab again → second
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Tab)], 0.064)
    draw.call([] of Egui::Event, 0.080)
    ctx.memory.focus.has_focus?(ids[1]).should be_true

    # Shift+Tab → back to first
    mods = Egui::Modifiers.new(shift: true)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Tab, mods)], 0.096)
    draw.call([] of Egui::Event, 0.112)
    ctx.memory.focus.has_focus?(ids[0]).should be_true
  end

  it "arrows move focus geometrically" do
    ctx = Egui::Context.new
    first_id = second_id = Egui::Id.from("x")

    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events, time)
      widget_ui(ctx).horizontal do |row|
        first_id = row.button("left").id
        second_id = row.button("right").id
      end
      ctx.end_frame
    end

    draw.call([] of Egui::Event, 0.016)
    # focus "left" by Tab (lands one frame later)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Tab)], 0.032)
    draw.call([] of Egui::Event, 0.048)
    # ArrowRight → focus moves to "right" (same row, to the right)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Right)], 0.064)
    draw.call([] of Egui::Event, 0.080)
    ctx.memory.focus.has_focus?(second_id).should be_true
  end

  it "typed digits edit a focused drag_value, Enter commits" do
    ctx = Egui::Context.new
    value = 10.0
    id = Egui::Id.from("x")

    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events, time)
      ui = widget_ui(ctx)
      r = ui.drag_value(value) { |v| value = v }
      id = r.id
      ctx.end_frame
    end

    draw.call([] of Egui::Event, 0.016)

    # focus it via Tab (it is the only focusable widget); lands next frame
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Tab)], 0.032)
    draw.call([] of Egui::Event, 0.048)
    ctx.memory.focus.has_focus?(id).should be_true

    # type "42": buffer only — the value commits on Enter
    draw.call([Egui::Event.text_input("4")], 0.064)
    draw.call([Egui::Event.text_input("2")], 0.080)
    value.should eq(10.0)

    # Enter commits and ends editing
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Enter)], 0.096)
    value.should eq(42.0)

    # cancel: type "99", Escape → value unchanged
    draw.call([Egui::Event.text_input("9")], 0.112)
    draw.call([Egui::Event.text_input("9")], 0.128)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Escape)], 0.144)
    value.should eq(42.0)
  end

  it "consume_key hides a pressed key from later readers" do
    ctx = Egui::Context.new
    raw_frame(ctx, [Egui::Event.key_pressed(Egui::KeyCode::Up)], 0.016)
    ctx.input.key_pressed?(Egui::KeyCode::Up).should be_true
    ctx.input.consume_key(Egui::KeyCode::Up).should be_true
    ctx.input.key_pressed?(Egui::KeyCode::Up).should be_false
    ctx.input.consume_key(Egui::KeyCode::Up).should be_false
    ctx.end_frame
  end

  it "key state persists across frames while held" do
    ctx = Egui::Context.new
    raw_frame(ctx, [Egui::Event.key_pressed(Egui::KeyCode::Left)], 0.016)
    raw_frame(ctx, [] of Egui::Event, 0.032)
    ctx.input.key_down?(Egui::KeyCode::Left).should be_true
    ctx.input.key_pressed?(Egui::KeyCode::Left).should be_false
    raw_frame(ctx, [Egui::Event.key_released(Egui::KeyCode::Left)], 0.048)
    ctx.input.key_down?(Egui::KeyCode::Left).should be_false
    ctx.input.key_released?(Egui::KeyCode::Left).should be_true
    ctx.end_frame
  end
end

describe "rich text & wrapping (phase 4)" do
  it "wraps a long label into several rows within the available width" do
    ctx = Egui::Context.new
    text = "The quick brown fox jumps over the lazy dog again and again"

    raw_frame(ctx)
    rect = widget_ui(ctx).label(text, wrap: true).rect
    ctx.end_frame

    # monospace estimate: char_w = 0.6 * 16 = 9.6pt; the 300pt-wide ui
    # fits ~31 chars per row, so the 61-char text must wrap to 2+ rows
    line_h = ctx.fonts.measure("x", ctx.style.font_size).y
    rect.height.should be > line_h          # more than a single line
    rows = (rect.height / line_h).round.to_i
    rows.should be >= 2
    rect.width.should be <= 300.0

    # the fragments reassemble into the original words
    cmds = ctx.painter.commands.select(Egui::TextCmd).map(&.text).join
    cmds.gsub(" ", "").should eq(text.gsub(" ", ""))
  end

  it "respects explicit newlines" do
    ctx = Egui::Context.new
    raw_frame(ctx)
    widget_ui(ctx).label("one\ntwo")
    ctx.end_frame
    ctx.painter.commands.select(Egui::TextCmd).map(&.text)
      .should contain("one")
    ctx.painter.commands.select(Egui::TextCmd).map(&.text)
      .should contain("two")
  end

  it "rich text carries color and underline into paint commands" do
    ctx = Egui::Context.new
    red = Egui::Color32.rgb(255, 0, 0)

    raw_frame(ctx)
    widget_ui(ctx).rich(
      Egui::RichText.new("warn").color(red).underline)
    ctx.end_frame

    text_cmd = ctx.painter.commands.select(Egui::TextCmd).first
    text_cmd.text.should eq("warn")
    text_cmd.color.should eq(red)
    # underline emitted as a LineCmd
    ctx.painter.commands.select(Egui::LineCmd).size.should eq(1)
  end

  it "heading sizes the text up via RichText" do
    ctx = Egui::Context.new
    raw_frame(ctx)
    heading_rect = widget_ui(ctx).heading("Title").rect
    label_rect = widget_ui(ctx).label("Title").rect
    ctx.end_frame
    heading_rect.height.should be > label_rect.height
  end
end
