# Document-wide text selection (TextSelection): a drag crosses widget
# boundaries like in a browser — anchor and focus are (cell, char)
# positions in the global selection, each label paints its own slice
# of the highlight, and Copy assembles the text in document order.
require "spec"
require "../src/egui"

TS_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 300.0))

def ts_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
             time : Float64 = 0.016, &)
  ctx.begin_frame(Egui::RawInput.new(TS_SCREEN, events, time))
  ui = Egui::Ui.new(ctx, Egui::Id.from("spec"), TS_SCREEN)
  yield ui
  ctx.end_frame
end

describe "document-wide text selection" do
  it "a drag across three labels copies all their text in order" do
    Egui::SystemPorts::Clipboard.text = ""
    ctx = Egui::Context.new
    rects = [] of Egui::Rect
    draw = ->(events : Array(Egui::Event), time : Float64) do
      ts_frame(ctx, events, time) do |ui|
        rects.clear
        rects << ui.label("one").rect
        rects << ui.label("two").rect
        rects << ui.label("three").rect
      end
    end

    draw.call([] of Egui::Event, 0.016)
    draw.call([] of Egui::Event, 0.032) # cells settle
    r1 = rects[0]
    r3 = rects[2]
    left = Egui::Pos2.new(r1.min.x, r1.center.y)
    right = Egui::Pos2.new(r3.right, r3.center.y)
    draw.call([Egui::Event.pointer_moved(left),
      Egui::Event.pointer_pressed(left)], 0.048)
    draw.call([Egui::Event.pointer_moved(right)], 0.064)
    draw.call([Egui::Event.pointer_released(right)], 0.080)

    ctx.text_selection.any_selection?.should be_true
    ctrl = Egui::Modifiers.new(ctrl: true)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::C, ctrl)], 0.096)
    Egui::SystemPorts::Clipboard.text.should eq("one\ntwo\nthree")
  end

  it "a partial drag paints a strip in every label it crosses" do
    ctx = Egui::Context.new
    rects = [] of Egui::Rect
    draw = ->(events : Array(Egui::Event), time : Float64) do
      ts_frame(ctx, events, time) do |ui|
        rects.clear
        rects << ui.label("alpha").rect
        rects << ui.label("beta").rect
      end
    end

    draw.call([] of Egui::Event, 0.016)
    draw.call([] of Egui::Event, 0.032)
    r1 = rects[0]
    r2 = rects[1]
    # from past the middle of "alpha" to the right edge of "beta"
    start = Egui::Pos2.new(r1.min.x + r1.width * 0.6, r1.center.y)
    fin = Egui::Pos2.new(r2.right, r2.center.y)
    draw.call([Egui::Event.pointer_moved(start),
      Egui::Event.pointer_pressed(start)], 0.048)
    draw.call([Egui::Event.pointer_moved(fin),
      Egui::Event.pointer_released(fin)], 0.064)
    draw.call([] of Egui::Event, 0.080)

    # one selection strip per crossed label, both in this frame's paint
    sel_fill = ctx.style.visuals.text_selection
    ctx.painter.commands.select(Egui::RectCmd)
      .count { |c| c.fill == sel_fill }.should eq(2)
  end

  it "double-click selects a word through the global gesture" do
    Egui::SystemPorts::Clipboard.text = ""
    ctx = Egui::Context.new
    rect = nil
    draw = ->(events : Array(Egui::Event), time : Float64) do
      ts_frame(ctx, events, time) do |ui|
        rect = ui.label("Hello World!").rect
      end
    end

    draw.call([] of Egui::Event, 0.016)
    draw.call([] of Egui::Event, 0.032)
    r = rect.not_nil!
    pos = Egui::Pos2.new(r.center.x, r.center.y)
    draw.call([Egui::Event.pointer_moved(pos),
      Egui::Event.pointer_pressed(pos)], 0.048)
    draw.call([Egui::Event.pointer_released(pos)], 0.064)
    draw.call([Egui::Event.pointer_pressed(pos)], 0.080)
    draw.call([Egui::Event.pointer_released(pos)], 0.096)

    ctx.text_selection.any_selection?.should be_true
    ctrl = Egui::Modifiers.new(ctrl: true)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::C, ctrl)], 0.112)
    Egui::SystemPorts::Clipboard.text.should eq("World")
  end

  it "a press on a non-text widget clears the selection" do
    Egui::SystemPorts::Clipboard.text = ""
    ctx = Egui::Context.new
    rect = nil
    btn = nil
    draw = ->(events : Array(Egui::Event), time : Float64) do
      ts_frame(ctx, events, time) do |ui|
        rect = ui.label("Hello World!").rect
        btn = ui.button("click").rect
      end
    end

    draw.call([] of Egui::Event, 0.016)
    draw.call([] of Egui::Event, 0.032)
    r = rect.not_nil!
    left = Egui::Pos2.new(r.min.x, r.center.y)
    right = Egui::Pos2.new(r.right, r.center.y)
    draw.call([Egui::Event.pointer_moved(left),
      Egui::Event.pointer_pressed(left)], 0.048)
    draw.call([Egui::Event.pointer_moved(right)], 0.064)
    draw.call([Egui::Event.pointer_released(right)], 0.080)
    ctx.text_selection.any_selection?.should be_true

    b = btn.not_nil!
    bpos = Egui::Pos2.new(b.center.x, b.center.y)
    draw.call([Egui::Event.pointer_moved(bpos),
      Egui::Event.pointer_pressed(bpos),
      Egui::Event.pointer_released(bpos)], 0.096)
    ctx.text_selection.any_selection?.should be_false
  end

  it "a drag started inside the first glyph grabs it (half-glyph snapping)" do
    Egui::SystemPorts::Clipboard.text = ""
    ctx = Egui::Context.new
    rect = nil
    draw = ->(events : Array(Egui::Event), time : Float64) do
      ts_frame(ctx, events, time) do |ui|
        rect = ui.label("Hello World!").rect
      end
    end

    draw.call([] of Egui::Event, 0.016)
    draw.call([] of Egui::Event, 0.032)
    r = rect.not_nil!
    # inside the LEFT half of the first glyph: the caret must land
    # before "H", so dragging right includes it (old glyph-start
    # snapping dropped the first character)
    start = Egui::Pos2.new(r.min.x + 1.5, r.center.y)
    fin = Egui::Pos2.new(r.right, r.center.y)
    draw.call([Egui::Event.pointer_moved(start),
      Egui::Event.pointer_pressed(start)], 0.048)
    draw.call([Egui::Event.pointer_moved(fin),
      Egui::Event.pointer_released(fin)], 0.064)

    ctrl = Egui::Modifiers.new(ctrl: true)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::C, ctrl)], 0.080)
    Egui::SystemPorts::Clipboard.text.should eq("Hello World!")
  end

  it "a click beside the text breaks the double-click series" do
    Egui::SystemPorts::Clipboard.text = ""
    ctx = Egui::Context.new
    rect = nil
    draw = ->(events : Array(Egui::Event), time : Float64) do
      ts_frame(ctx, events, time) do |ui|
        rect = ui.label("Hello World!").rect
      end
    end

    draw.call([] of Egui::Event, 0.016)
    draw.call([] of Egui::Event, 0.032)
    r = rect.not_nil!
    pos = Egui::Pos2.new(r.center.x, r.center.y)
    # double-click → word selected …
    draw.call([Egui::Event.pointer_moved(pos),
      Egui::Event.pointer_pressed(pos),
      Egui::Event.pointer_released(pos)], 0.048)
    draw.call([Egui::Event.pointer_pressed(pos),
      Egui::Event.pointer_released(pos)], 0.064)
    ctx.text_selection.any_selection?.should be_true
    # … a click on empty space clears it and ends the series …
    empty = Egui::Pos2.new(380.0, 290.0)
    draw.call([Egui::Event.pointer_moved(empty),
      Egui::Event.pointer_pressed(empty),
      Egui::Event.pointer_released(empty)], 0.080)
    ctx.text_selection.any_selection?.should be_false
    # … so the NEXT quick click on the label is a plain caret, not a
    # word selection riding the stale sequence
    draw.call([Egui::Event.pointer_moved(pos),
      Egui::Event.pointer_pressed(pos),
      Egui::Event.pointer_released(pos)], 0.096)
    ctx.text_selection.any_selection?.should be_false
  end
end
