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

    # frame 2: click near the left end of the rail — the value jumps
    # there right away (drag-only widgets drag from the press, like
    # upstream egui; no movement threshold)
    cy = rect.not_nil!.center.y
    press = Egui::Pos2.new(rect.not_nil!.min.x + 15.0, cy)
    raw_frame(ctx, events: [Egui::Event.pointer_moved(press),
      Egui::Event.pointer_pressed(press)], time: 0.032)
    widget_ui(ctx).slider(value, 0.0..100.0, "v") { |v| value = v }
    ctx.end_frame
    value.should be > 0.0 # the click itself sets the value
    value.should be < 10.0

    # frame 3: drag further right; the slider fills the
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

  it "combo box button click toggles the popup closed" do
    ctx = Egui::Context.new
    selected = "First"

    raw_frame(ctx, time: 0.016)
    widget_ui(ctx).combo_box("spec_toggle", selected, ["First", "Second"]) { |s| selected = s }
    ctx.end_frame

    # open it
    btn_center = ctx.memory.widget_rects.values.first.center
    raw_frame(ctx, events: [Egui::Event.pointer_moved(btn_center),
      Egui::Event.pointer_pressed(btn_center),
      Egui::Event.pointer_released(btn_center)], time: 0.032)
    widget_ui(ctx).combo_box("spec_toggle", selected, ["First", "Second"]) { |s| selected = s }
    ctx.end_frame
    ctx.memory.open_popups.should_not be_empty

    # click the same button again — the popup must close, not re-open
    raw_frame(ctx, events: [Egui::Event.pointer_moved(btn_center),
      Egui::Event.pointer_pressed(btn_center),
      Egui::Event.pointer_released(btn_center)], time: 0.048)
    widget_ui(ctx).combo_box("spec_toggle", selected, ["First", "Second"]) { |s| selected = s }
    ctx.end_frame
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

  it "menu item click wins over a background widget under the popup" do
    ctx = Egui::Context.new
    clicked_item = false
    clicked_under = false

    run_frame = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events: events, time: time)
      ctx.menu_bar do |bar|
        bar.menu_button("File") do |menu|
          menu.menu_item("Open") { clicked_item = true }
        end
      end
      # A clickable panel widget directly under the open dropdown: the
      # popup registers EARLIER in the frame (menu bar renders first)
      # but lives on the Foreground layer, so the click must land on
      # the menu item, not on what's painted underneath.
      ctx.central_panel do |ui|
        clicked_under = true if ui.button("Underneath").clicked?
      end
      ctx.end_frame
    end

    run_frame.call([] of Egui::Event, 0.016)
    file_center = ctx.memory.widget_rects.values.first.center
    run_frame.call([Egui::Event.pointer_moved(file_center),
      Egui::Event.pointer_pressed(file_center),
      Egui::Event.pointer_released(file_center)], 0.032)

    ctx.memory.open_popups.should_not be_empty

    # rects: [File button, menu item, panel button] — the item must
    # actually overlap the panel button or the spec proves nothing:
    # click a point covered by BOTH (the popup is on the Foreground
    # layer but registers earlier than the panel below it).
    rects = ctx.memory.widget_rects.values
    item_rect, under_rect = rects[1], rects[2]
    overlap_min = Egui::Pos2.new({item_rect.left, under_rect.left}.max,
      {item_rect.top, under_rect.top}.max)
    overlap_max = Egui::Pos2.new({item_rect.right, under_rect.right}.min,
      {item_rect.bottom, under_rect.bottom}.min)
    (overlap_max.x - overlap_min.x).should be > 0
    (overlap_max.y - overlap_min.y).should be > 0
    click_at = Egui::Pos2.new((overlap_min.x + overlap_max.x) / 2.0,
      (overlap_min.y + overlap_max.y) / 2.0)

    run_frame.call([Egui::Event.pointer_moved(click_at),
      Egui::Event.pointer_pressed(click_at),
      Egui::Event.pointer_released(click_at)], 0.048)

    clicked_item.should be_true
    clicked_under.should be_false
    ctx.memory.open_popups.should be_empty
  end

  it "menu_bar reserves the top strip so panels don't paint over it" do
    ctx = Egui::Context.new
    raw_frame(ctx, time: 0.016)
    ctx.menu_bar { |bar| bar.menu_button("File") { |menu| menu.menu_item("New") { } } }
    bar_bottom = ctx.available_rect.min.y
    bar_bottom.should be > 0

    # the bar button fills the strip's full height — no padding between
    # the button and the bar itself
    button = ctx.memory.widget_rects.values.first
    button.top.should be_close(0.0, 0.5)
    button.bottom.should be_close(bar_bottom, 0.5)

    side = ctx.side_panel(:left, "side", width: 100.0) { |ui| ui.label("side") }
    side.min.y.should be_close(bar_bottom, 0.01)

    central = ctx.central_panel { |ui| ui.label("center") }
    central.min.y.should be_close(bar_bottom, 0.01)

    # no panel background covers the menu bar strip anymore
    panel_fill = ctx.style.visuals.panel_fill
    ctx.painter.commands.select(Egui::RectCmd)
      .select { |c| c.fill == panel_fill && c.rect.height != bar_bottom }
      .each { |c| c.rect.min.y.should be >= bar_bottom }
    ctx.end_frame
  end

  it "menu item rows span the popup and the popup hugs its content" do
    ctx = Egui::Context.new

    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events: events, time: time)
      ctx.menu_bar do |bar|
        bar.menu_button("File") do |menu|
          menu.menu_item("New", "Ctrl+N") { }
          menu.menu_item("Open…", "Ctrl+O") { }
        end
      end
      ctx.end_frame
    end

    # open the menu (click "File")
    draw.call([] of Egui::Event, 0.016)
    file_center = ctx.memory.widget_rects.values.first.center
    draw.call([Egui::Event.pointer_moved(file_center),
      Egui::Event.pointer_pressed(file_center),
      Egui::Event.pointer_released(file_center)], 0.032)

    # let the measured popup size snap, then inspect one stable frame
    draw.call([] of Egui::Event, 0.048)

    rects = ctx.memory.widget_rects.values
    first, second = rects[-2], rects[-1]

    # full-bleed: the item row (highlight + click area) spans the
    # popup frame edge-to-edge, frame hugs the widest item
    frame = ctx.painter.commands.select(Egui::RectCmd)
      .find { |c| c.fill == ctx.style.visuals.window_fill }.not_nil!
    frame.rect.width.should be_close(second.width, 0.5)
    frame.rect.width.should be < 180.0 # no more fixed-width right gap

    # the frame hugs the items vertically too: no window_padding band
    # above the first item or below the last one
    frame.rect.top.should be_close(first.top, 0.5)
    frame.rect.bottom.should be_close(second.bottom, 0.5)

    # row height includes the menu vertical padding around the text
    text_h = ctx.fonts.measure("New", ctx.style.font_size).y
    second.height.should be >= text_h + 2 * Egui::MENU_PAD_Y - 0.5

    # rows stack flush: no item_spacing band between menu items
    second.top.should be_close(first.bottom, 0.5)

    # shortcut is right-aligned inside the row: label left of shortcut
    pad_x = ctx.style.spacing.button_padding.x
    texts = ctx.painter.commands.select(Egui::TextCmd)
      .select { |t| t.text == "New" || t.text == "Ctrl+N" }
    label = texts.find(&.text.==("New")).not_nil!
    shortcut = texts.find(&.text.==("Ctrl+N")).not_nil!
    label.pos.x.should be_close(first.left + pad_x, 0.5)
    shortcut.pos.x.should be > label.pos.x
    shortcut.pos.x.should be_close(
      first.right - pad_x -
        ctx.fonts.measure("Ctrl+N", ctx.style.font_size).x, 0.5)
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

describe "text edit (phase 4.5)" do
  it "types characters into a focused text edit" do
    ctx = Egui::Context.new
    buffer = "hello"
    id = Egui::Id.from("x")

    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events, time)
      ui = widget_ui(ctx)
      r = ui.text_edit_singleline(buffer) { |t| buffer = t }
      id = r.id
      ctx.end_frame
    end

    draw.call([] of Egui::Event, 0.016)

    # click the right edge to focus (cursor lands at the end)
    rect = ctx.memory.widget_rects.values.first
    right_edge = Egui::Pos2.new(rect.right - 1.0, rect.center.y)
    draw.call([Egui::Event.pointer_moved(right_edge),
      Egui::Event.pointer_pressed(right_edge),
      Egui::Event.pointer_released(right_edge)], 0.032)
    draw.call([] of Egui::Event, 0.048) # focus lands this frame
    ctx.memory.focus.has_focus?(id).should be_true

    # type "!" at the end
    draw.call([Egui::Event.text_input("!")], 0.064)
    buffer.should eq("hello!")

    # Backspace removes the last char
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Backspace)], 0.080)
    buffer.should eq("hello")
  end

  it "click places the cursor and typing inserts there" do
    ctx = Egui::Context.new
    buffer = "abcd"
    id = Egui::Id.from("x")

    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events, time)
      ui = widget_ui(ctx)
      r = ui.text_edit_singleline(buffer) { |t| buffer = t }
      id = r.id
      ctx.end_frame
      ctx.memory.widget_rects.values.first
    end

    rect = draw.call([] of Egui::Event, 0.016)

    # click between the 2nd and 3rd char: "ab|cd"
    # monospace: char_w = 9.6, pad = 6 → char 2 boundary at 6 + 19.2
    click_x = rect.left + 6.0 + 2 * 9.6
    click = Egui::Pos2.new(click_x, rect.center.y)
    draw.call([Egui::Event.pointer_moved(click),
      Egui::Event.pointer_pressed(click),
      Egui::Event.pointer_released(click)], 0.032)
    draw.call([] of Egui::Event, 0.048) # focus active

    # type "X" → inserted at cursor 2
    draw.call([Egui::Event.text_input("X")], 0.064)
    buffer.should eq("abXcd")
  end

  it "arrows move the caret within the field, not focus" do
    ctx = Egui::Context.new
    buffer = "ab"
    id = Egui::Id.from("x")

    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events, time)
      ui = widget_ui(ctx)
      r = ui.text_edit_singleline(buffer) { |t| buffer = t }
      id = r.id
      ctx.end_frame
    end

    draw.call([] of Egui::Event, 0.016)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Tab)], 0.032)
    draw.call([] of Egui::Event, 0.048)
    ctx.memory.focus.has_focus?(id).should be_true

    # Left moves caret to 1; typing inserts mid-string
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Left)], 0.064)
    draw.call([Egui::Event.text_input("-")], 0.080)
    buffer.should eq("a-b")

    # focus did not leave the field
    ctx.memory.focus.has_focus?(id).should be_true
  end
end

describe "panels (phase 5)" do
  it "panels take bites out of available_rect in order; central gets the rest" do
    ctx = Egui::Context.new

    raw_frame(ctx)
    top = ctx.top_panel { |ui| ui.label("TOP") }
    side = ctx.side_panel(:left, "side", width: 100.0) { |ui| ui.label("SIDE") }
    bottom = ctx.bottom_panel { |ui| ui.label("FPS") }
    central = ctx.central_panel { |ui| ui.label("CENTER") }
    ctx.end_frame

    screen = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))
    top.top.should eq(screen.top)
    side.top.should eq(top.bottom)
    side.left.should eq(screen.left)
    central.left.should eq(side.right)
    central.top.should eq(top.bottom)
    central.bottom.should eq(bottom.top)
    central.right.should eq(screen.right)
  end
end

describe "scroll area (phase 5)" do
  it "wheel scroll moves the offset, clamps it and clips content" do
    ctx = Egui::Context.new
    scroll_id = Egui::Id.from("spec").child(1)

    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events, time)
      widget_ui(ctx).scroll_area(max_height: 100.0) do |s|
        30.times { |i| s.label("row #{i}") }
      end
      ctx.end_frame
    end

    # frame 1: layout — content ≫ viewport, scrollbar painted
    draw.call([] of Egui::Event, 0.016)
    offset = ctx.memory.data.get_vec2(scroll_id, Egui::Vec2.zero)
    offset.y.should eq(0.0)
    ctx.painter.commands.select(Egui::TextCmd)
      .all? { |c| c.clip.height <= 100.0 }.should be_true

    # frame 2: pointer inside the viewport + wheel down → offset grows
    inside = Egui::Pos2.new(50.0, 50.0)
    draw.call([Egui::Event.pointer_moved(inside),
      Egui::Event.scroll(Egui::Vec2.new(0.0, 20.0))], 0.032)
    # arbitration resolved against frame 1's viewport only from frame 3
    draw.call([Egui::Event.scroll(Egui::Vec2.new(0.0, 20.0))], 0.048)
    offset = ctx.memory.data.get_vec2(scroll_id, Egui::Vec2.zero)
    offset.y.should be > 0.0

    # frame 4: massive scroll clamps to content - viewport
    draw.call([Egui::Event.scroll(Egui::Vec2.new(0.0, 100_000.0))], 0.064)
    content = ctx.memory.data.get_vec2(scroll_id.child(0), Egui::Vec2.zero)
    offset = ctx.memory.data.get_vec2(scroll_id, Egui::Vec2.zero)
    offset.y.should be < content.y # clamped, not past the end
    (offset.y - (content.y - 100.0)).abs.should be < 1.0
  end

  it "dragging the scrollbar thumb scrolls the content" do
    ctx = Egui::Context.new
    scroll_id = Egui::Id.from("spec").child(1)

    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events, time)
      widget_ui(ctx).scroll_area(max_height: 100.0) do |s|
        30.times { |i| s.label("row #{i}") }
      end
      ctx.end_frame
    end

    # frame 1: layout — content overflows, scrollbar exists
    draw.call([] of Egui::Event, 0.016)
    viewport = ctx.memory.scroll_rects[scroll_id].not_nil![0]
    content = ctx.memory.data.get_vec2(scroll_id.child(0), Egui::Vec2.zero)
    content.y.should be > viewport.height
    max_offset = content.y - viewport.height

    # frame 2: press the track near the bottom (below the thumb) — the
    # thumb centers on the pointer, jumping the offset near the end
    press = Egui::Pos2.new(viewport.right - 4.0, viewport.bottom - 10.0)
    draw.call([Egui::Event.pointer_moved(press),
      Egui::Event.pointer_pressed(press)], 0.032)
    offset = ctx.memory.data.get_vec2(scroll_id, Egui::Vec2.zero).y
    offset.should be > 0.8 * max_offset

    # frame 3: drag up along the bar — the offset follows proportionally
    up = Egui::Pos2.new(press.x, viewport.top + 10.0)
    draw.call([Egui::Event.pointer_moved(up)], 0.048)
    dragged = ctx.memory.data.get_vec2(scroll_id, Egui::Vec2.zero).y
    dragged.should be < offset / 2.0

    # frame 4: release — offset stays where it was dragged to
    draw.call([Egui::Event.pointer_released(up)], 0.064)
    after = ctx.memory.data.get_vec2(scroll_id, Egui::Vec2.zero).y
    after.should be_close(dragged, 0.01)
  end

  it "nested scroll areas: the inner one owns the scroll delta" do
    ctx = Egui::Context.new
    root = Egui::Id.from("spec")
    outer_id = root.child(1)                          # outer scroll area
    inner_id = outer_id.child(1).child(1)             # inner scroll area

    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events, time)
      widget_ui(ctx).scroll_area(max_height: 300.0) do |outer|
        outer.scroll_area(max_height: 100.0) do |inner|
          40.times { |i| inner.label("inner row #{i}") }
        end
        5.times { |i| outer.label("outer row #{i}") }
      end
      ctx.end_frame
    end

    draw.call([] of Egui::Event, 0.016)
    # pointer over the inner viewport (first thing in the outer content,
    # at the very top of the outer viewport)
    inner_center = ctx.memory.scroll_rects[inner_id]?.try &.[0].center
    inner_center.should_not be_nil
    draw.call([Egui::Event.pointer_moved(inner_center.not_nil!),
      Egui::Event.scroll(Egui::Vec2.new(0.0, 30.0))], 0.032)
    draw.call([Egui::Event.scroll(Egui::Vec2.new(0.0, 30.0))], 0.048)

    inner_offset = ctx.memory.data.get_vec2(inner_id, Egui::Vec2.zero).y
    outer_offset = ctx.memory.data.get_vec2(outer_id, Egui::Vec2.zero).y
    inner_offset.should be > 0.0
    outer_offset.should eq(0.0)
  end

  it "scales wheel notches by style.scroll_speed (px per notch)" do
    ctx = Egui::Context.new
    scroll_id = Egui::Id.from("spec").child(1)

    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events, time)
      widget_ui(ctx).scroll_area(max_height: 100.0) do |s|
        60.times { |i| s.label("row #{i}") }
      end
      ctx.end_frame
    end

    draw.call([Egui::Event.pointer_moved(Egui::Pos2.new(50.0, 50.0))], 0.016)
    # the backend reports ±1.0 per wheel notch
    draw.call([Egui::Event.scroll(Egui::Vec2.new(0.0, 1.0))], 0.032)
    draw.call([Egui::Event.scroll(Egui::Vec2.new(0.0, 1.0))], 0.048)
    before = ctx.memory.data.get_vec2(scroll_id, Egui::Vec2.zero).y
    before.should be > 0.0

    # once ownership is stable, one notch moves exactly scroll_speed px
    draw.call([Egui::Event.scroll(Egui::Vec2.new(0.0, 1.0))], 0.064)
    after = ctx.memory.data.get_vec2(scroll_id, Egui::Vec2.zero).y
    after.should be_close(before + ctx.style.scroll_speed, 0.01)

    # the speed is theme-tunable at runtime
    ctx.theme.style.scroll_speed = 120.0
    draw.call([Egui::Event.scroll(Egui::Vec2.new(0.0, 1.0))], 0.080)
    ctx.memory.data.get_vec2(scroll_id, Egui::Vec2.zero).y
      .should be_close(after + 120.0, 0.01)
  end
end

describe "window resize (phase 5)" do
  it "dragging the corner grip grows the stored window size" do
    ctx = Egui::Context.new
    win_id = Egui::Id.from("window/demo")
    grip_center = nil

    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events, time)
      ctx.window("demo") { |ui| ui.label("content") }
      ctx.end_frame
    end

    draw.call([] of Egui::Event, 0.016)
    initial = ctx.memory.layer_sizes[win_id].not_nil!
    # grip = bottom-right 12x12 of the window
    grip_center = Egui::Pos2.new(initial.x - 6.0, 0.0)
    # find the window rect: pos (24,24), height from layer_sizes
    grip_center = Egui::Pos2.new(24.0 + initial.x - 6.0, 24.0 + initial.y - 6.0)

    # press on the grip, drag down-right
    draw.call([Egui::Event.pointer_moved(grip_center),
      Egui::Event.pointer_pressed(grip_center)], 0.032)
    moved = grip_center + Egui::Vec2.new(30.0, 20.0)
    draw.call([Egui::Event.pointer_moved(moved)], 0.048)
    draw.call([] of Egui::Event, 0.064)

    grown = ctx.memory.layer_sizes[win_id].not_nil!
    grown.x.should be > initial.x + 10.0
    grown.y.should be > initial.y + 5.0
  end
end

describe "textures & images (phase 6)" do
  it "register_rgba produces ImageCmd with the texture id" do
    ctx = Egui::Context.new
    tex = ctx.textures.register_rgba(2, 2, Bytes.new(16, 255_u8))
    tex.should be > 0

    raw_frame(ctx)
    widget_ui(ctx).image(tex, Egui::Vec2.new(50.0, 40.0))
    ctx.end_frame

    cmd = ctx.painter.commands.select(Egui::ImageCmd).first
    cmd.texture_id.should eq(tex)
    cmd.rect.width.should eq(50.0)
    cmd.rect.height.should eq(40.0)
  end

  it "hue bar paints the full rainbow gradient (uv 0..1)" do
    ctx = Egui::Context.new
    color = Egui::Color32.rgb(255, 0, 0)

    raw_frame(ctx)
    widget_ui(ctx).color_edit32(color) { |c| color = c }
    ctx.end_frame

    images = ctx.painter.commands.select(Egui::ImageCmd)
    images.size.should eq(2) # SV square + hue bar
    bar = images[1]
    bar.uv.min.x.should be < 0.01
    bar.uv.width.should be > 0.99
  end

  it "texture cache is bounded per hue step" do
    ctx = Egui::Context.new
    color = Egui::Color32.rgb(255, 0, 0)
    raw_frame(ctx)
    widget_ui(ctx).color_edit32(color) { |c| color = c }
    ctx.end_frame
    before = ctx.memory.texture_cache.size

    # same hue again → no new textures
    raw_frame(ctx)
    widget_ui(ctx).color_edit32(color) { |c| color = c }
    ctx.end_frame
    ctx.memory.texture_cache.size.should eq(before)
  end
end

describe "hsv conversions (phase 6)" do
  it "roundtrips through hsv within one quantization step" do
    samples = [
      Egui::Color32.rgb(255, 0, 0), Egui::Color32.rgb(0, 255, 0),
      Egui::Color32.rgb(0, 0, 255), Egui::Color32.rgb(128, 64, 200),
      Egui::Color32.rgb(255, 255, 255), Egui::Color32.rgb(10, 10, 10),
      Egui::Color32.rgb(0, 200, 200), Egui::Color32.rgb(255, 128, 0),
    ]
    samples.each do |c|
      hsv = Egui::Hsva.from_color(c)
      hsv.v.should be >= 0.0
      hsv.v.should be <= 1.0
      back = hsv.to_color
      (back.r.to_i - c.r.to_i).abs.should be <= 2
      (back.g.to_i - c.g.to_i).abs.should be <= 2
      (back.b.to_i - c.b.to_i).abs.should be <= 2
    end
  end

  it "picks pure hues on the wheel edges" do
    Egui::Hsva.new(0.0, 1.0, 1.0, 1.0).to_color.should eq(Egui::Color32.rgb(255, 0, 0))
    Egui::Hsva.new(1.0 / 3.0, 1.0, 1.0, 1.0).to_color.should eq(Egui::Color32.rgb(0, 255, 0))
    Egui::Hsva.new(2.0 / 3.0, 1.0, 1.0, 1.0).to_color.should eq(Egui::Color32.rgb(0, 0, 255))
  end

  it "dragging the SV square changes the color" do
    ctx = Egui::Context.new
    color = Egui::Color32.rgb(255, 0, 0) # pure red: s=1, v=1
    square_center = nil

    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events, time)
      ui = widget_ui(ctx)
      # square = first widget of the picker: id spec.child(1)
      r = ui.color_edit32(color) { |c| color = c }
      ctx.end_frame
      r.rect
    end

    rect = draw.call([] of Egui::Event, 0.016)
    # click near the left edge of the square: saturation → ~0
    left = Egui::Pos2.new(rect.left + 2.0, rect.top + 2.0)
    draw.call([Egui::Event.pointer_moved(left),
      Egui::Event.pointer_pressed(left),
      Egui::Event.pointer_released(left)], 0.032)

    color.should_not eq(Egui::Color32.rgb(255, 0, 0))
    # low saturation + high value at hue 0 ≈ near-white
    color.r.should be > 200
    color.g.should be > 180
    color.b.should be > 180
  end

  it "keeps the hue when dragging the SV square into the white corner" do
    ctx = Egui::Context.new
    color = Egui::Color32.rgb(0, 0, 255) # pure blue: h = 2/3
    square = nil

    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events, time)
      r = widget_ui(ctx).color_edit32(color) { |c| color = c }
      ctx.end_frame
      # the SV square is the top 180x180 of the picker rect
      Egui::Rect.from_min_size(r.rect.min, Egui::Vec2.new(180.0, 180.0))
    end

    square = draw.call([] of Egui::Event, 0.016)
    # click the white corner: s = 0, v = 1 → the color becomes pure
    # white, whose hue is undefined (from_color would say 0 = red)
    corner = Egui::Pos2.new(square.not_nil!.left, square.not_nil!.top)
    draw.call([Egui::Event.pointer_moved(corner),
      Egui::Event.pointer_pressed(corner),
      Egui::Event.pointer_released(corner)], 0.032)

    color.should eq(Egui::Color32.rgb(255, 255, 255))
    Egui::Hsva.from_color(color).h.should eq(0.0) # the naive roundtrip loses the hue

    # next frame the picker must still remember the blue hue (upstream
    # color_cache: white → the Hsva it was produced from)
    draw.call([] of Egui::Event, 0.048)
    cached = ctx.memory.color_cache[color].not_nil!
    cached.h.should be_close(2.0 / 3.0, 0.01)
  end
end

describe "interaction clipping (overflowing widgets)" do
  it "does not click or hover widgets outside their panel's clip rect" do
    screen = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 200.0))
    ctx = Egui::Context.new
    button_rect = nil

    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw = Egui::RawInput.new(screen, events, time)
      ctx.begin_frame(raw)
      ctx.central_panel do |ui|
        30.times { |i| ui.label("row #{i}") } # push content past the panel bottom
        r = ui.button("Overflow")
        button_rect = r.rect
      end
      ctx.bottom_panel { |ui| ui.label("fps") }
      ctx.end_frame
    end

    draw.call([] of Egui::Event, 0.016)
    draw.call([] of Egui::Event, 0.032)
    rect = button_rect.not_nil!
    rect.bottom.should be > 200.0 # the button overflows the 200px screen

    # click right on the overflowing button — it must not react
    center = Egui::Pos2.new(rect.center.x, rect.center.y)
    resp = nil
    draw.call([Egui::Event.pointer_moved(center),
      Egui::Event.pointer_pressed(center)], 0.048)
    raw = Egui::RawInput.new(screen, [Egui::Event.pointer_released(center)], 0.064)
    ctx.begin_frame(raw)
    ctx.central_panel do |ui|
      30.times { |i| ui.label("row #{i}") }
      resp = ui.button("Overflow")
    end
    ctx.bottom_panel { |ui| ui.label("fps") }
    ctx.end_frame

    resp.not_nil!.clicked?.should be_false
    resp.not_nil!.hovered?.should be_false
  end

  it "clips interaction of widgets inside a horizontal row to their panel" do
    screen = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 200.0))
    ctx = Egui::Context.new
    button_rect = nil

    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw = Egui::RawInput.new(screen, events, time)
      ctx.begin_frame(raw)
      ctx.central_panel do |ui|
        30.times { |i| ui.label("row #{i}") } # push content past the panel bottom
        ui.horizontal do |row|
          r = row.button("Overflow")
          button_rect = r.rect
        end
      end
      ctx.bottom_panel { |ui| ui.label("fps") }
      ctx.end_frame
    end

    draw.call([] of Egui::Event, 0.016)
    draw.call([] of Egui::Event, 0.032)
    rect = button_rect.not_nil!
    rect.bottom.should be > 200.0 # the row's button overflows the 200px screen

    # click right on the overflowing button — it must not react (the
    # horizontal row inherits the panel's clip rect)
    center = Egui::Pos2.new(rect.center.x, rect.center.y)
    resp = nil
    draw.call([Egui::Event.pointer_moved(center),
      Egui::Event.pointer_pressed(center)], 0.048)
    raw = Egui::RawInput.new(screen, [Egui::Event.pointer_released(center)], 0.064)
    ctx.begin_frame(raw)
    ctx.central_panel do |ui|
      30.times { |i| ui.label("row #{i}") }
      ui.horizontal { |row| resp = row.button("Overflow") }
    end
    ctx.bottom_panel { |ui| ui.label("fps") }
    ctx.end_frame

    resp.not_nil!.clicked?.should be_false
    resp.not_nil!.hovered?.should be_false
  end
end

describe "cursor icons (CSS cursor)" do
  it "maps every CursorIcon to its exact CSS keyword" do
    Egui::CursorIcon.values.size.should eq(35)
    Egui::CursorIcon::Default.to_css.should eq("default")
    Egui::CursorIcon::None.to_css.should eq("none")
    Egui::CursorIcon::Pointer.to_css.should eq("pointer")
    Egui::CursorIcon::ContextMenu.to_css.should eq("context-menu")
    Egui::CursorIcon::VerticalText.to_css.should eq("vertical-text")
    Egui::CursorIcon::NotAllowed.to_css.should eq("not-allowed")
    Egui::CursorIcon::EwResize.to_css.should eq("ew-resize")
    Egui::CursorIcon::NeswResize.to_css.should eq("nesw-resize")
    Egui::CursorIcon::NwseResize.to_css.should eq("nwse-resize")
    Egui::CursorIcon::ColResize.to_css.should eq("col-resize")
    Egui::CursorIcon::SeResize.to_css.should eq("se-resize")
    Egui::CursorIcon::ZoomIn.to_css.should eq("zoom-in")
  end

  it "round-trips every CSS cursor keyword" do
    Egui::CursorIcon.values.each do |icon|
      Egui::CursorIcon.parse?(icon.to_css).should eq(icon)
    end
    Egui::CursorIcon.parse?("pointer").should eq(Egui::CursorIcon::Pointer)
    Egui::CursorIcon.parse?("ew-resize").should eq(Egui::CursorIcon::EwResize)
    Egui::CursorIcon.parse?("auto").should eq(Egui::CursorIcon::Default)
    Egui::CursorIcon.parse?("not-a-cursor").should be_nil
  end

  it "shows the style interact_cursor over a hovered button and resets next frame" do
    ctx = Egui::Context.new
    ctx.style.visuals.interact_cursor.should eq(Egui::CursorIcon::Pointer)
    center = nil

    raw_frame(ctx, time: 0.016)
    ctx.window("demo") { |ui| center = ui.button("Click me").rect.center }
    ctx.end_frame

    # hover frame → the style's pointer
    raw_frame(ctx, events: [Egui::Event.pointer_moved(center.not_nil!)], time: 0.032)
    ctx.window("demo") { |ui| ui.button("Click me") }
    ctx.cursor_icon.should eq(Egui::CursorIcon::Pointer)
    ctx.end_frame

    # pointer moved away → back to default
    raw_frame(ctx, events: [Egui::Event.pointer_moved(Egui::Pos2.new(500.0, 500.0))], time: 0.048)
    ctx.window("demo") { |ui| ui.button("Click me") }
    ctx.cursor_icon.should eq(Egui::CursorIcon::Default)
    ctx.end_frame
  end

  it "Button#cursor overrides the style cursor" do
    ctx = Egui::Context.new
    center = nil

    raw_frame(ctx, time: 0.016)
    center = widget_ui(ctx).add(Egui::Button.new("zoom").cursor(:zoom_in)).rect.center
    ctx.end_frame

    raw_frame(ctx, events: [Egui::Event.pointer_moved(center)], time: 0.032)
    widget_ui(ctx).add(Egui::Button.new("zoom").cursor(:zoom_in))
    ctx.cursor_icon.should eq(Egui::CursorIcon::ZoomIn)
    ctx.end_frame
  end

  it "hyperlink hover shows the pointer; on_hover_cursor sets any icon" do
    ctx = Egui::Context.new
    ctx.style.visuals.interact_cursor = nil # hyperlink is explicit
    center = nil

    raw_frame(ctx, time: 0.016)
    center = widget_ui(ctx).hyperlink_to("egui", "https://egui.rs").rect.center
    ctx.end_frame

    raw_frame(ctx, events: [Egui::Event.pointer_moved(center)], time: 0.032)
    widget_ui(ctx).hyperlink_to("egui", "https://egui.rs")
    ctx.cursor_icon.should eq(Egui::CursorIcon::Pointer)
    ctx.end_frame

    # on_hover_cursor on an arbitrary interact rect
    rect = Egui::Rect.from_min_size(Egui::Pos2.new(50.0, 50.0), Egui::Vec2.new(80.0, 20.0))
    raw_frame(ctx, time: 0.048)
    ctx.end_frame
    raw_frame(ctx, events: [Egui::Event.pointer_moved(rect.center)], time: 0.064)
    ui = widget_ui(ctx)
    resp = ui.interact(rect, ui.next_widget_id, Egui::Sense.click)
    resp.on_hover_cursor(Egui::CursorIcon::Help)
    resp.hovered?.should be_true
    ctx.cursor_icon.should eq(Egui::CursorIcon::Help)
    ctx.end_frame
  end

  it "drag_value hover shows ew-resize" do
    ctx = Egui::Context.new
    center = nil

    raw_frame(ctx, time: 0.016)
    center = widget_ui(ctx).drag_value(1.5) { |v| }.rect.center
    ctx.end_frame

    raw_frame(ctx, events: [Egui::Event.pointer_moved(center)], time: 0.032)
    widget_ui(ctx).drag_value(1.5) { |v| }
    ctx.cursor_icon.should eq(Egui::CursorIcon::EwResize)
    ctx.end_frame
  end
end

describe "theme (global style + per-widget overrides)" do
  it "defaults to the dark theme" do
    ctx = Egui::Context.new
    ctx.theme.name.should eq("dark")
    ctx.theme.dark?.should be_true
    ctx.style.should be(ctx.theme.style)
  end

  it "swaps the theme instantly — the next frame paints the new palette" do
    ctx = Egui::Context.new
    raw_frame(ctx)
    ctx.central_panel { |ui| ui.label("hello") }
    ctx.end_frame
    dark_fill = ctx.theme.style.visuals.panel_fill

    ctx.theme = Egui::Theme.light
    ctx.theme.dark?.should be_false
    ctx.style.visuals.panel_fill.should_not eq(dark_fill)

    raw_frame(ctx, time: 0.032)
    ctx.central_panel { |ui| ui.label("hello") }
    cmds = ctx.end_frame
    panel = cmds.select(Egui::RectCmd).find do |c|
      c.fill && c.fill != Egui::Color32.rgba(0, 0, 0, 0)
    end
    panel.not_nil!.fill.should eq(ctx.theme.style.visuals.panel_fill)
  end

  it "merges widget style overrides over the theme (nil = inherit)" do
    ctx = Egui::Context.new
    red = Egui::Color32.rgb(170, 40, 40)

    raw_frame(ctx)
    widget_ui(ctx).add(Egui::Button.new("OK").style { |s| s.fill = red })
    rects = ctx.end_frame.select(Egui::RectCmd)
    rects.any?(&.fill.==(red)).should be_true
  end

  it "overridden fields survive a theme swap; inherited fields follow it" do
    ctx = Egui::Context.new
    red = Egui::Color32.rgb(170, 40, 40)
    button = ->(ui : Egui::Ui) do
      ui.add(Egui::Button.new("OK").style { |s| s.fill = red })
      ui.add(Egui::Button.new("plain"))
    end

    raw_frame(ctx)
    button.call(widget_ui(ctx))
    ctx.end_frame

    ctx.theme = Egui::Theme.light
    light_text = ctx.theme.style.visuals.text_color
    light_fill = ctx.theme.style.visuals.button_weak

    raw_frame(ctx, time: 0.032)
    ui = widget_ui(ctx)
    ui.add(Egui::Button.new("OK").style { |s| s.fill = red })
    ui.add(Egui::Button.new("plain"))
    ctx.end_frame

    # The overridden button keeps its custom fill; the plain button took
    # the light theme's fill; both labels use the light theme's text
    # color (nobody overrode it).
    rects = ctx.painter.commands.select(Egui::RectCmd)
    rects.any? { |c| c.fill == red }.should be_true
    rects.any? { |c| c.fill == light_fill }.should be_true
    text_cmds = ctx.painter.commands.select(Egui::TextCmd)
    text_cmds.select(&.text.==("OK")).all?(&.color.==(light_text)).should be_true
    text_cmds.select(&.text.==("plain")).all?(&.color.==(light_text)).should be_true
  end

  it "WidgetStyle#merge_over copies the theme and applies only set fields" do
    base = Egui::Theme.dark.style
    ws = Egui::WidgetStyle.new
    ws.text_color = Egui::Color32.rgb(1, 2, 3)
    merged = ws.merge_over(base)

    merged.should_not be(base)
    merged.visuals.text_color.should eq(Egui::Color32.rgb(1, 2, 3))
    merged.visuals.button_weak.should eq(base.visuals.button_weak)
    # mutating the merged copy must not leak into the theme
    merged.visuals.button_weak = Egui::Color32.rgb(9, 9, 9)
    base.visuals.button_weak.should_not eq(Egui::Color32.rgb(9, 9, 9))
  end
end

describe "modal scrim follows the theme" do
  it "paints visuals.modal_dim; light theme lightens it" do
    ctx = Egui::Context.new
    dim = nil

    raw_frame(ctx)
    ctx.modal("m") { |ui| ui.label("blocked") }
    ctx.end_frame
    dim = ctx.painter.commands.select(Egui::RectCmd)
      .find(&.fill.==(ctx.theme.style.visuals.modal_dim))
    dim.should_not be_nil

    ctx.theme = Egui::Theme.light
    raw_frame(ctx, time: 0.032)
    ctx.modal("m") { |ui| ui.label("blocked") }
    ctx.end_frame
    ctx.painter.commands.select(Egui::RectCmd)
      .any?(&.fill.==(Egui::Color32.rgba(0, 0, 0, 70))).should be_true
  end
end

describe "Visuals#fade_color (theme-aware weak variants)" do
  it "darkens on dark themes, lightens on light ones" do
    dark = Egui::Theme.dark.style.visuals
    light = Egui::Theme.light.style.visuals
    base = Egui::Color32.rgb(100, 100, 100)

    faded = dark.fade_color(base, 0.5)
    faded.r.should eq(50)
    faded.g.should eq(50)
    faded.b.should eq(50)

    lightened = light.fade_color(base, 0.5)
    lightened.r.should eq(178)
    lightened.g.should eq(178)
    lightened.b.should eq(178)
  end

  it "hint text fades the right way in both themes" do
    dark = Egui::Theme.dark.style.visuals
    light = Egui::Theme.light.style.visuals
    dark.fade_color(dark.text_color, 0.55).r.should be < dark.text_color.r
    light.fade_color(light.text_color, 0.55).r.should be > light.text_color.r
  end
end

describe "Sidebar (sections + tabs)" do
  it "renders sections and tabs and reports the new selection on click" do
    ctx = Egui::Context.new
    sections = [
      Egui::Sidebar::Section.new("One", ["A", "B"]),
      Egui::Sidebar::Section.new("Two", ["C"]),
    ]
    section = 0
    tab = 0

    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events: events, time: time)
      resp = widget_ui(ctx).sidebar(sections, section, tab) do |s, t|
        section = s
        tab = t
      end
      ctx.end_frame
      resp
    end

    # frame 1: layout — section titles (uppercased) + tab texts painted
    draw.call([] of Egui::Event, 0.016)
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    {"ONE", "TWO", "A", "B", "C"}.each { |t| texts.should contain(t) }
    section.should eq(0)
    tab.should eq(0)

    # tab interaction rects in creation order (A, B, C) — skip the
    # 1px separator rect between the sections
    a_rect, b_rect, c_rect =
      ctx.memory.widget_rects.values.select { |r| r.height > 5.0 }

    # click tab B (same section) — press, then release lands the click
    draw.call([Egui::Event.pointer_moved(b_rect.center),
      Egui::Event.pointer_pressed(b_rect.center)], 0.032)
    resp = draw.call([Egui::Event.pointer_released(b_rect.center)], 0.048)
    resp.changed?.should be_true
    section.should eq(0)
    tab.should eq(1)

    # click tab C — the selection jumps to the other section
    draw.call([Egui::Event.pointer_moved(c_rect.center),
      Egui::Event.pointer_pressed(c_rect.center)], 0.064)
    draw.call([Egui::Event.pointer_released(c_rect.center)], 0.080)
    section.should eq(1)
    tab.should eq(0)

    # clicking the already-selected tab reports no change
    draw.call([Egui::Event.pointer_moved(c_rect.center),
      Egui::Event.pointer_pressed(c_rect.center)], 0.096)
    resp = draw.call([Egui::Event.pointer_released(c_rect.center)], 0.112)
    resp.changed?.should be_false
    section.should eq(1)
    tab.should eq(0)
  end

  it "paints the selected tab with the selection fill and the hovered one weak" do
    ctx = Egui::Context.new

    raw_frame(ctx)
    widget_ui(ctx).sidebar(
      [Egui::Sidebar::Section.new("S", ["x", "y"])], 0, 1) { |s, t| }
    ctx.end_frame

    x_rect, y_rect = ctx.memory.widget_rects.values
    selected = ctx.painter.commands.select(Egui::RectCmd)
      .find { |c| c.fill == ctx.style.visuals.selection_fill }.not_nil!
    # the fill sits on the selected tab (y, the second), not on x
    selected.rect.min.y.should be_close(y_rect.min.y, 0.01)
    selected.rect.min.y.should be > x_rect.min.y
  end

  it "styles tabs from the stylesheet: flush list, no separators, padded boxes" do
    ctx = Egui::Context.new

    raw_frame(ctx)
    widget_ui(ctx).sidebar(
      [Egui::Sidebar::Section.new("S", ["a", "b"])], 0, 0) { |s, t| }
    ctx.end_frame

    a_rect, b_rect = ctx.memory.widget_rects.values
    # zero gap between tab buttons (only the styled tab_spacing may
    # separate them; the layout's item_spacing is dropped)
    (b_rect.min.y - a_rect.max.y).should be_close(
      ctx.stylesheet.resolve("sidebar").f64("tab_spacing", 0.0), 0.01)
    # no separator lines anymore — sections are spaced, not ruled
    ctx.painter.commands.select(Egui::LineCmd).should be_empty
    # padding grows the button: height ≥ text + padding.top + padding.bottom
    pad = ctx.stylesheet.resolve("sidebar.tab").box("padding")
    text_h = ctx.fonts.measure("a", ctx.style.font_size).y
    a_rect.height.should be >= text_h + pad.vertical
  end

  it "re-reads the stylesheet after a live rule tweak" do
    ctx = Egui::Context.new
    sheet = ctx.stylesheet

    raw_frame(ctx)
    widget_ui(ctx).sidebar(
      [Egui::Sidebar::Section.new("S", ["a"])], 0, 0) { |s, t| }
    ctx.end_frame
    before = ctx.memory.widget_rects.values.first.height

    # CSS-like runtime restyle: more tab padding → taller buttons
    sheet.rule(Egui::Sidebar::TAB_CLASS, Egui::StyleVars{
      "padding.top"    => 14.0,
      "padding.bottom" => 14.0,
    })
    raw_frame(ctx, time: 0.032)
    widget_ui(ctx).sidebar(
      [Egui::Sidebar::Section.new("S", ["a"])], 0, 0) { |s, t| }
    ctx.end_frame
    after = ctx.memory.widget_rects.values.first.height
    after.should be > before + 12.0
  end

  it "nests a close button per closable tab: the X eats the click" do
    ctx = Egui::Context.new
    sections = [Egui::Sidebar::Section.new("One", ["A", "B"], closable: true)]
    section = 0
    tab = 0
    closed = nil.as({Int32, Int32}?)

    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events: events, time: time)
      widget_ui(ctx).sidebar(sections, section, tab,
        on_close: ->(s : Int32, t : Int32) { closed = {s, t} }) do |s, t|
        section = s
        tab = t
      end
      ctx.end_frame
    end

    draw.call([] of Egui::Event, 0.016)
    # one X (2 line segments) per closable tab
    ctx.painter.commands.select(Egui::LineCmd).size.should eq(4)
    # hit targets: wide rects are tabs, small ones the nested X buttons
    tab_rects = ctx.memory.widget_rects.values.select { |r| r.width > 100.0 }
    close_rects = ctx.memory.widget_rects.values.select { |r| r.width <= 100.0 }
    tab_rects.size.should eq(2)
    close_rects.size.should eq(2)

    # click the second tab's X: reported closed, tab NOT selected
    x = close_rects[1].center
    draw.call([Egui::Event.pointer_moved(x),
      Egui::Event.pointer_pressed(x)], 0.032)
    draw.call([Egui::Event.pointer_released(x)], 0.048)
    closed.should eq({0, 1})
    section.should eq(0)
    tab.should eq(0)

    # the tab body (away from the X) still selects normally — click
    # the *second* tab's body; the first one is already selected
    body = Egui::Pos2.new(tab_rects[1].min.x + 20.0, tab_rects[1].center.y)
    draw.call([Egui::Event.pointer_moved(body),
      Egui::Event.pointer_pressed(body)], 0.064)
    draw.call([Egui::Event.pointer_released(body)], 0.080)
    section.should eq(0)
    tab.should eq(1)
    closed.should eq({0, 1}) # no new close
  end

  it "survives an empty section list" do
    ctx = Egui::Context.new
    raw_frame(ctx)
    widget_ui(ctx).sidebar([] of Egui::Sidebar::Section, 0, 0) { |s, t| }
    ctx.end_frame
    ctx.painter.commands.select(Egui::LineCmd).should be_empty
  end
end

describe "StyleSheet (CSS-like classes)" do
  it "cascades in two layers: class defaults first, states always on top" do
    sheet = Egui::StyleSheet.new
    sheet.rule("sidebar", Egui::StyleVars{"fill" => Egui::Color32.rgb(1, 1, 1)})
    # a second rule on the same selector merges per key, CSS-cascade style
    sheet.rule("sidebar", Egui::StyleVars{"font_size" => 14.0})
    sheet.rule("sidebar.tab", Egui::StyleVars{
      "fill"   => Egui::Color32.rgb(2, 2, 2),
      "height" => 30.0,
    })
    sheet.rule("sidebar:hover", Egui::StyleVars{
      "fill"   => Egui::Color32.rgb(9, 9, 9),
      "height" => 5.0,
    })
    sheet.rule("sidebar.tab:hover", Egui::StyleVars{"fill" => Egui::Color32.rgb(3, 3, 3)})

    # class layer (defaults): more specific class wins per key
    base = sheet.resolve("sidebar.tab")
    base["font_size"].should eq(14.0)                    # inherited from ancestor
    base["fill"].should eq(Egui::Color32.rgb(2, 2, 2))   # own class wins
    base["height"].should eq(30.0)

    hover = sheet.resolve("sidebar.tab", "hover")
    # states always override classes — even the ancestor state beats
    # the leaf class default ("height" only set by sidebar:hover)
    hover["height"].should eq(5.0)
    # among states the leaf wins ("fill")
    hover["fill"].should eq(Egui::Color32.rgb(3, 3, 3))
    # the class-only resolve stays unaffected by overlays
    sheet.resolve("sidebar.tab")["fill"].should eq(Egui::Color32.rgb(2, 2, 2))
  end

  it "caches merged bags between frames; rule() drops the cache" do
    sheet = Egui::StyleSheet.new
    sheet.rule("x", Egui::StyleVars{"height" => 10.0})

    a = sheet.resolve("x")
    sheet.resolve("x").same?(a).should be_true

    sheet.rule("x", Egui::StyleVars{"height" => 20.0})
    sheet.resolve("x").same?(a).should be_false
    sheet.resolve("x")["height"].should eq(20.0)
  end

  it "coerces Int32 keys to Float64; boxes read per-side with shorthand fallback" do
    vars = Egui::StyleVars.new
    vars["height"] = 24
    vars.f64("height", 0.0).should eq(24.0)
    vars.f64("missing", 7.0).should eq(7.0)
    vars.f64?("fill").should be_nil # wrong type = unset, not a crash

    # per-side keys; missing sides fall back to the scalar shorthand,
    # then to 0 (CSS: `padding: 10px` sets all sides)
    box = Egui::StyleVars{"padding" => 10.0, "padding.left" => 24}
    pad = box.box("padding")
    pad.top.should eq(10.0)
    pad.right.should eq(10.0)
    pad.bottom.should eq(10.0)
    pad.left.should eq(24.0) # Int32 key coerced
    pad.vertical.should eq(20.0)
    pad.horizontal.should eq(34.0)
    Egui::StyleVars.new.box("padding").top.should eq(0.0)
  end

  it "introspects: classes, selectors and dump list every key" do
    theme = Egui::Theme.dark
    sheet = theme.sheet

    sheet.classes.should contain("sidebar")
    sheet.classes.should contain("sidebar.tab")
    sheet.selectors.should contain("sidebar.tab")
    sheet.selectors.should contain("sidebar.tab:hover")
    sheet.selectors.should contain("sidebar.tab:selected")

    io = IO::Memory.new
    sheet.dump(io)
    tree = io.to_s
    {"sidebar", "section", "tab", ":hover", ":selected", "padding.top",
     "padding.left", "padding.bottom", "padding.right",
     "tab_spacing", "margin.top", "font_size"}.each do |key|
      tree.should contain(key)
    end
    # values render CSS-ish: colors as #rrggbbaa hex
    hex = sprintf("#%02x%02x%02x%02x", 0, 122, 204, 255)
    tree.should contain(hex)
    sheet.to_s.should contain("sidebar") # to_s goes through dump
  end

  it "theme presets ship sidebar defaults that follow the palette" do
    dark = Egui::Theme.dark
    light = Egui::Theme.light

    dark.sheet.resolve("sidebar.tab", "selected")["fill"]
      .should eq(dark.style.visuals.selection_fill)
    dark.sheet.resolve("sidebar.tab", "hover")["fill"]
      .should eq(dark.style.visuals.button_weak)
    # each preset owns its sheet — light hover follows light visuals
    light.sheet.resolve("sidebar.tab", "hover")["fill"]
      .should eq(light.style.visuals.button_weak)
    light.sheet.should_not be(dark.sheet)
  end
end

describe "DefaultTheme (default_theme.cr — all defaults in one place)" do
  it "assembles the presets; Theme.dark/light delegate to it" do
    Egui::DefaultTheme.dark.name.should eq("dark")
    Egui::DefaultTheme.light.name.should eq("light")
    Egui::DefaultTheme.dark.style.visuals.selection_fill
      .should eq(Egui::Theme.dark.style.visuals.selection_fill)

    # custom preset derived from the defaults
    custom = Egui::DefaultTheme.build("ocean", dark: true)
    custom.style.visuals.dark.should be_true
    custom.sheet.selectors.should contain("button:hover")
  end

  it "ships class rules for every styled element" do
    sheet = Egui::Theme.dark.sheet
    {"sidebar", "sidebar.tab", "sidebar.tab:selected",
     "button", "button:hover", "button:active"}.each do |sel|
      sheet.selectors.should contain(sel)
    end
    sheet.resolve("button")["fill"]
      .should eq(Egui::Theme.dark.style.visuals.button_weak)
  end

  it "buttons restyle live through their class (padding box, hover fill)" do
    ctx = Egui::Context.new

    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events: events, time: time)
      rect = widget_ui(ctx).button("OK").rect
      ctx.end_frame
      rect
    end

    before = draw.call([] of Egui::Event, 0.016)

    # thicker padding → taller button, same class, next frame
    ctx.stylesheet.rule("button", Egui::StyleVars{
      "padding.top"    => 14.0,
      "padding.bottom" => 14.0,
    })
    after = draw.call([] of Egui::Event, 0.032)
    # 4→14 top and bottom: exactly +20
    after.height.should be_close(before.height + 20.0, 0.01)

    # class state rule paints the hover fill
    orange = Egui::Color32.rgb(255, 140, 0)
    ctx.stylesheet.rule("button:hover", Egui::StyleVars{"fill" => orange})
    draw.call([Egui::Event.pointer_moved(after.center)], 0.048)
    ctx.painter.commands.select(Egui::RectCmd)
      .find(&.fill.==(orange)).should_not be_nil

    # per-widget #style still beats the class (inline > stylesheet)
    red = Egui::Color32.rgb(170, 40, 40)
    draw2 = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events: events, time: time)
      widget_ui(ctx).add(Egui::Button.new("OK").style { |s| s.fill = red })
      ctx.end_frame
    end
    # park the pointer away so the button is in its base state
    draw2.call([Egui::Event.pointer_moved(Egui::Pos2.new(700.0, 500.0))], 0.064)
    ctx.painter.commands.select(Egui::RectCmd)
      .find(&.fill.==(red)).should_not be_nil
  end
end
