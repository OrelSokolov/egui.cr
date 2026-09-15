# Native file dialogs through SystemPorts (zenity/kdialog, fiber-backed
# and never blocking the frame loop): pick a file, then a destination to
# copy it to. The chosen paths arrive in the on_done callbacks a few
# frames later — the app state updates and the UI reflects it.

require "../src/egui"
require "../src/egui/backend/sokol"

class OpenFileDialogApp < Egui::App
  @picked : String? = nil
  @save_to : String? = nil
  @status = "Nothing picked yet."

  def update(ctx : Egui::Context) : Nil
    ctx.central_panel do |ui|
      ui.heading("Open file dialog")
      ui.label(@status)
      ui.separator

      if ui.button("Open file…").clicked?
        @status = "Opening dialog…"
        Egui::SystemPorts::OpenFileDialog.show(
          title: "Pick any file",
          filters: [] of String
        ) do |path|
          if path
            @picked = path
            @status = "Picked: #{path}"
          else
            @status = "Canceled (or no zenity/kdialog on PATH)."
          end
        end
      end

      if (p = @picked)
        ui.label("Source: #{p}")
        if ui.button("Choose destination…").clicked?
          Egui::SystemPorts::SaveFileDialog.show(
            title: "Copy #{File.basename(p)} to…",
            default_name: File.basename(p)
          ) do |dest|
            if dest
              begin
                File.copy(p, dest)
                @save_to = dest
                @status = "Copied to: #{dest}"
              rescue e : IO::Error | File::Error
                @status = "Copy failed: #{e.message}"
              end
            end
          end
        end
        ui.label("Destination: #{@save_to || "(none)"}") if @save_to
      end

      if Egui::SystemPorts::AsyncDialogs.pending?
        ui.spinner
        ui.label("Dialog is open — the UI keeps running.")
      end
    end
  end
end

Egui::Backend::Sokol.run(OpenFileDialogApp.new,
  title: "egui-cr — file dialogs", width: 520, height: 320)
