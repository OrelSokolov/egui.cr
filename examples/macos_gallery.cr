# macOS widget gallery — the egui.cr twin of the NATIVE oracle gallery:
#
#   cd oracle/macos && make && ./render gallery   # native, side by side
#   crystal run examples/macos_gallery.cr         # this one
#
# Everything is styled by Egui::MacOsTheme (src/egui/macos_theme.cr) —
# the theme measured against the headless AppKit renders
# (oracle/macos/png, diffed with twinshot — see oracle/FINDINGS.md).
# Live state: everything is interactive; the same widgets, states and
# accent as the native sheets.

require "../src/egui/driver_selector"
require "../src/egui/driver/crystalfonts"

class MacOsGalleryApp < Egui::App
  @checked = true
  @unchecked = false
  @radio = 0
  @sw_off = false
  @sw_on = true
  @text = "Placeholder"
  @search = ""
  @slider = 0.6_f64
  @seg = 1
  @combo = "First"
  @num = 42
  @progress = 0.45_f64
  @sf_installed = false

  # NSSearchField lens — the same placeholder gray as the hint.
  @lens : Egui::Svg = Egui::Icon.from_file(:lucide, :search, tint: SECONDARY)

  SECONDARY = Egui::Color32.rgb(110, 110, 115)

  def initialize
    super
    @ctx.theme = Egui::MacOsTheme.light
    # SF Pro — the font the native sheets render with.
    if File.exists?("/System/Library/Fonts/SFNS.ttf") &&
       (font = Egui::Driver::CrystalFonts.from_system(
          ["/System/Library/Fonts/SFNS.ttf"]))
      @ctx.fonts = font
    end
  end

  def update(ctx : Egui::Context) : Nil
    # SF Pro for the LIVE backend, swapped in on the first frame:
    # setting ctx.fonts in #initialize is clobbered by Sokol's startup
    # (default system font), and select_fonts BEFORE #run exits the
    # app silently — the documented runtime swap path re-uploads the
    # atlas on the next frame (see driver/sokol.cr#select_fonts).
    unless @sf_installed
      @sf_installed = true
      if File.exists?("/System/Library/Fonts/SFNS.ttf") &&
         (font = Egui::Driver::Sokol.fonts_from_system(
            ["/System/Library/Fonts/SFNS.ttf"]))
        Egui::Driver::Sokol.select_fonts(font)
      end
    end

    ctx.central_panel(fill: Egui::Color32.rgb(236, 236, 236)) do |ui|
      # No nested egui window: the app's own OS window carries the
      # title, the content lays out straight in the panel like the
      # native gallery (margin 16: the panel's 8pt padding + 8 here;
      # captions at x=12 → the 2pt left indent).
      ui.allocate_space(Egui::Vec2.new(2.0, 8.0))

      section(ui, "button") do |row|
        second_column(row, row.button("Button"))
        Egui::MacOsTheme.default_button(row, "OK")
      end

      section(ui, "checkbox") do |row|
        second_column(row,
          row.checkbox(@unchecked, "Check") { |v| @unchecked = v })
        row.checkbox(@checked, "Selected") { |v| @checked = v }
      end

      section(ui, "radio") do |row|
        first = row.radio(@radio == 0, "First")
        first.clicked? && (@radio = 0)
        second_column(row, first)
        row.radio(@radio == 1, "Second").clicked? && (@radio = 1)
      end

      section(ui, "switch") do |row|
        second_column(row, row.add(Egui::ToggleButton.new(@sw_off)))
        row.add(Egui::ToggleButton.new(@sw_on))
      end

      section(ui, "text_field") do |row|
        row.text_edit_singleline(@text, width: 200.0) { |t| @text = t }
      end

      section(ui, "search_field") do |row|
        # "search" scope → styles under "search.text_edit": the macOS
        # search field is a full capsule (9999px-style rounding),
        # unlike the 6pt text field above.
        row.with_style_scope("search") do |s|
          s.text_edit_singleline(@search, hint: "Search",
            width: 222.0, leading_icon: @lens) { |t| @search = t }
        end
      end

      section(ui, "slider") do |row|
        row.slider(@slider, 0.0..1.0) { |v| @slider = v }
      end

      section(ui, "segmented") do |row|
        row.segmented(@seg, ["One", "Two", "Three"]) { |v| @seg = v }
      end

      section(ui, "popup") do |row|
        row.combo_box("combo", @combo,
          ["First", "Second", "Third"], width: 200.0) { |s| @combo = s }
      end

      section(ui, "progress") do |row|
        row.progress_bar(@progress)
        row.allocate_space(Egui::Vec2.new(56.0, 0.0))
        row.spinner
      end

      section(ui, "stepper") do |row|
        row.number_input(@num) { |v| @num = v }
      end

      section(ui, "label") do |row|
        second_column(row, row.label("Label"))
        row.rich(Egui::RichText.new("Secondary label").color(SECONDARY))
      end
    end
  end

  # Space the second variant out to a FIXED column, like the native
  # gallery's x=250 (+150 from the widget column, whatever the first
  # widget's width). The row layout adds item_spacing on BOTH sides of
  # the spacer, so two of them must come out of the gap.
  private def second_column(row : Egui::Ui, first : Egui::Response) : Nil
    gap = 150.0 - first.rect.width -
          2.0 * row.style.spacing.item_spacing.x
    row.allocate_space(Egui::Vec2.new(gap, 0.0)) if gap > 0
  end

  # One gallery row, compact like the native oracle's live gallery
  # (render.swift#runGallery): the caption sits LEFT of the widgets
  # (native: caption at x=12, widget column at x=100 — an 88pt label
  # gutter), everything on one line, one 40pt pitch per section
  # (34pt seeded row + item_spacing.y).
  private def section(ui : Egui::Ui, name : String,
                      & : Egui::Ui ->) : Nil
    ui.horizontal(false) do |row|
      row.seed_row_height(40.0 - row.style.spacing.item_spacing.y)
      cap = row.rich(Egui::RichText.new(name).color(SECONDARY).size(11.0))
      # Widgets line up in one column across all sections: pad the
      # caption out to the label gutter. The row layout adds
      # item_spacing on BOTH sides of the spacer, so two of them come
      # out of the gutter (scripts/make_macos_oracle_shots.cr does the
      # same for the second sheet column).
      gap = 88.0 - cap.rect.width -
            2.0 * row.style.spacing.item_spacing.x
      row.allocate_space(Egui::Vec2.new(gap, 0.0)) if gap > 0
      yield row
    end
  end
end

# Executed directly → run the windowed app; required from a probe →
# just define the class (headless screenshots reuse it).
if PROGRAM_NAME.ends_with?("macos_gallery")
  Egui.run(MacOsGalleryApp.new, title: "macOS Widget Gallery (egui.cr)",
    inspector: :hidden)
end
