# TextArea follows the standard text-widget style cascade: `text_color`
# (and the other textlike keys) arrive through class rules, per-element
# overrides and inline WidgetStyles — applied over the effective Style
# BEFORE anything reads it, so the painted buffer, the caret and the
# hint all follow the tint (they all paint from `visuals.text_color`).

require "spec"
require "../src/egui"
require "../src/egui/html"

TA_STYLE_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 300.0))

def ta_style_frame(ctx : Egui::Context, &app : Egui::Context ->)
  raw = Egui::RawInput.new(TA_STYLE_SCREEN, [] of Egui::Event, 0.016)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

def ta_style_text_color(ctx : Egui::Context, needle : String) : Egui::Color32?
  ctx.painter.commands.select(Egui::TextCmd)
    .find { |t| t.text.includes?(needle) }.try(&.color)
end

describe "textarea style cascade" do
  it "a class rule tints the buffer text" do
    ctx = Egui::Context.new
    green = Egui::Color32.rgb(126, 231, 135)
    ctx.stylesheet.rule("textarea", Egui::StyleVars{"text_color" => green})
    ta_style_frame(ctx) do |c|
      c.central_panel { |ui| ui.textarea("color me", rows: 2) { |t| } }
    end
    ta_style_text_color(ctx, "color me").should eq green
  end

  it "a scoped rule (classes: wrapper) reaches the textarea" do
    ctx = Egui::Context.new
    blue = Egui::Color32.rgb(90, 142, 224)
    ctx.stylesheet.rule("ta.textarea", Egui::StyleVars{"text_color" => blue})
    ta_style_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.div(classes: "ta") { |d| d.textarea("scoped", rows: 2) { |t| } }
      end
    end
    ta_style_text_color(ctx, "scoped").should eq blue
  end

  it "an inline WidgetStyle text_color wins without any rule" do
    ctx = Egui::Context.new
    red = Egui::Color32.rgb(255, 64, 64)
    ta_style_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.add(Egui::TextArea.new("inline", nil, 2)
          .style { |s| s.text_color = red })
      end
    end
    ta_style_text_color(ctx, "inline").should eq red
  end

  it "font_family rides the same cascade" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("textarea",
      Egui::StyleVars{"font_family" => "monospace"})
    ta_style_frame(ctx) do |c|
      c.central_panel { |ui| ui.textarea("fam", rows: 2) { |t| } }
    end
    cmd = ctx.painter.commands.select(Egui::TextCmd)
      .find { |t| t.text.includes?("fam") }.should_not be_nil
    cmd.family.should eq "monospace"
  end
end
