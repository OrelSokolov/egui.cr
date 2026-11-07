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

  it "styles disabled rows through menu.item:disabled and kills their interaction" do
    ctx = Egui::Context.new
    fired = [] of String
    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw = Egui::RawInput.new(MENU_SPEC_SCREEN, events, time)
      ctx.begin_frame(raw)
      ctx.menu_bar do |bar|
        bar.menu_button("File") do |m|
          m.menu_item("Ok") { fired << "ok" }
          m.menu_item("Nope", enabled: false) { fired << "nope" }
        end
      end
      ctx.end_frame
    end

    draw.call([] of Egui::Event, 0.016) # bar button rect registered
    draw.call([Egui::Event.pointer_pressed(Egui::Pos2.new(20.0, 12.0))], 0.032)
    draw.call([Egui::Event.pointer_released(Egui::Pos2.new(20.0, 12.0))], 0.048)
    draw.call([] of Egui::Event, 0.064) # popup laid out

    # The disabled row is the popup's bottom half; hover it.
    popup = ctx.memory.popup_rects.values
      .select(&.min.y.>(30.0)).max_by(&.height).not_nil!
    row_c = Egui::Pos2.new(popup.center.x, popup.min.y + popup.height * 0.75)
    draw.call([Egui::Event.pointer_moved(row_c)], 0.080)

    v = ctx.style.visuals
    text = ->(s : String) do
      ctx.painter.commands.select(Egui::TextCmd).find { |c| c.text == s }.not_nil!
    end
    # No hover band behind the disabled row: nothing but the frame's
    # own fill covers its half of the popup.
    band = ctx.painter.commands.select(Egui::RectCmd).select do |c|
      c.fill && c.fill != v.window_fill && c.rect.contains?(row_c)
    end
    band.should be_empty
    # Its text is the built-in 45% fade; the enabled row stays plain.
    fade = v.fade_color(v.text_color, 0.45)
    text.call("Nope").color.should eq fade
    text.call("Ok").color.should_not eq fade

    # A click on the disabled row neither fires nor closes the menu.
    draw.call([Egui::Event.pointer_pressed(row_c)], 0.096)
    draw.call([Egui::Event.pointer_released(row_c)], 0.112)
    fired.should be_empty # nothing fired yet
    ctx.memory.menu_open.should_not be_nil

    # The state layer restyles the disabled text color.
    gray = Egui::Color32.rgb(120, 120, 120)
    ctx.stylesheet.rule("menu.item:disabled",
      Egui::StyleVars{"text_color" => gray})
    draw.call([] of Egui::Event, 0.128)
    text.call("Nope").color.should eq gray
    text.call("Ok").color.should_not eq gray
  end
end
