# MenuBar specs: the bar's popups size themselves from their rows —
# a nested submenu root (`Ui#menu_button` inside a popup) must size
# its row like a `menu_item`, not stretch to the popup Ui's unbounded
# max_rect (which ballooned the popup far past its last item).

require "spec"
require "../src/egui"

MENU_SPEC_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 300.0))

describe Egui::Ui do
  it "hugs its rows with a nested submenu root" do
    ctx = Egui::Context.new
    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw = Egui::RawInput.new(MENU_SPEC_SCREEN, events, time)
      ctx.begin_frame(raw)
      ctx.menu_bar do |bar|
        bar.menu_button("View") do |m|
          m.menu_item("Tool Box") { }
          m.menu_item("Status Bar") { }
          m.menu_button("Zoom") do |z|
            z.menu_item("Large Size (2×)") { }
          end
        end
      end
      ctx.end_frame
    end

    draw.call([] of Egui::Event, 0.016) # bar button rect registered
    draw.call([Egui::Event.pointer_pressed(Egui::Pos2.new(20.0, 12.0))],
      0.032)
    draw.call([Egui::Event.pointer_released(Egui::Pos2.new(20.0, 12.0))],
      0.048)
    draw.call([] of Egui::Event, 0.064) # popup laid out

    rect = ctx.memory.popup_rects.values.find(&.max.y.>(100.0))
    rect.should_not be_nil
    # Three rows ≈ 28px each: the popup must end well under 150px,
    # nowhere near the unbounded height the Zoom row used to union in.
    rect.not_nil!.max.y.should be < 150.0
  end
end
