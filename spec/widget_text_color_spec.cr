# The standard gallery widget set follows the SAME text-cascade as
# Label/TextArea: class rules (`text_color`, `font_*`) must land in the
# widget's effective Style before anything reads it. These tests pin
# the wiring per widget — each of these used to paint from a Style the
# class layer never reached (declared-but-dead `text_color`).

require "spec"
require "../src/egui"

WTC_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(600.0, 400.0))

def wtc_frame(ctx : Egui::Context, &app : Egui::Context ->)
  raw = Egui::RawInput.new(WTC_SCREEN, [] of Egui::Event, 0.016)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

def wtc_text_color(ctx : Egui::Context, needle : String) : Egui::Color32?
  ctx.painter.commands.select(Egui::TextCmd)
    .find { |t| t.text.includes?(needle) }.try(&.color)
end

describe "widget text_color cascade" do
  it "text_edit (input): a class rule tints the field text" do
    ctx = Egui::Context.new
    amber = Egui::Color32.rgb(240, 200, 100)
    ctx.stylesheet.rule("text_edit", Egui::StyleVars{"text_color" => amber})
    wtc_frame(ctx) do |c|
      c.central_panel { |ui| ui.add(Egui::TextEdit.new("edit me")) }
    end
    wtc_text_color(ctx, "edit me").should eq amber
  end

  it "checkbox: a class rule tints the label" do
    ctx = Egui::Context.new
    lime = Egui::Color32.rgb(120, 220, 90)
    ctx.stylesheet.rule("checkbox", Egui::StyleVars{"text_color" => lime})
    wtc_frame(ctx) do |c|
      c.central_panel { |ui| ui.add(Egui::Checkbox.new(true, "check me")) }
    end
    wtc_text_color(ctx, "check me").should eq lime
  end

  it "radio: a class rule tints the label (class newly exists)" do
    ctx = Egui::Context.new
    cyan = Egui::Color32.rgb(90, 220, 220)
    ctx.stylesheet.rule("radio", Egui::StyleVars{"text_color" => cyan})
    wtc_frame(ctx) do |c|
      c.central_panel { |ui| ui.add(Egui::RadioButton.new(true, "radio me")) }
    end
    wtc_text_color(ctx, "radio me").should eq cyan
  end

  it "slider: a class rule tints the label line" do
    ctx = Egui::Context.new
    pink = Egui::Color32.rgb(235, 130, 180)
    ctx.stylesheet.rule("slider", Egui::StyleVars{"text_color" => pink})
    wtc_frame(ctx) do |c|
      c.central_panel { |ui| ui.add(Egui::Slider.new(50.0, 0.0..100.0, "Volume")) }
    end
    wtc_text_color(ctx, "Volume").should eq pink
  end

  it "progressbar: a class rule tints the bar text" do
    ctx = Egui::Context.new
    gold = Egui::Color32.rgb(250, 210, 80)
    ctx.stylesheet.rule("progressbar", Egui::StyleVars{"text_color" => gold})
    wtc_frame(ctx) do |c|
      c.central_panel { |ui| ui.add(Egui::ProgressBar.new(0.7, "70%")) }
    end
    wtc_text_color(ctx, "70%").should eq gold
  end

  it "combo: a class rule tints the closed trigger label" do
    ctx = Egui::Context.new
    violet = Egui::Color32.rgb(190, 140, 240)
    ctx.stylesheet.rule("combo", Egui::StyleVars{"text_color" => violet})
    wtc_frame(ctx) do |c|
      c.central_panel do |ui|
        Egui::ComboBox.new("pick", "Two", ["One", "Two", "Three"]).show(ui) { |o| }
      end
    end
    wtc_text_color(ctx, "Two").should eq violet
  end
end
