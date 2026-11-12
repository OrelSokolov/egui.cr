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

# NSSearchField lens — the native sheet's placeholder-gray glyph.
LENS = Egui::Icon.from_file(:lucide, :search,
  tint: Egui::Color32.rgb(110, 110, 115))

SHEETS = %w[
  button checkbox radio switch text_field search_field
  slider segmented popup progress stepper label
  separator link secure_field textarea
  disclosure color_well date_picker time_picker
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
  @pw = "Placeholder"
  @notes = "Line one\nLine two"
  @date = Time.utc(2026, 11, 7, 14, 30, 5)
  @time = Time.utc(2026, 11, 7, 14, 30, 5)

  def initialize
    super
    # 1:1 macOS look — the measured platform theme (oracle/FINDINGS.md).
    @ctx.theme = Egui::MacOsTheme.light
    # A bare Separator stretches across the row's remaining height
    # (upstream semantics); the native separator is a 20pt hairline —
    # cap it under the "sheet" scope (the separator sheet only). Same
    # scope pins the textarea box to the native 56pt (rows:3 computes
    # 63pt with this theme's insets).
    @ctx.theme.sheet.rule("sheet.separator",
      Egui::StyleVars{"height" => 20.0})
    @ctx.theme.sheet.rule("sheet.textarea",
      Egui::StyleVars{"height" => 56.0})
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
               "slider" => 220.0, "secure_field" => 200.0,
               "textarea" => 200.0}[@sheet]? || 432.0
      # Row heights for centering on the native 80pt midline. The area
      # id is PER SHEET: areas remember their position in ctx.memory,
      # so one shared id would freeze every sheet at the first sheet's
      # y (that bit us — checkbox/progress rows sat 4-6px off).
      row_h = {"button" => 24.0, "switch" => 24.0, "segmented" => 24.0,
               "popup" => 24.0, "checkbox" => 18.0, "radio" => 18.0,
               "text_field" => 26.0, "search_field" => 26.0,
               "secure_field" => 26.0, "stepper" => 26.0, "slider" => 18.0,
               "separator" => 20.0, "textarea" => 56.0,
               "progress" => 15.0, "label" => 10.0, "link" => 18.0,
               "disclosure" => 24.0, "color_well" => 24.0,
               "date_picker" => 20.0, "time_picker" => 20.0}[@sheet]? || 24.0
      ctx.area("row_#{@sheet}",
        default_pos: Egui::Pos2.new(24.0, 80.0 - row_h / 2.0),
        width: width) do |area_ui|
        area_ui.horizontal(false) { |h| sheet_ui(h) }
      end

      # The panel's window_stroke frames the sheet with a 1px rim the
      # native renderer has no counterpart for (their sheets are solid
      # background to the edge — it alone was ~3% of every twinshot
      # diff). Overpaint the border strips with the sheet background;
      # nothing is painted there, the strips only cover the rim. This
      # must run INSIDE the panel block: the panel bg (and its rim) is
      # back-painted at a reserved index, but anything painted after
      # update (before the deferral) lands under it.
      bg = Egui::Color32.rgb(236, 236, 236)
      p = ctx.painter
      # The area left the painter clipped to its own rect — the strips
      # live at the sheet's edges, outside it, so reset the clip first.
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
      # "search" scope → "search.text_edit": the NSSearchField capsule
      # (see MacOsTheme), vs the 6pt text field above.
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
    when "separator"
      # "One" · hairline · "Two", mirroring the native x=26/64/82. The
      # zero-gap spacers must still be ALLOCATED: a skipped one drops
      # the item_spacing pair and shifts the next piece 8pt left.
      one = ui.label("One")
      sp = ui.style.spacing.item_spacing.x
      gap = 65.0 - 24.0 - one.rect.width - 2.0 * sp
      ui.allocate_space(Egui::Vec2.new(gap, 0.0)) if gap >= 0
      ui.with_style_scope("sheet") { |s| s.separator }
      gap2 = 82.0 - 66.0 - 2.0 * sp
      ui.allocate_space(Egui::Vec2.new(gap2, 0.0)) if gap2 >= 0
      ui.label("Two")
    when "link"
      # AppKit links: linkColor, no underline (see MacOsTheme).
      resp = ui.add(Egui::Hyperlink.new("Open the guide",
        "https://example.com").underline(false))
      at_second_column(ui, resp)
      ui.add(Egui::Hyperlink.new("More…",
        "https://example.com/more").underline(false))
    when "secure_field"
      ui.text_edit_singleline(@pw, password: true,
        width: 200.0) { |t| @pw = t }
    when "textarea"
      ui.with_style_scope("sheet") do |s|
        s.textarea(@notes, rows: 3) { |t| @notes = t }
      end
    when "disclosure"
      # A CollapsingHeader spans its region's full width — bound each
      # one to the native cluster (24pt bezel + label) with a fixed
      # child region, closed/open at the two sheet columns.
      first = disclosure_header(ui, "Advanced", open: false)
      gap = 250.0 - 24.0 - first.width -
            2.0 * ui.style.spacing.item_spacing.x
      ui.allocate_space(Egui::Vec2.new(gap, 0.0)) if gap >= 0
      disclosure_header(ui, "Advanced", open: true)
    when "color_well"
      resp = ui.add(Egui::ColorButton.new(
        Egui::Color32.rgb(0, 122, 255)))
      at_second_column(ui, resp)
      ui.add(Egui::ColorButton.new(Egui::Color32.rgb(255, 59, 48)))
    when "date_picker"
      # The native sheet runs en_US_POSIX + Gregorian + UTC — "11/07/2026";
      # the same format on this side keeps the text identical.
      ui.date_picker("date", @date, format: "%m/%d/%Y") { |t| @date = t }
    when "time_picker"
      ui.time_picker("time", @time, format: "%H:%M:%S") { |t| @time = t }
    end
  end

  # One bounded CollapsingHeader: a fixed child region the header
  # fills (its own allocate spans the whole parent otherwise — the
  # native cluster is bezel + label, not a full row).
  private def disclosure_header(ui : Egui::Ui, text : String,
                                open : Bool) : Egui::Rect
    rect = ui.allocate_space(Egui::Vec2.new(96.0, 18.0))
    child = ui.child_ui(rect, ui.next_widget_id)
    Egui::CollapsingHeader.new(text, default_open: open).show(child) { |body| }
    rect
  end

  # Space the second variant out to the native x=250 column. The row
  # layout adds item_spacing on BOTH sides of the spacer (widget→spacer
  # and spacer→widget), so two spacings must come out of the gap —
  # subtracting one landed the second column at x=258.
  private def at_second_column(ui : Egui::Ui, first : Egui::Response) : Nil
    gap = 250.0 - 24.0 - first.rect.width -
          2.0 * ui.style.spacing.item_spacing.x
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
