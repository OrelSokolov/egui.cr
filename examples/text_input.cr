# Text input across platforms: single-line TextEdit + multiline
# TextArea, echo of the live buffers.
#
# On iOS the interesting part is the plumbing this example exercises:
# tapping a field takes egui focus → the backend raises the system
# on-screen keyboard (sokol's hidden UITextField) → key taps arrive as
# CHAR / KEY events → the buffers edit live. Losing focus (tap outside,
# Esc) lowers the keyboard. The keyboard overlays the bottom of the
# screen — sokol_app's canvas-resize path doesn't work in scene mode —
# so the fields sit near the top.

require "../src/egui/backend_selector"

class TextInputApp < Egui::App
  @name = ""
  @story = ""
  # First frame: focus the single-line field so the on-screen keyboard
  # is up at launch (a tap into the field does the same at any time).
  @autofocus = true

  def update(ctx : Egui::Context) : Nil
    ctx.routes do |r|
      r.page "root/root" do
        ctx.window("Text input", Egui::Pos2.new(30.0, 60.0), width: 340.0) do |ui|
          ui.heading("Keyboard input")
          ui.label("Tap a field to focus — the on-screen keyboard " \
                   "opens; Esc or tapping outside closes it.")

          ui.separator

          ui.label("Name:")
          response = ui.text_edit_singleline(@name, hint: "type here…") do |text|
            @name = text
          end
          response.request_focus if @autofocus

          ui.label("Story:")
          ui.textarea(@story, hint: "multiline…", rows: 4) do |text|
            @story = text
          end

          ui.separator
          ui.label("name: #{@name.empty? ? "—" : @name}")
          ui.label("story: #{@story.size} chars")
          if ui.button("Clear").clicked?
            @name = ""
            @story = ""
          end
        end
      end
    end
    @autofocus = false
  end
end

Egui.run(TextInputApp.new, title: "egui-cr — text input")
