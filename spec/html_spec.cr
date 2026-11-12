# The NativeHTML element vocabulary (plans/NativeHTML.md §5):
# `require "egui/html"` adds the browser's element names as Ui
# methods. These specs pin the mapping end to end — element →
# widget → painted commands — plus the universal attribute five
# (classes/id/style/title/disabled/hidden) and data_testid.

require "spec"
require "../src/egui/html"

HTML_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(400.0, 300.0))

def html_frame(ctx : Egui::Context, &app : Egui::Context ->)
  raw = Egui::RawInput.new(HTML_SCREEN, [] of Egui::Event, 0.016)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

def html_texts(ctx : Egui::Context) : Array(Egui::TextCmd)
  ctx.painter.commands.select(Egui::TextCmd)
end

describe "html vocabulary" do
  it "div classes chain inner widgets onto the scoped rule" do
    ctx = Egui::Context.new
    lime = Egui::Color32.rgb(0, 255, 100)
    ctx.stylesheet.rule("card.button", Egui::StyleVars{
      "background" => lime,
    })

    html_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.div(classes: "card") do |d|
          d.add(Egui::Button.new("OK"))
        end
        ui.add(Egui::Button.new("Outside"))
      end
    end

    rects = ctx.painter.commands.select(Egui::RectCmd)
      .select { |r| r.fill == lime }
    rects.size.should eq(1) # only the button inside div.card
  end

  it "inline style: color beats the class rule (cascade contract)" do
    ctx = Egui::Context.new
    red = Egui::Color32.rgb(255, 0, 0)
    ctx.stylesheet.rule("button", Egui::StyleVars{
      "text_color" => Egui::Color32.rgb(0, 0, 255),
    })
    # p has no class of its own; the style attr must still win over
    # nothing — and the painted color must be exactly the inline one.
    html_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.p("hello", style: "color: #ff0000")
      end
    end
    html_texts(ctx).first.color.should eq(red)
  end

  it "p with inline background paints the swatch fill" do
    ctx = Egui::Context.new
    html_frame(ctx) do |c|
      c.central_panel do |ui|
        # the html_gallery "fill palette strip" idiom: a label sized
        # through the universal width/height attrs, filled inline.
        ui.p(" ", style: "background: #e01b4c", width: 44, height: 26)
      end
    end
    red = Egui::Color32.rgb(224, 27, 76)
    swatches = ctx.painter.commands.select(Egui::RectCmd)
      .select { |r| r.fill == red }
    swatches.size.should eq(1)
    swatches.first.rect.width.should be_close(44.0, 0.01)
    swatches.first.rect.height.should be_close(26.0, 0.01)
  end

  it "hidden: skips rendering entirely" do
    ctx = Egui::Context.new
    html_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.p("visible")
        ui.p("gone", hidden: true)
      end
    end
    html_texts(ctx).map(&.text).should_not contain("gone")
    html_texts(ctx).map(&.text).should contain("visible")
  end

  it "data_testid: records the widget id for selectors" do
    ctx = Egui::Context.new
    html_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.p("hello", data_testid: "greeting")
      end
    end
    ctx.data_testids["greeting"]?.should_not be_nil
  end

  it "h1..h6 use the CSS heading scale, h1 is bold" do
    ctx = Egui::Context.new
    html_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.h1("Big")
        ui.h6("Small")
      end
    end
    texts = html_texts(ctx)
    big = texts.find { |t| t.text == "Big" }.not_nil!
    small = texts.find { |t| t.text == "Small" }.not_nil!
    big.size.should eq(ctx.style.font_size * 2.0)
    small.size.should eq(ctx.style.font_size * 0.67)
    big.bold?.should be_true
  end

  it "strong/em/code carry their text styling" do
    ctx = Egui::Context.new
    html_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.strong("bold")
        ui.em("italic")
        ui.code("mono")
      end
    end
    texts = html_texts(ctx)
    texts.find { |t| t.text == "bold" }.not_nil!.bold?.should be_true
    texts.find { |t| t.text == "italic" }.not_nil!.italic?.should be_true
    texts.find { |t| t.text == "mono" }.not_nil!.family.should eq("monospace")
  end

  it "sub/sup shift the baseline below/above the line" do
    ctx = Egui::Context.new
    html_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.span do |s|
          s.label("H")
          s.sub("2")
          s.label("O")
          s.sup("2")
        end
      end
    end
    texts = html_texts(ctx)
    texts.map(&.text).should eq(["H", "2", "O", "2"])
    h, sub2, o, sup2 = texts
    f = ctx.style.font_size
    # 0.75em script size on both
    sub2.size.should be_close(f * 0.75, 0.01)
    sup2.size.should be_close(f * 0.75, 0.01)
    # the base letters share one line (one em center)…
    h.pos.y.should be_close(o.pos.y, 0.01)
    # …the subscript drops below it (0.25em baseline drop plus the
    # em-center delta), the superscript rises above it
    sub2.pos.y.should be > h.pos.y + f * 0.25
    sup2.pos.y.should be < h.pos.y - f * 0.2
    # the script hugs its base letter: no item_spacing word gap
    # between "H" and "2" — just the glyph advance
    sub2.pos.x.should be < h.pos.x + f * 0.75
  end

  it "br is a hard break inside span (a no-wrap row)" do
    ctx = Egui::Context.new
    html_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.span do |s|
          s.label("before break")
          s.br
          s.label("after break")
        end
      end
    end
    texts = html_texts(ctx)
    texts.map(&.text).should eq(["before break", "after break"])
    after = texts[1].pos
    # the second run starts on a fresh line: same left edge, below
    # the first — not pinned at the row's right edge.
    after.x.should eq(texts[0].pos.x)
    after.y.should be > texts[0].pos.y
  end

  it "br in a wrapping row and in vertical flow" do
    ctx = Egui::Context.new
    html_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.horizontal do |row|
          row.label("one")
          row.br
          row.label("two")
        end
        ui.br # vertical flow: a no-op, the next widget is its own line
        ui.label("three")
      end
    end
    texts = html_texts(ctx).map { |t| {t.text, t.pos} }
    texts.map(&.[0]).should eq(["one", "two", "three"])
    texts[1][1].y.should be > texts[0][1].y
    texts[2][1].x.should eq(texts[1][1].x)
  end

  it "ol numbers its li rows; ul does not" do
    ctx = Egui::Context.new
    html_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.ol { |list| list.li("first"); list.li("second") }
        ui.ul { |list| list.li("plain") }
      end
    end
    texts = html_texts(ctx).map(&.text)
    texts.should contain("1.")
    texts.should contain("2.")
    texts.should contain("•")
  end

  it "a ul nested inside an ol shows bullets and keeps outer numbering" do
    ctx = Egui::Context.new
    html_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.ol do |list|
          list.li("one")
          list.li do |row|
            row.ul { |inner| inner.li("inner a"); inner.li("inner b") }
          end
          list.li("three")
        end
      end
    end
    texts = html_texts(ctx).map(&.text)
    texts.count("•").should eq(2)
    texts.should contain("1.")
    texts.should contain("2.")
    texts.should contain("3.")
    texts.should_not contain("3.1.")
  end

  it "an ol nested inside an ol restarts at 1 (plain HTML numbering)" do
    ctx = Egui::Context.new
    html_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.ol do |list|
          list.li("one")
          list.li do |row|
            row.ol { |inner| inner.li("inner a"); inner.li("inner b") }
          end
          list.li("three")
        end
      end
    end
    texts = html_texts(ctx).map(&.text)
    # the nested ol numbers its own rows from 1 — hierarchical
    # "2.1." markers are CSS counters, not HTML
    texts.count("1.").should eq(2) # outer item one + inner item one
    texts.count("2.").should eq(2) # outer item two + inner item two
    texts.should contain("3.")     # outer numbering restored after the nested ol
    texts.should_not contain("2.1.")
    texts.should_not contain("2.2.")
  end

  it "blockquote paints a left accent stroke frame" do
    ctx = Egui::Context.new
    accent = ctx.style.visuals.selection_fill
    html_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.blockquote { |b| b.label("quoted") }
      end
    end
    frames = ctx.painter.commands.select(Egui::RectCmd)
      .select(&.stroke_sides).reject(&.stroke_sides.not_nil!.left.width.zero?)
    frames.size.should be > 0
    frames.first.stroke_sides.not_nil!.left.color.should eq(accent)
  end

  it "a() renders the hyperlink label" do
    ctx = Egui::Context.new
    html_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.a("Docs", href: "https://example.com")
      end
    end
    html_texts(ctx).map(&.text).join.should contain("Docs")
  end

  it "fieldset paints the frame with the legend on the top border" do
    ctx = Egui::Context.new
    stroke = ctx.style.visuals.window_stroke
    html_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.fieldset("Legend caption") { |f| f.p("content") }
      end
    end
    # the frame: per-side stroke, top off (the caption breaks the line)
    frames = ctx.painter.commands.select(Egui::RectCmd)
      .select(&.stroke_sides).reject(&.stroke_sides.not_nil!.left.width.zero?)
    frames.size.should be > 0
    sides = frames.first.stroke_sides.not_nil!
    sides.top.on?.should be_false
    sides.left.color.should eq(stroke)
    # the top border redrawn as two segments around the caption text
    segs = ctx.painter.commands.select(Egui::LineCmd)
      .select { |l| l.color == stroke }
    segs.size.should eq(2)
    html_texts(ctx).map(&.text).join.should contain("Legend caption")
  end

  it "progress renders the bar track" do
    ctx = Egui::Context.new
    html_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.progress(0.5)
      end
    end
    ctx.painter.commands.select(Egui::RectCmd).size.should be > 0
  end

  it "input renders the field with its placeholder hint" do
    ctx = Egui::Context.new
    buffer = "typed"
    changed = nil
    html_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.input(buffer, placeholder: "type here") { |t| changed = t }
      end
    end
    html_texts(ctx).map(&.text).should contain("typed")
    changed.should be_nil # nothing typed this frame
  end

  it "details renders the summary header" do
    ctx = Egui::Context.new
    html_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.details("More") { |d| d.label("body") }
      end
    end
    html_texts(ctx).map(&.text).join.should contain("More")
  end

  it "select renders the selected option" do
    ctx = Egui::Context.new
    html_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.select("pick", "Two", ["One", "Two", "Three"]) { |o| }
      end
    end
    html_texts(ctx).map(&.text).join.should contain("Two")
  end
end

describe "html display:flex" do
  it "lays div children out by flexbox (justify-content: center)" do
    ctx = Egui::Context.new
    html_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.div(style: "display: flex; justify-content: center; gap: 10") do |d|
          d.add(Egui::Label.new("l"))
          d.add(Egui::Label.new("r"))
        end
      end
    end
    # Read the real geometry AFTER the frame (the flex child responses
    # are placeholders until the container block closes).
    texts = html_texts(ctx).select { |t| t.text == "l" || t.text == "r" }
    texts.size.should eq 2
    left, right = texts.map(&.pos.x).minmax
    # two labels centered in the 400-wide panel: the pair straddles
    # the middle, kept apart by the gap.
    left.should be < 200.0
    right.should be > 200.0
    (right - left).should be > 15.0 # label width + the 10px gap
  end

  it "a nested div is one flex item (column direction stacks)" do
    ctx = Egui::Context.new
    html_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.div(style: "display: flex; flex-direction: column") do |d|
          d.div { |inner| inner.add(Egui::Label.new("b")) }
          d.add(Egui::Label.new("x"))
        end
      end
    end
    texts = html_texts(ctx).select { |t| t.text == "b" || t.text == "x" }
    texts.size.should eq 2
    b_y = texts.find { |t| t.text == "b" }.not_nil!.pos.y
    x_y = texts.find { |t| t.text == "x" }.not_nil!.pos.y
    x_y.should be > b_y
  end
end
