# egui-cr phase 1 widget gallery — every simple widget in one window.
#
# Mirrors the phase-1 slice of components.md: checkbox, radio,
# separator, progress_bar, spinner, hyperlink (+ button/label/heading
# from slice 1).

require "../src/egui"
require "../src/egui/backend/sokol"

class GalleryApp < Egui::App
  @checked = false
  @radio : Int32 = 1
  @progress = 0.35_f64

  def update(ctx : Egui::Context) : Nil
    # Animate the progress bar up and down.
    @progress = 0.5 + 0.5 * Math.sin(ctx.input.time)

    ctx.window("Widget Gallery", Egui::Pos2.new(24.0, 24.0), width: 420.0) do |ui|
      ui.heading("Simple widgets")

      ui.checkbox(@checked, "Checkbox (#{@checked})") { |v| @checked = v }
      ui.checkbox(@checked, "Checkbox, block form") { |v| @checked = v }

      ui.horizontal do |row|
        if row.radio(@radio == 0, "First").changed?
          @radio = 0
        end
        if row.radio(@radio == 1, "Second").changed?
          @radio = 1
        end
        if row.radio(@radio == 2, "Third").changed?
          @radio = 2
        end
      end

      ui.separator

      ui.label("Progress (animated):")
      ui.progress_bar(@progress.clamp(0.0, 1.0), animate: true)

      ui.separator

      ui.horizontal do |row|
        row.label("Loading: ")
        row.spinner
      end

      ui.separator

      ui.label("Links:")
      ui.hyperlink_to("egui on GitHub", "https://github.com/emilk/egui")
      ui.hyperlink("https://crystal-lang.org")

      ui.separator

      if ui.button("Reset checkbox").clicked?
        @checked = false
      end
    end

    ctx.bottom_panel("fps") do |ui|
      ui.label("FPS: #{"%.1f" % ctx.fps}")
    end
  end
end

Egui::Backend::Sokol.run(GalleryApp.new, title: "egui-cr — widget gallery",
  width: 900, height: 700)
