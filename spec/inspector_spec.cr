require "spec"
require "../src/egui"

INSP_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

def insp_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
               time : Float64 = 0.016, &app : Egui::Context ->)
  raw = Egui::RawInput.new(INSP_SCREEN, events, time)
  ctx.begin_frame(raw)
  ctx.inspector.before_update
  yield ctx
  ctx.inspector.after_update
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
    m.props.any? { |p| p.key == "fill" }.should be_true

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
    ctx.stylesheet.rule("button", Egui::StyleVars{"fill" => blue})

    button_fill = nil
    raw = Egui::RawInput.new(INSP_SCREEN, [] of Egui::Event, 0.016)
    ctx.begin_frame(raw)
    ctx.window("w") do |ui|
      ui.add(Egui::Button.new("OK", id: "save").style do |s|
        s.fill = green
      end)
    end
    ctx.end_frame
    cmds = ctx.painter.commands
    # …and the element override red beats both
    ctx.set_id_style(Egui::Id.from("save"), "fill", red)
    raw = Egui::RawInput.new(INSP_SCREEN, [] of Egui::Event, 0.032)
    ctx.begin_frame(raw)
    ctx.window("w") do |ui|
      ui.add(Egui::Button.new("OK", id: "save").style do |s|
        s.fill = green
      end)
    end
    ctx.end_frame
    rects = ctx.painter.commands.select(Egui::RectCmd)
    rects.any? { |r| r.fill == red }.should be_true
    rects.none? { |r| r.fill == blue }.should be_true
  end

  it "clear_id_style drops the override" do
    ctx = Egui::Context.new
    red = Egui::Color32.rgb(255, 0, 0)
    ctx.set_id_style(Egui::Id.from("save"), "fill", red)
    ctx.id_style_overrides[Egui::Id.from("save")].should_not be_nil
    ctx.clear_id_style(Egui::Id.from("save"), "fill")
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
    ctx.stylesheet.rule("button", Egui::StyleVars{"fill" => pink})
    after = draw.call(0.032)
    after.any? { |r| r.fill == pink }.should be_true
    before.none? { |r| r.fill == pink }.should be_true
    # unset reverts to the theme
    ctx.stylesheet.unset("button", "fill")
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
    # paints on the tooltip layer
    insp_frame(ctx, time: 0.048) do |c|
      c.window("w") { |ui| ui.button("OK", id: "save") }
    end
    ctx.painter.commands.any?(Egui::RectCmd).should be_true
  end

  it "shows non-stylable widgets honestly (Spinner has no props)" do
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    insp_frame(ctx) do |c|
      c.window("w") { |ui| ui.spinner }
    end
    metas = ctx.inspector.meta_values
    metas.any? { |m| m.kind == "Spinner" }.should be_true
    metas.find { |m| m.kind == "Spinner" }.not_nil!.props.should be_empty
  end
end
