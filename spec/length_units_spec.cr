# Этап 1 of plans/responsive-mobile.md: unit lengths in ECSS —
# parsing (`50%`, `10vw`, `4vmin`, `1.5rem`, `12px` = plain points),
# serialization round-trip, and resolution against the containing Ui
# (percent of max_rect — minus item_spacing in horizontal rows —
# viewport units against `screen_rect`, rem against the root font).
require "spec"
require "../src/egui"

LENGTH_SCREEN = Egui::Rect.from_min_size(
  Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

private def length_frame(ctx : Egui::Context, &app : Egui::Context ->)
  raw = Egui::RawInput.new(LENGTH_SCREEN, [] of Egui::Event, 0.016)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

describe "style length units" do
  it "parses unit suffixes, keeps plain numbers as points" do
    doc = Egui::Ecss::Doc.parse(<<-ECSS)
      button {
        width: 50%;
        min_width: 10vw;
        height: 4vmin;
        max_width: 25vh;
        padding: 1.5rem;
        font_size: 12px;
        rounding: 6;
      }
    ECSS
    vars = doc.class_vars("button", nil).not_nil!
    vars["width"].should eq Egui::StyleLength.new(50.0, :percent)
    vars["min_width"].should eq Egui::StyleLength.new(10.0, :vw)
    vars["height"].should eq Egui::StyleLength.new(4.0, :vmin)
    vars["max_width"].should eq Egui::StyleLength.new(25.0, :vh)
    vars["padding"].should eq Egui::StyleLength.new(1.5, :rem)
    vars["font_size"].should eq 12.0 # px — the default unit, back-compat
    vars["rounding"].should eq 6.0   # a bare number stays a number
  end

  it "round-trips unit values through serialize → parse" do
    once = Egui::Ecss::Doc.parse(
      "button { width: 50%; min_width: 10vw; padding: 1.5rem; }"
    ).to_s
    twice = Egui::Ecss::Doc.parse(once).to_s
    twice.should eq once
    twice.should contain("width: 50%;")
    twice.should contain("min_width: 10vw;")
    twice.should contain("padding: 1.5rem;")
  end

  it "StyleVars#length_px resolves units against the containing Ui" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("paneltest", Egui::StyleVars{
      "a" => Egui::StyleLength.new(50.0, :percent),
      "b" => Egui::StyleLength.new(10.0, :vw),
      "c" => Egui::StyleLength.new(25.0, :vh),
      "d" => Egui::StyleLength.new(10.0, :vmin),
      "e" => Egui::StyleLength.new(10.0, :vmax),
      "f" => Egui::StyleLength.new(2.0, :rem),
      "g" => 42.0,
      "h" => Egui::Color32.rgb(0, 0, 0),
    })

    results = nil
    panel_rect = nil
    length_frame(ctx) do |c|
      c.central_panel do |ui|
        panel_rect = ui.max_rect
        vars = ctx.stylesheet.resolve("paneltest")
        results = {
          a: vars.length_px?("a", ui),
          b: vars.length_px?("b", ui),
          c: vars.length_px?("c", ui),
          d: vars.length_px?("d", ui),
          e: vars.length_px?("e", ui),
          f: vars.length_px?("f", ui),
          g: vars.length_px?("g", ui),
          h: vars.length_px?("h", ui),
          z: vars.length_px?("z", ui),
        }
      end
    end

    r = results.not_nil!
    rect = panel_rect.not_nil!
    # % of the panel's max_rect (vertical layout — no spacing taken).
    r[:a].should eq rect.width / 2.0
    # viewport: 800x600
    r[:b].should eq 80.0
    r[:c].should eq 150.0
    r[:d].should eq 60.0  # min side
    r[:e].should eq 80.0  # max side
    # rem: the default theme's root font size × 2
    r[:f].should eq 2.0 * ctx.style.font_size
    r[:g].should eq 42.0  # plain number passes through
    r[:h].should be_nil   # non-length values read as unset
    r[:z].should be_nil   # missing keys too
  end

  it "percent in a horizontal row splits the row exactly for a 50/50 pair" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("w", Egui::StyleVars{"width" =>
      Egui::StyleLength.new(50.0, :percent)})

    widths = [] of Float64
    row_w = nil
    length_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.horizontal do |row|
          row_w = row.max_rect.width
          2.times do
            vars = ctx.stylesheet.resolve("w")
            w = vars.length_px?("width", row)
            widths << w.not_nil!
            row.add(Egui::Label.new("x"))
          end
        end
      end
    end

    # Both widgets resolve to the SAME (W − spacing)/2 — the second
    # one's remaining space is exactly that number, so a 50/50 pair
    # tiles the row without the second one being clamped narrower.
    widths[0].should eq widths[1]
    spacing = ctx.style.spacing.item_spacing.x
    widths[0].should eq (row_w.not_nil! - spacing) / 2.0
  end

  it "percent height in an unbounded region resolves to nil (fallback)" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("paneltest", Egui::StyleVars{
      "y" => Egui::StyleLength.new(50.0, :percent)})

    bounded = nil
    unbounded = nil
    panel_h = nil
    length_frame(ctx) do |c|
      c.central_panel do |ui|
        panel_h = ui.max_rect.height
        vars = ctx.stylesheet.resolve("paneltest")
        bounded = vars.length_px?("y", ui, axis: :y)
        ui.frame do |inner| # frames hand out ~1e6-high inner rects
          unbounded = vars.length_px?("y", inner, axis: :y, )
        end
      end
    end

    bounded.not_nil!.should eq panel_h.not_nil! / 2.0 # half the panel
    unbounded.should be_nil
  end

  it "@media width conditions stay strict about units" do
    Egui::MediaCond.parse("(min-width: 600px)").should_not be_nil
    Egui::MediaCond.parse("(min-width: 600)").should_not be_nil
    # Unit garbage no longer silently parses as 600 — the whole
    # condition is rejected (the caller warns and drops the block).
    Egui::MediaCond.parse("(min-width: 600em)").should be_nil
    Egui::MediaCond.parse("(min-width: 600dpi)").should be_nil
  end
end
