require "spec"
require "../src/egui"

SMOKE_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(900.0, 700.0))

def smoke_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
                time : Float64 = 0.016, &app : Egui::Context ->)
  raw = Egui::RawInput.new(SMOKE_SCREEN, events, time)
  ctx.begin_frame(raw)
  ctx.inspector.before_update
  yield ctx
  ctx.inspector.after_update
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
    # simulate what a row editor write does ("fill" edits the BASE
    # state, so the pointer must be off the button — not hovering it)
    ctx.set_id_style(Egui::Id.from("save"), "fill",
      Egui::Color32.rgb(10, 200, 30))
    smoke_frame(ctx, events: [Egui::Event.pointer_moved(Egui::Pos2.new(4.0, 4.0))],
      time: 0.096) do |c|
      c.window("w") { |ui| ui.button("OK", id: "save") }
    end
    ctx.painter.commands.select(Egui::RectCmd)
      .any? { |r| r.fill == Egui::Color32.rgb(10, 200, 30) }.should be_true

    # panel closed → F12 semantics (toggle directly) and frames keep running
    ctx.inspector.open = false
    smoke_frame(ctx, time: 0.112) do |c|
      c.window("w") { |ui| ui.button("OK", id: "save") }
    end
  end
end
