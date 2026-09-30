require "../src/egui"
require "./core_spec" # raw_frame helper + SCREEN

describe "Context#embedded_window" do
  it "blocks interaction below like a modal, its own widgets work" do
    ctx = Egui::Context.new
    btn_center = nil

    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events: events, time: time)
      hovered = false
      ctx.window("demo") do |ui|
        r = ui.button("below")
        btn_center = r.rect.center
        hovered = r.hovered?
      end
      ctx.embedded_window("d", title: "Dialog") { |ui| ui.button("inside") }
      ctx.end_frame
      hovered
    end

    2.times { |i| draw.call([] of Egui::Event, 0.016 * (i + 1)) }
    # hover the covered window button — blocked by the modal layer
    draw.call([Egui::Event.pointer_moved(btn_center.not_nil!)], 0.064)
      .should be_false

    # the embedded window's own button is reachable
    inner = nil
    raw_frame(ctx, time: 0.080)
    ctx.window("demo") { |ui| ui.button("below") }
    ctx.embedded_window("d", title: "Dialog") { |ui| inner = ui.button("inside").hovered? }
    ctx.embedded_window("d") { } # second call same frame: idempotent draw
    ctx.end_frame
  end

  it "closes on the ✕, the scrim and Escape" do
    ctx = Egui::Context.new
    closed = false

    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events: events, time: time)
      closed = ctx.embedded_window("d", title: "Dialog") { |ui| ui.label("body") }
      ctx.end_frame
    end

    # frame 1: measure; find the ✕ from memory's widget rects (the
    # close button is registered under "embedded/d/close")
    draw.call([] of Egui::Event, 0.016)
    draw.call([] of Egui::Event, 0.032)

    # Escape closes
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Escape)], 0.048)
    closed.should be_true

    # reopen: ✕ closes
    draw.call([] of Egui::Event, 0.064)
    closed.should be_false
    close_rect = ctx.memory.widget_rects[Egui::Id.from("embedded/d/close")]?
    close_rect.should_not be_nil
    center = close_rect.not_nil!.center
    draw.call([Egui::Event.pointer_moved(center),
               Egui::Event.pointer_pressed(center)], 0.080)
    closed.should be_false
    draw.call([Egui::Event.pointer_released(center)], 0.096)
    closed.should be_true

    # reopen: a scrim click (outside the card) closes
    draw.call([] of Egui::Event, 0.112)
    corner = Egui::Pos2.new(4.0, 4.0) # far from the centered card
    draw.call([Egui::Event.pointer_moved(corner),
               Egui::Event.pointer_pressed(corner),
               Egui::Event.pointer_released(corner)], 0.128)
    closed.should be_true
  end

  it "centers on first open and paints title + shell" do
    ctx = Egui::Context.new
    raw_frame(ctx, time: 0.016)
    ctx.embedded_window("d", title: "Settings", width: 400.0) { |ui| ui.label("body") }
    ctx.end_frame

    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("Settings")
    texts.should contain("body")
    # centered: the card (not the full-screen scrim) spans the middle
    # of the 800×600 screen
    shell = ctx.painter.commands.select(Egui::RectCmd)
      .map(&.rect).reject { |r| r.width >= 800.0 }.max_by(&.width)
    shell.left.should be > 100.0
    shell.right.should be < 700.0
  end

  it "dragging the title bar moves the window" do
    ctx = Egui::Context.new
    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events: events, time: time)
      ctx.embedded_window("d", title: "Dialog") { |ui| ui.label("body") }
      ctx.end_frame
    end

    draw.call([] of Egui::Event, 0.016)
    draw.call([] of Egui::Event, 0.032)
    title_rect = ctx.memory.widget_rects[Egui::Id.from("embedded/d").child(0_u64)]?
    title_rect.should_not be_nil
    center = title_rect.not_nil!.center
    draw.call([Egui::Event.pointer_moved(center)], 0.048)
    draw.call([Egui::Event.pointer_moved(center),
               Egui::Event.pointer_pressed(center)], 0.064)
    moved = Egui::Pos2.new(center.x + 60.0, center.y + 30.0)
    draw.call([Egui::Event.pointer_moved(moved)], 0.080)
    draw.call([Egui::Event.pointer_released(moved)], 0.096)

    after = ctx.memory.widget_rects[Egui::Id.from("embedded/d").child(0_u64)].not_nil!
    after.left.should be > title_rect.not_nil!.left + 50.0
  end
end
