# Fullscreen demo: big type dead-center and one gradient button that
# toggles the window between fullscreen and normal mode through the
# SystemPorts::Window contract (`set_fullscreen`/`fullscreen?` — the
# label follows the LIVE mode, so an Esc-out of native fullscreen
# flips the button back on the next frame).

require "../src/egui/driver_selector"

class FullscreenDemo < Egui::App
  def update(ctx : Egui::Context) : Nil
    ctx.central_panel do |ui|
      # The screen-centering trick: a flex container pinned to all four
      # edges (position: :fixed + inset 0) has BOTH axes definite, so
      # justify/align :center place the column dead-center — the flex
      # algorithm does the centering, no manual math.
      ui.flex(position: :fixed, top: 0, right: 0, bottom: 0, left: 0,
        margin: Egui::Vec2.zero, gap: 32.0,
        direction: :column, justify: :center, align: :center) do |f|
        f.child do |ui|
          ui.rich(Egui::RichText.new("Fullscreen").size(96.0))
        end
        f.child do |ui|
          fs = Egui::SystemPorts::Window.fullscreen?
          if ui.add(Egui::Button.new(fs ? "Back to normal mode" : "Go fullscreen")
            .gradient(Egui::Color32.rgb(40, 100, 200), Egui::Color32.rgb(16, 42, 92))
            .min_size(Egui::Vec2.new(240.0, 52.0))).clicked?
            Egui::SystemPorts::Window.set_fullscreen(!fs)
          end
        end
        f.child do |ui|
          ui.label("the button follows the live window mode")
        end
      end
    end
  end
end

Egui.run(FullscreenDemo.new,
  title: "egui-cr — fullscreen demo", inspector: :hidden)
