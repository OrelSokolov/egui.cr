# iOS Demo — every system port the iOS backend wires, in one scrollable
# sheet: text input (soft keyboard), clipboard, message boxes,
# notifications, URL opening, document pickers (open / save / folder)
# and the user directories. The iOS counterpart of android_demo.cr —
# same sections, same contracts. Runs on the desktop too: the ports
# fall back to their desktop implementations, which keeps the non-iOS
# branches honest.
#
# Build (host):  crystal build --cross-compile --target=aarch64-apple-darwin \
#                 -o ios_demo.o examples/ios_demo.cr \
#                 --link-flags "tmp/ios/phase3/libegui_cr_sokol_ios.a"
# App bundle:    tmp/ios/phase4/build_demo.sh <dir>/ios_demo.o

require "../src/egui/backend_selector"

class IosDemoApp < Egui::App
  # Text input (soft keyboard).
  @plain = ""
  @secret = ""
  @multi = ""

  # Clipboard.
  @clip_field = "Hello from egui.cr"
  @clip_readback = "(nothing pasted yet)"

  # Notification.
  @notif_title = "egui-cr"
  @notif_body = "Hello from the iOS demo!"

  # OpenUrl.
  @url = "https://www.crystal-lang.org"
  @url_result = "—"

  # MessageBox.
  @confirm_result = "—"

  # File dialogs (document picker).
  @open_result = "—"
  @open_text = ""

  # UserDirs — filled once on the first frame.
  @dirs : Array({String, String})? = nil

  def update(ctx : Egui::Context) : Nil
    ctx.central_panel do |ui|
      ui.heading("iOS Demo")
      ui.label("system ports on iOS — scroll down")
      ui.separator

      ui.scroll_area do |ui|
        # --- text input (soft keyboard) ---------------------------------
        ui.label("plain: #{@plain.inspect}")
        ui.text_edit_singleline(@plain, hint: "single line") { |t| @plain = t }
        ui.label("secret: #{@secret.size} chars")
        ui.text_edit_singleline(@secret, hint: "password", password: true) { |t| @secret = t }
        ui.label("multiline: #{@multi.inspect}")
        ui.textarea(@multi, hint: "multiline", rows: 3) { |t| @multi = t }
        ui.separator

        # --- clipboard --------------------------------------------------
        ui.label("clipboard")
        ui.text_edit_singleline(@clip_field, hint: "text to copy") { |t| @clip_field = t }
        if ui.button("Copy").clicked?
          Egui::SystemPorts::Clipboard.text = @clip_field
        end
        if ui.button("Paste").clicked?
          @clip_readback = Egui::SystemPorts::Clipboard.text || "(empty)"
        end
        ui.label("read: #{@clip_readback.inspect}")
        ui.separator

        # --- message box ------------------------------------------------
        ui.label("message box")
        if ui.button("Info").clicked?
          Egui::SystemPorts::MessageBox.info("Hello from egui.cr!", "Info")
        end
        if ui.button("Warning").clicked?
          Egui::SystemPorts::MessageBox.warning("Something looks off.", "Warning")
        end
        if ui.button("Error").clicked?
          Egui::SystemPorts::MessageBox.error("It broke (not really).", "Error")
        end
        if ui.button("Confirm?").clicked?
          @confirm_result = "(asking…)"
          Egui::SystemPorts::MessageBox.confirm("Really do the thing?") do |ok|
            @confirm_result = ok ? "yes" : "no"
          end
        end
        ui.label("confirm answer: #{@confirm_result}")
        ui.separator

        # --- notification -----------------------------------------------
        ui.label("notification")
        ui.text_edit_singleline(@notif_title, hint: "title") { |t| @notif_title = t }
        ui.text_edit_singleline(@notif_body, hint: "body") { |t| @notif_body = t }
        if ui.button("Send notification").clicked?
          Egui::SystemPorts::Notification.show(@notif_title, @notif_body)
        end
        ui.separator

        # --- open url ---------------------------------------------------
        ui.label("open url")
        ui.text_edit_singleline(@url, hint: "url") { |t| @url = t }
        if ui.button("Open in browser").clicked?
          @url_result = Egui::SystemPorts::OpenUrl.show(@url) ? "launched" : "refused"
        end
        ui.label("result: #{@url_result}")
        ui.separator

        # --- file dialogs (document picker) -----------------------------
        ui.label("file dialogs")
        if ui.button("Open file…").clicked?
          @open_result = "(picking…)"
          @open_text = ""
          Egui::SystemPorts::OpenFileDialog.show("Open file",
            ["*.txt", "*.md", "*.json"]) do |path|
            @open_result = path || "(cancelled)"
            if path
              # The picker copies the file into the sandbox — a plain
              # File.read (no content-resolver roundtrip like Android).
              text = begin
                File.read(path)
              rescue
                nil
              end
              @open_text = text ? text[0, 400] : "(unreadable)"
            end
          end
        end
        if ui.button("Save file as…").clicked?
          @open_result = "(saving…)"
          Egui::SystemPorts::SaveFileDialog.show("Save file",
            default_name: "egui_cr_demo.txt") do |path|
            @open_result = path ? "save → #{path}" : "(cancelled)"
          end
        end
        if ui.button("Pick folder…").clicked?
          @open_result = "(picking…)"
          Egui::SystemPorts::PickFolderDialog.show("Choose folder") do |path|
            @open_result = path ? "folder → #{path}" : "(cancelled)"
          end
        end
        ui.label("result: #{@open_result}")
        unless @open_text.empty?
          ui.scroll_area(max_height: 120) do |ui|
            ui.label(@open_text)
          end
        end
        ui.separator

        # --- user dirs --------------------------------------------------
        ui.label("user dirs")
        if (dirs = @dirs).nil?
          @dirs = [
            {"home",     Egui::SystemPorts::UserDirs.home},
            {"config",   Egui::SystemPorts::UserDirs.config},
            {"cache",    Egui::SystemPorts::UserDirs.cache},
            {"documents", Egui::SystemPorts::UserDirs.documents || "(none)"},
          ]
        end
        @dirs.try &.each do |name, path|
          ui.label("#{name}: #{path}")
        end
      end
    end
  end
end

Egui.run(IosDemoApp.new, title: "egui-cr — iOS Demo")
