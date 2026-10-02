require "spec"
require "../src/egui"

WEIGHT_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(900.0, 700.0))

def weight_frame(ctx : Egui::Context, &app : Egui::Context ->)
  raw = Egui::RawInput.new(WEIGHT_SCREEN, [] of Egui::Event, 0.016)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

def text_cmd(ctx : Egui::Context, needle : String) : Egui::TextCmd?
  ctx.painter.commands.select(Egui::TextCmd)
    .find { |t| t.text.includes?(needle) }
end

describe "CSS font_weight" do
  it "defaults to 400 — no bold without a rule, .bold still bold" do
    ctx = Egui::Context.new
    weight_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.label("Plain")
        ui.rich(Egui::RichText.new("Bold").bold)
      end
    end
    text_cmd(ctx, "Plain").not_nil!.bold?.should be_false
    text_cmd(ctx, "Bold").not_nil!.bold?.should be_true
  end

  it "a label class rule >= 600 bolds the text" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("label", Egui::StyleVars{"font_weight" => 700.0})
    weight_frame(ctx) do |c|
      c.central_panel { |ui| ui.label("Heavy") }
    end
    text_cmd(ctx, "Heavy").not_nil!.bold?.should be_true
  end

  it "a rule < 600 stays normal (500), and unbolds a .bold label (400)" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("label", Egui::StyleVars{"font_weight" => 500.0})
    weight_frame(ctx) { |c| c.central_panel { |ui| ui.label("Mid") } }
    text_cmd(ctx, "Mid").not_nil!.bold?.should be_false

    ctx2 = Egui::Context.new
    ctx2.stylesheet.rule("label", Egui::StyleVars{"font_weight" => 400.0})
    weight_frame(ctx2) do |c|
      c.central_panel { |ui| ui.rich(Egui::RichText.new("Unbold").bold) }
    end
    text_cmd(ctx2, "Unbold").not_nil!.bold?.should be_false
  end

  it "a per-element override bolds one label (>= 600 beats markup too)" do
    ctx = Egui::Context.new
    id = nil
    weight_frame(ctx) { |c| c.central_panel { |ui| id = ui.label("Solo").id } }
    ctx.set_id_style(id.not_nil!, "font_weight", 800.0)
    weight_frame(ctx) { |c| c.central_panel { |ui| ui.label("Solo") } }
    text_cmd(ctx, "Solo").not_nil!.bold?.should be_true
  end

  it "bolds a RichLabel through a per-element override (markup base too)" do
    ctx = Egui::Context.new
    id = nil
    weight_frame(ctx) do |c|
      c.central_panel { |ui| id = ui.add(Egui::RichLabel.new("RL text", id: "rlw")).id }
    end
    ctx.set_id_style(id.not_nil!, "font_weight", 700.0)
    weight_frame(ctx) do |c|
      c.central_panel { |ui| ui.add(Egui::RichLabel.new("RL text", id: "rlw")) }
    end
    text_cmd(ctx, "RL text").not_nil!.bold?.should be_true
  end

  it "bolds button/checkbox text via class rules or element overrides" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("button", Egui::StyleVars{"font_weight" => 700.0})
    weight_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.button("BtnW", id: "bw")
        ui.checkbox(false, "CbW", id: "cw")
      end
    end
    text_cmd(ctx, "BtnW").not_nil!.bold?.should be_true

    ctx2 = Egui::Context.new
    cid = nil
    weight_frame(ctx2) do |c|
      c.central_panel { |ui| cid = ui.checkbox(false, "CbSolo", id: "cs").id }
    end
    ctx2.set_id_style(cid.not_nil!, "font_weight", 700.0)
    weight_frame(ctx2) { |c| c.central_panel { |ui| ui.checkbox(false, "CbSolo", id: "cs") } }
    text_cmd(ctx2, "CbSolo").not_nil!.bold?.should be_true
  end

  it "clamps the weight to the 100..900 ladder in apply_over" do
    base = Egui::Style.new
    hi = Egui::StyleVars{"font_weight" => 5000.0}.apply_over(base)
    hi.font_weight.should eq(900.0)
    hi.font_weight_bold?.should be_true
    lo = Egui::StyleVars{"font_weight" => -50.0}.apply_over(base)
    lo.font_weight.should eq(100.0)
    lo.font_weight_bold?.should be_false
  end

  it "declares the font_weight property as a :weight select" do
    prop = Egui::StyleProps.textlike.find { |p| p.key == "font_weight" }.not_nil!
    prop.kind.should eq(:weight)
    Egui::Style.new.tap(&.font_weight = 400.0).font_weight_bold?.should be_false
  end
end
