require "spec"
require "../src/egui"

VSCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

def fill_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
               time : Float64 = 0.016)
  ctx.begin_frame(Egui::RawInput.new(VSCREEN, events, time))
end

describe "Ui#fill_child (fill-editor pattern)" do
  it "clamps a fill textarea to the visible fold so it scrolls itself" do
    ctx = Egui::Context.new
    line = "the quick brown fox jumps over the lazy dog\n"
    text = line * 40 # ~40 rows, taller than the panel remainder

    3.times do |i|
      fill_frame(ctx, time: 0.016 * (i + 1))
      ctx.central_panel do |ui|
        ui.heading("Fill editor")
        editor = ui.fill_child(Egui::Id.from("doc"))
        editor.textarea(text, rows: 100) { |_t| }
      end
      ctx.end_frame
    end

    # The textarea registered a scroll sink over the REMAINDER rect
    # (clamped to the fold), not a 100-row-tall rect past the window.
    sink = ctx.memory.scroll_rects.first?
    sink.should_not be_nil
    rect = sink.not_nil![1].rect
    rect.bottom.should be <= 600.0
    (rect.height > 300.0).should be_true # most of the panel remainder

    # The wheel drives the textarea's own offset.
    (1..8).each do |i|
      ev = [Egui::Event.pointer_moved(Egui::Pos2.new(400.0, 400.0))]
      ev << Egui::Event.scroll(Egui::Vec2.new(0.0, 50.0)) if i > 1
      fill_frame(ctx, events: ev, time: 0.048 + i * 0.016)
      ctx.central_panel do |ui|
        ui.heading("Fill editor")
        editor = ui.fill_child(Egui::Id.from("doc"))
        editor.textarea(text, rows: 100) { |_t| }
      end
      ctx.end_frame
    end
    ctx.memory.data.get_vec2(sink.not_nil![0], Egui::Vec2.zero).y
      .should be > 0.0
  end

  it "registers no sink when the content fits the fold" do
    ctx = Egui::Context.new
    3.times do |i|
      fill_frame(ctx, time: 0.016 * (i + 1))
      ctx.central_panel do |ui|
        ui.heading("Fill editor")
        editor = ui.fill_child(Egui::Id.from("doc"))
        editor.textarea("short\nbuffer", rows: 100) { |_t| }
      end
      ctx.end_frame
    end
    ctx.memory.scroll_rects.should be_empty
  end
end
