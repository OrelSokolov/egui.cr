# Line-height + shared-baseline geometry of the text stack:
#
#   * `Fonts#layout`'s optional `line_height` multiplier grows the row
#     box (markdown body passes 1.5) without touching the default
#     LINE_H_FACTOR behavior — and rides the single-run layout cache
#     key, so the same text at two factors lays out twice.
#   * `Galley::Row#ascent` places ONE shared baseline per row, derived
#     from the union em-box of the row's stacks. Single-stack rows keep
#     exactly the legacy baseline (row center + em/2); mixed rows
#     (inline code) align on a common baseline instead of per-font
#     centers.
#   * The inline-code chip (a backgrounded run) centers on its run's
#     em-box and clamps into the row box: with a 1.5 line-height it
#     leaves visible leading instead of filling the line edge to edge.

require "spec"
require "../src/egui"

LH_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 300.0))

def lh_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
             time : Float64 = 0.016, &app : Egui::Context ->)
  raw = Egui::RawInput.new(LH_SCREEN, events, time)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

# Monospace estimate with NARROWER metrics (em = 1.2×size vs the default
# 1.3×size) — stands in for a real second font stack (inline code).
class NarrowFonts < Egui::MonospaceFonts
  def metrics_at(size : Float64) : {Float64, Float64}
    {size, -size * 0.2}
  end
end

# Monospace estimate with WIDER advances — for caret/selection geometry:
# a run measured through the WRONG stack drifts off its glyphs.
class LhWideFonts < Egui::MonospaceFonts
  def measure(text : String, size : Float64) : Egui::Vec2
    lines = 1
    widest = 0
    current = 0
    text.each_char do |ch|
      if ch == '\n'
        lines += 1
        widest = current if current > widest
        current = 0
      else
        current += 1
      end
    end
    widest = current if current > widest
    Egui::Vec2.new(widest * size * 0.8, lines * size * 1.3)
  end
end

describe "line height" do
  it "multiplies the row height when given, default stays 1.3" do
    fonts = Egui::MonospaceFonts.new
    run = ->(lh : Float64?) do
      fonts.layout([Egui::TextRun.new("a\nb", 16.0)], nil, nil, lh).size.y
    end
    run.call(nil).should eq(2 * 16.0 * 1.3)
    run.call(2.0).should eq(2 * 16.0 * 2.0)
  end

  it "rides the single-run layout cache key" do
    fonts = Egui::MonospaceFonts.new
    default = fonts.layout([Egui::TextRun.new("word", 16.0)])
    roomy = fonts.layout([Egui::TextRun.new("word", 16.0)], nil, nil, 2.0)
    # same text, different factor → different galleys (no stale hit)
    roomy.size.y.should eq(32.0)
    default.size.y.should eq(16.0 * 1.3)
  end

  it "derives one shared baseline from the union em-box" do
    fonts = Egui::MonospaceFonts.new
    narrow = NarrowFonts.new
    resolve = ->(family : String?, bold : Bool, italic : Bool) : Egui::Fonts do
      family == "monospace" ? narrow : fonts
    end
    galley = fonts.layout(
      [Egui::TextRun.new("abc ", 16.0),
       Egui::TextRun.new("x", 16.0, family: "monospace")],
      nil, resolve)
    row = galley.rows.first
    # union: asc = max(16, 16), desc = min(-4.8, -3.2) → em = 20.8;
    # baseline = row center + (asc+desc)/2 (em box centered in the row)
    row.height.should eq(16.0 * 1.3)
    row.ascent.should be_close(16.0 * 1.3 / 2.0 + (16.0 + -4.8) / 2.0, 1e-9)
    # paint_galley's math: every run's em-center anchor plus its own
    # em/2 lands on the SAME baseline (the row's), whatever its stack
    baselines = row.runs.map do |run|
      stack = resolve.call(run.family, false, false)
      asc, desc = stack.metrics_at(run.size)
      row.ascent - (asc + desc) / 2.0 + (asc + desc) / 2.0
    end
    baselines.uniq.size.should eq(1)
    baselines.first.should eq(row.ascent)
    # …and it differs from the per-font-center baseline the old model
    # produced for the narrow stack (row center + em_narrow/2 = 20.0)
    baselines.first.should_not eq(16.0 * 1.3 / 2.0 + 19.2 / 2.0)
  end

  it "keeps the legacy baseline for single-stack rows" do
    fonts = Egui::MonospaceFonts.new
    galley = fonts.layout([Egui::TextRun.new("hi", 16.0)])
    row = galley.rows.first
    # default metrics_at: {size, -0.3×size} → asc = 16, desc = -4.8.
    # Legacy = the TextCmd row-center anchor: the em-box CENTER sits on
    # the row center, so the baseline is center + (asc+desc)/2 — NOT
    # center + em/2 (that dropped every row by |desc| and read as top
    # padding inside TextEdit/TextArea fields).
    row.ascent.should be_close(row.height / 2.0 + (16.0 + -4.8) / 2.0, 1e-9)
  end

  it "splits an explicit line_height's leading half above / half below" do
    fonts = Egui::MonospaceFonts.new
    galley = fonts.layout([Egui::TextRun.new("hi", 16.0)], nil, nil, 1.5)
    row = galley.rows.first
    # half-leading (CSS line box): em box centered in the row, baseline
    # = top padding + ascent — the roomy line keeps text (and its
    # chip) centered instead of pressed to the row bottom
    em = 16.0 * 1.3
    row.height.should eq(24.0)
    row.ascent.should eq((24.0 - em) / 2.0 + 16.0)
  end

  it "fits the inline-code chip inside a 1.5 line box (RichLabel)" do
    ctx = Egui::Context.new
    rect = nil
    lh_frame(ctx) do |c|
      c.central_panel do |ui|
        rect = ui.add(Egui::RichLabel.new("use `map` here",
          line_height: 1.5)).rect
      end
    end

    chip = ctx.painter.commands.select(Egui::RectCmd)
      .find { |r| r.fill == Egui::RichLabel::INLINE_CODE_BG_DARK }
    chip.should_not be_nil
    # 15px mono × 1.4 = 21 tall, inside the 16px × 1.5 = 24px row box
    # — with half-leading the chip hugs the text, not the row edges
    chip.not_nil!.rect.height.should be_close(15.0 * 1.4, 1e-6)
    top = rect.not_nil!.min.y
    chip.not_nil!.rect.min.y.should be >= top
    chip.not_nil!.rect.max.y.should be <= top + 16.0 * 1.5
    # The layout reserved the chip's side padding as advance width
    # (add_margin): the chip's left edge lands exactly where the
    # preceding run's advance ends — no overlap with "use " anymore.
    fonts = Egui::MonospaceFonts.new
    chip.not_nil!.rect.min.x.should be_close(
      rect.not_nil!.min.x + fonts.measure("use ", 16.0).x, 1e-6)
  end

  it "paints the selection over the chip, under the glyphs" do
    ctx = Egui::Context.new
    rect = nil
    draw = ->(events : Array(Egui::Event), time : Float64) {
      lh_frame(ctx, events, time) do |c|
        c.central_panel do |ui|
          rect = ui.add(Egui::RichLabel.new("use `map` here")).rect
        end
      end
    }
    draw.call([] of Egui::Event, 0.016)
    r = rect.not_nil!
    p1 = Egui::Pos2.new(r.left + r.width * 0.3, r.center.y)
    p2 = Egui::Pos2.new(r.left + r.width * 0.9, r.center.y)
    draw.call([Egui::Event.pointer_moved(p1)], 0.032)
    draw.call([Egui::Event.pointer_pressed(p1)], 0.048)
    draw.call([Egui::Event.pointer_moved(p2)], 0.064)

    cmds = ctx.painter.commands
    chip_i = cmds.index { |c|
      c.is_a?(Egui::RectCmd) && c.fill == Egui::RichLabel::INLINE_CODE_BG_DARK }
    sel_i = cmds.index { |c|
      c.is_a?(Egui::RectCmd) && c.fill == ctx.style.visuals.selection_fill }
    code_i = cmds.index { |c|
      c.is_a?(Egui::TextCmd) && c.text == "map" }
    chip_i.should_not be_nil
    sel_i.should_not be_nil
    code_i.should_not be_nil
    # chip under selection under glyphs — a chip painted over the
    # highlight is what made selected code look unselectable
    chip_i.not_nil!.should be < sel_i.not_nil!
    sel_i.not_nil!.should be < code_i.not_nil!
  end

  it "measures caret offsets run-by-run through each run's stack" do
    fonts = Egui::MonospaceFonts.new
    wide = LhWideFonts.new
    resolve = ->(family : String?, bold : Bool, italic : Bool) : Egui::Fonts do
      family == "monospace" ? wide : fonts
    end
    galley = fonts.layout(
      [Egui::TextRun.new("ab", 16.0),
       Egui::TextRun.new("cd", 14.0, family: "monospace")],
      nil, resolve)
    # prefix "abcd": 2 chars at 16×0.6 + 2 chars at 14×0.8 — the DRAWN
    # widths; the dominant-font fallback would give 4 × 16 × 0.6
    galley.x_at(0, 4, fonts, resolve).should be_close(
      2 * 16.0 * 0.6 + 2 * 14.0 * 0.8, 1e-6)
    galley.x_at(0, 4, fonts).should be_close(4 * 16.0 * 0.6, 1e-6)
  end

  it "reserves table row heights for wrapped chip cells (no overlap)" do
    ctx = Egui::Context.new
    md = <<-MD
      | a | b |
      | --- | --- |
      | widget `inspector` and `snippets` plus enough words to wrap the cell wide | mid |
      | yyafter | c |
    MD
    lh_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.add(Egui::Markdown.new(md))
      end
    end
    texts = ctx.painter.commands.select(Egui::TextCmd)
    # the wrapped cell's LAST line vs the NEXT row's first line: an
    # under-reserved row height puts row three on top of row two's
    # wrapped last line. A reserved row = line height (24) + vertical
    # padding (8) past the last line's anchor.
    wrapped = texts.reject { |t| ["a", "b", "mid", "yyafter", "c"].includes?(t.text) }
      .map(&.pos.y)
    after_y = texts.find(&.text.==("yyafter")).try(&.pos.y)
    after_y.should_not be_nil
    wrapped.should_not be_empty
    after_y.not_nil!.should be > wrapped.max.not_nil! + 26.0
  end
end
