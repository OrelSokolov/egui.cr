# Font rendering preview: the full Latin and Cyrillic alphabets, digits and
# punctuation at a range of sizes — the visual test bed for the Crystal
# text stack. Three live-switchable backends (tabs at the top): FreeType
# (the C library, real hinting), the Crystal port of it (rasterizer +
# TrueType bytecode hinter, no libfreetype — see backend/crystalfonts.cr)
# and the Crystal light-hint fallback — see
# src/egui/backend/{freetype,crystalfonts,text}.cr. Look for: solid
# crossbars (e, A, Б), consistent baselines, even spacing, stem weight
# parity between the tabs.

require "../src/egui"
require "../src/egui/backend/sokol"
require "../src/egui/backend/crystalfonts"
# The C-FFI tab is part of the A/B toolset — fontpreview links
# libfreetype unconditionally, even in release builds (it is the
# diagnostic app; shipped apps don't).
require "../src/egui/backend/freetype"

class FontPreviewApp < Egui::App
  GROUPS = {
    "Latin upper"    => "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    "Latin lower"    => "abcdefghijklmnopqrstuvwxyz",
    "Cyrillic upper" => "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ",
    "Cyrillic lower" => "абвгдеёжзийклмнопрстуфхцчшщъыьэюя",
    "Digits"         => "0123456789",
    "Punctuation"    => ".,:;!?—–-()[]{}«»\"'…",
  }

  SIZES = [12.0, 14.0, 16.0, 20.0, 24.0, 32.0]

  @tab = 0
  @freetype : Egui::Backend::AtlasFonts?
  @crystal : Egui::Backend::AtlasFonts?
  @light : Egui::Backend::AtlasFonts?

  CONTROL = "/tmp/fontpreview.tab"

  def initialize
    super()
  end

  def update(ctx : Egui::Context) : Nil
    # All three backends loaded once, then toggled live via Sokol.select_fonts:
    # each has its own atlas; the pipeline rebinds on the next frame.
    @freetype ||= Egui::Backend::FreetypeFonts.from_system(
      Egui::SystemPorts::Fonts.search_paths)
    @crystal ||= Egui::Backend::CrystalFonts.from_system(
      Egui::SystemPorts::Fonts.search_paths)
    @light ||= Egui::Backend::LightHintedFonts.from_system(
      Egui::SystemPorts::Fonts.search_paths)

    ctx.window("fontpreview", Egui::Pos2.new(24.0, 24.0), width: 780.0) do |ui|
      ui.horizontal do |row|
        row.selectable(@tab == 0, "FreeType (C)") { |v| @tab = 0 if v }
        row.selectable(@tab == 1, "Crystal port") { |v| @tab = 1 if v }
        row.selectable(@tab == 2, "Crystal light-hint") { |v| @tab = 2 if v }
      end
      heading = case @tab
                when 0 then "Font preview — FreeType"
                when 1 then "Font preview — Crystal FreeType port"
                else        "Font preview — light hint"
                end
      ui.heading(heading)

      # Automation hook: the sapp C loop pumps frames but never yields
      # to the Crystal scheduler, so Signal traps can't run — poll a
      # control file instead (echo 0|1|2 > /tmp/fontpreview.tab).
      if File.exists?(CONTROL)
        v = File.read(CONTROL).strip
        @tab = v.to_i if {"0", "1", "2"}.includes?(v)
      end

      font = case @tab
             when 0 then @freetype
             when 1 then @crystal
             else        @light
             end
      if font && font.loaded?
        Egui::Backend::Sokol.select_fonts(font)
      end

      GROUPS.each do |name, alphabet|
        ui.rich(Egui::RichText.new(name).small(ui.style.font_size).weak(ui.style.visuals))
        ui.label(alphabet)
      end

      ui.separator
      ui.rich(Egui::RichText.new("sizes").small(ui.style.font_size).weak(ui.style.visuals))
      SIZES.each do |size|
        ui.rich(Egui::RichText
          .new("AaEeОоБбЕе 0123 — hxeao: #{size.to_i}")
          .size(size))
      end
    end
  end
end

Egui::Backend::Sokol.run(FontPreviewApp.new, title: "egui-cr — fontpreview",
  width: 820, height: 720, inspector: :hidden)
