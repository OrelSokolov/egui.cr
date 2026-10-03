# LaTeX formulas in egui-cr, typeset by mathjax.cr — the Crystal port
# of the MathJax v3 core (https://github.com/OrelSokolov/mathjax.cr).
#
# Pipeline: TeX -> MathJax.to_svg(paths: true) — the v3-structure SVG
# (glyph outline paths in <defs> + <use>, no fonts involved) — baked
# into a texture by the stock Svg widget through the pure-Crystal
# NanoSVG port. One code path for icons and formulas, no replay layer,
# no MathJax TeX font files: the outlines ride inside the SVG.
#
#   bin/formulas   # GUI: a handful of formulas + a size slider

require "mathjax"
require "../src/egui"
require "../src/egui/backend/sokol"

# One typeset formula: the v3 SVG is produced once; the Svg widget
# caches rasters per pixel size, so the slider only rebakes.
class Formula
  getter svg : String
  getter width_em : Float64
  getter height_em : Float64
  getter error : String?

  def initialize(@tex : String, @display : Bool = true)
    @svg = ""
    @width_em = 0.0
    @height_em = 0.0
    begin
      @svg = MathJax.to_svg(@tex, display: @display, paths: true)
      # width/height attrs are in ex (1 em = 2 ex at the renderer's
      # em:16/ex:8 reference)
      @width_em = attr_em("width")
      @height_em = attr_em("height")
    rescue ex : MathJax::TeX::TexError
      @error = ex.message.to_s
    end
  end

  private def attr_em(name : String) : Float64
    if (v = @svg.match(/#{name}="([\d.]+)ex"/))
      v[1].to_f / 2.0
    else
      0.0
    end
  end
end

# Render styles: the paper card (white card, fixed dark ink) or the
# formula painted bare in the theme's text color, like any label.
STYLES = ["Paper card", "Theme ink"]

FORMULAS = [
  {"Quadratic formula", %q(x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a})},
  {"Euler's identity", %q(e^{i\pi} + 1 = 0)},
  {"Gauss's summation", %q(\sum_{i=1}^{n} i = \frac{n(n+1)}{2})},
  {"Fundamental theorem of calculus", %q(\int_{a}^{b} f'(x)\,dx = f(b) - f(a))},
  {"Rotation matrix", %q(\begin{pmatrix} \cos\theta & -\sin\theta \\ \sin\theta & \cos\theta \end{pmatrix})},
  {"Cauchy–Schwarz", %q(\left( \sum_{k=1}^{n} a_k b_k \right)^2 \le \left( \sum_{k=1}^{n} a_k^2 \right) \left( \sum_{k=1}^{n} b_k^2 \right))},
]

INK       = Egui::Color32.rgb(0x1a, 0x1a, 0x2e)
PAPER     = Egui::Color32.rgb(0xff, 0xff, 0xff)
CARD_EDGE = Egui::Color32.rgb(0xd8, 0xd8, 0xe2)

class FormulasApp < Egui::App
  @em = 26.0_f64
  @style = "Paper card"
  @formulas : Array(Formula)

  def initialize
    super # App#initialize creates the Context
    @formulas = FORMULAS.map { |_, tex| Formula.new(tex) }
  end

  def update(ctx : Egui::Context) : Nil
    ctx.central_panel do |ui|
      ui.heading("LaTeX formulas — mathjax.cr + egui-cr")
      ui.label("TeX → MathJax core port → v3 path SVG (defs+use, no fonts) " \
        "→ NanoSVG bake → texture. Same pipeline as icons.")
      ui.separator
      ui.horizontal do |row|
        row.label("size:")
        row.slider(@em, 14.0..48.0) { |v| @em = v }
        row.label("#{"%.0f" % @em} px/em")
      end
      ui.horizontal do |row|
        row.label("style:")
        row.combo_box("fml_style", @style, STYLES) { |opt| @style = opt }
      end

      FORMULAS.each_with_index do |(name, tex), i|
        ui.separator
        ui.label(name)
        ui.label(tex)
        formula = @formulas[i]
        if error = formula.error
          ui.label("parse error: #{error}")
          next
        end
        if @style == "Theme ink"
          # Bare formula in the theme's text color — same tint the
          # labels use; the Svg resolves currentColor into it.
          size = Egui::Vec2.new(formula.width_em * @em, formula.height_em * @em)
          rect = ui.allocate_at_least(size)
          Egui::Svg.new(formula.svg, size: size,
            current_color: ui.style.visuals.text_color).paint(ui, rect)
          next
        end
        # A paper card at the formula's natural size (the Svg widget
        # fits the aspect-preserving quad inside; width/height come
        # from the same TeX metrics that positioned the glyphs).
        size = Egui::Vec2.new(formula.width_em * @em + 24.0,
          formula.height_em * @em + 16.0)
        rect = ui.allocate_at_least(size)
        ui.painter.rect(rect, 8.0, fill: PAPER, stroke_color: CARD_EDGE)
        inner = Egui::Rect.new(
          min: Egui::Pos2.new(rect.min.x + 12.0, rect.min.y + 8.0),
          max: Egui::Pos2.new(rect.max.x - 12.0, rect.max.y - 8.0))
        Egui::Svg.new(formula.svg,
          size: Egui::Vec2.new(inner.width, inner.height),
          current_color: INK).paint(ui, inner)
      end
    end
  end
end

Egui::Backend::Sokol.run(FormulasApp.new,
  title: "egui-cr — LaTeX formulas (mathjax.cr)",
  width: 720, height: 1080, inspector: :hidden)
