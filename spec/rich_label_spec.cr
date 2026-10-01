require "spec"
require "../src/egui"

RICH_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 300.0))

def rich_frame(ctx : Egui::Context, events : Array(Egui::Event), time : Float64,
               &app : Egui::Context ->)
  raw = Egui::RawInput.new(RICH_SCREEN, events, time)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

def rich_runs(markup : String) : Array(Egui::TextRun)
  Egui::RichText.new(markup).styled_runs(
    16.0, Egui::Color32.rgba(255, 255, 255, 255),
    Egui::Color32.rgba(102, 170, 255, 255))
end

describe "RichText inline markup" do
  it "splits plain text into a single unstyled run" do
    runs = rich_runs("just text")
    runs.size.should eq(1)
    runs.first.text.should eq("just text")
    runs.first.bold?.should be_false
    runs.first.italic?.should be_false
    runs.first.family.should be_nil
  end

  it "parses **bold** and *italic*" do
    runs = rich_runs("a **b** c *d*")
    runs.map(&.text).should eq(["a ", "b", " c ", "d"])
    runs[1].bold?.should be_true
    runs[3].italic?.should be_true
  end

  it "parses ***bold italic*** and nested emphasis" do
    runs = rich_runs("***x***")
    runs.first.bold?.should be_true
    runs.first.italic?.should be_true

    nested = rich_runs("**a *b* c**")
    nested[1].italic?.should be_true
    nested[1].bold?.should be_true # inherits from the enclosing bold
  end

  it "parses `code` as a monospace run without inner markup" do
    runs = rich_runs("use `map` here")
    runs.map(&.text).should eq(["use ", "map", " here"])
    runs[1].family.should eq("monospace")
    runs[1].bold?.should be_false
  end

  it "renders unclosed markers literally" do
    runs = rich_runs("2 * 3 and `unclosed")
    runs.map(&.text).join.should eq("2 * 3 and `unclosed")
    runs.none?(&.italic?).should be_true
  end

  it "escapes marker characters with a backslash" do
    runs = rich_runs("\\*not italic\\*")
    runs.first.text.should eq("*not italic*")
    runs.first.italic?.should be_false
  end

  it "parses [label](url) links with span ranges" do
    rich = Egui::RichText.new("see [docs](https://example.com) now")
    runs = rich.styled_runs(16.0,
      Egui::Color32.rgba(255, 255, 255, 255),
      Egui::Color32.rgba(102, 170, 255, 255))
    link = runs[1]
    link.text.should eq("docs")
    link.underline?.should be_true
    link.color.should eq(Egui::Color32.rgba(102, 170, 255, 255))

    rich.link_spans.size.should eq(1)
    span = rich.link_spans.first
    span.url.should eq("https://example.com")
    # char range within the STRIPPED text: "see " is 4 chars
    span.from.should eq(4)
    span.to.should eq(8)
  end

  it "measures link spans in chars, not bytes (multibyte paragraphs)" do
    white = Egui::Color32.rgba(255, 255, 255, 255)
    blue = Egui::Color32.rgba(102, 170, 255, 255)

    # README line 7 verbatim inside bold: "►" is 3 bytes but 1 char —
    # a byte-based span would shift by 2 and miss the hit test.
    rich = Egui::RichText.new("**[► WATCH DEMO](DEMO.md)** tail")
    rich.styled_runs(16.0, white, blue)
    span = rich.link_spans.first
    span.from.should eq(0)
    span.to.should eq("► WATCH DEMO".size) # 12 chars, not 14 bytes

    # README line 14 shape: multibyte "—" BEFORE the link shifts byte
    # offsets but not char offsets.
    rich2 = Egui::RichText.new("Crystal — inspired by [egui](https://github.com/emilk/egui)'s")
    rich2.styled_runs(16.0, white, blue)
    span2 = rich2.link_spans.first
    span2.from.should eq("Crystal — inspired by ".size) # 22 chars
    span2.to.should eq(span2.from + 4)
  end

  it "parses ~~strikethrough~~ (a lone ~ stays prose)" do
    runs = rich_runs("a ~~b~~ c ~ d")
    runs.map(&.text).should eq(["a ", "b", " c ~ d"])
    runs[1].strikethrough?.should be_true
    runs[2].strikethrough?.should be_false
  end

  it "keeps ~~nesting~~ inside emphasis" do
    runs = rich_runs("**gone ~~gone~~ still**")
    runs[0].bold?.should be_true
    runs[1].bold?.should be_true
    runs[1].strikethrough?.should be_true
  end

  it "renders an inline image as its alt text, not a link" do
    runs = rich_runs("an ![icon](img.png) in prose")
    runs.map(&.text).should eq(["an ", "icon", " in prose"])
    runs[1].underline?.should be_false
  end
end

describe "RichLabel widget" do
  it "emits one TextCmd per styled span with its flags" do
    ctx = Egui::Context.new
    rich_frame(ctx, [] of Egui::Event, 0.016) do |c|
      c.central_panel do |ui|
        ui.add(Egui::RichLabel.new("plain **bold** `code`"))
      end
    end

    texts = ctx.painter.commands.select(Egui::TextCmd)
    texts.map(&.text).should eq(["plain ", "bold", " ", "code"])
    texts[1].bold?.should be_true
    texts[3].family.should eq("monospace")
  end

  it "paints a strikethrough line through the run" do
    ctx = Egui::Context.new
    rich_frame(ctx, [] of Egui::Event, 0.016) do |c|
      c.central_panel do |ui|
        ui.add(Egui::RichLabel.new("kept ~~dropped~~ kept"))
      end
    end

    texts = ctx.painter.commands.select(Egui::TextCmd)
    texts.map(&.text).should eq(["kept ", "dropped", " kept"])
    lines = ctx.painter.commands.select(Egui::LineCmd)
    # a horizontal line roughly through the row's middle
    run = texts[1]
    lines.any? { |l|
      l.p1.y == l.p2.y &&
        l.p1.y > run.pos.y - 4.0 && l.p1.y < run.pos.y + 4.0
    }.should be_true
  end

  it "supports base decorations through Label#underline / #strikethrough" do
    ctx = Egui::Context.new
    rich_frame(ctx, [] of Egui::Event, 0.016) do |c|
      c.central_panel do |ui|
        l1 = Egui::Label.new("under"); l1.underline; ui.add(l1)
        l2 = Egui::Label.new("struck"); l2.strikethrough; ui.add(l2)
      end
    end

    lines = ctx.painter.commands.select(Egui::LineCmd)
    texts = ctx.painter.commands.select(Egui::TextCmd)
    lines.size.should eq(2) # one underline + one strike line
    # strike sits lower than the text center, underline near the bottom
    under, struck = texts[0], texts[1]
    y1, y2 = lines.map(&.p1.y).sort
    y1.should be < struck.pos.y # strike crosses the middle
    y2.should be > under.pos.y  # underline sits below center
  end

  it "shows the pointer cursor over a link span" do
    ctx = Egui::Context.new
    pos = nil
    draw = ->(events : Array(Egui::Event), time : Float64) {
      rich_frame(ctx, events, time) do |c|
        c.central_panel do |ui|
          pos = ui.add(Egui::RichLabel.new("see [docs](https://example.com)"))
            .rect.center
        end
      end
    }
    draw.call([] of Egui::Event, 0.016)
    ctx.cursor_icon.should eq(Egui::CursorIcon::Default)

    draw.call([Egui::Event.pointer_moved(pos.not_nil!)], 0.032)
    ctx.cursor_icon.should eq(Egui::CursorIcon::Pointer)
  end

  it "hit-tests links in multibyte paragraphs (README demo line)" do
    ctx = Egui::Context.new
    link_pos = nil
    draw = ->(events : Array(Egui::Event), time : Float64) {
      rich_frame(ctx, events, time) do |c|
        c.central_panel do |ui|
          ui.add(Egui::RichLabel.new(
            "**[► WATCH DEMO](DEMO.md)** — screenshots of everything below."))
        end
      end
      unless link_pos
        cmd = ctx.painter.commands.select(Egui::TextCmd)
          .find(&.text.==("► WATCH DEMO"))
        link_pos = cmd.try(&.pos)
      end
    }
    draw.call([] of Egui::Event, 0.016)
    link_pos.should_not be_nil

    draw.call([Egui::Event.pointer_moved(link_pos.not_nil!)], 0.032)
    ctx.cursor_icon.should eq(Egui::CursorIcon::Pointer)
  end

  it "selects a range on drag (highlight behind the text)" do
    ctx = Egui::Context.new
    label_rect = nil
    draw = ->(events : Array(Egui::Event), time : Float64) {
      rich_frame(ctx, events, time) do |c|
        c.central_panel do |ui|
          label_rect = ui.add(
            Egui::RichLabel.new("plain **bold** tail")).rect
        end
      end
    }
    draw.call([] of Egui::Event, 0.016)
    r = label_rect.not_nil!
    p1 = Egui::Pos2.new(r.left + 4.0, r.center.y)
    p2 = Egui::Pos2.new(r.left + r.width * 0.75, r.center.y)

    draw.call([Egui::Event.pointer_moved(p1)], 0.032)
    draw.call([Egui::Event.pointer_pressed(p1)], 0.048)
    draw.call([Egui::Event.pointer_moved(p2)], 0.064)

    fill = ctx.style.visuals.selection_fill
    ctx.painter.commands.select(Egui::RectCmd)
      .any?(&.fill.==(fill)).should be_true
  end
end
