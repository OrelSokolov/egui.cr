require "spec"
require "../src/egui"

SMOKE_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(900.0, 700.0))

def smoke_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
                time : Float64 = 0.016, &app : Egui::Context ->)
  raw = Egui::RawInput.new(SMOKE_SCREEN, events, time)
  ctx.begin_frame(raw)
  ctx.inspector.before_update
  yield ctx
  ctx.end_frame
end

describe "inspector panel rendering smoke" do
  it "renders the panel, both tabs, after a pick" do
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    center = nil

    # frame 1: app + panel (element tab, nothing selected yet)
    smoke_frame(ctx) do |c|
      c.window("w") do |ui|
        center = ui.button("OK", id: "save").rect.center
        ui.label("plain label")
        ui.checkbox(true, "box")
        ui.slider(0.5, 0.0..1.0, "S") { |_v| }
        ui.separator
      end
    end

    # frame 2: secondary press → pick menu → select
    events = [Egui::Event.pointer_moved(center.not_nil!),
              Egui::Event.pointer_pressed(center.not_nil!,
                Egui::PointerButton::Secondary)]
    smoke_frame(ctx, events: events, time: 0.032) do |c|
      c.window("w") { |ui| ui.button("OK", id: "save") }
    end
    ctx.inspector.selected = Egui::Id.from("save")

    # frame 3: element tab renders full property rows
    smoke_frame(ctx, time: 0.048) do |c|
      c.window("w") { |ui| ui.button("OK", id: "save") }
    end

    # frame 4: class tab renders (button class, base state)
    ctx.inspector.tab = :class
    smoke_frame(ctx, time: 0.064) do |c|
      c.window("w") { |ui| ui.button("OK", id: "save") }
    end

    # frame 5: class tab in :hover state renders
    smoke_frame(ctx, time: 0.080) do |c|
      c.window("w") { |ui| ui.button("OK", id: "save") }
    end

    # element edit actually reaches the paint output through the panel:
    # simulate what a row editor write does — a BASE edit is flat across
    # states (CSS inline semantics), so it shows even while hovering
    ctx.set_id_style(Egui::Id.from("save"), "background",
      Egui::Color32.rgb(10, 200, 30))
    smoke_frame(ctx, events: [Egui::Event.pointer_moved(Egui::Pos2.new(4.0, 4.0))],
      time: 0.096) do |c|
      c.window("w") { |ui| ui.button("OK", id: "save") }
    end
    ctx.painter.commands.select(Egui::RectCmd)
      .any? { |r| r.fill == Egui::Color32.rgb(10, 200, 30) }.should be_true
  end

  it "shows the real theme value for unset keys (font_size ≠ 0)" do
    ctx = Egui::Context.new
    ctx.inspector_enabled = true

    smoke_frame(ctx) do |c|
      c.window("w") { |ui| ui.button("OK", id: "save") }
    end
    ctx.inspector.inspect_widget(Egui::Id.from("save"))
    smoke_frame(ctx, time: 0.032) do |c|
      c.window("w") { |ui| ui.button("OK", id: "save") }
    end
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    fs = "%.1f" % ctx.style.font_size
    # the row is [label "font_size"][drag_value] — the editor must show
    # the real theme size (16.0), not the pre-fix bogus 0.0
    idx = texts.index("font_size").not_nil!
    texts[idx + 1].should eq(fs)
  end

  it "reveals the panel when picking with it hidden" do
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    smoke_frame(ctx) do |c|
      c.window("w") { |ui| ui.button("OK", id: "save") }
    end
    ctx.inspector.open = false
    ctx.inspector.inspect_widget(Egui::Id.from("save"))
    ctx.inspector.open?.should be_true
    ctx.inspector.selected.should eq Egui::Id.from("save")
    smoke_frame(ctx, time: 0.112) do |c|
      c.window("w") { |ui| ui.button("OK", id: "save") }
    end
  end

  it "drops the selection when the panel closes (✕ / open=, F12)" do
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    smoke_frame(ctx) do |c|
      c.window("w") { |ui| ui.button("OK", id: "save") }
    end
    ctx.inspector.inspect_widget(Egui::Id.from("save"))
    ctx.inspector.selected.should eq Egui::Id.from("save")

    # closing the panel (the ✕ path uses the same setter) clears the
    # selection, so the orange outline stops painting
    ctx.inspector.open = false
    ctx.inspector.selected.should be_nil
    smoke_frame(ctx, time: 0.032) do |c|
      c.window("w") { |ui| ui.button("OK", id: "save") }
    end
    ctx.painter.commands.select(Egui::RectCmd)
      .any? { |r| r.stroke_color == Egui::Inspector::HIGHLIGHT_COLOR }.should be_false

    # F12 closes the same way: select again, press F12 → no selection
    ctx.inspector.inspect_widget(Egui::Id.from("save"))
    smoke_frame(ctx, events: [Egui::Event.key_pressed(Egui::KeyCode::F12)],
      time: 0.048) do |c|
      c.window("w") { |ui| ui.button("OK", id: "save") }
    end
    ctx.inspector.open?.should be_false
    ctx.inspector.selected.should be_nil
  end

  it "exports element overrides as set_id_style calls" do
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    smoke_frame(ctx) do |c|
      c.window("w") { |ui| ui.button("OK", id: "save") }
    end
    ctx.inspector.inspect_widget(Egui::Id.from("save"))
    ctx.set_id_style(Egui::Id.from("save"), "background",
      Egui::Color32.rgb(10, 200, 30))
    snippet = ctx.inspector.export_element_snippet
    snippet.should contain(%[ctx.set_id_style(Egui::Id.from("save"), "background", Egui::Color32.rgb(10, 200, 30))])
  end

  it "exports class rules (base + state overlays) as rule calls" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("button", Egui::StyleVars{"background" => Egui::Color32.rgb(1, 2, 3)})
    ctx.stylesheet.rule("button:hover", Egui::StyleVars{"background" => Egui::Color32.rgb(4, 5, 6)})
    ctx.inspector_enabled = true
    ctx.inspector.tab = :class
    smoke_frame(ctx) do |c|
      c.window("w") { |ui| ui.button("OK") }
    end
    snippet = ctx.inspector.export_class_snippet
    snippet.should contain(%[ctx.stylesheet.rule("button", Egui::StyleVars{])
    snippet.should contain(%["background" => Egui::Color32.rgb(1, 2, 3),])
    snippet.should contain(%[ctx.stylesheet.rule("button:hover", Egui::StyleVars{])
  end

  it "docks right by default and re-docks to the bottom strip" do
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    close = nil

    # right dock (the default): the header — and its ✕ — sits at the
    # TOP-right of the screen, next to the right edge.
    smoke_frame(ctx) do |c|
      c.window("w") { |ui| ui.button("OK") }
      close = c.memory.widget_rects[Egui::Id.from("inspector_close")]
    end
    ctx.inspector.dock.should eq(:right)
    close.not_nil!.right.should be > SMOKE_SCREEN.width - 50.0
    close.not_nil!.top.should be < 60.0

    # the dock menu lists both docks with the current one checked
    ctx.open_popup(Egui::Inspector::DOCK_MENU)
    smoke_frame(ctx, time: 0.032) do |c|
      c.window("w") { |ui| ui.button("OK") }
    end
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("Right")
    texts.should contain("Bottom")

    # bottom dock: the header moves to the bottom strip
    ctx.inspector.dock = :bottom
    smoke_frame(ctx, time: 0.048) do |c|
      c.window("w") { |ui| ui.button("OK") }
      close = c.memory.widget_rects[Egui::Id.from("inspector_close")]
    end
    ctx.inspector.dock.should eq(:bottom)
    close.not_nil!.right.should be > SMOKE_SCREEN.width - 50.0
    close.not_nil!.top.should be > SMOKE_SCREEN.height - 250.0
  end

  it "renders the export modal with the snippet and copies to clipboard" do
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    smoke_frame(ctx) do |c|
      c.window("w") { |ui| ui.button("OK", id: "save") }
    end
    ctx.inspector.inspect_widget(Egui::Id.from("save"))
    ctx.set_id_style(Egui::Id.from("save"), "background", Egui::Color32.rgb(9, 9, 9))
    # the element tab is a manual switch now (Class is the default);
    # this test exercises the element snippet
    ctx.inspector.tab = :element
    ctx.inspector.open_export
    smoke_frame(ctx, time: 0.032) do |c|
      c.window("w") { |ui| ui.button("OK", id: "save") }
    end
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("Export style")
    texts.should contain("Copy")
    # the textarea shows the snippet (its label row paints it)
    texts.join("\n").should contain("set_id_style")
  end

  it "font_family edits from the catalog via a combo (not free text)" do
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    # the catalog: the reserved system/monospace + everything registered
    ctx.register_font_family("testmono", ctx.fonts)
    ctx.register_font_family("Adisplay", ctx.fonts)
    ctx.font_family_catalog.should eq(["Adisplay", "monospace", "system", "testmono"])

    center = nil
    smoke_frame(ctx) do |c|
      c.window("w") do |ui|
        ui.add(Egui::Label.new("hi", id: "lbl"))
      end
    end
    ctx.inspector.inspect_widget(Egui::Id.from("lbl"))
    # the element tab is a manual switch now (Class is the default)
    ctx.inspector.tab = :element

    # the element tab's font_family row is a combo: the closed button
    # shows the placeholder (nothing set), not a text cursor field
    smoke_frame(ctx, time: 0.032) do |c|
      c.window("w") { |ui| ui.add(Egui::Label.new("hi", id: "lbl")) }
    end
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("(наследуется)")

    # open it and pick "monospace" from the loaded catalog. TWO rows
    # show the «(наследуется)» placeholder now (font_weight's select
    # has one too) — the family row is the LAST (weight sits above it).
    btn = ctx.painter.commands.select(Egui::TextCmd)
      .select(&.text.==("(наследуется)")).last.not_nil!
    click = Egui::Pos2.new(btn.pos.x + 10.0, btn.pos.y)
    smoke_frame(ctx, events: [Egui::Event.pointer_moved(click),
      Egui::Event.pointer_pressed(click)], time: 0.048) do |c|
      c.window("w") { |ui| ui.add(Egui::Label.new("hi", id: "lbl")) }
    end
    smoke_frame(ctx, events: [Egui::Event.pointer_released(click)], time: 0.064) do |c|
      c.window("w") { |ui| ui.add(Egui::Label.new("hi", id: "lbl")) }
    end
    # the popup lists the catalog entries
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("monospace")
    texts.should contain("testmono")
    opt = ctx.painter.commands.select(Egui::TextCmd)
      .find { |t| t.text == "monospace" }.not_nil!
    pick = Egui::Pos2.new(opt.pos.x + 10.0, opt.pos.y)
    smoke_frame(ctx, events: [Egui::Event.pointer_moved(pick),
      Egui::Event.pointer_pressed(pick)], time: 0.080) do |c|
      c.window("w") { |ui| ui.add(Egui::Label.new("hi", id: "lbl")) }
    end
    smoke_frame(ctx, events: [Egui::Event.pointer_released(pick)], time: 0.096) do |c|
      c.window("w") { |ui| ui.add(Egui::Label.new("hi", id: "lbl")) }
    end

    # the pick landed as a per-element override and the label now draws
    # through the mono stack
    bag = ctx.id_style_overrides[Egui::Id.from("lbl")].not_nil![nil].not_nil!
    bag["font_family"].should eq("monospace")
    ctx.painter.commands.select(Egui::TextCmd)
      .find { |t| t.text == "hi" }.not_nil!.family.should eq("monospace")
  end
end
