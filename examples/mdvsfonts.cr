# Side-by-side font-path probe, one window:
#   1. the real NotoSans-SemiBold file through the fontbrowser path
#      (a deferred system-file stack routed via ctx.style.font_family),
#   2. the markdown widget's h1 (bold run → the primary stack's REAL
#      bold variant, 2em over the 16px body = 32px),
#   3. Regular 32px for contrast,
#   4. *italic* through the real Italic file.
# Rows 1 and 2 must be metric twins: same letter pitches, same edges.

require "../src/egui/backend_selector"

REPO_ROOT = File.expand_path(File.join(__DIR__, ".."))
TEXT = "egui.cr — Crossplatform UI in pure Crystal"

# The markdown-demo font setup: Regular primary + real variant faces.
fonts_dir = File.join(REPO_ROOT, "assets", "fonts")
noto = Egui::Backend::Sokol.fonts_from_system(
  [File.join(fonts_dir, "NotoSans-Regular.ttf")])
semibold = Egui::Backend::Sokol.fonts_from_system(
  [File.join(fonts_dir, "NotoSans-SemiBold.ttf")])
italic = Egui::Backend::Sokol.fonts_from_system(
  [File.join(fonts_dir, "NotoSans-Italic.ttf")])
if noto && semibold
  Egui::Backend::Sokol.select_fonts(noto, bold: semibold, italic: italic)
else
  STDERR.puts "mdvsfonts: assets fonts missing (#{noto ? "semibold" : "regular"})"
end

# The fontbrowser path: the SYSTEM file behind a deferred stack name.
SYS_SEMI = Dir["/usr/share/fonts/truetype/noto/NotoSans-SemiBold.ttf"].first?
if (sys_semi = SYS_SEMI)
  Egui::Backend::Sokol.register_deferred_font("spec600", [sys_semi])
else
  STDERR.puts "mdvsfonts: no system NotoSans-SemiBold.ttf"
end

class MdVsFontsApp < Egui::App
  def update(ctx : Egui::Context) : Nil
    ctx.central_panel do |ui|
      # 1. fontbrowser path — real SemiBold 600 at 32px.
      if SYS_SEMI
        ctx.style.font_family = "spec600"
        ui.rich(Egui::RichText.new(TEXT).size(32.0))
        ctx.style.font_family = nil
      else
        ui.rich(Egui::RichText.new(TEXT).size(32.0))
      end
      ui.separator
      # 2. the markdown widget's h1 — bold run, primary bold variant.
      ui.add(Egui::Markdown.new("# #{TEXT}"))
      ui.separator
      # 3. Regular 32px through the primary stack.
      ui.rich(Egui::RichText.new(TEXT).size(32.0))
      ui.separator
      # 4. italic run — the real Italic face.
      ui.rich(Egui::RichText.new(TEXT).size(32.0).italic)
    end
  end
end

app = MdVsFontsApp.new
app.theme = Egui::Theme.light
Egui.run(app, title: "egui-cr — md vs fonts",
  width: 900, height: 420, inspector: :hidden)
