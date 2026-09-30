require "spec"
require "../src/egui"

PANEL_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

def panel_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
                time : Float64 = 0.016, &app : Egui::Context ->)
  raw = Egui::RawInput.new(PANEL_SCREEN, events, time)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

def insp_panel_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
                     time : Float64 = 0.016, &app : Egui::Context ->)
  # These scenarios exercise the BOTTOM dock (the 190px strip): fold
  # culling, full-width background, the covering window geometry.
  ctx.inspector.dock = :bottom
  raw = Egui::RawInput.new(PANEL_SCREEN, events, time)
  ctx.begin_frame(raw)
  ctx.inspector.before_update
  yield ctx
  ctx.end_frame
end

describe "panel overflow (CSS overflow-y: auto by default)" do
  it "renders fitting central panel content unchanged — no scrollbar" do
    ctx = Egui::Context.new
    panel_frame(ctx) do |c|
      c.central_panel { |ui| ui.label("hi") }
    end
    bar_w = Egui::ScrollArea::BAR_W
    ctx.painter.commands.select(Egui::RectCmd)
      .none? { |cmd| cmd.rect.width == bar_w }.should be_true
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).should contain("hi")
  end

  it "scrolls overflowing central panel content: bar appears, wheel reveals later rows" do
    ctx = Egui::Context.new
    draw = ->(events : Array(Egui::Event), t : Float64) do
      panel_frame(ctx, events: events, time: t) do |c|
        c.central_panel do |ui|
          40.times { |i| ui.label("row #{i}") }
        end
      end
      ctx.painter.commands
    end

    # pointer inside the panel so its viewport owns the wheel
    draw.call([Egui::Event.pointer_moved(Egui::Pos2.new(400.0, 300.0))] of Egui::Event, 0.016)
    draw.call([] of Egui::Event, 0.032)
    # overflow: the bar is painted, content is clipped to the viewport
    # (galley rows outside the clip are culled from the output)
    bar_w = Egui::ScrollArea::BAR_W
    ctx.painter.commands.select(Egui::RectCmd)
      .any? { |cmd| cmd.rect.width == bar_w }.should be_true
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("row 0")
    texts.should_not contain("row 39")

    # wheel down → later rows scroll into view
    scrolled = draw.call([Egui::Event.scroll(Egui::Vec2.new(0.0, 400.0))] of Egui::Event, 0.048)
      .select(Egui::TextCmd).map(&.text)
    scrolled.should contain("row 39")
    scrolled.should_not contain("row 0")
  end

  it "keeps rows below the fold full-size instead of overlapping (v_overflow propagates)" do
    ctx = Egui::Context.new
    panel_frame(ctx) do |c|
      c.central_panel do |ui|
        40.times do |i|
          ui.horizontal { |row| row.button("row #{i}", id: "row#{i}") }
        end
      end
    end
    rects = (0...40).map { |i| ctx.memory.widget_rects[Egui::Id.from("row#{i}")].not_nil! }
    # full natural height everywhere — no row collapsed at the fold
    rects.each { |r| r.height.should be > 20.0 }
    # strictly stacked: each row starts below the previous one's bottom
    rects.each_cons_pair do |a, b|
      b.top.should be >= a.bottom
    end
  end

  it "keeps horizontal top/bottom strips as one unscrolled row" do
    ctx = Egui::Context.new
    panel_frame(ctx) do |c|
      c.bottom_panel("b", height: 60.0) do |ui|
        ui.label("one")
        ui.label("two")
      end
    end
    texts = ctx.painter.commands.select(Egui::TextCmd)
    ys = texts.select { |t| {"one", "two"}.includes?(t.text) }.map(&.pos.y)
    ys.size.should eq 2
    ys.uniq.size.should eq 1 # same row, side by side
    bar_w = Egui::ScrollArea::BAR_W
    ctx.painter.commands.select(Egui::RectCmd)
      .none? { |cmd| cmd.rect.width == bar_w }.should be_true
  end

  it "scrolls the inspector panel body when rows overflow" do
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    insp_panel_frame(ctx) do |c|
      c.window("w") { |ui| ui.button("OK", id: "save") }
    end
    ctx.inspector.inspect_widget(Egui::Id.from("save"))
    insp_panel_frame(ctx, time: 0.032) do |c|
      c.window("w") { |ui| ui.button("OK", id: "save") }
    end
    # the element tab's rows overflow the 190px panel: rows below the
    # fold are culled (galley labels: the state switch row pushes
    # "background" and everything after it under the fold — "text_color"
    # above it stays visible, "bevel_light" far beyond), the header tab
    # selector stays pinned — then the wheel scrolls the body (labels
    # painted via painter.text are clipped by the backend at render, so
    # visibility is asserted on galley rows)
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("Класс")
    texts.should contain("text_color")
    texts.should_not contain("bevel_light")

    insp_panel_frame(ctx,
      events: [Egui::Event.pointer_moved(Egui::Pos2.new(400.0, 550.0)),
               Egui::Event.scroll(Egui::Vec2.new(0.0, 400.0))],
      time: 0.048) do |c|
      c.window("w") { |ui| ui.button("OK", id: "save") }
    end
    scrolled = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    # scrolled to the (clamped) end: the last rows show, the first are
    # culled away
    scrolled.should contain("shadow.y")
    scrolled.should_not contain("text_color")
  end

  it "paints a background distinct from app panels (DevTools look)" do
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    insp_panel_frame(ctx) do |c|
      c.window("w") { |ui| ui.button("OK", id: "save") }
    end
    v = ctx.style.visuals
    expected = v.fade_color(v.panel_fill, 0.055)
    # the panel's full-width bg rect at the bottom of the screen
    bg = ctx.painter.commands.select(Egui::RectCmd)
      .find { |cmd| cmd.fill == expected && cmd.rect.width > 700.0 }
    bg.should_not be_nil
    bg.not_nil!.rect.bottom.should be > 590.0
    # and it differs from the regular panel fill
    expected.should_not eq v.panel_fill
  end

  it "stays above app windows: paint order and clicks" do
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    close_pos = nil
    cover = ->(c : Egui::Context) do
      c.window("cover", Egui::Pos2.new(0.0, 300.0), width: 800.0) do |ui|
        30.times { |i| ui.button("win button #{i}") }
      end
    end

    # A window deliberately covering the inspector strip (the window
    # spans 300..600 vertically, the panel 410..600).
    insp_panel_frame(ctx) do |c|
      cover.call(c)
      close_pos = c.memory.widget_rects[Egui::Id.from("inspector_close")]?.try(&.center)
    end
    close_pos.should_not be_nil

    # Paint order: the flattened commands put the window (Middle z=50)
    # BEFORE the inspector panel (z=98) — the panel paints over it.
    texts = ctx.painter.commands_in_layer_order
      .select(Egui::TextCmd).map(&.text)
    (texts.index("Класс").not_nil! > texts.index("cover").not_nil!)
      .should be_true

    # Input: a click on the panel's ✕ button lands on the INSPECTOR
    # (z=98), not on the window content underneath — the panel closes.
    pos = close_pos.not_nil!
    insp_panel_frame(ctx,
      events: [Egui::Event.pointer_moved(pos),
               Egui::Event.pointer_pressed(pos)], time: 0.032) { |c| cover.call(c) }
    insp_panel_frame(ctx,
      events: [Egui::Event.pointer_released(pos)], time: 0.048) { |c| cover.call(c) }
    ctx.inspector.open?.should be_false
  end
end
