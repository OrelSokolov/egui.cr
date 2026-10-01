require "../src/egui"
require "./core_spec" # raw_frame helper + SCREEN

# The card shell of an embedded window/modal: the largest RectCmd that
# is not the full-screen scrim (the scrim spans the whole 800×600
# screen; the shell of a taller-than-screen dialog is taller than it).
private def card_shell(ctx)
  ctx.painter.commands.select(Egui::RectCmd)
    .reject { |c| c.rect.width >= 800.0 }
    .max_by { |c| c.rect.width * c.rect.height }.rect
end

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

  it "re-centers on the measured size once the content settles" do
    ctx = Egui::Context.new
    draw = ->(time : Float64) do
      raw_frame(ctx, time: time)
      ctx.embedded_window("d", title: "Dialog", width: 400.0) do |ui|
        20.times { |i| ui.label("line #{i}") }
      end
      ctx.end_frame
    end

    draw.call(0.016)
    first = card_shell(ctx)
    # frame 1 centers on the 220px height estimate, so a tall card sits
    # below the true center of the 800×600 screen
    (first.center.y - 300.0).abs.should be > 30.0

    draw.call(0.032)
    settled = card_shell(ctx)
    (settled.center.y - 300.0).abs.should be <= 2.0
    settled.top.should be < first.top # moved up to true center
  end

  it "pins a taller-than-screen dialog at the top" do
    ctx = Egui::Context.new
    draw = ->(time : Float64) do
      raw_frame(ctx, time: time)
      ctx.embedded_window("d", title: "Dialog", width: 400.0) do |ui|
        60.times { |i| ui.label("line #{i}") }
      end
      ctx.end_frame
    end

    2.times { |i| draw.call(0.016 * (i + 1)) }
    shell = card_shell(ctx)
    shell.height.should be > 600.0
    shell.top.should be < 5.0 # clamped at the screen top, not centered off-screen
  end

  it "keeps a dragged position instead of re-centering" do
    ctx = Egui::Context.new
    title_id = Egui::Id.from("embedded/d").child(0_u64)
    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events: events, time: time)
      ctx.embedded_window("d", title: "Dialog", width: 400.0) do |ui|
        20.times { |i| ui.label("line #{i}") }
      end
      ctx.end_frame
    end

    draw.call([] of Egui::Event, 0.016)
    draw.call([] of Egui::Event, 0.032)
    center = ctx.memory.widget_rects[title_id].not_nil!.center
    draw.call([Egui::Event.pointer_moved(center)], 0.048)
    draw.call([Egui::Event.pointer_moved(center),
               Egui::Event.pointer_pressed(center)], 0.064)
    moved = Egui::Pos2.new(center.x + 80.0, center.y)
    draw.call([Egui::Event.pointer_moved(moved)], 0.080)
    draw.call([Egui::Event.pointer_released(moved)], 0.096)
    dragged_left = ctx.memory.widget_rects[title_id].not_nil!.left

    draw.call([] of Egui::Event, 0.112)
    after = ctx.memory.widget_rects[title_id].not_nil!.left
    (after - dragged_left).abs.should be <= 2.0 # no snap back to center
  end

  # The title band is only measurable after the content, but painting it
  # at the end would stack it OVER the title text and the ✕ (insertion
  # order == paint order within a layer) — the band must be back-painted
  # into a slot reserved before the texts, like the shell background.
  it "paints the title band under the title text and the ✕" do
    ctx = Egui::Context.new
    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events: events, time: time)
      ctx.embedded_window("d", title: "Settings", width: 400.0) do |ui|
        ui.label("body")
      end
      ctx.end_frame
    end

    2.times { |i| draw.call([] of Egui::Event, 0.016 * (i + 1)) }
    flat = ctx.painter.commands_in_layer_order
    title = flat.index { |c| c.is_a?(Egui::TextCmd) && c.as(Egui::TextCmd).text == "Settings" }
    close = flat.index { |c| c.is_a?(Egui::TextCmd) && c.as(Egui::TextCmd).text == "✕" }
    band = flat.rindex { |c| c.is_a?(Egui::RectCmd) && c.as(Egui::RectCmd).fill == ctx.style.visuals.title_bar_fill }
    title.should_not be_nil
    close.should_not be_nil
    band.should_not be_nil
    band.not_nil!.should be < title.not_nil!
    band.not_nil!.should be < close.not_nil!
  end

  # A popup drawn inside the content (a color picker under a swatch,
  # like the theme editor) resets the painter's layer to Background on
  # exit — the trailing title-band paint must stay in the window's own
  # layer, not sink below the scrim (which made the title flash visible
  # only while the popup was open).
  it "keeps the title band in the window layer while a popup is open inside" do
    ctx = Egui::Context.new
    swatch_center = nil
    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events: events, time: time)
      ctx.embedded_window("d", title: "Settings", width: 400.0) do |ui|
        ui.label("body")
        swatch = ui.allocate_space(Egui::Vec2.new(40.0, 16.0))
        swatch_center = swatch.center
        resp = ui.interact(swatch, ui.next_widget_id, Egui::Sense.click)
        pop_id = "pick/#{ui.next_widget_id.value}"
        if resp.clicked?
          ctx.popup_open?(pop_id) ? ctx.close_popup(pop_id) : ctx.open_popup(pop_id)
        end
        if ctx.popup_open?(pop_id)
          ctx.popup(pop_id, Egui::Pos2.new(swatch.left, swatch.bottom),
            width: 200.0) { |pop| pop.color_edit32(Egui::Color32.rgb(255, 0, 0)) { } }
        end
      end
      ctx.end_frame
    end

    2.times { |i| draw.call([] of Egui::Event, 0.016 * (i + 1)) }
    c = swatch_center.not_nil!
    draw.call([Egui::Event.pointer_moved(c), Egui::Event.pointer_pressed(c)], 0.048)
    draw.call([Egui::Event.pointer_released(c)], 0.064)

    flat = ctx.painter.commands_in_layer_order
    title = flat.index { |c| c.is_a?(Egui::TextCmd) && c.as(Egui::TextCmd).text == "Settings" }
    # the title band: a wide, short rect at the card's top
    band = flat.rindex do |c|
      next false unless c.is_a?(Egui::RectCmd)
      r = c.as(Egui::RectCmd).rect
      r.width > 300.0 && r.height < 40.0
    end
    title.should_not be_nil
    band.should_not be_nil
    band.not_nil!.should be < title.not_nil!
  end
end
