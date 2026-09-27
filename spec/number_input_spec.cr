require "spec"
require "../src/egui"

NI_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(300.0, 300.0))

def ni_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
             time : Float64 = 0.016, &)
  ctx.begin_frame(Egui::RawInput.new(NI_SCREEN, events, time))
  ui = Egui::Ui.new(ctx, Egui::Id.from("spec"), NI_SCREEN)
  yield ui
  ctx.end_frame
end

describe Egui::NumberInput do
  it "renders the value with prefix/suffix" do
    ctx = Egui::Context.new
    ni_frame(ctx) { |ui| ui.number_input(42, prefix: "w: ", suffix: " px") { } }
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).should contain("w: 42 px")
  end

  it "pressing the up arrow button steps once immediately" do
    ctx = Egui::Context.new
    value = 10
    up_center = nil

    3.times do |i|
      events = [] of Egui::Event
      if i == 1 && (c = up_center)
        events << Egui::Event.pointer_moved(c)
        events << Egui::Event.pointer_pressed(c)
      end
      ni_frame(ctx, events, 0.016 * (i + 1)) do |ui|
        r = ui.number_input(value) { |v| value = v }
        up_center = ctx.memory.widget_rects[r.id.child(Egui::NumberInput::UP_SALT)]
          .not_nil!.center
      end
    end
    value.should eq(11)
  end

  it "holding the up arrow auto-repeats" do
    ctx = Egui::Context.new
    value = 0
    center = nil

    # frame 0: layout; frame 1: press (steps once); frames 2..: hold —
    # 16ms frames, delay 0.4s ≈ frame 26, then 15 steps/s.
    steps_at = [] of Float64

    45.times do |i|
      events = [] of Egui::Event
      if i > 0 && (c = center)
        events << Egui::Event.pointer_moved(c)
        events << Egui::Event.pointer_pressed(c) if i == 1
      end
      before = value
      ni_frame(ctx, events, 0.016 * (i + 1)) do |ui|
        r = ui.number_input(value) { |v| value = v }
        center = ctx.memory.widget_rects[r.id.child(Egui::NumberInput::UP_SALT)]
          .not_nil!.center
      end
      steps_at << value.to_f64 if value != before
    end
    # press step + at least a couple of repeats within 0.72s of holding
    value.should be > 3
  end

  it "rejects non-digit input, commits digits on Enter" do
    ctx = Egui::Context.new
    value = 5
    id = nil

    draw = ->(events : Array(Egui::Event), time : Float64) do
      ni_frame(ctx, events, time) do |ui|
        r = ui.number_input(value) { |v| value = v }
        id = r.id
      end
    end

    draw.call([] of Egui::Event, 0.016)
    # focus via Tab (only focusable widget), lands next frame
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Tab)], 0.032)
    draw.call([] of Egui::Event, 0.048)
    ctx.memory.focus.has_focus?(id.not_nil!).should be_true

    # letters and the decimal point are dropped, digits pass
    draw.call([Egui::Event.text_input("a")], 0.064)
    draw.call([Egui::Event.text_input("7")], 0.080)
    draw.call([Egui::Event.text_input(".")], 0.096)
    draw.call([Egui::Event.text_input("3")], 0.112)
    value.should eq(5) # buffer only

    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Enter)], 0.128)
    value.should eq(73)
  end

  it "clamps typed values and arrow steps to the range" do
    ctx = Egui::Context.new
    value = 50
    id = nil

    draw = ->(events : Array(Egui::Event), time : Float64) do
      ni_frame(ctx, events, time) do |ui|
        r = ui.number_input(value, 0..100) { |v| value = v }
        id = r.id
      end
    end

    draw.call([] of Egui::Event, 0.016)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Tab)], 0.032)
    draw.call([] of Egui::Event, 0.048)

    # type 999 → Enter clamps to 100
    draw.call([Egui::Event.text_input("9"),
      Egui::Event.text_input("9"), Egui::Event.text_input("9")], 0.064)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Enter)], 0.080)
    value.should eq(100)

    # Up at the ceiling is a no-op; Down steps and commits immediately
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Up)], 0.096)
    value.should eq(100)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Down)], 0.112)
    value.should eq(99)
  end

  it "rejects a minus sign when the range has no negatives" do
    ctx = Egui::Context.new
    value = 3
    id = nil

    draw = ->(events : Array(Egui::Event), time : Float64) do
      ni_frame(ctx, events, time) do |ui|
        r = ui.number_input(value, 0..10) { |v| value = v }
        id = r.id
      end
    end

    draw.call([] of Egui::Event, 0.016)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Tab)], 0.032)
    draw.call([] of Egui::Event, 0.048)
    # "-" never starts an edit → Enter finds no buffer → value intact
    draw.call([Egui::Event.text_input("-")], 0.064)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Enter)], 0.080)
    value.should eq(3)
  end

  it "accepts negatives when the range allows them" do
    ctx = Egui::Context.new
    value = 0
    id = nil

    draw = ->(events : Array(Egui::Event), time : Float64) do
      ni_frame(ctx, events, time) do |ui|
        r = ui.number_input(value, -50..50) { |v| value = v }
        id = r.id
      end
    end

    draw.call([] of Egui::Event, 0.016)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Tab)], 0.032)
    draw.call([] of Egui::Event, 0.048)
    draw.call([Egui::Event.text_input("-7")], 0.064)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Enter)], 0.080)
    value.should eq(-7)
  end

  it "commits the buffer when focus moves away" do
    ctx = Egui::Context.new
    value = 1
    id = nil

    draw = ->(events : Array(Egui::Event), time : Float64) do
      ni_frame(ctx, events, time) do |ui|
        ui.button("other") # somewhere for Tab to go
        r = ui.number_input(value) { |v| value = v }
        id = r.id
      end
    end

    draw.call([] of Egui::Event, 0.016)
    # first Tab lands on the button, second on the number input
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Tab)], 0.032)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Tab)], 0.048)
    draw.call([] of Egui::Event, 0.064)
    ctx.memory.focus.has_focus?(id.not_nil!).should be_true

    draw.call([Egui::Event.text_input("9"),
      Egui::Event.text_input("9")], 0.080)
    # Tab away: blur commits the "99" buffer (Windows kill-focus);
    # the focus move lands the frame after the Tab itself.
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Tab)], 0.096)
    draw.call([] of Egui::Event, 0.112)
    value.should eq(99)
  end

  it "Escape cancels the edit buffer" do
    ctx = Egui::Context.new
    value = 8

    draw = ->(events : Array(Egui::Event), time : Float64) do
      ni_frame(ctx, events, time) do |ui|
        ui.number_input(value) { |v| value = v }
      end
    end

    draw.call([] of Egui::Event, 0.016)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Tab)], 0.032)
    draw.call([] of Egui::Event, 0.048)
    draw.call([Egui::Event.text_input("1"),
      Egui::Event.text_input("1")], 0.064)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Escape)], 0.080)
    value.should eq(8)
  end

  it "the mouse wheel steps once per scroll event while hovering" do
    ctx = Egui::Context.new
    value = 20
    field_center = nil

    2.times do |i|
      ni_frame(ctx, [] of Egui::Event, 0.016 * (i + 1)) do |ui|
        r = ui.number_input(value) { |v| value = v }
        field_center = r.rect.center
      end
    end

    ni_frame(ctx, [Egui::Event.pointer_moved(field_center.not_nil!),
      Egui::Event.scroll(Egui::Vec2.new(0.0, -120.0))], 0.048) do |ui|
      ui.number_input(value) { |v| value = v }
    end
    value.should eq(19)
  end

  it "claims the wheel over a parent ScrollArea (no double scroll)" do
    ctx = Egui::Context.new
    value = 5
    center = nil
    ni_id = nil

    draw = ->(events : Array(Egui::Event), time : Float64) do
      ni_frame(ctx, events, time) do |ui|
        ui.scroll_area(max_height: 40.0) do |inner|
          20.times { |i| inner.label("line #{i}") }
          r = inner.number_input(value) { |v| value = v }
          ni_id = r.id
          center = r.rect.center
        end
      end
    end

    draw.call([] of Egui::Event, 0.016)
    draw.call([] of Egui::Event, 0.032)
    # wheel down over the input: the input steps, the parent stays put
    draw.call([Egui::Event.pointer_moved(center.not_nil!),
      Egui::Event.scroll(Egui::Vec2.new(0.0, -1.0))], 0.048)

    value.should eq(4)
    parent_sink = ctx.memory.scroll_rects.keys.find { |k| k != ni_id }
    parent_sink.not_nil! # the ScrollArea viewport registered beside it
    ctx.memory.data.get_vec2(parent_sink.not_nil!)
      .should eq(Egui::Vec2.new(0.0, 0.0))
  end

  it "binds to a Signal(Int32) without a block" do
    ctx = Egui::Context.new
    sig = Egui::Signal.new(7)

    ni_frame(ctx) { |ui| ui.number_input(sig, 0..10, step: 2) }
    sig.value.should eq(7)

    id = nil
    ni_frame(ctx) { |ui| id = ui.number_input(sig, 0..10, step: 2).id }
    draw = ->(events : Array(Egui::Event), time : Float64) do
      ni_frame(ctx, events, time) { |ui| ui.number_input(sig, 0..10, step: 2) }
    end
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Tab)], 0.064)
    draw.call([] of Egui::Event, 0.080)
    # Up steps by 2 and writes straight into the signal
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Up)], 0.096)
    sig.value.should eq(9)
  end
end
