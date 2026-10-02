require "spec"
require "../src/egui"

FONTSIZE_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(900.0, 700.0))

def fsize_frame(ctx : Egui::Context, &app : Egui::Context ->)
  raw = Egui::RawInput.new(FONTSIZE_SCREEN, [] of Egui::Event, 0.016)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

def first_text_size(ctx : Egui::Context, needle : String) : Float64?
  cmd = ctx.painter.commands.select(Egui::TextCmd)
    .find { |t| t.text.includes?(needle) }
  cmd.try(&.size)
end

describe "label font_size cascade" do
  it "a per-element override beats the RichText's explicit size" do
    ctx = Egui::Context.new
    id = nil
    fsize_frame(ctx) do |c|
      c.central_panel { |ui| id = ui.heading("Head").id }
    end
    # heading bakes 1.25× the base size into the RichText — the
    # override used to be a silent no-op against it.
    base = first_text_size(ctx, "Head").should_not be_nil
    ctx.set_id_style(id.not_nil!, "font_size", 30.0)
    fsize_frame(ctx) do |c|
      c.central_panel { |ui| ui.heading("Head") }
    end
    first_text_size(ctx, "Head").should eq(30.0)
  end

  it "a class rule beats the RichText's explicit size" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("label", Egui::StyleVars{"font_size" => 20.0})
    fsize_frame(ctx) do |c|
      c.central_panel { |ui| ui.add(Egui::Label.new("Sized", id: "sz").style { |s| s.font_size = 40.0 }) }
    end
    # class_vars carry the rule → 20.0 wins over the RichText size
    first_text_size(ctx, "Sized").should eq(20.0)
  end

  it "without a cascade value the RichText size still wins (upstream behavior)" do
    ctx = Egui::Context.new
    fsize_frame(ctx) do |c|
      c.central_panel { |ui| ui.heading("Plain") }
    end
    size = first_text_size(ctx, "Plain").not_nil!
    # 1.25× the default 16 — NOT the raw theme 16
    size.should be_close(20.0, 0.01)
  end

  it "a RichLabel's explicit size yields to a per-element override" do
    ctx = Egui::Context.new
    rich = Egui::RichText.new("RL").size(28.0)
    id = nil
    fsize_frame(ctx) do |c|
      c.central_panel { |ui| id = ui.add(Egui::RichLabel.new(rich, id: "rl")).id }
    end
    first_text_size(ctx, "RL").should eq(28.0)
    ctx.set_id_style(id.not_nil!, "font_size", 12.0)
    fsize_frame(ctx) do |c|
      c.central_panel { |ui| ui.add(Egui::RichLabel.new(rich, id: "rl")) }
    end
    first_text_size(ctx, "RL").should eq(12.0)
  end

  it "floors a negative font_size at 0 wherever it enters the cascade" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("label", Egui::StyleVars{"font_size" => -8.0})
    fsize_frame(ctx) do |c|
      c.central_panel { |ui| ui.label("Neg") }
    end
    first_text_size(ctx, "Neg").should eq(0.0)
  end

  it "declares min bounds on non-negative number properties" do
    textlike = Egui::StyleProps.textlike
    fs = textlike.find { |p| p.key == "font_size" }.not_nil!
    fs.min.should eq(0.0)
    button = Egui::Button.new("x").style_properties
    button.find { |p| p.key == "rounding" }.not_nil!.min.should eq(0.0)
    button.find { |p| p.key == "shadow.blur" }.not_nil!.min.should eq(0.0)
    # Offsets stay unclamped — negative x/y is legitimate CSS.
    button.find { |p| p.key == "shadow.x" }.not_nil!.min.should be_nil
  end
end
