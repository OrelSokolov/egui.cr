# ContextMenu specs: class-built menus attached via
# Response#context_menu — secondary press opens the popup at the
# pointer, rows render (icons aside, hotkey hints right-aligned) and
# fire their handlers on click, closing the popup.

require "spec"
require "../src/egui"

MENU_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 300.0))

describe Egui::ContextMenu do
  it "opens on secondary press, shows hints, fires the clicked item" do
    fired = [] of String
    menu = Egui::ContextMenu.new
      .item("Alpha", icon: :check, hotkey: "Ctrl+A") { fired << "alpha" }
      .separator
      .item("Beta", icon: :copy) { fired << "beta" }

    ctx = Egui::Context.new
    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw = Egui::RawInput.new(MENU_SCREEN, events, time)
      ctx.begin_frame(raw)
      ctx.central_panel do |ui|
        ui.button("target").context_menu(menu)
      end
      ctx.end_frame
    end

    draw.call([] of Egui::Event, 0.016) # widget rects registered

    pos = Egui::Pos2.new(30.0, 20.0)
    draw.call([Egui::Event.pointer_pressed(pos, :secondary)], 0.032)

    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("Alpha")    # rows rendered
    texts.should contain("Beta")
    texts.should contain("Ctrl+A")   # the static hotkey hint
    fired.should be_empty

    # Click the first row: the popup content starts at the anchor plus
    # the popup's window padding.
    item_pos = Egui::Pos2.new(pos.x + 12.0, pos.y + 12.0)
    draw.call([] of Egui::Event, 0.048) # popup item rects registered
    draw.call([Egui::Event.pointer_pressed(item_pos)], 0.064)
    draw.call([Egui::Event.pointer_released(item_pos)], 0.080)

    fired.should eq(["alpha"])
  end

  it "keeps two attachments independent (per-widget popups)" do
    fired = [] of String
    menu = Egui::ContextMenu.new
      .item("Only", icon: :plus) { fired << "only" }

    ctx = Egui::Context.new
    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw = Egui::RawInput.new(MENU_SCREEN, events, time)
      ctx.begin_frame(raw)
      ctx.central_panel do |ui|
        ui.button("one").context_menu(menu)
        ui.button("two").context_menu(menu)
      end
      ctx.end_frame
    end

    draw.call([] of Egui::Event, 0.016)

    # Open on the second button; only one popup is live even though
    # the menu instance drives both attachments.
    second = Egui::Pos2.new(30.0, 60.0)
    draw.call([Egui::Event.pointer_pressed(second, :secondary)], 0.032)
    draw.call([] of Egui::Event, 0.048)

    item_pos = Egui::Pos2.new(second.x + 12.0, second.y + 12.0)
    draw.call([Egui::Event.pointer_pressed(item_pos)], 0.064)
    draw.call([Egui::Event.pointer_released(item_pos)], 0.080)
    fired.should eq(["only"])
  end
end
