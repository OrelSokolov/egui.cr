require "spec"
require "../src/egui"

LINK_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 300.0))

def link_frame(ctx : Egui::Context, events : Array(Egui::Event), time : Float64,
               &app : Egui::Context ->)
  raw = Egui::RawInput.new(LINK_SCREEN, events, time)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

# The link widget paints through the CSS-like `link` class: HTML <a>
# semantics — underlined and hyperlink-colored by default, recolored on
# hover/active the way a button fill is, `#underline(false)` the CSS
# `text-decoration: none`.
describe "hyperlink" do
  it "is underlined with the hyperlink color by default" do
    ctx = Egui::Context.new
    link_frame(ctx, [] of Egui::Event, 0.016) do |c|
      c.central_panel do |ui|
        ui.hyperlink_to("docs", "https://example.com", id: "l")
      end
    end

    color = ctx.style.visuals.hyperlink_color
    texts = ctx.painter.commands.select(Egui::TextCmd)
    texts.select(&.text.includes?("docs")).first.color.should eq(color)
    # the underline is a 1px line under the run, painted in run color
    lines = ctx.painter.commands.select(Egui::LineCmd)
    lines.any? { |l| l.color == color }.should be_true
  end

  it "recolors on hover through the link:hover rule" do
    ctx = Egui::Context.new
    pos = nil
    draw = ->(events : Array(Egui::Event), time : Float64) {
      link_frame(ctx, events, time) do |c|
        c.central_panel do |ui|
          pos = ui.hyperlink_to("docs", "https://example.com", id: "l").rect.center
        end
      end
    }
    draw.call([] of Egui::Event, 0.016)
    draw.call([Egui::Event.pointer_moved(pos.not_nil!)], 0.032)

    base = ctx.style.visuals.hyperlink_color
    hover = ctx.stylesheet.resolve("link", "hover").color?("text_color").not_nil!
    hover.should_not eq(base)
    texts = ctx.painter.commands.select(Egui::TextCmd)
    texts.select(&.text.includes?("docs")).first.color.should eq(hover)
  end

  it "recolors on active through the link:active rule" do
    ctx = Egui::Context.new
    pos = nil
    draw = ->(events : Array(Egui::Event), time : Float64) {
      link_frame(ctx, events, time) do |c|
        c.central_panel do |ui|
          pos = ui.hyperlink_to("docs", "https://example.com", id: "l").rect.center
        end
      end
    }
    draw.call([] of Egui::Event, 0.016)
    draw.call([Egui::Event.pointer_moved(pos.not_nil!),
               Egui::Event.pointer_pressed(pos.not_nil!)], 0.032)

    active = ctx.stylesheet.resolve("link", "active").color?("text_color").not_nil!
    texts = ctx.painter.commands.select(Egui::TextCmd)
    texts.select(&.text.includes?("docs")).first.color.should eq(active)
  end

  it "drops the underline via #underline(false) but keeps the color" do
    ctx = Egui::Context.new
    link_frame(ctx, [] of Egui::Event, 0.016) do |c|
      c.central_panel do |ui|
        ui.add(Egui::Hyperlink.new("docs", "https://example.com", id: "l")
          .underline(false))
      end
    end

    color = ctx.style.visuals.hyperlink_color
    texts = ctx.painter.commands.select(Egui::TextCmd)
    texts.select(&.text.includes?("docs")).first.color.should eq(color)
    ctx.painter.commands.select(Egui::LineCmd)
      .any? { |l| l.color == color }.should be_false
  end

  it "re-enables the underline per-state via a stylesheet rule" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("link", Egui::StyleVars{"underline" => false})
    ctx.stylesheet.rule("link:hover", Egui::StyleVars{"underline" => true})
    pos = nil
    draw = ->(events : Array(Egui::Event), time : Float64) {
      link_frame(ctx, events, time) do |c|
        c.central_panel do |ui|
          pos = ui.hyperlink_to("docs", "https://example.com", id: "l").rect.center
        end
      end
    }
    draw.call([] of Egui::Event, 0.016)
    color = ctx.style.visuals.hyperlink_color
    ctx.painter.commands.select(Egui::LineCmd)
      .any? { |l| l.color == color }.should be_false

    draw.call([Egui::Event.pointer_moved(pos.not_nil!)], 0.032)
    hover_color = ctx.stylesheet.resolve("link", "hover")
      .color?("text_color").not_nil!
    ctx.painter.commands.select(Egui::LineCmd)
      .any? { |l| l.color == hover_color }.should be_true
  end
end
