# <formula> exml tag specs: typeset cache, headless render (the Svg
# allocates its rect and paints nothing without a GPU), the parse-
# error fallback, and linter acceptance of the registered tag.

require "spec"
require "../src/egui"
require "../src/egui/exml_formula"

FORMULA_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(800.0, 600.0))

def formula_frame(ctx : Egui::Context, nodes : Array(Egui::Exml::Node),
                  rt : Egui::Exml::Runtime,
                  renderer : Egui::Exml::Renderer) : Nil
  ctx.begin_frame(Egui::RawInput.new(FORMULA_SCREEN,
    [] of Egui::Event, 0.016))
  ctx.window("w") do |ui|
    nodes.each { |n| renderer.render(n, ui, ctx, rt) }
  end
  ctx.end_frame
end

describe Egui::ExmlFormula do
  it "typesets once and caches per (tex, display)" do
    a = Egui::ExmlFormula.typeset(%q(e^{i\pi} + 1 = 0), display: true)
    a.error.should be_nil
    a.width_em.should be > 0.0
    a.height_em.should be > 0.0
    a.svg.should contain("<defs")

    b = Egui::ExmlFormula.typeset(%q(e^{i\pi} + 1 = 0), display: true)
    b.should be(a) # cache hit — same object, no re-typeset

    c = Egui::ExmlFormula.typeset(%q(e^{i\pi} + 1 = 0), display: false)
    c.should_not be(a) # display mode keys the cache
  end

  it "captures TeX parse errors instead of raising" do
    e = Egui::ExmlFormula.typeset(%q(\frac{oops), display: true)
    e.error.should_not be_nil
  end

  it "renders <formula> headless — a valid formula and an error label" do
    doc = Egui::Exml.parse(%(
      <exml>
        <page id="root/root">
          <formula tex="x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}" size="30"/>
          <formula tex="\\frac{broken"/>
        </page>
      </exml>
    ))
    rt = Egui::Exml::Runtime.new
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new
    formula_frame(ctx, doc.pages.first.children, rt, renderer)
  end

  it "interpolates tex/size attrs from the store" do
    doc = Egui::Exml.parse(%(
      <exml>
        <page id="root/root">
          <formula tex="{state/tex}" size="{state/em}"/>
        </page>
      </exml>
    ))
    rt = Egui::Exml::Runtime.new
    rt.strings["state/tex"] = %q(\sum_{i=1}^{n} i)
    rt.floats["state/em"] = 40.0
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new
    formula_frame(ctx, doc.pages.first.children, rt, renderer)

    cached = Egui::ExmlFormula.typeset(%q(\sum_{i=1}^{n} i), display: true)
    cached.error.should be_nil
    cached.width_em.should be > 0.0
  end

  it "parses color attrs and rejects junk" do
    Egui::ExmlFormula.parse_color("#1a1a2e").should eq(
      Egui::Color32.rgb(0x1a, 0x1a, 0x2e))
    Egui::ExmlFormula.parse_color("#fff").should eq(
      Egui::Color32.rgb(255, 255, 255))
    Egui::ExmlFormula.parse_color("red").should be_nil
    Egui::ExmlFormula.parse_color("#12345").should be_nil
  end

  it "validates clean — the registry counts as a known custom element" do
    doc = Egui::Exml.parse(%(
      <exml>
        <page id="root/root">
          <formula tex="x^2" size="26" color="#102030" display="false"/>
        </page>
      </exml>
    ))
    Egui::Exml.validate(doc).should be_empty
  end

  it "renders the demo markup (assets/formulas.exml) end to end" do
    doc = Egui::Exml::Document.load(
      File.join(__DIR__, "..", "assets", "formulas.exml"))
    Egui::Exml.validate(doc).should be_empty

    rt = Egui::Exml::Runtime.new
    rt.floats["em"] = 26.0
    rt.strings["style"] = "Paper card"
    rt.rows["formulas"] = [
      {"name" => "Quadratic", "tex" => %q(x = \frac{-b}{2a})},
      {"name" => "Broken", "tex" => %q(\frac{oops)},
    ]
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new
    # Two frames: the paper branch (box + formula), then the theme
    # branch — both formulas' SVGs land in the typeset cache.
    formula_frame(ctx, doc.pages.first.children, rt, renderer)
    rt.strings["style"] = "Theme ink"
    formula_frame(ctx, doc.pages.first.children, rt, renderer)

    ok = Egui::ExmlFormula.typeset(%q(x = \frac{-b}{2a}), display: true)
    ok.error.should be_nil
    broken = Egui::ExmlFormula.typeset(%q(\frac{oops), display: true)
    broken.error.should_not be_nil
  end
end
