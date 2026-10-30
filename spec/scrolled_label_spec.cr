# ScrolledLabel: a read-only TextArea — wraps exactly like a
# textarea, grows with its content, and clamps to max_height with
# scrolling once the text is taller.
require "spec"
require "../src/egui"

SL_SCREEN = Egui::Rect.from_min_size(
  Egui::Pos2.zero, Egui::Vec2.new(402.0, 874.0))

private def sl_frame(ctx : Egui::Context,
                     screen : Egui::Rect = SL_SCREEN,
                     &app : Egui::Context ->)
  raw = Egui::RawInput.new(screen, [] of Egui::Event, 0.016)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

SL_LONG = "Достаточно длинный текст, который обязан переноситься по словам " \
          "в несколько строк, потому что он не помещается на одну строку " \
          "панели — и должен ломаться там же, где ломается textarea"

describe "ScrolledLabel" do
  it "wraps like a textarea at the region width" do
    ctx = Egui::Context.new
    sl = expected = nil
    sl_frame(ctx) do |c|
      c.central_panel do |ui|
        resp = ui.scrolledlabel(SL_LONG)
        sl = resp.rect
        # Same measure the widget itself does: the galley wrapped at
        # the region width minus the delegate's scrollbar column.
        fonts = c.fonts_for(ui.style.font_family)
        font_size = ui.style.font_size
        line_h = font_size * Egui::Fonts::LINE_H_FACTOR
        wrap_w = {ui.available_width - Egui::TextArea::BAR_W, 10.0}.max
        galley = fonts.layout(
          [Egui::TextRun.new(SL_LONG, font_size)], max_width: wrap_w)
        expected = (galley.size.y / line_h).ceil.to_i * line_h
      end
    end
    sl.not_nil!.width.should be > 300.0 # block-level, not a sliver
    (sl.not_nil!.height - expected.not_nil!).abs.should be <= 0.5
  end

  it "grows with its content when no max_height is set" do
    ctx = Egui::Context.new
    short = tall = nil
    sl_frame(ctx) do |c|
      c.central_panel do |ui|
        short = ui.scrolledlabel("одна строка").rect
      end
    end
    sl_frame(ctx) do |c|
      c.central_panel do |ui|
        tall = ui.scrolledlabel(SL_LONG * 3).rect
      end
    end
    short.not_nil!.height.should be < 30.0
    tall.not_nil!.height.should be > 100.0
  end

  it "clamps to max_height and keeps the full text (scrolls)" do
    ctx = Egui::Context.new
    r = nil
    sl_frame(ctx) do |c|
      c.central_panel do |ui|
        r = ui.scrolledlabel(SL_LONG * 4, max_height: 120.0).rect
      end
    end
    r.not_nil!.height.should be <= 125.0 # capped viewport, not content height
    r.not_nil!.height.should be >= 90.0  # a real multi-line viewport
  end

  it "is read-only: never reports edits and never holds focus" do
    ctx = Egui::Context.new
    resp = nil
    # Click into the middle of the field and type — nothing may change.
    events = [
      Egui::Event.pointer_moved(Egui::Pos2.new(200.0, 60.0)),
      Egui::Event.pointer_pressed(Egui::Pos2.new(200.0, 60.0)),
      Egui::Event.pointer_released(Egui::Pos2.new(200.0, 60.0)),
      Egui::Event.key_pressed(Egui::KeyCode::A),
      Egui::Event.text_input("a"),
    ] of Egui::Event
    3.times do
      raw = Egui::RawInput.new(SL_SCREEN, events, 0.016)
      ctx.begin_frame(raw)
      ctx.central_panel do |ui|
        resp = ui.scrolledlabel(SL_LONG, id: "sl")
      end
      ctx.end_frame
    end
    resp.not_nil!.changed?.should be_false
    resp.not_nil!.widget_text.should eq(SL_LONG)
    resp.not_nil!.has_focus?.should be_false
  end
end
