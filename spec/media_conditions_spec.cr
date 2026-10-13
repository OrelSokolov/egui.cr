# Этап 3 of plans/responsive-mobile.md: media conditions beyond
# width — orientation, min/max-height, pointer/hover — parsed from
# `@media` blocks and matched against the live viewport each frame.
require "spec"
require "../src/egui"

MEDIA_SCREEN = Egui::Rect.from_min_size(
  Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

private def media_frame(ctx : Egui::Context,
                        screen : Egui::Rect = MEDIA_SCREEN,
                        &app : Egui::Context ->)
  raw = Egui::RawInput.new(screen, [] of Egui::Event, 0.016)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

describe "media conditions" do
  it "parses orientation, height and pointer conditions" do
    c = Egui::MediaCond.parse("(orientation: portrait)").not_nil!
    c.matches?(800.0, 600.0).should be_false # landscape
    c.matches?(600.0, 800.0).should be_true

    c = Egui::MediaCond.parse("(orientation: landscape)").not_nil!
    c.matches?(800.0, 600.0).should be_true
    c.matches?(600.0, 800.0).should be_false
    # A square is landscape per CSS (w >= h).
    c.matches?(600.0, 600.0).should be_true

    c = Egui::MediaCond.parse("(min-height: 700px)").not_nil!
    c.matches?(800.0, 750.0).should be_true
    c.matches?(800.0, 650.0).should be_false

    c = Egui::MediaCond.parse("(pointer: coarse)").not_nil!
    c.matches?(800.0, 600.0, pointer_coarse: true).should be_true
    c.matches?(800.0, 600.0, pointer_coarse: false).should be_false

    c = Egui::MediaCond.parse("(hover: none)").not_nil!
    c.matches?(800.0, 600.0, pointer_coarse: true).should be_true
    c.matches?(800.0, 600.0, pointer_coarse: false).should be_false

    # Combinations bind with AND; width still parses alongside.
    c = Egui::MediaCond.parse(
      "(min-width: 600px) and (orientation: portrait)").not_nil!
    c.matches?(700.0, 900.0).should be_true
    c.matches?(700.0, 500.0).should be_false
    c.matches?(500.0, 900.0).should be_false

    # Unsupported features still reject the whole condition.
    Egui::MediaCond.parse("(print)").should be_nil
    Egui::MediaCond.parse("(aspect-ratio: 16/9)").should be_nil
    Egui::MediaCond.parse("(min-height: 400em)").should be_nil
  end

  it "@media orientation/height rules apply through the cascade" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("button", Egui::StyleVars{
      "width" => Egui::StyleLength.new(100.0, :percent),
    }, media: "(orientation: portrait)")
    ctx.stylesheet.rule("button", Egui::StyleVars{
      "width" => Egui::StyleLength.new(50.0, :percent),
    }, media: "(min-height: 700px)")

    portrait = Egui::Rect.from_min_size(
      Egui::Pos2.zero, Egui::Vec2.new(600.0, 900.0))
    landscape = Egui::Rect.from_min_size(
      Egui::Pos2.zero, Egui::Vec2.new(900.0, 600.0))

    widths = {} of String => Float64
    media_frame(ctx, landscape) do |c|
      c.central_panel do |ui|
        widths["landscape"] = ui.add(Egui::Button.new("OK")).rect.width
      end
    end
    media_frame(ctx, portrait) do |c|
      c.central_panel do |ui|
        widths["portrait"] = ui.add(Egui::Button.new("OK")).rect.width
      end
    end

    panel_w = nil
    media_frame(ctx, landscape) do |c|
      c.central_panel do |ui|
        panel_w = ui.max_rect.width
      end
    end
    # landscape: no rule matches → natural width; portrait (600 wide,
    # both rules match — the later min-height declaration wins per
    # source order) → 100% of the panel.
    widths["landscape"].should be < panel_w.not_nil! # natural, no rule
    widths["portrait"].should be > 0.0
    widths["portrait"].should_not eq(widths["landscape"])
  end

  it "pointer_coarse flips (pointer: coarse) rules live" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("button", Egui::StyleVars{"width" => 500.0},
      media: "(pointer: coarse)")

    width = nil
    media_frame(ctx) do |c|
      c.central_panel do |ui|
        width = ui.add(Egui::Button.new("OK")).rect.width
      end
    end
    width.not_nil!.should be < 500.0 # fine pointer — rule not active

    ctx.pointer_coarse = true
    media_frame(ctx) do |c|
      c.central_panel do |ui|
        width = ui.add(Egui::Button.new("OK")).rect.width
      end
    end
    width.not_nil!.should eq 500.0
  end

  it "ecss parses @media blocks with the new conditions" do
    doc = Egui::Ecss::Doc.parse(<<-'ECSS')
      @media (orientation: portrait) {
        button { width: 100%; }
      }
      @media (pointer: coarse) and (max-height: 500px) {
        button { min_width: 48; }
      }
    ECSS
    buckets = doc.media
    buckets.size.should eq 2
    buckets[0][0].to_s.should eq "(orientation: portrait)"
    buckets[1][0].to_s.should eq "(max-height: 500px) and (pointer: coarse)"
    buckets[0][1]["button"].not_nil!
      .vars["width"].should eq Egui::StyleLength.new(100.0, :percent)
    # Round-trip keeps the spelling.
    once = doc.to_s
    Egui::Ecss::Doc.parse(once).to_s.should eq(once)
  end
end
