# Label#align / the `text_align` style key: :center/:right labels are
# block-level in a vertical layout (stretch to the width, text placed
# by the free slack); :left/nil keep the hugging upstream size.
require "spec"
require "../src/egui"

AL_SCREEN = Egui::Rect.from_min_size(
  Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

private def al_frame(ctx : Egui::Context, &app : Egui::Context ->)
  raw = Egui::RawInput.new(AL_SCREEN, [] of Egui::Event, 0.016)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

describe "Label align" do
  it "stretches and centers/right-aligns in a vertical layout" do
    ctx = Egui::Context.new
    left = center = right = nil
    al_frame(ctx) do |c|
      c.central_panel do |ui|
        left = ui.label("left text").rect
        center = ui.label("centered text", align: :center).rect
        right = ui.label("right text", align: :right).rect
      end
    end
    # :left hugs its text — narrower than the panel line.
    left.not_nil!.width.should be < 200.0
    # :center/:right are block-level: full line width…
    center.not_nil!.width.should be > 700.0
    right.not_nil!.width.should be > 700.0
    # …and share its edges.
    center.not_nil!.left.should be < left.not_nil!.left + 1.0
    right.not_nil!.right.should be > left.not_nil!.right + 500.0
  end

  it "places the text at the aligned edge" do
    ctx = Egui::Context.new
    rects = {} of String => Egui::Rect
    al_frame(ctx) do |c|
      c.central_panel do |ui|
        ["left text", "centered text", "right text"].each do |t|
          rects[t] = ui.label(t,
            align: {"left text" => :left, "centered text" => :center,
                    "right text" => :right}[t]).rect
        end
      end
    end
    # TextCmd pos is the glyph run's LEFT edge (paint_galley) — check
    # it against the label rect and the measured text width.
    size = ctx.style.font_size
    ctx.painter.commands.select(Egui::TextCmd)
         .select { |t| rects[t.text]? }.each do |t|
      r = rects[t.text].not_nil!
      w = ctx.fonts_for(ctx.style.font_family).measure(t.text, size).x
      case t.text
      when "left text"   then t.pos.x.should be_close(r.left, 2.0)
      when "centered text" then t.pos.x.should be_close(r.center.x - w / 2.0, 2.0)
      when "right text"  then t.pos.x.should be_close(r.right - w, 2.0)
      end
    end
  end

  it "centers every row of a wrapped multi-line label" do
    ctx = Egui::Context.new
    raw = Egui::RawInput.new(
      Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(300.0, 400.0)),
      [] of Egui::Event, 0.016)
    ctx.begin_frame(raw)
    rect = nil
    ctx.central_panel do |ui|
      rect = ui.label(
        "первая строка\nа вторая заметно длиннее первой строки",
        wrap: true, align: :center).rect
    end
    ctx.end_frame
    r = rect.not_nil!
    center = r.center.x
    size = ctx.style.font_size
    ctx.painter.commands.select(Egui::TextCmd)
         .select { |t| t.text.includes?("строка") }.each do |t|
      w = ctx.fonts_for(ctx.style.font_family).measure(t.text, size).x
      # pos is the run's left edge: a centered row's left edge sits
      # symmetrically around the rect center.
      (t.pos.x + w / 2.0 - center).abs.should be < 8.0
    end
  end

  it "reads the alignment from the text_align style key" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("label", Egui::StyleVars{"text_align" => "center"})
    rect = nil
    al_frame(ctx) do |c|
      c.central_panel do |ui|
        rect = ui.label("styled").rect
      end
    end
    rect.not_nil!.width.should be > 700.0 # stretched = the key applied
  end
end
