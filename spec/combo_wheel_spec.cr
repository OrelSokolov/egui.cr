require "spec"
require "../src/egui"

CB_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(300.0, 300.0))

def cb_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
             time : Float64 = 0.016, &)
  ctx.begin_frame(Egui::RawInput.new(CB_SCREEN, events, time))
  ui = Egui::Ui.new(ctx, Egui::Id.from("spec"), CB_SCREEN)
  yield ui
  ctx.end_frame
end

# The only widget on screen that registers a scroll sink: its rect.
def cb_center(ctx : Egui::Context) : Egui::Pos2
  ctx.memory.scroll_rects.each_value.first[0].center
end

describe "wheel-stepping the combos" do
  it "ComboBox: wheel-down is next, wheel-up is previous, clamped at the ends" do
    ctx = Egui::Context.new
    value = "b"

    2.times do |i|
      cb_frame(ctx, [] of Egui::Event, 0.016 * (i + 1)) do |ui|
        ui.combo_box("cb", value, %w[a b c]) { |v| value = v }
      end
    end
    center = cb_center(ctx)

    # wheel down (scroll.y > 0) → next
    cb_frame(ctx, [Egui::Event.pointer_moved(center),
      Egui::Event.scroll(Egui::Vec2.new(0.0, 1.0))], 0.048) do |ui|
      ui.combo_box("cb", value, %w[a b c]) { |v| value = v }
    end
    value.should eq("c")

    # clamped at the last option
    cb_frame(ctx, [Egui::Event.pointer_moved(center),
      Egui::Event.scroll(Egui::Vec2.new(0.0, 1.0))], 0.064) do |ui|
      ui.combo_box("cb", value, %w[a b c]) { |v| value = v }
    end
    value.should eq("c")

    # wheel up → previous
    cb_frame(ctx, [Egui::Event.pointer_moved(center),
      Egui::Event.scroll(Egui::Vec2.new(0.0, -1.0))], 0.080) do |ui|
      ui.combo_box("cb", value, %w[a b c]) { |v| value = v }
    end
    value.should eq("b")
  end

  it "ComboBox: wheel away from the widget is a no-op" do
    ctx = Egui::Context.new
    value = "b"

    2.times do |i|
      cb_frame(ctx, [] of Egui::Event, 0.016 * (i + 1)) do |ui|
        ui.combo_box("cb", value, %w[a b c]) { |v| value = v }
      end
    end
    cb_frame(ctx, [Egui::Event.pointer_moved(Egui::Pos2.new(280.0, 280.0)),
      Egui::Event.scroll(Egui::Vec2.new(0.0, 1.0))], 0.048) do |ui|
      ui.combo_box("cb", value, %w[a b c]) { |v| value = v }
    end
    value.should eq("b")
  end

  it "SelectBox: wheel steps the selection and the field follows" do
    ctx = Egui::Context.new
    value = "b"

    2.times do |i|
      cb_frame(ctx, [] of Egui::Event, 0.016 * (i + 1)) do |ui|
        ui.select_box("sb", value, %w[a b c]) { |v| value = v }
      end
    end
    center = cb_center(ctx)

    cb_frame(ctx, [Egui::Event.pointer_moved(center),
      Egui::Event.scroll(Egui::Vec2.new(0.0, 1.0))], 0.048) do |ui|
      ui.select_box("sb", value, %w[a b c]) { |v| value = v }
    end
    value.should eq("c")

    cb_frame(ctx, [Egui::Event.pointer_moved(center),
      Egui::Event.scroll(Egui::Vec2.new(0.0, -1.0))], 0.064) do |ui|
      ui.select_box("sb", value, %w[a b c]) { |v| value = v }
    end
    value.should eq("b")

    # the field shows the stepped value (the buffer was rewritten)
    cb_frame(ctx, [] of Egui::Event, 0.080) do |ui|
      ui.select_box("sb", value, %w[a b c]) { |v| value = v }
    end
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).should contain("b")
  end

  it "ComboBox: wheel-down from nothing selected picks the first option" do
    ctx = Egui::Context.new
    value = ""

    2.times do |i|
      cb_frame(ctx, [] of Egui::Event, 0.016 * (i + 1)) do |ui|
        ui.combo_box("cb", value, %w[a b c], label: "pick one") { |v| value = v }
      end
    end
    cb_frame(ctx, [Egui::Event.pointer_moved(cb_center(ctx)),
      Egui::Event.scroll(Egui::Vec2.new(0.0, 1.0))], 0.048) do |ui|
      ui.combo_box("cb", value, %w[a b c], label: "pick one") { |v| value = v }
    end
    value.should eq("a")
  end
end

describe "the open ComboBox list" do
  it "caps at max_height and wheel-scrolls the popup rows" do
    ctx = Egui::Context.new
    value = "opt-1"
    opts = (1..60).map { |i| "opt-#{i}" }

    3.times do |i|
      cb_frame(ctx, [] of Egui::Event, 0.016 * (i + 1)) do |ui|
        ui.combo_box("cb", value, opts, max_height: 120.0) { |v| value = v }
      end
    end
    # Open the list by clicking the button.
    btn = cb_center(ctx)
    cb_frame(ctx, [Egui::Event.pointer_moved(btn),
      Egui::Event.pointer_pressed(btn)], 0.064) do |ui|
      ui.combo_box("cb", value, opts, max_height: 120.0) { |v| value = v }
    end
    cb_frame(ctx, [Egui::Event.pointer_released(btn)], 0.080) do |ui|
      ui.combo_box("cb", value, opts, max_height: 120.0) { |v| value = v }
    end
    ctx.popup_open?("cb").should be_true

    # The list viewport registered on the popup layer (Foreground).
    list_id = Egui::Id.from("cb/list")
    rect = ctx.memory.scroll_rects[list_id]?.try(&.[0])
    rect.should_not be_nil
    rect.not_nil!.height.should be <= 121.0

    # Wheel over the open list scrolls it (not the closed box below).
    list_pos = rect.not_nil!.center
    3.times do |i|
      cb_frame(ctx, [Egui::Event.pointer_moved(list_pos),
        Egui::Event.scroll(Egui::Vec2.new(0.0, 1.0))], 0.096 + 0.016 * i) do |ui|
        ui.combo_box("cb", value, opts, max_height: 120.0) { |v| value = v }
      end
    end
    offset = ctx.memory.data.get_vec2(list_id, Egui::Vec2.zero).y
    offset.should be > 0.0
    # …and the selection was NOT stepped by the popup's wheel.
    value.should eq("opt-1")
  end

  it "Up/Down walk the options when focused, Enter confirms" do
    ctx = Egui::Context.new
    value = "b"

    3.times do |i|
      cb_frame(ctx, [] of Egui::Event, 0.016 * (i + 1)) do |ui|
        ui.combo_box("cb", value, %w[a b c]) { |v| value = v }
      end
    end
    btn = cb_center(ctx)

    # Click focuses the combo (focus lands next frame).
    cb_frame(ctx, [Egui::Event.pointer_moved(btn),
      Egui::Event.pointer_pressed(btn)], 0.064) do |ui|
      ui.combo_box("cb", value, %w[a b c]) { |v| value = v }
    end
    cb_frame(ctx, [Egui::Event.pointer_released(btn)], 0.080) do |ui|
      ui.combo_box("cb", value, %w[a b c]) { |v| value = v }
    end

    # Down opens the list parked on the selection (no step yet).
    cb_frame(ctx, [Egui::Event.key_pressed(Egui::KeyCode::Down)], 0.096) do |ui|
      ui.combo_box("cb", value, %w[a b c]) { |v| value = v }
    end
    ctx.popup_open?("cb").should be_true

    # A second Down walks to "c"; Enter confirms it.
    cb_frame(ctx, [Egui::Event.key_pressed(Egui::KeyCode::Down)], 0.112) do |ui|
      ui.combo_box("cb", value, %w[a b c]) { |v| value = v }
    end
    cb_frame(ctx, [Egui::Event.key_pressed(Egui::KeyCode::Enter)], 0.128) do |ui|
      ui.combo_box("cb", value, %w[a b c]) { |v| value = v }
    end
    value.should eq("c")
    ctx.popup_open?("cb").should be_false
  end
end
