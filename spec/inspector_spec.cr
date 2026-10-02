require "spec"
require "../src/egui"

INSP_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

def insp_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
               time : Float64 = 0.016, &app : Egui::Context ->)
  raw = Egui::RawInput.new(INSP_SCREEN, events, time)
  ctx.begin_frame(raw)
  ctx.inspector.before_update
  yield ctx
  ctx.end_frame
end

describe "widget inspector" do
  it "Id#short_label is 6 [A-Za-z] chars, deterministic" do
    id = Egui::Id.from("save")
    id.short_label.should match(/^[A-Za-z]{6}$/)
    id.short_label.should eq Egui::Id.from("save").short_label
  end

  it "raises on a duplicate explicit widget id" do
    ctx = Egui::Context.new
    expect_raises(Egui::DuplicateWidgetIdError, /"dup"/) do
      raw = Egui::RawInput.new(INSP_SCREEN, [] of Egui::Event, 0.016)
      ctx.begin_frame(raw)
      ctx.window("w") do |ui|
        ui.add(Egui::Button.new("A", id: "dup"))
        ui.add(Egui::Button.new("B", id: "dup"))
      end
      ctx.end_frame
    end
  end

  it "claims reset per frame — the same id next frame is fine" do
    ctx = Egui::Context.new
    2.times do |i|
      raw = Egui::RawInput.new(INSP_SCREEN, [] of Egui::Event, 0.016 * (i + 1))
      ctx.begin_frame(raw)
      ctx.window("w") { |ui| ui.add(Egui::Button.new("A", id: "ok")) }
      ctx.end_frame
    end
  end

  it "records widget meta only while enabled" do
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    insp_frame(ctx) do |c|
      c.window("w") { |ui| ui.add(Egui::Button.new("OK", id: "save")) }
    end
    m = ctx.inspector.meta_for(Egui::Id.from("save")).not_nil!
    m.kind.should eq "Button"
    m.style_class.should eq "button"
    m.id_name.should eq "save"
    m.props.any? { |p| p.key == "background" }.should be_true

    ctx.inspector_enabled = false
    2.times do |i|
      insp_frame(ctx, time: 0.032 * (i + 1)) do |c|
        c.window("w") { |ui| ui.add(Egui::Button.new("OK", id: "save")) }
      end
    end
    # meta rotated away (one extra frame rides in prev_meta); nothing
    # new recorded while disabled
    ctx.inspector.meta_for(Egui::Id.from("save")).should be_nil
  end

  it "per-element override changes the button fill, beating class rule and inline style" do
    ctx = Egui::Context.new
    red = Egui::Color32.rgb(255, 0, 0)
    green = Egui::Color32.rgb(0, 255, 0)
    blue = Egui::Color32.rgb(0, 0, 255)
    # class rule blue + inline green — inline should win…
    ctx.stylesheet.rule("button", Egui::StyleVars{"background" => blue})

    button_fill = nil
    raw = Egui::RawInput.new(INSP_SCREEN, [] of Egui::Event, 0.016)
    ctx.begin_frame(raw)
    ctx.window("w") do |ui|
      ui.add(Egui::Button.new("OK", id: "save").style do |s|
        s.background = green
      end)
    end
    ctx.end_frame
    cmds = ctx.painter.commands
    # …and the element override red beats both
    ctx.set_id_style(Egui::Id.from("save"), "background", red)
    raw = Egui::RawInput.new(INSP_SCREEN, [] of Egui::Event, 0.032)
    ctx.begin_frame(raw)
    ctx.window("w") do |ui|
      ui.add(Egui::Button.new("OK", id: "save").style do |s|
        s.background = green
      end)
    end
    ctx.end_frame
    rects = ctx.painter.commands.select(Egui::RectCmd)
    rects.any? { |r| r.fill == red }.should be_true
    rects.none? { |r| r.fill == blue }.should be_true
  end

  it "one background key: element base edit applies while hovering; a state edit refines it" do
    ctx = Egui::Context.new
    red = Egui::Color32.rgb(255, 0, 0)
    lime = Egui::Color32.rgb(0, 255, 100)
    center = nil
    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw = Egui::RawInput.new(INSP_SCREEN, events, time)
      ctx.begin_frame(raw)
      ctx.window("w") { |ui| center = ui.button("OK", id: "save").rect.center }
      ctx.end_frame
      ctx.painter.commands.select(Egui::RectCmd)
    end
    draw.call([] of Egui::Event, 0.016)

    # a BASE element edit is flat across states (CSS inline semantics):
    # it shows even while hovering, beating the default button:hover rule
    ctx.set_id_style(Egui::Id.from("save"), "background", red)
    draw.call([Egui::Event.pointer_moved(center.not_nil!)], 0.032)
      .any? { |r| r.fill == red }.should be_true

    # an element hover-state edit refines it (state value over base)
    ctx.set_id_style(Egui::Id.from("save"), "background", lime, state: "hover")
    draw.call([Egui::Event.pointer_moved(center.not_nil!)], 0.048)
      .any? { |r| r.fill == lime }.should be_true

    # off the button the base value shows again
    draw.call([Egui::Event.pointer_moved(Egui::Pos2.new(4.0, 4.0))], 0.064)
      .any? { |r| r.fill == red }.should be_true
  end

  it "declares one state-scoped background prop — no fill_hovered/fill_active" do
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    insp_frame(ctx) do |c|
      c.window("w") { |ui| ui.add(Egui::Button.new("OK", id: "save")) }
    end
    m = ctx.inspector.meta_for(Egui::Id.from("save")).not_nil!
    bg = m.props.find { |p| p.key == "background" }.not_nil!
    bg.states?.should be_true
    m.props.any? { |p| {"fill_hovered", "fill_active"}.includes?(p.key) }
      .should be_false
  end

  it "clear_id_style drops the override" do
    ctx = Egui::Context.new
    red = Egui::Color32.rgb(255, 0, 0)
    ctx.set_id_style(Egui::Id.from("save"), "background", red)
    ctx.id_style_overrides[Egui::Id.from("save")].should_not be_nil
    ctx.clear_id_style(Egui::Id.from("save"), "background")
    ctx.id_style_overrides[Egui::Id.from("save")]?.should be_nil
  end

  it "a live stylesheet rule changes the paint output" do
    ctx = Egui::Context.new
    pink = Egui::Color32.rgb(255, 105, 180)
    draw = ->(t : Float64) do
      raw = Egui::RawInput.new(INSP_SCREEN, [] of Egui::Event, t)
      ctx.begin_frame(raw)
      ctx.window("w") { |ui| ui.button("OK") }
      ctx.end_frame
      ctx.painter.commands.select(Egui::RectCmd)
    end
    before = draw.call(0.016)
    ctx.stylesheet.rule("button", Egui::StyleVars{"background" => pink})
    after = draw.call(0.032)
    after.any? { |r| r.fill == pink }.should be_true
    before.none? { |r| r.fill == pink }.should be_true
    # unset reverts to the theme
    ctx.stylesheet.unset("button", "background")
    reverted = draw.call(0.048)
    reverted.none? { |r| r.fill == pink }.should be_true
  end

  it "picks a widget via secondary press and opens the Inspect menu" do
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    center = nil

    # frame 1: lay out the button, record rect + meta
    insp_frame(ctx) do |c|
      c.window("w") do |ui|
        center = ui.button("OK", id: "save").rect.center
      end
    end

    # frame 2: secondary press over it → pick menu opens
    events = [Egui::Event.pointer_moved(center.not_nil!),
              Egui::Event.pointer_pressed(center.not_nil!,
                Egui::PointerButton::Secondary)]
    insp_frame(ctx, events: events, time: 0.032) do |c|
      c.window("w") { |ui| ui.button("OK", id: "save") }
    end
    ctx.popup_open?("inspector_pick").should be_true

    # selecting targets the widget (the popup's menu item does this)
    ctx.inspector.selected = Egui::Id.from("save")
    ctx.inspector.selected.should eq Egui::Id.from("save")

    # frame 3: the panel renders without exploding and the highlight
    # paints on its own layer above windows, below the panel/popups
    insp_frame(ctx, time: 0.048) do |c|
      c.window("w") { |ui| ui.button("OK", id: "save") }
    end
    ctx.painter.commands.any?(Egui::RectCmd).should be_true
  end

  # Composite widgets are built from subwidgets via `Ui#add` — those
  # record their own meta. The pick menu must list EVERY widget under
  # the press (outermost first), not just the topmost one: right-clicked
  # markdown offers both the Markdown root and the RichLabel the
  # clicked block is made of.
  it "pick menu offers nested subwidgets (Markdown → RichLabel)" do
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    pos = nil
    label_id = nil

    # frame 1: lay out markdown, aim at the PARAGRAPH label
    insp_frame(ctx) do |c|
      c.window("w") do |ui|
        ui.add(Egui::Markdown.new("# Title\n\nSome **bold** prose."))
      end
      meta = ctx.inspector.meta_values.find { |m|
        m.kind == "RichLabel" && m.label.try(&.includes?("bold"))
      }.not_nil!
      label_id = meta.id
      rect = ctx.memory.prev_widget_rects[meta.id]? ||
             ctx.memory.widget_rects[meta.id]
      pos = rect.not_nil!.center
    end

    # frame 2: secondary press over the paragraph → pick menu opens
    events = [Egui::Event.pointer_moved(pos.not_nil!),
              Egui::Event.pointer_pressed(pos.not_nil!,
                Egui::PointerButton::Secondary)]
    insp_frame(ctx, events: events, time: 0.032) do |c|
      c.window("w") { |ui|
        ui.add(Egui::Markdown.new("# Title\n\nSome **bold** prose."))
      }
    end
    ctx.popup_open?("inspector_pick").should be_true

    # frame 3: the menu lists both the root and the nested label
    insp_frame(ctx, time: 0.048) do |c|
      c.window("w") { |ui|
        ui.add(Egui::Markdown.new("# Title\n\nSome **bold** prose."))
      }
    end
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.any?(&.starts_with?("Inspect Markdown")).should be_true
    texts.any?(&.starts_with?("Inspect RichLabel")).should be_true

    # clicking the RichLabel row selects the subwidget, not the root
    row = ctx.painter.commands.select(Egui::TextCmd)
      .find(&.text.starts_with?("Inspect RichLabel")).not_nil!
    insp_frame(ctx, events: [Egui::Event.pointer_pressed(row.pos),
                             Egui::Event.pointer_released(row.pos)],
      time: 0.064) { |c| }
    ctx.inspector.selected.should eq label_id
  end

  # The one-menu rule: a widget with its own context menu gets the
  # «Inspect …» row appended as that menu's LAST item — never a second
  # popup beside it. Reproduces the bin/terminal double-menu bug: the
  # central panel renders DEFERRED (inside end_frame), so the pick
  # decision must run after it to see the widget's own menu claim the
  # press.
  it "appends Inspect as the last item of the widget's own menu (no second popup)" do
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    menu = Egui::ContextMenu.new.item("Copy") { }
    center = nil

    frame = ->(events : Array(Egui::Event), time : Float64) do
      raw = Egui::RawInput.new(INSP_SCREEN, events, time)
      ctx.begin_frame(raw)
      ctx.inspector.before_update
      ctx.central_panel do |ui|
        resp = ui.button("OK", id: "save")
        center = resp.rect.center
        resp.context_menu(menu)
      end
      ctx.end_frame
    end

    frame.call([] of Egui::Event, 0.016)
    events = [Egui::Event.pointer_moved(center.not_nil!),
              Egui::Event.pointer_pressed(center.not_nil!,
                Egui::PointerButton::Secondary)]
    frame.call(events, 0.032)

    # ONE popup: the widget's own menu, with Inspect as its last row
    ctx.memory.open_popups.size.should eq(1)
    ctx.popup_open?("inspector_pick").should be_false
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("Copy")
    texts.any?(&.starts_with?("Inspect Button")).should be_true

    # Clicking the Inspect row selects the widget and reveals the panel
    frame.call([] of Egui::Event, 0.048) # popup rows registered
    row = ctx.painter.commands.select(Egui::TextCmd)
      .find(&.text.starts_with?("Inspect Button")).not_nil!
    frame.call([Egui::Event.pointer_pressed(row.pos),
                Egui::Event.pointer_released(row.pos)], 0.064)
    ctx.inspector.selected.should eq Egui::Id.from("save")
    ctx.inspector.open?.should be_true
    ctx.memory.open_popups.size.should eq(0)
  end

  it "shows non-stylable widgets honestly (RadioButton has no props)" do
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    insp_frame(ctx) do |c|
      c.window("w") { |ui| ui.radio(false, "r") }
    end
    metas = ctx.inspector.meta_values
    metas.any? { |m| m.kind == "RadioButton" }.should be_true
    metas.find { |m| m.kind == "RadioButton" }.not_nil!.props.should be_empty
  end
end
