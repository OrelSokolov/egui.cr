# iOS system-integration demo — the counterpart of the Android IME test
# (tmp/android/ime_test.cr): soft-keyboard input across field profiles,
# local notifications, the document picker and Quit.
#
# On iOS the interesting plumbing this example exercises:
# - tap a field → egui focus → the backend raises the system keyboard
#   with the field's profile (plain / password-masked / multiline) —
#   TextInputKind/TextInputAction, same registry the Android IME sync
#   reads; tap outside or Esc lowers the keyboard
# - "Notify" → UNUserNotificationCenter local notification (the first
#   tap also triggers the iOS permission alert)
# - "Open file…" → the system Files browser (UIDocumentPickerViewController);
#   the pick is copied into the sandbox, the path stays readable
# - "Quit" → exit(0)
# The keyboard overlays the bottom of the screen — fields sit near the
# top.

require "../src/egui/backend_selector"

class TextInputApp < Egui::App
  @plain = ""
  @secret = ""
  @multi = ""
  @opened : String? = nil
  @notified = 0
  # First frame: focus the plain field so the keyboard is up at launch.
  @autofocus = true

  def update(ctx : Egui::Context) : Nil
    ctx.routes do |r|
      r.page "root/root" do
        ctx.window("iOS demo", Egui::Pos2.new(24.0, 60.0), width: 350.0) do |ui|
          ui.heading("Soft keyboard")
          ui.label("plain: #{@plain.inspect}")
          response = ui.text_edit_singleline(@plain, hint: "single line") do |text|
            @plain = text
          end
          response.request_focus if @autofocus

          ui.separator

          ui.label("secret: #{@secret.size} chars")
          ui.text_edit_singleline(@secret, hint: "password", password: true) do |text|
            @secret = text
          end

          ui.separator

          ui.label("multiline: #{@multi.inspect}")
          ui.textarea(@multi, hint: "multiline", rows: 3) do |text|
            @multi = text
          end

          ui.separator

          ui.heading("System")
          if ui.button("Notify").clicked?
            @notified += 1
            Egui::SystemPorts::Notification.show(
              "egui.cr demo",
              "local notification ##{@notified}")
          end
          ui.label("sent: #{@notified}")

          if ui.button("Open file…").clicked?
            @opened = nil
            Egui::SystemPorts::OpenFileDialog.show(
              filters: ["*.png", "*.jpg", "*.txt"]) { |path| @opened = path }
          end
          if Egui::SystemPorts::AsyncDialogs.pending?
            ui.label("opening…")
          else
            ui.label("opened: #{@opened || "—"}")
          end

          if ui.button("Quit").clicked?
            Egui::SystemPorts::Quit.quit!
          end
        end
      end
    end
    @autofocus = false
  end
end

Egui.run(TextInputApp.new, title: "egui-cr — iOS demo")
