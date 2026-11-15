# Theme widget gallery — macOS / GNOME / KDE in one binary. The merge
# of the former macos_gallery / gnome_gallery / kde_gallery examples:
# the SAME interactive widget rows, the profile picks the platform:
#
#   crystal run examples/theme_gallery.cr -- gnome   # or kde / macos
#   rake build:dev[theme_gallery] && bin/clones/theme_gallery kde
#
# Everything is styled by the platform themes (src/egui/
# {macos,gnome,kde}_theme.cr) — each measured against its native
# oracle (oracle/macos, oracle/gtk, oracle/qt; see oracle/FINDINGS.md).
# The switcher row re-applies theme + fonts LIVE: state (checkboxes,
# slider…) survives the switch, so the same row can be compared under
# all three themes without restarting.
#
#   macos — Egui::MacOsTheme.light, SF Pro when present, the twin of
#           the native AppKit sheets (oracle/macos/png)
#   gnome — Egui::GnomeTheme.light, the Adwaita light palette
#           (#FAFAFB windows, #3584E4 accent, Cantarell 11pt)
#   kde   — Egui::KdeTheme.light, the Breeze light palette (#FCFCFC
#           windows, #3DAEE9 accent, #EFF0F1 bezels, Noto Sans 10pt)
#   winxp — Egui::WinXpTheme.light, the Luna look (#ECE9D8 face, navy
#           menu bands, gradient push buttons; Tahoma when present)

require "../src/egui/driver_selector"
require "../src/egui/driver/crystalfonts"

class ThemeGalleryApp < Egui::App
  PROFILES = {"macos", "gnome", "kde", "winxp"}

  # System font of each platform; the lists cover the distro layout
  # variants (Debian/Arch/Fedora; GNOME also vendors a static
  # TrueType instance for the oracle — the font port reads glyf only,
  # see oracle/FINDINGS.md). Missing files fall back to the default.
  FONT_PATHS = {
    "macos" => ["/System/Library/Fonts/SFNS.ttf"],
    "gnome" => [
      "oracle/gtk/fonts/truetype/Cantarell-Regular.ttf",
      "/usr/share/fonts/cantarell/Cantarell-Regular.ttf",
      "/usr/share/fonts/cantarell/Cantarell-VF.otf",
      "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
    ],
    "kde" => [
      "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
      "/usr/share/fonts/noto/NotoSans-Regular.ttf",
      "/usr/share/fonts/google-noto/NotoSans-Regular.ttf",
    ],
    # XP's Tahoma — usually absent on Linux (msttcorefonts), the
    # default font is the honest fallback.
    "winxp" => [
      "/usr/share/fonts/truetype/msttcorefonts/tahoma.ttf",
      "/usr/share/fonts/tahoma/tahoma.ttf",
      "/usr/share/fonts/truetype/corefonts/tahoma.ttf",
    ],
  }

  SECONDARY = {
    "macos" => Egui::Color32.rgb(110, 110, 115),
    "gnome" => Egui::Color32.rgb(125, 125, 126),
    "kde"   => Egui::Color32.rgb(127, 140, 141),
    "winxp" => Egui::Color32.rgb(108, 106, 100),
  }

  PANEL_FILL = {
    "macos" => Egui::Color32.rgb(236, 236, 236),
    "gnome" => Egui::Color32.rgb(250, 250, 251),
    "kde"   => Egui::Color32.rgb(239, 240, 241),
    "winxp" => Egui::Color32.rgb(236, 233, 216),
  }

  CAPTION_SIZE = {"macos" => 11.0, "gnome" => 11.0, "kde" => 10.0,
                  "winxp" => 11.0}

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

  @profile = "macos"
  # Profile applied to ctx (theme + fonts)? Re-run on a live switch.
  @styled : String? = nil
  # The LIVE (Sokol) font swap done? Re-run on a live switch.
  @live_fonts : String? = nil

  # Search-field lens — tinted with the ACTIVE profile's secondary
  # gray; rebuilt on switch (Icon.from_file is a compile-time macro,
  # the tint is a runtime argument).
  @lens : Egui::Svg? = nil

  def initialize(profile : String? = nil)
    super()
    @profile = PROFILES.includes?(profile) ? profile.not_nil! : "macos"
    style_for_profile(@ctx)
  end

  def update(ctx : Egui::Context) : Nil
    # Live profile switch: theme + ctx.fonts first…
    style_for_profile(ctx) unless @styled == @profile
    # …then the LIVE backend font. Setting ctx.fonts in #initialize is
    # clobbered by Sokol's startup (default system font), and
    # select_fonts BEFORE #run exits the app silently — the documented
    # runtime swap path re-uploads the atlas on the next frame (see
    # driver/sokol.cr#select_fonts).
    if @live_fonts != @profile
      @live_fonts = @profile
      paths = FONT_PATHS[@profile]
      if paths.any? { |p| File.exists?(p) } &&
         (font = Egui::Driver::Sokol.fonts_from_system(paths))
        Egui::Driver::Sokol.select_fonts(font)
      end
    end

    ctx.central_panel(fill: PANEL_FILL[@profile]) do |ui|
      # Profile switcher — re-applies theme + fonts live, state stays.
      ui.horizontal do |row|
        PROFILES.each do |key|
          row.selectable(@profile == key, key.capitalize) { |v|
            @profile = key if v
          }
        end
      end

      ctx.window("#{@profile.capitalize} Widget Gallery (egui.cr)",
        Egui::Pos2.new(40.0, 40.0), width: 520.0) do |win|
        section(win, "button") do |row|
          row.button("Button")
          row.allocate_space(Egui::Vec2.new(28.0, 0.0))
          case @profile
          when "macos" then Egui::MacOsTheme.default_button(row, "OK")
          when "gnome" then Egui::GnomeTheme.suggested_button(row, "OK")
          when "winxp" then row.button("OK")
          else              row.button("Default")
          end
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
          # "search" scope keeps the entry look; the lens icon is what
          # marks a search field in all three platforms (macOS rounds
          # the entry into a full capsule on top of it).
          row.with_style_scope("search") do |s|
            s.text_edit_singleline(@search, hint: "Search",
              width: 222.0, leading_icon: (@lens ||= Egui::Icon.from_file(
                :lucide, :search, tint: SECONDARY[@profile]))) { |t| @search = t }
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
          row.rich(Egui::RichText.new("Dim label").color(SECONDARY[@profile]))
        end
      end
    end
  end

  # Theme + ctx.fonts for the active profile (idempotent, re-runs on a
  # live switch). The ctx.fonts half matters for the headless/capybara
  # path; the live Sokol swap is the separate first-frame step above.
  private def style_for_profile(ctx : Egui::Context) : Nil
    @styled = @profile
    @lens = nil # re-tint the lens with the new secondary gray
    case @profile
    when "macos" then ctx.theme = Egui::MacOsTheme.light
    when "gnome" then ctx.theme = Egui::GnomeTheme.light
    when "winxp" then ctx.theme = Egui::WinXpTheme.light
    else              ctx.theme = Egui::KdeTheme.light
    end
    paths = FONT_PATHS[@profile]
    if paths.any? { |p| File.exists?(p) } &&
       (font = Egui::Driver::CrystalFonts.from_system(paths))
      ctx.fonts = font
    end
  end

  # One sheet row: a small dim caption + the widgets from the
  # matching native sheet (oracle/<platform>/png/<name>.png).
  private def section(ui : Egui::Ui, name : String,
                      &block : Egui::Ui ->) : Nil
    ui.rich(Egui::RichText.new(name).color(SECONDARY[@profile])
      .size(CAPTION_SIZE[@profile]))
    ui.allocate_space(Egui::Vec2.new(0.0, 2.0))
    ui.horizontal(false, &block)
    ui.allocate_space(Egui::Vec2.new(0.0, 8.0))
  end
end

# Executed directly → run the windowed app; required from a probe →
# just define the class (headless screenshots reuse it).
if PROGRAM_NAME.ends_with?("theme_gallery")
  Egui.run(ThemeGalleryApp.new(ARGV[0]?),
    title: "egui-cr — theme gallery", inspector: :hidden)
end
