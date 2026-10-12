# Media conditions in the style cascade — the CSS
# `@media (min-width: …)` analog: rules gated on the viewport width
# (logical points), applied between the class and state layers.
require "spec"
require "../src/egui"

describe "media conditions" do
  it "MediaCond parses min/max (and combinations, screen prefix)" do
    c = Egui::MediaCond.parse("(min-width: 600px)").should_not be_nil
    c.min_width.should eq(600.0)
    c.max_width.should be_nil
    c.matches?(599.0).should be_false
    c.matches?(600.0).should be_true # inclusive, like CSS

    c2 = Egui::MediaCond.parse("screen and (max-width: 899px)").should_not be_nil
    c2.min_width.should be_nil
    c2.max_width.should eq(899.0)
    c2.matches?(899.0).should be_true
    c2.matches?(900.0).should be_false

    c3 = Egui::MediaCond.parse(
      "(min-width: 600px) and (max-width: 899px)").should_not be_nil
    c3.matches?(700.0).should be_true
    c3.matches?(500.0).should be_false
    c3.matches?(1000.0).should be_false

    # to_s round-trips through parse
    again = Egui::MediaCond.parse(c3.to_s).should_not be_nil
    again.min_width.should eq(600.0)
    again.max_width.should eq(899.0)

    # unsupported conditions are nil (caller warns and drops)
    Egui::MediaCond.parse("(orientation: landscape)").should be_nil
    Egui::MediaCond.parse("print").should be_nil
  end

  it "a matching media rule overrides the class defaults" do
    sheet = Egui::StyleSheet.new
    sheet.rule("button", Egui::StyleVars{"padding.top" => 4.0})
    sheet.rule("button", Egui::StyleVars{"padding.top" => 10.0},
               media: "(max-width: 600px)")

    sheet.viewport_width = 400.0
    sheet.resolve("button").f64("padding.top", 0.0).should eq(10.0)

    sheet.viewport_width = 1200.0
    sheet.resolve("button").f64("padding.top", 0.0).should eq(4.0)
  end

  it "a state rule still beats a media class rule (CSS specificity)" do
    sheet = Egui::StyleSheet.new
    sheet.rule("button", Egui::StyleVars{"background" => Egui::Color32.rgb(1, 1, 1)})
    sheet.rule("button:hover", Egui::StyleVars{"background" => Egui::Color32.rgb(2, 2, 2)})
    sheet.rule("button", Egui::StyleVars{"background" => Egui::Color32.rgb(9, 9, 9)},
               media: "(max-width: 600px)")

    sheet.viewport_width = 400.0
    sheet.resolve("button").color("background", Egui::Color32.rgb(0, 0, 0))
      .should eq(Egui::Color32.rgb(9, 9, 9)) # media beats class
    sheet.resolve("button", "hover").color("background", Egui::Color32.rgb(0, 0, 0))
      .should eq(Egui::Color32.rgb(2, 2, 2)) # state beats media
  end

  it "a media state rule beats the plain state layer" do
    sheet = Egui::StyleSheet.new
    sheet.rule("button:hover", Egui::StyleVars{"background" => Egui::Color32.rgb(2, 2, 2)})
    sheet.rule("button:hover", Egui::StyleVars{"background" => Egui::Color32.rgb(3, 3, 3)},
               media: "(max-width: 600px)")

    sheet.viewport_width = 400.0
    sheet.resolve("button", "hover").color("background", Egui::Color32.rgb(0, 0, 0))
      .should eq(Egui::Color32.rgb(3, 3, 3))

    sheet.viewport_width = 800.0
    sheet.resolve("button", "hover").color("background", Egui::Color32.rgb(0, 0, 0))
      .should eq(Egui::Color32.rgb(2, 2, 2))
  end

  it "media rules apply along the class chain (button -> sidebar.button)" do
    # resolve() alone never crosses into "button" from "sidebar.button"
    # (same as plain class rules) — the chain form pulls both layers,
    # media included.
    sheet = Egui::StyleSheet.new
    sheet.rule("button", Egui::StyleVars{"padding.top" => 4.0})
    sheet.rule("button", Egui::StyleVars{"padding.top" => 10.0},
               media: "(max-width: 600px)")
    sheet.viewport_width = 400.0
    sheet.resolve_chain(["button", "sidebar.button"])
      .f64("padding.top", 0.0).should eq(10.0)
  end

  it "width changes inside a breakpoint band keep the resolve cache" do
    sheet = Egui::StyleSheet.new
    sheet.rule("button", Egui::StyleVars{"padding.top" => 10.0},
               media: "(max-width: 600px)")
    sheet.viewport_width = 300.0
    bag = sheet.resolve("button")
    sheet.viewport_width = 500.0 # still mobile, no flip
    sheet.resolve("button").should be(bag) # same cached object
    sheet.viewport_width = 700.0 # flip -> fresh bag
    sheet.resolve("button").f64?("padding.top").should be_nil
  end

  it "unset removes a key from the media rule only" do
    sheet = Egui::StyleSheet.new
    sheet.rule("button", Egui::StyleVars{"padding.top" => 4.0})
    sheet.rule("button", Egui::StyleVars{"padding.top" => 10.0},
               media: "(max-width: 600px)")
    sheet.unset("button", "padding.top", media: "(max-width: 600px)")
    sheet.viewport_width = 400.0
    sheet.resolve("button").f64("padding.top", 0.0).should eq(4.0)
  end

  it ".ecss @media blocks parse, apply through the cascade, round-trip" do
    doc = Egui::Ecss::Doc.parse(<<-ECSS)
      button { padding.top: 4.0; }
      @media (max-width: 600px) {
        button { padding.top: 10.0; }
        button:active { background: #ff0000ff; }
      }
      ECSS
    doc.media.size.should eq(1)
    cond, classes = doc.media.first
    cond.max_width.should eq(600.0)
    classes.has_key?("button").should be_true

    # round-trip: the serialized form parses back to the same shape
    text = doc.to_s
    again = Egui::Ecss::Doc.parse(text)
    again.media.size.should eq(1)
    again.media.first[1]["button"].vars["padding.top"].should eq(10.0)
    text.should contain("@media (max-width: 600px) {")
  end

  it "Context#begin_frame feeds the viewport width to the theme sheet" do
    ctx = Egui::Context.new
    rect = Egui::Rect.from_min_size(Egui::Pos2.zero,
      Egui::Vec2.new(450.0, 800.0))
    ctx.begin_frame(Egui::RawInput.new(rect, [] of Egui::Event, 0.0))
    ctx.stylesheet.viewport_width.should eq(450.0)
  end

  it "the default theme sizes buttons up on phone widths" do
    sheet = Egui::Theme.dark.sheet
    sheet.viewport_width = 400.0
    pad = sheet.resolve("button").box("padding")
    (pad.vertical + 15.0).should be >= 40.0 # font 15 + padding >= 40pt hit target
    sheet.resolve("button").f64("rounding", 4.0).should eq(8.0)

    sheet.viewport_width = 1200.0
    sheet.resolve("button").f64("rounding", 4.0).should eq(4.0)
  end
end
