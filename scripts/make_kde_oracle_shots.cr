# Renders the egui.cr twin of the KDE widget oracle (see
# oracle/qt/render.cpp and the KDE section of oracle/FINDINGS.md):
# the same flat 480x160 sheets as the native Qt6/Breeze renders,
# headless through Egui::Capybara, into oracle/egui-kde/png/<sheet>.png.
#
#   crystal run scripts/make_kde_oracle_shots.cr [-- --only button,slider]
#
# Light theme, 10pt text, #EFF0F1 background to match the native
# sheets; Noto Sans from the system (the KDE system font).

require "../src/egui"
require "../src/egui/capybara"
require "../src/egui/capybara/fonts"

SHEET_W = 480
SHEET_H = 160

# Search lens — the dimmed-text gray of the placeholder hint.
LENS = Egui::Icon.from_file(:lucide, :search,
  tint: Egui::Color32.rgb(127, 140, 141))

# No switch sheet (QtWidgets has no switch primitive — see FINDINGS)
# and no spinner on the progress sheet (no QtWidgets spinner either).
SHEETS = %w[
  button checkbox radio text_field search_field
  slider segmented popup progress stepper label
]

# The KDE widget oracle app: one flat sheet per frame, selected by
# name — the Capybara session steps it once per sheet.
class KdeOracleApp < Egui::App
  property sheet = "button"

  @checked = true
  @radio = 0
  @text = "Placeholder"
  @search = ""
  @slider = 0.6_f64
  @seg = 1
  @combo = "First"
  @num = 42

  def initialize
    super
    # 1:1 Breeze look — the measured platform theme (oracle/FINDINGS.md).
    @ctx.theme = Egui::KdeTheme.light
  end

  def update(ctx : Egui::Context) : Nil
    ctx.central_panel(fill: Egui::Color32.rgb(239, 240, 241)) do |ui|
      # Row at a fixed origin, mirroring the native renderer's
      # place(x: 24) column (Qt sheets are single-column); y centers
      # the row's widgets on the native 80pt midline (row heights
      # measured off oracle/qt/png).
      width = {"text_field" => 200.0, "search_field" => 222.0,
               "popup" => 200.0, "progress" => 200.0,
               "slider" => 220.0}[@sheet]? || 432.0
      row_h = {"button" => 33.0, "segmented" => 33.0, "popup" => 31.0,
               "checkbox" => 16.0, "radio" => 16.0,
               "text_field" => 32.0, "search_field" => 32.0,
               "stepper" => 32.0, "slider" => 19.0,
               "progress" => 6.0, "label" => 10.0}[@sheet]? || 24.0
      ctx.area("row_#{@sheet}",
        default_pos: Egui::Pos2.new(24.0, 80.0 - row_h / 2.0),
        width: width) do |area_ui|
        area_ui.horizontal(false) { |h| sheet_ui(h) }
      end

      # The panel's window_stroke frames the sheet with a 1px rim the
      # native renderer has no counterpart for. Overpaint the border
      # strips with the sheet background (the macOS-twin trick — see
      # make_macos_oracle_shots.cr).
      bg = Egui::Color32.rgb(239, 240, 241)
      p = ctx.painter
      p.clip = Egui::Rect.from_min_size(Egui::Pos2.zero,
        Egui::Vec2.new(SHEET_W.to_f, SHEET_H.to_f))
      p.rect(Egui::Rect.from_min_size(Egui::Pos2.zero,
        Egui::Vec2.new(SHEET_W.to_f, 2.0)), 0.0, bg)
      p.rect(Egui::Rect.from_min_size(Egui::Pos2.new(0.0, SHEET_H.to_f - 2.0),
        Egui::Vec2.new(SHEET_W.to_f, 2.0)), 0.0, bg)
      p.rect(Egui::Rect.from_min_size(Egui::Pos2.zero,
        Egui::Vec2.new(2.0, SHEET_H.to_f)), 0.0, bg)
      p.rect(Egui::Rect.from_min_size(Egui::Pos2.new(SHEET_W.to_f - 2.0, 0.0),
        Egui::Vec2.new(2.0, SHEET_H.to_f)), 0.0, bg)
    end
  end

  private def sheet_ui(ui : Egui::Ui) : Nil
    case @sheet
    when "button"
      resp = ui.button("Button")
      at_second_column(ui, resp)
      ui.button("Default")
    when "checkbox"
      resp = ui.checkbox(false, "Check")
      at_second_column(ui, resp)
      ui.checkbox(@checked, "Selected")
    when "radio"
      resp = ui.radio(@radio == 0, "First")
      at_second_column(ui, resp)
      ui.radio(@radio == 1, "Second")
    when "text_field"
      ui.text_edit_singleline(@text, width: 200.0) { |t| @text = t }
    when "search_field"
      # "search" scope: the search entry keeps the plain entry look in
      # Breeze — only the lens differs (see KdeTheme).
      ui.with_style_scope("search") do |s|
        s.text_edit_singleline(@search, hint: "Search",
          width: 222.0, leading_icon: LENS) { |t| @search = t }
      end
    when "slider"
      ui.slider(@slider, 0.0..1.0) { |v| @slider = v }
    when "segmented"
      ui.segmented(@seg, ["One", "Two", "Three"]) { |v| @seg = v }
    when "popup"
      ui.combo_box("combo", @combo,
        ["First", "Second", "Third"], width: 200.0) { |s| @combo = s }
    when "progress"
      # No spinner — QtWidgets has none; the native sheet is the bar
      # alone (see FINDINGS).
      ui.progress_bar(0.45)
    when "stepper"
      ui.number_input(@num) { |v| @num = v }
    when "label"
      resp = ui.label("Label")
      at_second_column(ui, resp)
      ui.rich(Egui::RichText.new("Dim label")
        .color(Egui::Color32.rgb(151, 153, 154)))
    end
  end

  # Space the second variant out to the native x=250 column (the
  # macOS-twin arithmetic: the row layout adds item_spacing on BOTH
  # sides of the spacer).
  private def at_second_column(ui : Egui::Ui, first : Egui::Response) : Nil
    gap = 250.0 - 24.0 - first.rect.width -
          2.0 * ui.style.spacing.item_spacing.x
    ui.allocate_space(Egui::Vec2.new(gap, 0.0)) if gap > 0
  end
end

app = KdeOracleApp.new

# Noto Sans — the KDE system font; common distro layouts.
noto = ["/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/noto/NotoSans-Regular.ttf"]
font_paths = noto.select { |p| File.exists?(p) }
font_paths = nil if font_paths.empty?
Egui::Capybara::Fonts.install!(app.ctx, paths: font_paths)

Dir.mkdir_p("oracle/egui-kde/png")
sheets = ARGV.empty? ? SHEETS : SHEETS & ARGV.map(&.downcase)
sheets.each do |sheet|
  app.sheet = sheet
  session = Egui::Capybara::Session.new(app, width: SHEET_W,
    height: SHEET_H)
  session.step
  path = "oracle/egui-kde/png/#{sheet}.png"
  session.screenshot(path)
  puts path
end
