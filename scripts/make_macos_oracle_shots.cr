# Renders the egui.cr twin of the macOS widget oracle (see
# plans/macos-oracle-gallery.md): the same flat 480x160 sheets as
# oracle/macos/render.swift, headless through Egui::Capybara, into
# oracle/egui/png/<sheet>.png — ready for twinshot diffing against
# oracle/macos/png/.
#
#   crystal run scripts/make_macos_oracle_shots.cr [-- --only button,slider]
#
# Light theme, 13pt text, dialog-gray background to match the native
# sheets; SF Pro via the system font file when present.

require "../src/egui"
require "../src/egui/capybara"
require "../src/egui/capybara/fonts"

SHEET_W = 480
SHEET_H = 160

SHEETS = %w[
  button checkbox radio switch text_field search_field
  slider segmented popup progress stepper label
]

# The macOS widget oracle app: one flat sheet per frame, selected by
# name — the Capybara session steps it once per sheet.
class MacOsOracleApp < Egui::App
  property sheet = "button"

  @checked = true
  @radio = 0
  @sw_off = false
  @sw_on = true
  @text = "Placeholder"
  @search = ""
  @slider = 0.6_f64
  @seg = 1
  @combo = "First"
  @num = 42

  def initialize
    super
    # 1:1 macOS look — the measured platform theme (oracle/FINDINGS.md).
    @ctx.theme = Egui::MacOsTheme.light
  end

  def update(ctx : Egui::Context) : Nil
    ctx.central_panel(fill: Egui::Color32.rgb(236, 236, 236)) do |ui|
      # Row at a fixed origin, mirroring the native renderer's
      # place(x: 24) / place(x: 250) columns; y centers the row's
      # widgets on the native 80pt midline (row heights differ per
      # sheet). Field sheets use a narrower region so the edit fills
      # the native 200/222pt width (edits hug their region width).
      width = {"text_field" => 200.0, "search_field" => 222.0,
               "popup" => 200.0, "progress" => 200.0,
               "slider" => 220.0}[@sheet]? || 432.0
      # Row heights for centering on the native 80pt midline. The area
      # id is PER SHEET: areas remember their position in ctx.memory,
      # so one shared id would freeze every sheet at the first sheet's
      # y (that bit us — checkbox/progress rows sat 4-6px off).
      row_h = {"button" => 24.0, "switch" => 24.0, "segmented" => 24.0,
               "popup" => 24.0, "checkbox" => 18.0, "radio" => 18.0,
               "text_field" => 26.0, "search_field" => 26.0,
               "stepper" => 26.0, "slider" => 18.0,
               "progress" => 15.0, "label" => 10.0}[@sheet]? || 24.0
      ctx.area("row_#{@sheet}",
        default_pos: Egui::Pos2.new(24.0, 80.0 - row_h / 2.0),
        width: width) do |area_ui|
        area_ui.horizontal(false) { |h| sheet_ui(h) }
      end
    end
  end

  private def sheet_ui(ui : Egui::Ui) : Nil
    case @sheet
    when "button"
      resp = ui.button("Button")
      at_second_column(ui, resp)
      Egui::MacOsTheme.default_button(ui, "OK")
    when "checkbox"
      resp = ui.checkbox(false, "Check")
      at_second_column(ui, resp)
      ui.checkbox(@checked, "Selected")
    when "radio"
      resp = ui.radio(@radio == 0, "First")
      at_second_column(ui, resp)
      ui.radio(@radio == 1, "Second")
    when "switch"
      resp = ui.add(Egui::ToggleButton.new(@sw_off))
      at_second_column(ui, resp)
      ui.add(Egui::ToggleButton.new(@sw_on))
    when "text_field"
      ui.text_edit_singleline(@text, width: 200.0) { |t| @text = t }
    when "search_field"
      ui.text_edit_singleline(@search, hint: "Search",
        width: 222.0) { |t| @search = t }
    when "slider"
      ui.slider(@slider, 0.0..1.0) { |v| @slider = v }
    when "segmented"
      ui.segmented(@seg, ["One", "Two", "Three"]) { |v| @seg = v }
    when "popup"
      ui.combo_box("combo", @combo,
        ["First", "Second", "Third"], width: 200.0) { |s| @combo = s }
    when "progress"
      ui.progress_bar(0.45)
      ui.allocate_space(Egui::Vec2.new(56.0, 0.0))
      ui.spinner
    when "stepper"
      ui.number_input(@num) { |v| @num = v }
    when "label"
      resp = ui.label("Label")
      at_second_column(ui, resp)
      ui.rich(Egui::RichText.new("Secondary label")
        .color(Egui::Color32.rgb(110, 110, 115)))
    end
  end

  # Space the second variant out to the native x=250 column (minus
  # the row's item_spacing, which the layout adds on top).
  private def at_second_column(ui : Egui::Ui, first : Egui::Response) : Nil
    gap = 250.0 - 24.0 - first.rect.width -
         ui.style.spacing.item_spacing.x
    ui.allocate_space(Egui::Vec2.new(gap, 0.0)) if gap > 0
  end
end

app = MacOsOracleApp.new

# SF Pro when the system file exists (it does on every macOS); fall
# back to the bundled Noto Sans otherwise.
font_paths = File.exists?("/System/Library/Fonts/SFNS.ttf") ?
  ["/System/Library/Fonts/SFNS.ttf"] : nil
Egui::Capybara::Fonts.install!(app.ctx, paths: font_paths)

Dir.mkdir_p("oracle/egui/png")
sheets = ARGV.empty? ? SHEETS : SHEETS & ARGV.map(&.downcase)
sheets.each do |sheet|
  app.sheet = sheet
  session = Egui::Capybara::Session.new(app, width: SHEET_W,
    height: SHEET_H)
  session.step
  path = "oracle/egui/png/#{sheet}.png"
  session.screenshot(path)
  puts path
end
