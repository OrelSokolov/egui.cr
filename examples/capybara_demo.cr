# egui-cr Capybara demo: a suite embedded in a real app.
#
# Two modes:
#
#   crystal examples/capybara_demo.cr            # run the suite (headless)
#   crystal examples/capybara_demo.cr --window   # run the app itself
#
# The suite is the reproduce-a-bug workflow: plain Crystal scenarios
# against the real app class — clicks by id/label, typing, dragging,
# expectations, screenshots — at full speed, no window, no GL, no
# external grabber. `--selftest` style embedding works the same way in
# your own apps: keep the suite next to the app class and run it from
# main when a flag is present instead of Egui.run.

require "../src/egui"
require "../src/egui/capybara"
require "../src/egui/capybara/fonts"
require "../src/egui/backend_selector"

class NotesApp < Egui::App
  property notes = ["buy milk", "write egui.cr docs"]
  @draft = ""
  @selected = 0

  def update(ctx : Egui::Context) : Nil
    ctx.window("Notes", Egui::Pos2.new(60.0, 60.0), width: 460.0) do |ui|
      ui.text_edit_singleline(@draft, hint: "new note…") { |t| @draft = t }
      if ui.button("Add", id: "add").clicked? && !@draft.empty?
        @notes << @draft
        @draft = ""
      end
      ui.separator
      @notes.each_with_index do |note, i|
        if ui.selectable_label(i == @selected, note).clicked?
          @selected = i
        end
      end
      ui.label("#{@notes.size} notes, selected: #{@notes[@selected]? || "—"}")
    end
  end
end

suite = Egui::Capybara::Suite.new(-> { NotesApp.new.as(Egui::App) },
  width: 700, height: 520)

suite.scenario "adds a note end-to-end" do |t|
  t.expect_text("2 notes")
  t.fill("TextEdit", "port capybara")
  t.click("#add")
  t.expect_text("3 notes")
  t.expect_text("port capybara")
  t.screenshot("tmp/capybara_notes_added.png")
end

suite.scenario "selects a note by clicking it" do |t|
  t.click("write egui.cr docs")
  t.expect_text("selected: write egui.cr docs")
  t.screenshot("tmp/capybara_notes_selected.png")
end

suite.scenario "empty draft does not add" do |t|
  t.click("#add")
  t.expect_text("2 notes")
end

if ARGV.includes?("--window")
  Egui.run(NotesApp.new, title: "egui-cr — capybara demo")
else
  Dir.mkdir_p("tmp")
  exit suite.run
end
