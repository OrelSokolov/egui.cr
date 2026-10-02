require "spec"
require "../src/egui"

# Real variant faces: Context#fonts_for(bold:/italic:) routes the
# PRIMARY stack to its installed variant slots (bold/italic/
# bold_italic), degrades to the nearest real face when one is missing
# (never an emulation), and leaves NAMED families untouched. Layout
# measures bold runs through the same routing the painter draws with.

# A Fonts double whose measure is a fixed width per instance — which
# stack served a run is visible in the galley's row width.
class VariantProbeFonts < Egui::Fonts
  getter width : Float64

  def initialize(@width : Float64, @label : String)
  end

  getter label : String

  def measure(text : String, size : Float64) : Egui::Vec2
    Egui::Vec2.new(@width * text.size, size * 1.2)
  end
end

describe "font variant faces" do
  it "routes bold/italic to the installed variant, degrades to nearest real" do
    ctx = Egui::Context.new
    base = VariantProbeFonts.new(1.0, "base")
    bold = VariantProbeFonts.new(2.0, "bold")
    ital = VariantProbeFonts.new(3.0, "italic")
    ctx.fonts = base

    # No variants installed: every flag serves the base face.
    ctx.fonts_for(nil).should eq(base)
    ctx.fonts_for(nil, bold: true).should eq(base)
    ctx.fonts_for(nil, bold: true, italic: true).should eq(base)

    ctx.bold_fonts = bold
    ctx.italic_fonts = ital
    ctx.fonts_for(nil, bold: true).should eq(bold)
    ctx.fonts_for(nil, italic: true).should eq(ital)
    # bold+italic without a combined face degrades to bold (nearest).
    ctx.fonts_for(nil, bold: true, italic: true).should eq(bold)

    ctx.bold_italic_fonts = VariantProbeFonts.new(4.0, "bold_italic")
    ctx.fonts_for(nil, bold: true, italic: true)
      .try(&.as(VariantProbeFonts).label).should eq("bold_italic")
  end

  it "leaves named families on their own stack whatever the flags" do
    ctx = Egui::Context.new
    base = VariantProbeFonts.new(1.0, "base")
    named = VariantProbeFonts.new(5.0, "named")
    ctx.fonts = base
    ctx.register_font_family("display", named)
    ctx.bold_fonts = VariantProbeFonts.new(2.0, "bold")

    ctx.fonts_for("display", bold: true).should eq(named)
    # the reserved primary alias DOES take variants
    ctx.fonts_for("system", bold: true)
      .try(&.as(VariantProbeFonts).label).should eq("bold")
  end

  it "layout measures bold runs through the bold face" do
    ctx = Egui::Context.new
    base = VariantProbeFonts.new(1.0, "base")
    bold = VariantProbeFonts.new(2.0, "bold")
    ctx.fonts = base
    ctx.bold_fonts = bold

    run = Egui::TextRun.new("word", 16.0)
    plain = base.layout([run])
    bold_run = Egui::TextRun.new("word", 16.0, bold: true)
    laid = base.layout([bold_run],
      resolve: ->(f : String?, b : Bool, i : Bool) { ctx.fonts_for(f, b, i) })

    # 4 chars: plain 1.0/char through base, bold 2.0/char through the
    # bold variant — the wrap token measured with the DRAW face.
    plain.rows.first.width.should eq(4.0)
    laid.rows.first.width.should eq(8.0)
  end
end
