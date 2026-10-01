require "spec"
require "../src/egui"

ECSS_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

private def ecss_tmp_path : String
  File.join(Dir.tempdir, "ecss_spec_#{Random.rand(1_000_000_000)}",
    "app_style.ecss")
end

describe "ecss" do
  it "parses classes, states, elements, colors, numbers and strings" do
    src = <<-ECSS
      button {
        background: #3d3d3dff;
        padding.top: 4; // line comment
        /* block comment */
        text_color: #fff;
      }
      button:hover {
        background: #5a5a5a;
      }
      #save:active {
        background: #ff8800ff;
        font_family: "Inter Semi";
      }
      #0x1a2b3c {
        text_color: #ffffff00;
      }
    ECSS
    doc = Egui::Ecss::Doc.parse(src)
    base = doc.class_vars("button", nil).not_nil!
    base.color?("background").should eq Egui::Color32.rgb(0x3d, 0x3d, 0x3d)
    base.f64?("padding.top").should eq 4.0
    base.color?("text_color").should eq Egui::Color32.rgb(255, 255, 255)
    hover = doc.class_vars("button", "hover").not_nil!
    hover.color?("background").should eq Egui::Color32.rgb(90, 90, 90)
    act = doc.element(Egui::Id.from("save")).not_nil!
    act.states["active"].color?("background").should eq Egui::Color32.rgb(255, 136, 0)
    act.states["active"].str?("font_family").should eq "Inter Semi"
    # Raw auto-id rules are filtered out — a raw value means nothing
    # in another process.
    doc.element(Egui::Id.new(0x1a2b3c)).should be_nil
  end

  it "round-trips through serialize → parse" do
    src = <<-ECSS
      button {
        background: #3d3d3dff;
        padding.top: 4;
      }
      button:hover {
        background: #5a5a5aff;
      }
      #save:active {
        background: #ff8800ff;
        font_family: "Inter";
      }
    ECSS
    once = Egui::Ecss::Doc.parse(src).to_s
    twice = Egui::Ecss::Doc.parse(once).to_s
    twice.should eq once
    twice.should contain("button:hover")
    twice.should contain("#save:active")
    twice.should contain("font_family: \"Inter\";")
  end

  it "parses leniently — broken pieces warn, not raise" do
    doc = Egui::Ecss::Doc.parse(<<-ECSS)
      button { background: nope; stroke: #00ff00ff; }
      bogus {
      #bad-raw { text_color: #0x }
    ECSS
    base = doc.class_vars("button", nil).not_nil!
    base.has_key?("background").should be_false
    base.color?("stroke").should eq Egui::Color32.rgb(0, 255, 0)
  end

  it "Session applies a loaded file to the context" do
    path = ecss_tmp_path
    Dir.mkdir_p(File.dirname(path))
    File.write(path, <<-ECSS)
      button { background: #102030ff; }
      #save:hover { text_color: #ff0000ff; }
    ECSS
    ctx = Egui::Context.new
    Egui::Ecss::Session.new(ctx, path)
    ctx.stylesheet.resolve("button")
      .color?("background").should eq Egui::Color32.rgb(16, 32, 48)
    ctx.id_style_state_vars(Egui::Id.from("save"), "hover")
      .not_nil!.color?("text_color").should eq Egui::Color32.rgb(255, 0, 0)
  end

  it "records edits, flushes the file and hot-reloads external changes" do
    path = ecss_tmp_path
    ctx = Egui::Context.new
    default_hover = ctx.stylesheet.resolve("button", "hover")
      .color?("background")
    s = Egui::Ecss::Session.new(ctx, path)
    File.exists?(path).should be_false

    # An auto-id element edit applies live but never persists.
    auto = Egui::Id.new(0xdeadbeef_u64)
    s.record_element(auto, nil, "stroke", Egui::Color32.rgb(9, 9, 9))
    ctx.id_style_state_vars(auto, nil).not_nil!
      .color?("stroke").should eq Egui::Color32.rgb(9, 9, 9)
    s.record_class("button:hover", "background", Egui::Color32.rgb(1, 2, 3))
    s.record_element(Egui::Id.from("save"), "save", "stroke",
      Egui::Color32.rgb(4, 5, 6))
    s.flush
    text = File.read(path)
    text.should contain("button:hover")
    text.should contain("#save")
    text.should_not contain("deadbeef")

    # External edit: the old hover rule must DISAPPEAR (journal un-applies).
    File.write(path, "button { stroke: #00ff00ff; }\n")
    s.poll
    ctx.stylesheet.resolve("button")
      .color?("stroke").should eq Egui::Color32.rgb(0, 255, 0)
    ctx.stylesheet.resolve("button", "hover")
      .color?("background").should eq default_hover
    # The never-persisted auto-id override survived the reload (it
    # lives only in the Context, outside the document).
    ctx.id_style_state_vars(auto, nil)
      .not_nil!.color?("stroke").should eq Egui::Color32.rgb(9, 9, 9)
  end

  it "clear_element wipes every state of an element override" do
    path = ecss_tmp_path
    ctx = Egui::Context.new
    s = Egui::Ecss::Session.new(ctx, path)
    id = Egui::Id.from("save")
    s.record_element(id, "save", "stroke", Egui::Color32.rgb(1, 1, 1))
    s.record_element(id, "save", "background", Egui::Color32.rgb(2, 2, 2), "hover")
    s.flush
    File.read(path).should contain("#save:hover")
    s.clear_element(id)
    s.flush
    File.read(path).should_not contain("#save")
    ctx.id_style_overrides.empty?.should be_true
  end

  it "re-applies class rules after a theme swap" do
    path = ecss_tmp_path
    ctx = Egui::Context.new
    s = Egui::Ecss::Session.new(ctx, path)
    ctx.ecss = s
    s.record_class("button", "background", Egui::Color32.rgb(9, 8, 7))
    ctx.stylesheet.resolve("button")
      .color?("background").should eq Egui::Color32.rgb(9, 8, 7)
    ctx.theme = Egui::Theme.light
    ctx.stylesheet.resolve("button")
      .color?("background").should eq Egui::Color32.rgb(9, 8, 7)
  end

  it "records edits in memory — the file is written only by flush" do
    path = ecss_tmp_path
    ctx = Egui::Context.new
    s = Egui::Ecss::Session.new(ctx, path)
    ctx.ecss = s
    raw = Egui::RawInput.new(ECSS_SCREEN, [] of Egui::Event, 0.016)
    ctx.begin_frame(raw)
    s.record_class("button", "background", Egui::Color32.rgb(3, 3, 3))
    ctx.end_frame
    File.exists?(path).should be_false # no write per change
    s.flush(force: true)               # the «Сохранить» button
    File.exists?(path).should be_true
    File.read(path).should contain("button")
  end

  it "inspector Class tab writes through to the .ecss file" do
    path = ecss_tmp_path
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    ctx.inspector.open = true
    ctx.inspector.tab = :class
    ctx.ecss = Egui::Ecss::Session.new(ctx, path)

    t = 0.016
    draw = ->(events : Array(Egui::Event)) do
      t += 0.016
      raw = Egui::RawInput.new(ECSS_SCREEN, events, t)
      ctx.begin_frame(raw)
      ctx.inspector.before_update
      ctx.central_panel do |ui|
        ui.add(Egui::Button.new("OK", id: "save"))
      end
      ctx.end_frame
    end

    draw.call([] of Egui::Event) # meta recorded ("button" class)
    draw.call([] of Egui::Event) # class tab rows render, rects register

    # The marker checkbox renders just before its name Label — locate
    # the row's marker that way. Pick a key NOT in the default theme's
    # class rule ("rounding"): its marker starts unchecked, so the
    # click SEEDS the value (a checked marker like "background" would
    # take the unset branch instead).
    vals = ctx.inspector.meta_values
    idx = vals.index { |m| m.kind == "Label" && m.label == "rounding" }.not_nil!
    marker = vals[idx - 1]
    marker.kind.should eq("Checkbox")
    rect = ctx.memory.widget_rects[marker.id].not_nil!
    center = Egui::Pos2.new(rect.center.x, rect.center.y)

    draw.call([Egui::Event.pointer_pressed(center)])
    draw.call([Egui::Event.pointer_released(center)])

    # Edits recorded, but nothing on disk until «Сохранить».
    File.exists?(path).should be_false
    save = ctx.inspector.meta_values.find { |m| m.kind == "Button" && m.label == "Сохранить" }.not_nil!
    save_rect = ctx.memory.widget_rects[save.id].not_nil!
    save_center = Egui::Pos2.new(save_rect.center.x, save_rect.center.y)
    draw.call([Egui::Event.pointer_pressed(save_center)])
    draw.call([Egui::Event.pointer_released(save_center)])

    text = File.read(path)
    text.should contain("button {")
    text.should contain("rounding:")

    # Un-tick: the override row resets; after another «Сохранить» the
    # rule has left the file.
    draw.call([] of Egui::Event)
    draw.call([Egui::Event.pointer_pressed(center)])
    draw.call([Egui::Event.pointer_released(center)])
    draw.call([Egui::Event.pointer_pressed(save_center)])
    draw.call([Egui::Event.pointer_released(save_center)])
    File.read(path).should_not contain("rounding:")
  end

  it "inspector Element tab writes through to the .ecss file" do
    path = ecss_tmp_path
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    ctx.inspector.open = true
    ctx.ecss = Egui::Ecss::Session.new(ctx, path)

    t = 0.016
    draw = ->(events : Array(Egui::Event)) do
      t += 0.016
      raw = Egui::RawInput.new(ECSS_SCREEN, events, t)
      ctx.begin_frame(raw)
      ctx.inspector.before_update
      ctx.central_panel do |ui|
        ui.add(Egui::Button.new("OK", id: "save"))
      end
      ctx.end_frame
    end

    draw.call([] of Egui::Event)
    ctx.inspector.selected = Egui::Id.from("save")
    draw.call([] of Egui::Event) # element tab rows render

    markers = ctx.inspector.meta_values
    idx = markers.index { |m| m.kind == "Label" && m.label == "background" }.not_nil!
    marker = markers[idx - 1]
    marker.kind.should eq("Checkbox")
    rect = ctx.memory.widget_rects[marker.id].not_nil!
    center = Egui::Pos2.new(rect.center.x, rect.center.y)

    draw.call([Egui::Event.pointer_pressed(center)])
    draw.call([Egui::Event.pointer_released(center)])
    File.exists?(path).should be_false

    save = ctx.inspector.meta_values.find { |m| m.kind == "Button" && m.label == "Сохранить" }.not_nil!
    save_rect = ctx.memory.widget_rects[save.id].not_nil!
    save_center = Egui::Pos2.new(save_rect.center.x, save_rect.center.y)
    draw.call([Egui::Event.pointer_pressed(save_center)])
    draw.call([Egui::Event.pointer_released(save_center)])

    text = File.read(path)
    text.should contain("#save {")
    text.should contain("background:")
    ctx.id_style_state_vars(Egui::Id.from("save"), nil)
      .not_nil!.has_key?("background").should be_true
  end

  it "switching to the Class tab targets the last selected element's class" do
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    ctx.inspector.open = true
    ctx.inspector.tab = :class
    ctx.ecss = Egui::Ecss::Session.new(ctx, ecss_tmp_path)

    t = 0.016
    draw = ->(events : Array(Egui::Event)) do
      t += 0.016
      raw = Egui::RawInput.new(ECSS_SCREEN, events, t)
      ctx.begin_frame(raw)
      ctx.inspector.before_update
      ctx.central_panel do |ui|
        ui.add(Egui::Button.new("OK", id: "save"))
        ui.add(Egui::Checkbox.new(false, "check me", id: "the_box"))
      end
      ctx.end_frame
    end

    draw.call([] of Egui::Event) # meta recorded
    draw.call([] of Egui::Event) # class tab renders (defaults to the
    # alphabetically-first class) and the header cells register rects
    ctx.inspector.class_sel.should eq "button"

    # Pick the Checkbox — selection forces the Element tab; clicking
    # "Class" afterwards must jump to "checkbox", not stay on "button".
    ctx.inspector.selected = Egui::Id.from("the_box")
    ctx.inspector.tab.should eq :element
    draw.call([] of Egui::Event)

    class_tab = ctx.inspector.meta_values.find { |m|
      m.kind == "InspectorTab" && m.label == "Class" }.not_nil!
    rect = ctx.memory.widget_rects[class_tab.id].not_nil!
    center = Egui::Pos2.new(rect.center.x, rect.center.y)
    draw.call([Egui::Event.pointer_pressed(center)])
    draw.call([Egui::Event.pointer_released(center)])

    ctx.inspector.tab.should eq :class
    ctx.inspector.class_sel.should eq "checkbox"
  end

  {% if flag?(:debug) %}
    it "enable_ecss macro defines the debug hooks" do
      EcssSpecApp.new.ecss_app_id.should eq "ecss_spec_app"
    end
  {% end %}
end

class EcssSpecApp < Egui::App
  enable_ecss "ecss_spec_app"

  def update(ctx : Egui::Context) : Nil
  end
end
