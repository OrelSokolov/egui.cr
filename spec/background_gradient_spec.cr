# The stylable gradient background: `background` is the top stop,
# `background2` (per state, like `background`) the bottom one — the
# inspector's editable parameters for a gradient fill. A built-in
# `Button#gradient(c1, c2)` seeds both stops' display fallbacks and
# yields per stop to explicit cascade values.
require "spec"
require "../src/egui"

GRAD_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

def grad_frame(ctx : Egui::Context, &app : Egui::Context ->)
  raw = Egui::RawInput.new(GRAD_SCREEN, [] of Egui::Event, 0.016)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

def grad_rect(ctx : Egui::Context, fill : Egui::Color32,
              fill2 : Egui::Color32?) : Egui::RectCmd?
  ctx.painter.commands.select(Egui::RectCmd)
    .find { |c| c.fill == fill && c.fill2 == fill2 }
end

describe "gradient background (background2)" do
  it "declares background2, seeded from a built-in #gradient" do
    top = Egui::Color32.rgb(60, 150, 90)
    bot = Egui::Color32.rgb(24, 80, 48)
    props = Egui::Button.new("G").gradient(top, bot).style_properties
    props.find { |p| p.key == "background2" }.not_nil!
      .fallback.as?(Egui::Color32).should eq bot
    props.find { |p| p.key == "background" }.not_nil!
      .fallback.as?(Egui::Color32).should eq top
    # …while a plain button's stops have no fallback (unset reads as
    # the theme slot / gray, the standard unset convention).
    plain = Egui::Button.new("P").style_properties
    plain.find { |p| p.key == "background2" }.not_nil!.fallback.should be_nil
  end

  it "paints background → background2 from a class rule" do
    ctx = Egui::Context.new
    top = Egui::Color32.rgb(10, 20, 30)
    bot = Egui::Color32.rgb(40, 50, 60)
    ctx.stylesheet.rule("button", Egui::StyleVars{
      "background"  => top,
      "background2" => bot,
    })
    grad_frame(ctx) do |c|
      c.window("w") { |ui| ui.add(Egui::Button.new("OK", id: "save")) }
    end
    grad_rect(ctx, top, bot).should_not be_nil
  end

  it "a per-element override supplies the second stop" do
    ctx = Egui::Context.new
    top = Egui::Color32.rgb(1, 2, 3)
    bot = Egui::Color32.rgb(4, 5, 6)
    ctx.set_id_style(Egui::Id.from("save"), "background2", bot)
    grad_frame(ctx) do |c|
      c.window("w") { |ui| ui.add(Egui::Button.new("OK", id: "save").style do |s|
        s.background = top
      end) }
    end
    grad_rect(ctx, top, bot).should_not be_nil
  end

  it "an explicit background recolors only the top stop of a built-in #gradient" do
    ctx = Egui::Context.new
    gtop = Egui::Color32.rgb(60, 150, 90)
    gbot = Egui::Color32.rgb(24, 80, 48)
    red = Egui::Color32.rgb(255, 0, 0)
    ctx.stylesheet.rule("button", Egui::StyleVars{"background" => red})
    grad_frame(ctx) do |c|
      c.window("w") { |ui| ui.add(Egui::Button.new("G").gradient(gtop, gbot)) }
    end
    # the class rule wins the top, the built-in bottom survives
    grad_rect(ctx, red, gbot).should_not be_nil
    grad_rect(ctx, gtop, gbot).should be_nil
  end
end
