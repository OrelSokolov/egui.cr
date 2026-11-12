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
      ctx.window("macOS Widget Gallery (egui.cr)",
        Egui::Pos2.new(40.0, 40.0), width: 520.0) do |win|
        section(win, "button") do |row|
          row.button("Button")
          row.allocate_space(Egui::Vec2.new(28.0, 0.0))
          Egui::MacOsTheme.default_button(row, "OK")
        end

        section(win, "checkbox") do |row|
          row.checkbox(@unchecked, "Check") { |v| @unchecked = v }
          row.allocate_space(Egui::Vec2.new(28.0, 0.0))
          row.checkbox(@checked, "Selected") { |v| @checked = v }
        end

        section(win, "radio") do |row|
          row.radio(@radio == 0, "First").clicked? && (@radio = 0)
          row.allocate_space(Egui::Vec2.new(28.0, 0.0))
          row.radio(@radio == 1, "Second").clicked? && (@radio = 1)
        end

        section(win, "switch") do |row|
row.add(Egui::ToggleButton.new(@sw_off))
          row.allocate_space(Egui::Vec2.new(28.0, 0.0))
          row.add(Egui::ToggleButton.new(@sw_on))
        end

        section(win, "text_field") do |row|
          row.text_edit_singleline(@text, width: 200.0) { |t| @text = t }
        end

        section(win, "search_field") do |row|
          # "search" scope → styles under "search.text_edit": the macOS
          # search field is a full capsule (9999px-style rounding),
          # unlike the 6pt text field above.
          row.with_style_scope("search") do |s|
            s.text_edit_singleline(@search, hint: "Search",
              width: 222.0, leading_icon: @lens) { |t| @search = t }
          end
        end

        section(win, "slider") do |row|
          row.slider(@slider, 0.0..1.0) { |v| @slider = v }
        end

        section(win, "segmented") do |row|
          row.segmented(@seg, ["One", "Two", "Three"]) { |v| @seg = v }
        end

        section(win, "popup") do |row|
          row.combo_box("combo", @combo,
            ["First", "Second", "Third"], width: 200.0) { |s| @combo = s }
        end

        section(win, "progress") do |row|
          row.progress_bar(@progress)
          row.allocate_space(Egui::Vec2.new(56.0, 0.0))
          row.spinner
        end

        section(win, "stepper") do |row|
          row.number_input(@num) { |v| @num = v }
        end

        section(win, "label") do |row|
          row.label("Label")
          row.allocate_space(Egui::Vec2.new(28.0, 0.0))
          row.rich(Egui::RichText.new("Secondary label").color(SECONDARY))
        end
      end
    end
  end

  # One sheet row: a small secondary caption + the widgets from the
  # matching native sheet (oracle/macos/png/<name>.png).
  private def section(ui : Egui::Ui, name : String,
                      &block : Egui::Ui ->) : Nil
    ui.rich(Egui::RichText.new(name).color(SECONDARY).size(11.0))
    ui.allocate_space(Egui::Vec2.new(0.0, 2.0))
    ui.horizontal(false, &block)
    ui.allocate_space(Egui::Vec2.new(0.0, 8.0))
  end
end

# Executed directly → run the windowed app; required from a probe →
# just define the class (headless screenshots reuse it).
if PROGRAM_NAME.ends_with?("macos_gallery")
  Egui.run(MacOsGalleryApp.new, title: "egui-cr — macOS gallery",
    inspector: :hidden)
end
