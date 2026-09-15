# egui-cr: async native file dialogs — OpenFileDialog demo.
#
# The dialog call never blocks the frame: it spawns a worker fiber
# (AsyncDialogs) and the chosen path arrives in the callback on a
# later frame. While the picker is open the UI keeps rendering —
# watch the spinner animate and the frame counter climb, then pick
# (or cancel) in the native zenity/kdialog window.

require "../src/egui"
require "../src/egui/backend/sokol"

class OpenFileDialogApp < Egui::App
  @picks = [] of String
  @busy = false

  def update(ctx : Egui::Context) : Nil
    ctx.window("OpenFileDialog", Egui::Pos2.new(40.0, 40.0), width: 420.0) do |ui|
      ui.heading("Async native dialog")

      busy = @busy || Egui::SystemPorts::AsyncDialogs.pending?
      if ui.button("Open file…").clicked? && !busy
        @busy = true
        Egui::SystemPorts::OpenFileDialog.show(
          title: "Pick a picture",
          filters: ["*.png", "*.jpg", "*.jpeg"]) do |path|
          @busy = false
          @picks.unshift(path || "(cancelled)")
        end
      end

      if busy
        ui.horizontal do |row|
          row.spinner
          row.label("dialog is open — the UI keeps rendering…")
        end
      end

      unless @picks.empty?
        ui.separator
        ui.label("picks (newest first):")
        @picks.first(5).each { |pick| ui.label("  #{pick}") }
      end

      if ui.button("Quit").clicked?
        Egui::SystemPorts::Quit.quit!
      end
    end

    ctx.bottom_panel("fps") do |ui|
      ui.label("FPS: #{"%.1f" % ctx.fps}  (frame #{(ctx.input.dt * 1000).round(1)} ms)")
    end
  end
end

Egui::Backend::Sokol.run(OpenFileDialogApp.new, title: "egui-cr — OpenFileDialog")
