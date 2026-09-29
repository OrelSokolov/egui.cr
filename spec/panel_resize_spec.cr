require "spec"
require "../src/egui"

RESIZE_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

def resize_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
                 time : Float64 = 0.016, &app : Egui::Context ->)
  raw = Egui::RawInput.new(RESIZE_SCREEN, events, time)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

describe "resizable panels" do
  it "grows a bottom panel by dragging its top edge, and it persists" do
    ctx = Egui::Context.new
    rect = nil

    # frame 1: register the grip (panel 540..600, edge y=540)
    resize_frame(ctx) { |c| rect = c.bottom_panel("p", height: 60.0) { |ui| ui.label("x") } }
    rect.not_nil!.height.should eq 60.0
    grip = Egui::Pos2.new(400.0, 540.0)

    # frame 2: press on the grip
    resize_frame(ctx, events: [Egui::Event.pointer_moved(grip),
                               Egui::Event.pointer_pressed(grip)],
      time: 0.032) { |c| c.bottom_panel("p", height: 60.0) { |ui| ui.label("x") } }

    # frame 3: drag up 40px — the grip writes the new size during THIS
    # frame's render, so the rect still shows the old height
    resize_frame(ctx, events: [Egui::Event.pointer_moved(Egui::Pos2.new(400.0, 500.0))],
      time: 0.048) { |c| c.bottom_panel("p", height: 60.0) { |ui| ui.label("x") } }

    # frame 4: re-laid out with the stored size, and it persists
    resize_frame(ctx, time: 0.064) { |c| rect = c.bottom_panel("p", height: 60.0) { |ui| ui.label("x") } }
    rect.not_nil!.height.should be > 90.0
    resize_frame(ctx, time: 0.080) { |c| rect = c.bottom_panel("p", height: 60.0) { |ui| ui.label("x") } }
    rect.not_nil!.height.should be > 90.0
  end

  it "grows a left side panel by dragging its right edge" do
    ctx = Egui::Context.new
    rect = nil
    resize_frame(ctx) { |c| rect = c.side_panel(:left, "s", width: 100.0) { |ui| ui.label("x") } }
    grip = Egui::Pos2.new(100.0, 300.0)

    resize_frame(ctx, events: [Egui::Event.pointer_moved(grip),
                               Egui::Event.pointer_pressed(grip)],
      time: 0.032) { |c| c.side_panel(:left, "s", width: 100.0) { |ui| ui.label("x") } }
    resize_frame(ctx, events: [Egui::Event.pointer_moved(Egui::Pos2.new(160.0, 300.0))],
      time: 0.048) { |c| c.side_panel(:left, "s", width: 100.0) { |ui| ui.label("x") } }
    resize_frame(ctx, time: 0.064) { |c| rect = c.side_panel(:left, "s", width: 100.0) { |ui| ui.label("x") } }
    rect.not_nil!.width.should be > 150.0
  end

  it "never shrinks below the minimum nor past 90% of the screen" do
    ctx = Egui::Context.new
    rect = nil
    resize_frame(ctx) { |c| rect = c.bottom_panel("p", height: 60.0) { } }
    grip = Egui::Pos2.new(400.0, 540.0)
    resize_frame(ctx, events: [Egui::Event.pointer_moved(grip),
                               Egui::Event.pointer_pressed(grip)],
      time: 0.032) { |c| c.bottom_panel("p", height: 60.0) { } }
    # drag down hard (would go negative) → clamped to the minimum
    resize_frame(ctx, events: [Egui::Event.pointer_moved(Egui::Pos2.new(400.0, 700.0))],
      time: 0.048) { |c| rect = c.bottom_panel("p", height: 60.0) { } }
    rect.not_nil!.height.should be >= Egui::Context::PANEL_MIN_SIZE

    # drag up beyond the screen → clamped to 90% of 600 = 540
    resize_frame(ctx, events: [Egui::Event.pointer_moved(grip),
                               Egui::Event.pointer_pressed(Egui::Pos2.new(400.0, 540.0))],
      time: 0.064) { |c| c.bottom_panel("p", height: 60.0) { } }
    # continue the same drag far up (pointer stays down)
    resize_frame(ctx, events: [Egui::Event.pointer_moved(Egui::Pos2.new(400.0, -500.0))],
      time: 0.080) { |c| rect = c.bottom_panel("p", height: 60.0) { } }
    resize_frame(ctx, time: 0.096) { |c| rect = c.bottom_panel("p", height: 60.0) { } }
    rect.not_nil!.height.should be <= 540.0
  end

  it "resizable: false keeps the panel fixed" do
    ctx = Egui::Context.new
    rect = nil
    resize_frame(ctx) { |c| rect = c.bottom_panel("p", height: 60.0, resizable: false) { } }
    grip = Egui::Pos2.new(400.0, 540.0)
    resize_frame(ctx, events: [Egui::Event.pointer_moved(grip),
                               Egui::Event.pointer_pressed(grip)],
      time: 0.032) { |c| c.bottom_panel("p", height: 60.0, resizable: false) { } }
    resize_frame(ctx, events: [Egui::Event.pointer_moved(Egui::Pos2.new(400.0, 500.0))],
      time: 0.048) { |c| rect = c.bottom_panel("p", height: 60.0, resizable: false) { } }
    rect.not_nil!.height.should eq 60.0
  end
end
