require "../src/egui"
SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))
ctx = Egui::Context.new
ctx.inspector_enabled = true
raw = Egui::RawInput.new(SCREEN, [] of Egui::Event, 0.016)
ctx.begin_frame(raw)
ctx.inspector.before_update
ctx.window("w") { |ui| ui.button("OK", id: "save") }
ctx.end_frame
# replicate the header manually with prints
ctx2 = Egui::Context.new
ctx2.inspector_enabled = true
raw = Egui::RawInput.new(SCREEN, [] of Egui::Event, 0.016)
ctx2.begin_frame(raw)
ctx2.inspector.before_update
ctx2.window("w") { |ui| ui.button("OK", id: "save") }
ctx2.end_frame
