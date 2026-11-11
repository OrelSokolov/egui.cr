# The CSS `border-radius` shorthand (Backgrounds & Borders §5.1):
# 1-4 space-separated radii expanded clockwise from top-left, carried
# through the style system as a `CornerRadii` value, resolved against
# the painted rect with the standard's corner-conflict rule
# (`CornerRadii#fit`), painted per corner by both backends (the fill
# through `RectCmd#corners`, the stroke through per-corner rings).

require "spec"
require "../src/egui"
require "../src/egui/html"

describe "CornerRadii.parse?" do
  it "expands the 1-4 value forms per the CSS standard" do
    Egui::CornerRadii.parse?("8").should eq Egui::CornerRadii.new(8, 8, 8, 8)
    Egui::CornerRadii.parse?("0 8").should eq Egui::CornerRadii.new(0, 8, 0, 8)
    Egui::CornerRadii.parse?("0 8 16").should eq Egui::CornerRadii.new(0, 8, 16, 8)
    Egui::CornerRadii.parse?("0 8 16 2").should eq Egui::CornerRadii.new(0, 8, 16, 2)
    Egui::CornerRadii.parse?("0 8px 16px 2px")
      .should eq Egui::CornerRadii.new(0, 8, 16, 2)
  end

  it "rejects the elliptical slash form and non-numbers" do
    Egui::CornerRadii.parse?("4 / 8").should be_nil
    Egui::CornerRadii.parse?("50%").should be_nil
    Egui::CornerRadii.parse?("a b").should be_nil
    Egui::CornerRadii.parse?("-4 8").should be_nil
    Egui::CornerRadii.parse?("1 2 3 4 5").should be_nil
  end

  it "spells back as the shorthand (uniform collapses to one number)" do
    Egui::CornerRadii.new(8, 8, 8, 8).to_s.should eq "8"
    Egui::CornerRadii.new(0, 8, 16, 2).to_s.should eq "0 8 16 2"
  end
end

describe "CornerRadii#fit" do
  rect = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(100.0, 20.0))

  it "scales overlapping radii proportionally (CSS §5.5)" do
    # Uniform 9999 on 100x20: f = 20/19998 → every corner 10 = h/2,
    # the capsule.
    fitted = Egui::CornerRadii.new(9999, 9999, 9999, 9999).fit(rect)
    fitted.top_left.should be_close 10.0, 1e-9
    fitted.uniform?.should be_true
    # 60/60 on top overlap horizontally (120 > 100), and each also
    # overflows the 20px height down its side — f = 20/60.
    fitted = Egui::CornerRadii.new(60, 60, 0, 0).fit(rect)
    fitted.top_left.should be_close 20.0, 1e-9
    fitted.top_right.should be_close 20.0, 1e-9
  end

  it "leaves non-overlapping radii untouched" do
    big = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(200.0, 60.0))
    c = Egui::CornerRadii.new(0, 8, 16, 2)
    c.fit(big).should eq c
  end
end

describe "ecss border-radius shorthand" do
  it "parses `rounding: 0 8 16 2` into a CornerRadii value" do
    doc = Egui::Ecss::Doc.parse(<<-ECSS)
      button {
        rounding: 0 8 16 2;
      }
    ECSS
    vars = doc.class_vars("button", nil).not_nil!
    vars.rounding_corners?("rounding", Egui::Rect.from_min_size(
      Egui::Pos2.zero, Egui::Vec2.new(200.0, 40.0)))
      .should eq Egui::CornerRadii.new(0, 8, 16, 2)
    # The scalar reader sees the largest corner (fit to the rect).
    vars.rounding_px("rounding", Egui::Rect.from_min_size(
      Egui::Pos2.zero, Egui::Vec2.new(200.0, 40.0)), 4.0).should eq 16.0
  end

  it "takes the CSS `border-radius` key spelling as the same key" do
    doc = Egui::Ecss::Doc.parse(<<-ECSS)
      button {
        border-radius: 0 8 16 2;
      }
    ECSS
    vars = doc.class_vars("button", nil).not_nil!
    vars.rounding_corners?("rounding", Egui::Rect.from_min_size(
      Egui::Pos2.zero, Egui::Vec2.new(200.0, 40.0)))
      .should eq Egui::CornerRadii.new(0, 8, 16, 2)
  end

  it "round-trips through format_value → parse" do
    c = Egui::CornerRadii.new(0, 8, 16, 2)
    Egui::Ecss::Doc.format_value(c).should eq "0 8 16 2"
    Egui::CornerRadii.parse?(Egui::Ecss::Doc.format_value(c))
      .should eq Egui::CornerRadii.new(0, 8, 16, 2)
    # Uniform stays the plain scalar spelling it always was.
    Egui::Ecss::Doc.format_value(Egui::CornerRadii.new(6, 6, 6, 6))
      .should eq "6"
  end

  it "keeps a scalar rounding a Float64 (the uniform path untouched)" do
    doc = Egui::Ecss::Doc.parse(<<-ECSS)
      button {
        rounding: 8;
      }
    ECSS
    vars = doc.class_vars("button", nil).not_nil!
    vars.f64?("rounding").should eq 8.0
    vars.rounding_corners?("rounding", Egui::Rect.from_min_size(
      Egui::Pos2.zero, Egui::Vec2.new(200.0, 40.0))).should be_nil
  end
end

describe "StyleVars#rounding_corners" do
  rect = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(200.0, 40.0))

  it "resolves scalars, capsule and per-corner values" do
    vars = Egui::StyleVars{"rounding" => Egui::CornerRadii.new(0, 8, 16, 2)}
    vars.rounding_corners("rounding", rect, 4.0)
      .should eq Egui::CornerRadii.new(0, 8, 16, 2)
    vars = Egui::StyleVars{"rounding" => 6.0}
    vars.rounding_corners("rounding", rect, 4.0)
      .should eq Egui::CornerRadii.new(6, 6, 6, 6)
    vars = Egui::StyleVars{"rounding" => "capsule"}
    vars.rounding_corners("rounding", rect, 4.0)
      .should eq Egui::CornerRadii.new(20, 20, 20, 20)
    vars = Egui::StyleVars.new
    vars.rounding_corners("rounding", rect, 4.0)
      .should eq Egui::CornerRadii.new(4, 4, 4, 4)
  end

  it "interpolates corner-wise between two shorthands" do
    a = Egui::CornerRadii.new(0, 8, 16, 2)
    b = Egui::CornerRadii.new(4, 8, 8, 8)
    mid = Egui::Keyframes.interpolate(a, b, 0.5).as(Egui::CornerRadii)
    mid.should eq Egui::CornerRadii.new(2, 8, 12, 5)
  end
end

describe "Html.box_style border-radius" do
  it "parses the multi-value form into per-corner params" do
    params = Egui::Html.box_style("border-radius: 0 8 16 2",
      Egui::Html::BoxParams.new)
    params.corners.should eq Egui::CornerRadii.new(0, 8, 16, 2)
    params.rounding.should be_nil
    # A single number stays the scalar it always was.
    params = Egui::Html.box_style("border-radius: 8px",
      Egui::Html::BoxParams.new)
    params.rounding.should eq 8.0
    params.corners.should be_nil
  end
end
