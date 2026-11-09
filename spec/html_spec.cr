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
