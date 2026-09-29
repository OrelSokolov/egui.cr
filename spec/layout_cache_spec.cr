# Fonts#layout cross-frame cache: the galley bakes run color and
# underline into its rows, so those must ride the cache KEY — a
# differently-styled layout of the same text must not hit a stale
# entry. Regression: after a theme swap, labels kept the previous
# theme's text color until the cache entry got evicted.

require "spec"
require "../src/egui"

LAYOUT_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(800.0, 600.0))

def layout_frame(ctx : Egui::Context, time : Float64, theme : Egui::Theme,
                  &content : Egui::Ui ->) : Array(Egui::TextCmd)
  raw = Egui::RawInput.new(LAYOUT_SCREEN, [] of Egui::Event, time)
  ctx.begin_frame(raw)
  ctx.theme = theme
  ctx.central_panel { |ui| content.call(ui) }
  ctx.end_frame
  ctx.painter.commands.select(Egui::TextCmd)
end

describe Egui::Fonts do
  it "re-layouts (does not cache-hit) when the run color changes with the theme" do
    ctx = Egui::Context.new
    t = 0.0
    text_cmd = ->(theme : Egui::Theme) do
      cmds = layout_frame(ctx, t += 0.016, theme) { |ui| ui.label("hello") }
      cmds.first.not_nil!
    end

    text_cmd.call(Egui::Theme.dark).color
      .should eq(Egui::Theme.dark.style.visuals.text_color)
    # The very frame after the swap the label must already paint the
    # new theme's color, not the cached dark one.
    text_cmd.call(Egui::Theme.light).color
      .should eq(Egui::Theme.light.style.visuals.text_color)
    text_cmd.call(Egui::Theme.dark).color
      .should eq(Egui::Theme.dark.style.visuals.text_color)
  end

  it "keeps distinct colors apart for the same text, size and width" do
    ctx = Egui::Context.new
    red = Egui::Color32.rgb(255, 0, 0)
    blue = Egui::Color32.rgb(0, 0, 255)
    cmds = layout_frame(ctx, 0.016, Egui::Theme.dark) do |ui|
      ui.add(Egui::Label.new(Egui::RichText.new("same").color(red)))
      ui.add(Egui::Label.new(Egui::RichText.new("same").color(blue)))
    end
    cmds.map(&.color).should eq([red, blue])
  end
end
