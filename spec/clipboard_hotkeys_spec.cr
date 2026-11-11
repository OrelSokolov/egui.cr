# Copy/paste HOTKEYS (Ctrl+C / Ctrl+V) across the text widgets: the
# focused editable fields own them (TextEdit/TextArea keyboard pass),
# but selections that live OUTSIDE the focus system — readonly text
# views (ScrolledLabel) and labels — must still answer Ctrl+C, and a
# keyboard focus held by a NON-text widget (a combo box) must not
# block a label copy (the browser rule: only a focused editable owns
# the clipboard).
require "spec"
require "../src/egui"

CH_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 300.0))

def ch_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
             time : Float64 = 0.016, &)
  ctx.begin_frame(Egui::RawInput.new(CH_SCREEN, events, time))
  ui = Egui::Ui.new(ctx, Egui::Id.from("spec"), CH_SCREEN)
  yield ui
  ctx.end_frame
end

describe "clipboard hotkeys" do
  it "textarea: mouse drag-select then Ctrl+C copies" do
    Egui::SystemPorts::Clipboard.text = ""
    ctx = Egui::Context.new
    rect = nil
    buffer = "hello world"
    draw = ->(events : Array(Egui::Event), time : Float64) do
      ch_frame(ctx, events, time) do |ui|
        rect = ui.textarea(buffer) { |t| buffer = t }.rect
      end
    end

    draw.call([] of Egui::Event, 0.016)
    r = rect.not_nil!
    # frameless view: x=0 is the exact glyph-0 boundary (a couple px in
    # maps past glyph 0 and shifts the selection start)
    left = Egui::Pos2.new(r.min.x, r.min.y + 12.0)
    right = Egui::Pos2.new(r.max.x - 2.0, r.min.y + 12.0)
    draw.call([Egui::Event.pointer_moved(left),
      Egui::Event.pointer_pressed(left)], 0.032)
    draw.call([Egui::Event.pointer_moved(right)], 0.048)
    draw.call([Egui::Event.pointer_released(right)], 0.064)

    ctrl = Egui::Modifiers.new(ctrl: true)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::C, ctrl)], 0.080)
    Egui::SystemPorts::Clipboard.text.should eq("hello world")
  end

  it "readonly textarea: mouse drag-select then Ctrl+C copies" do
    Egui::SystemPorts::Clipboard.text = ""
    ctx = Egui::Context.new
    rect = nil
    draw = ->(events : Array(Egui::Event), time : Float64) do
      ch_frame(ctx, events, time) do |ui|
        rect = ui.scrolledlabel("hello world").rect
      end
    end

    draw.call([] of Egui::Event, 0.016)
    r = rect.not_nil!
    # frameless view: x=0 is the exact glyph-0 boundary (a couple px in
    # maps past glyph 0 and shifts the selection start)
    left = Egui::Pos2.new(r.min.x, r.min.y + 12.0)
    right = Egui::Pos2.new(r.max.x - 2.0, r.min.y + 12.0)
    draw.call([Egui::Event.pointer_moved(left),
      Egui::Event.pointer_pressed(left)], 0.032)
    draw.call([Egui::Event.pointer_moved(right)], 0.048)
    draw.call([Egui::Event.pointer_released(right)], 0.064)

    ctrl = Egui::Modifiers.new(ctrl: true)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::C, ctrl)], 0.080)
    Egui::SystemPorts::Clipboard.text.should eq("hello world")
  end

  it "readonly textarea: Ctrl+A selects all, Ctrl+C copies" do
    Egui::SystemPorts::Clipboard.text = ""
    ctx = Egui::Context.new
    draw = ->(events : Array(Egui::Event), time : Float64) do
      ch_frame(ctx, events, time) do |ui|
        ui.scrolledlabel("hello world")
      end
    end

    draw.call([] of Egui::Event, 0.016)
    ctrl = Egui::Modifiers.new(ctrl: true)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::A, ctrl)], 0.032)
    draw.call([Egui::Event.key_released(Egui::KeyCode::A, Egui::Modifiers.new)], 0.048)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::C, ctrl)], 0.064)
    Egui::SystemPorts::Clipboard.text.should eq("hello world")
  end

  it "label: Ctrl+C works while a non-text widget holds keyboard focus" do
    Egui::SystemPorts::Clipboard.text = ""
    ctx = Egui::Context.new
    label_rect = nil
    draw = ->(events : Array(Egui::Event), time : Float64) do
      ch_frame(ctx, events, time) do |ui|
        label_rect = ui.label("Hello World!").rect
        ui.combo_box("pick", "a", ["a", "b"]) { |_| }
      end
    end

    draw.call([] of Egui::Event, 0.016)
    draw.call([] of Egui::Event, 0.032) # rects settle
    # the combo box: the focusable rect below the label
    lr = label_rect.not_nil!
    cr = ctx.memory.widget_rects.values.find { |w| w.top > lr.bottom }
    combo_pos = Egui::Pos2.new(cr.not_nil!.center.x, cr.not_nil!.center.y)
    # click the combo box — it takes keyboard focus and KEEPS it
    draw.call([Egui::Event.pointer_moved(combo_pos),
      Egui::Event.pointer_pressed(combo_pos),
      Egui::Event.pointer_released(combo_pos)], 0.048)
    draw.call([] of Egui::Event, 0.064)
    ctx.memory.focus.id.should_not be_nil # focus really held

    # drag-select the label text — the copy must work despite the focus
    left = Egui::Pos2.new(lr.min.x, lr.center.y)
    right = Egui::Pos2.new(lr.right, lr.center.y)
    draw.call([Egui::Event.pointer_moved(left),
      Egui::Event.pointer_pressed(left)], 0.080)
    draw.call([Egui::Event.pointer_moved(right)], 0.096)
    draw.call([Egui::Event.pointer_released(right)], 0.112)

    ctrl = Egui::Modifiers.new(ctrl: true)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::C, ctrl)], 0.128)
    Egui::SystemPorts::Clipboard.text.should eq("Hello World!")
  end

  it "label: Ctrl+A selects all then Ctrl+C copies" do
    Egui::SystemPorts::Clipboard.text = ""
    ctx = Egui::Context.new
    draw = ->(events : Array(Egui::Event), time : Float64) do
      ch_frame(ctx, events, time) do |ui|
        ui.label("Hello World!")
      end
    end

    draw.call([] of Egui::Event, 0.016)
    ctrl = Egui::Modifiers.new(ctrl: true)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::A, ctrl)], 0.032)
    draw.call([Egui::Event.key_released(Egui::KeyCode::A, Egui::Modifiers.new)], 0.048)
    # selection highlight painted
    sel_fill = ctx.style.visuals.text_selection
    ctx.painter.commands.select(Egui::RectCmd)
      .any? { |c| c.fill == sel_fill }.should be_true
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::C, ctrl)], 0.064)
    Egui::SystemPorts::Clipboard.text.should eq("Hello World!")
  end

  it "textarea: Ctrl+C copies the painted selection after focus was lost" do
    Egui::SystemPorts::Clipboard.text = ""
    ctx = Egui::Context.new
    rect = nil
    buffer = "hello world"
    draw = ->(events : Array(Egui::Event), time : Float64) do
      ch_frame(ctx, events, time) do |ui|
        rect = ui.textarea(buffer) { |t| buffer = t }.rect
      end
    end

    draw.call([] of Egui::Event, 0.016)
    r = rect.not_nil!
    left = Egui::Pos2.new(r.min.x + 2.0, r.min.y + 12.0)
    right = Egui::Pos2.new(r.max.x - 2.0, r.min.y + 12.0)
    draw.call([Egui::Event.pointer_moved(left),
      Egui::Event.pointer_pressed(left)], 0.032)
    draw.call([Egui::Event.pointer_moved(right)], 0.048)
    draw.call([Egui::Event.pointer_released(right)], 0.064)
    # click empty space outside — the field surrenders focus but the
    # selection stays painted, so Ctrl+C must still copy it
    outside = Egui::Pos2.new(380.0, 290.0)
    draw.call([Egui::Event.pointer_moved(outside),
      Egui::Event.pointer_pressed(outside),
      Egui::Event.pointer_released(outside)], 0.080)
    draw.call([] of Egui::Event, 0.096)
    ctx.memory.focus.id.should be_nil

    ctrl = Egui::Modifiers.new(ctrl: true)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::C, ctrl)], 0.112)
    Egui::SystemPorts::Clipboard.text.should eq("hello world")
  end

  it "focused TextEdit still owns Ctrl+C (label does not steal it)" do
    Egui::SystemPorts::Clipboard.text = "sentinel"
    ctx = Egui::Context.new
    edit_rect = nil
    text = "edit text"
    draw = ->(events : Array(Egui::Event), time : Float64) do
      ch_frame(ctx, events, time) do |ui|
        ui.label("label text")
        r = ui.add(Egui::TextEdit.new(text))
        text = r.widget_text.not_nil!
        edit_rect = r.rect
      end
    end

    draw.call([] of Egui::Event, 0.016)
    er = edit_rect.not_nil!
    pos = Egui::Pos2.new(er.min.x + 12.0, er.center.y)
    draw.call([Egui::Event.pointer_moved(pos),
      Egui::Event.pointer_pressed(pos)], 0.032)
    draw.call([Egui::Event.pointer_released(pos)], 0.048)
    ctx.memory.focus.id.should_not be_nil

    # select all in the edit, then Ctrl+C must copy the EDIT's text
    ctrl = Egui::Modifiers.new(ctrl: true)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::A, ctrl)], 0.064)
    draw.call([Egui::Event.key_released(Egui::KeyCode::A, Egui::Modifiers.new)], 0.080)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::C, ctrl)], 0.096)
    Egui::SystemPorts::Clipboard.text.should eq("edit text")
  end
end
