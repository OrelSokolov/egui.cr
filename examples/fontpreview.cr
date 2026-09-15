# Font rendering preview: the full Latin and Cyrillic alphabets, digits and
# punctuation at a range of sizes — the visual test bed for the Crystal
# text stack (light Y-hint, see src/egui/backend/text.cr). Look for:
# solid crossbars (e, A, Б), consistent baselines across adjacent glyphs,
# even letter spacing, no clipped or missing glyphs.

require "../src/egui"
require "../src/egui/backend/sokol"

class FontPreviewApp < Egui::App
  GROUPS = {
    "Latin upper"  => "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    "Latin lower"  => "abcdefghijklmnopqrstuvwxyz",
    "Cyrillic upper" => "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ",
    "Cyrillic lower" => "абвгдеёжзийклмнопрстуфхцчшщъыьэюя",
    "Digits"       => "0123456789",
    "Punctuation"  => ".,:;!?—–-()[]{}«»\"'…",
  }

  SIZES = [12.0, 14.0, 16.0, 20.0, 24.0, 32.0]

  def update(ctx : Egui::Context) : Nil
    ctx.window("fontpreview", Egui::Pos2.new(24.0, 24.0), width: 780.0) do |ui|
      ui.heading("Font preview — light hint")

      GROUPS.each do |name, alphabet|
        ui.rich(Egui::RichText.new(name).small(ui.style.font_size).weak(ui.style.visuals))
        ui.label(alphabet)
      end

      ui.separator
      ui.rich(Egui::RichText.new("sizes").small(ui.style.font_size).weak(ui.style.visuals))
      SIZES.each do |size|
        ui.rich(Egui::RichText
          .new("AaEeОоБб 0123 — hxeao: 16")
          .size(size))
      end
    end
  end
end

Egui::Backend::Sokol.run(FontPreviewApp.new, title: "egui-cr — fontpreview",
  width: 820, height: 720)
