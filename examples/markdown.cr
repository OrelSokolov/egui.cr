# Markdown widget demo — renders the project's README.md (fallback:
# the built-in demo below when the file is missing). Images are
# supported: standalone `![alt](path)` lines load through the texture
# registry and scale down to the available width; relative paths
# resolve against the repo root. Inline `**bold**`, *italic*, `code`
# and links through RichLabel; fenced code renders as plain
# monospace blocks (no syntax highlighting).

require "../src/egui"
require "../src/egui/backend/sokol"

REPO_ROOT = File.expand_path(File.join(__DIR__, ".."))

# Demo fonts: NotoSans (prose) + LiberationMono (code) shipped in
# assets/fonts (both SIL OFL). NotoSans becomes the PRIMARY stack with
# REAL bold/italic variant faces (headings, **bold**, *italic* draw and
# measure through the actual 600/oblique files — never an emulation);
# LiberationMono the "monospace" family. Missing files degrade silently
# to the faces that did load (a variant without its file falls back to
# the regular face).
def pick_fonts : Nil
  fonts_dir = File.join(REPO_ROOT, "assets", "fonts")

  noto = Egui::Backend::Sokol.fonts_from_system([
    File.join(fonts_dir, "NotoSans-Regular.ttf"),
  ])
  if noto
    bold = Egui::Backend::Sokol.fonts_from_system(
      [File.join(fonts_dir, "NotoSans-SemiBold.ttf")])
    italic = Egui::Backend::Sokol.fonts_from_system(
      [File.join(fonts_dir, "NotoSans-Italic.ttf")])
    bold_italic = Egui::Backend::Sokol.fonts_from_system(
      [File.join(fonts_dir, "NotoSans-SemiBoldItalic.ttf")])
    Egui::Backend::Sokol.select_fonts(noto,
      bold: bold, italic: italic, bold_italic: bold_italic)
  else
    STDERR.puts "markdown demo: NotoSans-Regular.ttf not found — system font"
  end

  mono_candidates = [
    File.join(fonts_dir, "LiberationMono-Regular.ttf"),
    "JetBrainsMonoNerdFontMono-Regular.ttf",
    "JetBrainsMono-Regular.ttf",
  ]
  {% if flag?(:win32) %}
    mono_candidates += ["C:\\Windows\\Fonts\\consola.ttf",
                        "C:\\Windows\\Fonts\\lucon.ttf"]
  {% else %}
    mono_candidates += [
      "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
      "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
      "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
      "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
      "/usr/share/fonts/truetype/ubuntu/UbuntuMono-R.ttf",
      "/System/Library/Fonts/SFNSMono.ttf",
    ]
  {% end %}
  mono = Egui::Backend::Sokol.fonts_from_system(mono_candidates)
  Egui::Backend::Sokol.register_font("monospace", mono) if mono
end

pick_fonts

FALLBACK = <<-'MD'
  # Markdown demo

  The README.md was not found next to the example — showing the
  built-in fallback with **bold**, *italic*, `code` and an image.

  ![widget gallery](screenshots/widgets-dark.png)

  > Quoted text renders weak with an accent bar.

  ---

  ```crystal
  puts "that's all"
  ```
MD

class MarkdownApp < Egui::App
  @source : String?

  def update(ctx : Egui::Context) : Nil
    ctx.routes do |r|
      r.page "root/root" do
        ctx.central_panel do |ui|
          Egui::ScrollArea.new.show(ui) do |scroll|
            scroll.markdown(@source || read_source, base_dir: REPO_ROOT)
          end
        end
      end
    end
  end

  # Read once, lazily (the first frame, not at startup — a missing
  # file must not kill the app before the window opens).
  private def read_source : String
    @source ||= begin
      readme = File.join(REPO_ROOT, "README.md")
      File.exists?(readme) ? File.read(readme) : FALLBACK
    end
  end
end

app = MarkdownApp.new
app.theme = Egui::Theme.light # a markdown reader reads best light
Egui::Backend::Sokol.run(app, title: "egui-cr — markdown",
  inspector: :hidden)
