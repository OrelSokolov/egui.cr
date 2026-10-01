require "spec"
require "../src/egui"

MD_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 300.0))

def md_frame(ctx : Egui::Context, &app : Egui::Context ->)
  ctx.begin_frame(Egui::RawInput.new(MD_SCREEN, [] of Egui::Event, 0.016))
  yield ctx
  ctx.end_frame
end

describe "Markdown.parse" do
  it "splits headings, paragraphs and rules" do
    blocks = Egui::Markdown.parse(<<-MD)
      # Title

      first line
      soft-wrapped

      ---
    MD
    blocks.map(&.kind).should eq([:heading, :paragraph, :hr])
    blocks[0].text.should eq("Title")
    blocks[0].level.should eq(1)
    blocks[1].text.should eq("first line soft-wrapped")
  end

  it "captures fenced code verbatim, markers included" do
    blocks = Egui::Markdown.parse(<<-MD)
      text

      ```crystal
      a = 1 * 2
      # not a heading
      ```
      MD
    blocks.map(&.kind).should eq([:paragraph, :code])
    blocks[1].text.should eq("a = 1 * 2\n# not a heading")
  end

  it "parses list items with numbers and bullets" do
    blocks = Egui::Markdown.parse(<<-MD)
      - one
      * two

      1. first
      2. second
    MD
    blocks.map(&.kind).should eq([:list_item, :list_item, :list_item, :list_item])
    blocks[0].ordered?.should be_false
    blocks[2].ordered?.should be_true
    blocks[2].number.should eq(1)
    blocks[3].number.should eq(2)
  end

  it "strips the quote marker from blockquotes" do
    blocks = Egui::Markdown.parse("> quoted **bold** text")
    blocks.map(&.kind).should eq([:quote])
    blocks.first.text.should eq("quoted **bold** text")
  end

  it "keeps inline markup out of the block model (rendered later)" do
    blocks = Egui::Markdown.parse("para with **bold** inside")
    blocks.first.text.should eq("para with **bold** inside")
  end

  it "parses a standalone image line as an image block" do
    blocks = Egui::Markdown.parse("![widget gallery](screenshots/widgets-dark.png)")
    blocks.map(&.kind).should eq([:image])
    blocks.first.text.should eq("screenshots/widgets-dark.png")
    blocks.first.alt.should eq("widget gallery")
  end

  it "keeps an image inside prose inline (not an image block)" do
    blocks = Egui::Markdown.parse("see ![icon](img.png) here")
    blocks.map(&.kind).should eq([:paragraph])
    blocks.first.text.should eq("see ![icon](img.png) here")
  end

  it "parses an HTML <p align><img width></p> block" do
    blocks = Egui::Markdown.parse(<<-HTML)
      <p align="center">
        <img src="assets/icon.png" width="160" alt="egui-cr logo">
      </p>
      HTML
    blocks.map(&.kind).should eq([:image])
    img = blocks.first
    img.text.should eq("assets/icon.png")
    img.alt.should eq("egui-cr logo")
    img.width_px.should eq(160.0)
    img.align.should eq(:center)
  end

  it "parses GFM tables (header + separator + rows)" do
    blocks = Egui::Markdown.parse(<<-MD)
      | os | status |
      | --- | :---: |
      | linux | ✓ |
      | win | ✓ |
      MD
    blocks.map(&.kind).should eq([:table])
    rows = blocks.first.text.split('\n').map(&.split("\x1F"))
    rows.should eq([["os", "status"], ["linux", "✓"], ["win", "✓"]])
  end

  it "soft-wraps lazy continuation lines into the list item" do
    blocks = Egui::Markdown.parse(<<-MD)
      - item text that
        continues on the next source line
      - second item
      MD
    blocks.map(&.kind).should eq([:list_item, :list_item])
    blocks.first.text.should eq(
      "item text that continues on the next source line")
    blocks[1].text.should eq("second item")
  end

  it "ends the list at a blank line (next paragraph stays separate)" do
    blocks = Egui::Markdown.parse("- item\n  continued\n\nplain paragraph")
    blocks.map(&.kind).should eq([:list_item, :paragraph])
  end

  it "nests list items by leading indent (2 spaces per level)" do
    blocks = Egui::Markdown.parse(<<-MD)
      - outer
        - inner
          - deepest
      - back
      MD
    blocks.map(&.level).should eq([0, 1, 2, 0])
  end

  it "renders wrapped list-item lines indented right of the bullet" do
    ctx = Egui::Context.new
    md_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.markdown("- a lazy continuation item whose text\n" \
                    "  joined from two source lines and is long enough " \
                    "to wrap in this narrow panel for sure")
      end
    end

    texts = ctx.painter.commands.select(Egui::TextCmd)
    bullet = texts.find(&.text.==("•")).not_nil!
    body = texts.find(&.text.starts_with?("a lazy")).not_nil!
    body.pos.x.should be > bullet.pos.x + 3.0
    wrapped = texts.select { |t| t.pos.y > body.pos.y + 5.0 }
    wrapped.should_not be_empty
    wrapped.all? { |t| t.pos.x >= body.pos.x - 0.5 }.should be_true
  end
end

describe "Markdown widget" do
  it "renders a code block as a monospace block on a background rect" do
    ctx = Egui::Context.new
    md_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.markdown(<<-MD)
          ```crystal
          puts "hi"
          ```
          MD
      end
    end

    texts = ctx.painter.commands.select(Egui::TextCmd)
    texts.size.should eq(1)
    texts.first.text.should eq("puts \"hi\"")
    texts.first.family.should eq("monospace")

    rects = ctx.painter.commands.select(Egui::RectCmd)
    code_bg = ctx.style.visuals.fade_color(ctx.style.visuals.text_color, 0.12)
    rects.count(&.fill.==(code_bg)).should eq(1) # the code block background
  end

  it "renders headings bold and scaled, rules as separator lines" do
    ctx = Egui::Context.new
    md_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.markdown("# Head\n\n---")
      end
    end

    texts = ctx.painter.commands.select(Egui::TextCmd)
    texts.size.should eq(1)
    texts.first.text.should eq("Head")
    texts.first.bold?.should be_true
    texts.first.size.should be > ctx.style.font_size

    ctx.painter.commands.select(Egui::LineCmd)
      .any? { |l| l.p1.y == l.p2.y }.should be_true # the horizontal rule
  end

  it "renders list markers before item text" do
    ctx = Egui::Context.new
    md_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.markdown("- item one")
      end
    end

    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should eq(["•", "item one"])
  end

  it "stacks consecutive list items vertically (no overlap)" do
    ctx = Egui::Context.new
    md_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.markdown("- one\n- two\n- three")
      end
    end

    texts = ctx.painter.commands.select(Egui::TextCmd)
      .select { |t| {"one", "two", "three"}.includes?(t.text) }
    texts.size.should eq(3)
    ys = texts.map(&.pos.y)
    ys.should eq(ys.sort) # strictly top-to-bottom, one row each
    (ys[1] - ys[0]).should be > 10.0
    (ys[2] - ys[1]).should be > 10.0
  end

  it "renders inline markup inside paragraphs through RichLabel" do
    ctx = Egui::Context.new
    md_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.markdown("text with `code` inside")
      end
    end

    texts = ctx.painter.commands.select(Egui::TextCmd)
    texts.map(&.text).should eq(["text with ", "code", " inside"])
    texts[1].family.should eq("monospace")
  end

  it "degrades an unloadable image to a weak alt-text label (headless)" do
    ctx = Egui::Context.new
    md_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.markdown("![missing shot](no/such.png)", base_dir: "/tmp")
      end
    end

    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.join.should contain("[image: missing shot]")
    # no ImageCmd — nothing to draw without a real texture size
    ctx.painter.commands.select(Egui::ImageCmd).should be_empty
  end

  it "underlines H1/H2 with a rule below the heading" do
    ctx = Egui::Context.new
    md_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.markdown("# Big\n\n## Medium\n\n### Small")
      end
    end

    lines = ctx.painter.commands.select(Egui::LineCmd)
      .select { |l| l.p1.y == l.p2.y } # horizontal
    # two heading rules (+ nothing else horizontal for H3)
    lines.size.should eq(2)
  end

  it "hangs list items: text starts right of the bullet column" do
    ctx = Egui::Context.new
    md_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.markdown("- a long list item text that certainly wraps onto " \
                    "several lines because the panel is narrow and the " \
                    "text just keeps going and going and going")
      end
    end

    texts = ctx.painter.commands.select(Egui::TextCmd)
    bullet = texts.find(&.text.==("•")).not_nil!
    body = texts.find(&.text.starts_with?("a long")).not_nil!
    body.pos.x.should be > bullet.pos.x + 3.0
    # wrapped lines align to the text column, not to the bullet
    wrapped = texts.select { |t| t.pos.y > body.pos.y + 5.0 }
    wrapped.all? { |t| t.pos.x >= body.pos.x - 0.5 }.should be_true
  end

  it "renders tables as aligned columns with a header rule" do
    ctx = Egui::Context.new
    md_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.markdown("| name | status |\n| --- | --- |\n| linux | ✓ |")
      end
    end

    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    {"name", "status", "linux", "✓"}.each do |cell|
      texts.should contain(cell)
    end
    # the header rule under the header row
    ctx.painter.commands.select(Egui::LineCmd)
      .any? { |l| l.p1.y == l.p2.y }.should be_true
  end

  it "routes link clicks through #on_link with the raw target" do
    ctx = Egui::Context.new
    clicked = [] of String
    pos = nil
    draw = ->(events : Array(Egui::Event), time : Float64) {
      ctx.begin_frame(Egui::RawInput.new(MD_SCREEN, events, time))
      ctx.central_panel do |ui|
        widget = Egui::Markdown.new("**[WATCH DEMO](DEMO.md)**", base_dir: "/tmp")
        widget.on_link = ->(t : String) { clicked << t }
        pos = ui.add(widget).rect.center
      end
      ctx.end_frame
    }
    draw.call([] of Egui::Event, 0.016)
    draw.call([Egui::Event.pointer_moved(pos.not_nil!)], 0.032)
    draw.call([Egui::Event.pointer_pressed(pos.not_nil!)], 0.048)
    draw.call([Egui::Event.pointer_released(pos.not_nil!)], 0.064)

    clicked.should eq(["DEMO.md"])
  end
end
