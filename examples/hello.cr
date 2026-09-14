# egui-cr slice 1: Hello World — button + label + label change.
#
# The Rust egui equivalent:
#
#   egui::CentralPanel::default().show(ctx, |ui| {
#       ui.label("Hello World!");
#       if ui.button("Click me").clicked() {
#           count += 1;
#       }
#       ui.label(format!("count: {}", count));
#   });

require "../src/egui"
require "../src/egui/backend/sokol"

class HelloApp < Egui::App
  @count = 0

  def update(ctx : Egui::Context) : Nil
    # Movable window: drag the title bar (window position is system
    # state — Areas), the body content sits below it.
    ctx.window("Hello egui-cr", Egui::Pos2.new(40.0, 40.0), width: 360.0) do |ui|
      ui.heading("Hello World!")

      # CollapsingHeader: open/closed flag is system state (IdTypeMap),
      # not app state — try collapsing and watch it survive.
      Egui::CollapsingHeader.new("Demo", default_open: true).show(ui) do |body|
        if body.button("Click me").clicked?
          @count += 1
        end
        body.label("Clicked #{@count} times")
      end
    end

    # FPS counter panel pinned to the bottom of the screen
    # (egui: TopBottomPanel::bottom("fps").show(ctx, |ui| …)).
    ctx.bottom_panel("fps") do |ui|
      ui.label("FPS: #{"%.1f" % ctx.fps}  (frame #{(ctx.input.dt * 1000).round(1)} ms)")
    end
  end
end

Egui::Backend::Sokol.run(HelloApp.new, title: "egui-cr — hello")
