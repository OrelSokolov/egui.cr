# LaTeX formulas in egui-cr — the EXML edition: the interface is
# assets/formulas.exml (hot-reloaded on save), and every formula is
# the <formula> tag from src/egui/exml_formula.cr — the opt-in
# mathjax.cr widget registered in the global `widget` registry.
#
# Pipeline (all inside the tag): TeX -> MathJax.to_svg(paths: true)
# — the v3-structure SVG (glyph outline paths in <defs> + <use>, no
# fonts) — baked into a texture by the stock Svg widget through the
# pure-Crystal NanoSVG port. Typesetting runs once per (tex, display)
# in a bounded cache; the app below only publishes rows to the store.
#
#   bin/apps/formulas   # GUI: a handful of formulas + a size slider

# Registers <formula> (and pulls the whole egui core with it).
require "../src/egui/exml_formula"
require "../src/egui/driver_selector"

class FormulasApp < Egui::App
  # The demo list: names for the labels, TeX for the tag. Published to
  # the store as the "formulas" row slot — the markup's <repeat> walks
  # it; parse errors surface inside the tag as error labels.
  FORMULAS = [
    {"Quadratic formula", %q(x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a})},
    {"Euler's identity", %q(e^{i\pi} + 1 = 0)},
    {"Gauss's summation", %q(\sum_{i=1}^{n} i = \frac{n(n+1)}{2})},
    {"Fundamental theorem of calculus", %q(\int_{a}^{b} f'(x)\,dx = f(b) - f(a))},
    {"Rotation matrix", %q(\begin{pmatrix} \cos\theta & -\sin\theta \\ \sin\theta & \cos\theta \end{pmatrix})},
    {"Cauchy–Schwarz", %q(\left( \sum_{k=1}^{n} a_k b_k \right)^2 \le \left( \sum_{k=1}^{n} a_k^2 \right) \left( \sum_{k=1}^{n} b_k^2 \right))},
  ]

  @exml : Egui::Exml::Document
  @renderer = Egui::Exml::Renderer.new
  @rt = Egui::Exml::Runtime.new

  # Locate the markup: EGUI_EXML=env override, then the repo checkout
  # (__DIR__/../assets), then the working directory — in that order.
  def self.exml_path : String
    candidates = [
      ENV["EGUI_EXML"]?,
      File.join(__DIR__, "..", "assets", "formulas.exml"),
      File.join("assets", "formulas.exml"),
    ].compact
    candidates.each { |c| return c if File.file?(c) }
    candidates.last # Document.load reports the missing file itself
  end

  def initialize
    super # App#initialize creates the Context
    @exml = Egui::Exml::Document.load(self.class.exml_path)
    lint_exml
    # The store's binding vocabulary: the slider/combo own em and
    # style (widgets write slots directly); the derived paper flag and
    # the formatted size label are published each frame in #update.
    @rt.floats["em"] = 26.0
    @rt.strings["style"] = "Paper card"
    @rt.rows["formulas"] = FORMULAS.map do |(name, tex)|
      {"name" => name, "tex" => tex}
    end
  end

  # Vocabulary lint: silent when clean; issues land in the console
  # (startup + every hot reload). <formula> needs no listing — the
  # linter knows the global `widget` registry.
  private def lint_exml : Nil
    Egui::Exml.validate(@exml).each { |i| STDERR.puts "exml: #{i}" }
  end

  def update(ctx : Egui::Context) : Nil
    # Hot reload the markup on external edits (the notepad pattern);
    # surviving widget paths keep their state.
    lint_exml if @exml.reload_if_changed

    # Derived slots — a condition the box/formula branches test, and
    # a size label formatted without the store's two-decimal floats.
    @rt.bools["paper"] = @rt.string("style") == "Paper card"
    @rt.strings["em_label"] = "%.0f px/em" % @rt.float("em")

    ctx.central_panel do |ui|
      @exml.pages.first.children.each do |node|
        @renderer.render(node, ui, ctx, @rt)
      end
    end
  end
end

Egui.run(FormulasApp.new,
  title: "egui-cr — LaTeX formulas (exml)",
  width: 720, height: 1080, inspector: :hidden)
