# Clipboard context menu for the text widgets (TextEditMenu): a touch
# LONG-PRESS (Memory synthesizes the secondary press after 0.5 s held
# stationary) opens Copy / Cut / Paste / Select All over the field,
# long-press selects the word under the finger (Android semantics), and
# the item handlers record a command the widget applies next frame.
require "spec"
require "../src/egui"

TCM_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 300.0))

def tcm_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
              time : Float64 = 0.016, &)
  ctx.begin_frame(Egui::RawInput.new(TCM_SCREEN, events, time))
  ui = Egui::Ui.new(ctx, Egui::Id.from("spec"), TCM_SCREEN)
  yield ui
  ctx.end_frame
end

# A point over the field's text (left edge of the inner area).
def tcm_field_pos(ctx : Egui::Context, id : Egui::Id) : Egui::Pos2
  rect = ctx.memory.widget_rects[id]
  Egui::Pos2.new(rect.min.x + 12.0, rect.center.y)
end

describe "text clipboard context menu" do
  it "long-press selects the word, opens the menu, Copy works" do
    Egui::SystemPorts::Clipboard.text = ""
    ctx = Egui::Context.new
    id = nil
    text = "hello world"
    draw = ->(events : Array(Egui::Event), time : Float64) do
      tcm_frame(ctx, events, time) do |ui|
        r = ui.add(Egui::TextEdit.new(text))
        id = r.id
        text = r.widget_text.not_nil!
      end
    end

    draw.call([] of Egui::Event, 0.016) # field rect registered
    pos = tcm_field_pos(ctx, id.not_nil!)

    # Press and HOLD stationary: no click/drag engages, and at +0.5 s
    # Memory fires the long-press → same-frame word selection + menu.
    draw.call([Egui::Event.pointer_pressed(pos)], 0.032)
    draw.call([] of Egui::Event, 0.400) # still holding (< 0.5 s)
    ctx.memory.long_press_fired?.should be_false
    draw.call([] of Egui::Event, 0.700) # 0.668 s ≥ 0.5 s → fires
    ctx.memory.long_press_fired?.should be_true

    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("Copy")
    texts.should contain("Paste")
    texts.should contain("Select all")

    # Lift the finger (the long-press cancelled the pending click, so
    # the popup must NOT close), then click the Copy row.
    draw.call([Egui::Event.pointer_released(pos)], 0.716)
    draw.call([] of Egui::Event, 0.732) # popup row rects registered
    item = Egui::Pos2.new(pos.x + 12.0, pos.y + 12.0)
    draw.call([Egui::Event.pointer_pressed(item)], 0.748)
    draw.call([Egui::Event.pointer_released(item)], 0.764)
    draw.call([] of Egui::Event, 0.780) # the recorded command applies

    # The long-press selected "hello"; Copy put it on the clipboard.
    Egui::SystemPorts::Clipboard.text.should eq("hello")
    # The menu closed on the click (menu_popup_key must survive the
    # `enabled` child ui the rows live in).
    ctx.memory.open_popups.empty?.should be_true
  end

  it "Copy stays disabled with no selection (empty field)" do
    Egui::SystemPorts::Clipboard.text = "clip"
    ctx = Egui::Context.new
    id = nil
    draw = ->(events : Array(Egui::Event), time : Float64) do
      tcm_frame(ctx, events, time) do |ui|
        r = ui.add(Egui::TextEdit.new(""))
        id = r.id
      end
    end

    draw.call([] of Egui::Event, 0.016)
    pos = tcm_field_pos(ctx, id.not_nil!)
    draw.call([Egui::Event.pointer_pressed(pos)], 0.032)
    draw.call([] of Egui::Event, 0.700) # long-press fires, menu opens

    # The rows render (grayed) — clicking Copy must do nothing.
    draw.call([Egui::Event.pointer_released(pos)], 0.716)
    draw.call([] of Egui::Event, 0.732)
    item = Egui::Pos2.new(pos.x + 12.0, pos.y + 12.0)
    draw.call([Egui::Event.pointer_pressed(item)], 0.748)
    draw.call([Egui::Event.pointer_released(item)], 0.780)
    Egui::SystemPorts::Clipboard.text.should eq("clip")

    # Disabled rows gray out through MUTED TEXT, not a scrim band: the
    # panel_fill rectangle read as a black background over the menu.
    v = ctx.style.visuals
    scrim = v.fade_color(v.panel_fill, 0.5)
    ctx.painter.commands.select(Egui::RectCmd)
      .any? { |c| c.fill == scrim }.should be_false
    copy = ctx.painter.commands.select(Egui::TextCmd)
      .find(&.text.==("Copy")).not_nil!
    copy.color.should eq(v.fade_color(v.text_color, 0.45))
    # the empty field disables Select all as well — muted the same way
    sel = ctx.painter.commands.select(Egui::TextCmd)
      .find(&.text.==("Select all")).not_nil!
    sel.color.should eq(v.fade_color(v.text_color, 0.45))
  end

  it "applies a recorded paste command (single-line strips breaks)" do
    Egui::SystemPorts::Clipboard.text = "PA\nST"
    ctx = Egui::Context.new
    id = nil
    text = "hello world"
    draw = ->(events : Array(Egui::Event), time : Float64) do
      tcm_frame(ctx, events, time) do |ui|
        r = ui.add(Egui::TextEdit.new(text))
        id = r.id
        text = r.widget_text.not_nil!
      end
    end

    draw.call([] of Egui::Event, 0.016)
    # What the Paste item handler leaves behind; the widget's next
    # frame applies it before its keyboard pass.
    ctx.memory.data.set_string(
      id.not_nil!.child(Egui::TextEditMenu::CMD_SALT), "paste")
    draw.call([] of Egui::Event, 0.032)

    # Caret starts at the end: the paste appends, newline flattened.
    text.should eq("hello worldPA ST")
  end

  it "select_all + cut empties the field and takes the text" do
    Egui::SystemPorts::Clipboard.text = ""
    ctx = Egui::Context.new
    id = nil
    text = "hello world"
    draw = ->(events : Array(Egui::Event), time : Float64) do
      tcm_frame(ctx, events, time) do |ui|
        r = ui.add(Egui::TextEdit.new(text))
        id = r.id
        text = r.widget_text.not_nil!
      end
    end

    draw.call([] of Egui::Event, 0.016)
    cmd = id.not_nil!.child(Egui::TextEditMenu::CMD_SALT)
    ctx.memory.data.set_string(cmd, "select_all")
    draw.call([] of Egui::Event, 0.032)
    ctx.memory.data.set_string(cmd, "cut")
    draw.call([] of Egui::Event, 0.048)

    text.should eq("")
    Egui::SystemPorts::Clipboard.text.should eq("hello world")
  end
end
