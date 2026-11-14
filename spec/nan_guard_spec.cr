# NaN guards (src/egui/math.cr): the framework's math must never
# produce or propagate NaN silently, and must never fail with the
# opaque ArgumentError that `{a, b}.min` throws from deep inside
# Enumerable. Every guard aborts with an explicit Egui::NaNError that
# names the operation and the operands.
require "spec"
require "../src/egui"

NAN = Float64::NAN
INF = Float64::INFINITY

private def nan_rect(x = NAN, y = NAN)
  Egui::Rect.new(Egui::Pos2.new(x, y), Egui::Pos2.new(x + 10.0, y + 10.0))
end

describe "NaN guards" do
  it "finite geometry passes through untouched" do
    a = Egui::Rect.from_min_size(Egui::Pos2.new(0.0, 0.0), Egui::Vec2.new(10.0, 20.0))
    b = Egui::Rect.from_min_size(Egui::Pos2.new(5.0, -5.0), Egui::Vec2.new(10.0, 10.0))
    a.union(b).should eq Egui::Rect.new(Egui::Pos2.new(0.0, -5.0), Egui::Pos2.new(15.0, 20.0))
    a.intersect(b).should eq Egui::Rect.new(Egui::Pos2.new(5.0, 0.0), Egui::Pos2.new(10.0, 5.0))
    Egui::Vec2.new(1.0, 2.0).min(Egui::Vec2.new(3.0, 0.5)).should eq Egui::Vec2.new(1.0, 0.5)
    Egui::Vec2.new(1.0, 2.0).max(Egui::Vec2.new(3.0, 0.5)).should eq Egui::Vec2.new(3.0, 2.0)
  end

  it "Rect.infinite keeps finite extents (no false positive)" do
    r = Egui::Rect.infinite
    r.width.should eq 2e9
    r.height.should eq 2e9
    r.nan?.should be_false
  end

  it "Rect#union raises Egui::NaNError naming the operation (NaN in self)" do
    expect_raises(Egui::NaNError, /Rect#union.*NaN operand.*self=Rect\(Pos2\(NaN/) do
      nan_rect.union(Egui::Rect.zero)
    end
  end

  it "Rect#union raises Egui::NaNError naming the other operand" do
    expect_raises(Egui::NaNError, /other=Rect\(Pos2\(NaN/) do
      Egui::Rect.zero.union(nan_rect)
    end
  end

  it "Rect#intersect raises Egui::NaNError" do
    expect_raises(Egui::NaNError, /Rect#intersect/) do
      nan_rect(x: 1.0).intersect(Egui::Rect.zero)
    end
  end

  it "Vec2#min / #max raise Egui::NaNError" do
    expect_raises(Egui::NaNError, /Vec2#min/) do
      Egui::Vec2.new(NAN, 1.0).min(Egui::Vec2.new(0.0, 0.0))
    end
    expect_raises(Egui::NaNError, /Vec2#max/) do
      Egui::Vec2.new(0.0, 0.0).max(Egui::Vec2.new(1.0, NAN))
    end
  end

  it "Rect#width raises at the Inf - Inf NaN birth, not later" do
    degenerate = Egui::Rect.new(Egui::Pos2.new(INF, 0.0), Egui::Pos2.new(INF, 10.0))
    expect_raises(Egui::NaNError, /Rect#width: non-finite value/) { degenerate.width }
    degenerate.height.should eq 10.0 # the healthy axis still reads fine
  end

  it "Rect#width/height reject a bare Inf extent before it becomes Inf - Inf" do
    inf_wide = Egui::Rect.new(Egui::Pos2.new(0.0, 0.0), Egui::Pos2.new(INF, 10.0))
    expect_raises(Egui::NaNError, /Rect#width: non-finite value/) { inf_wide.width }
    inf_tall = Egui::Rect.new(Egui::Pos2.new(0.0, 0.0), Egui::Pos2.new(10.0, INF))
    expect_raises(Egui::NaNError, /Rect#height: non-finite value/) { inf_tall.height }
  end

  it "Rect#height raises at the NaN birth" do
    degenerate = Egui::Rect.new(Egui::Pos2.new(0.0, -INF), Egui::Pos2.new(10.0, -INF))
    expect_raises(Egui::NaNError, /Rect#height/) { degenerate.height }
  end

  it "a NaN coordinate is caught by extent guards too" do
    r = Egui::Rect.new(Egui::Pos2.new(NAN, 0.0), Egui::Pos2.new(10.0, 10.0))
    expect_raises(Egui::NaNError, /Rect#width/) { r.width }
  end

  it "nan? predicates cover every component" do
    Egui::Vec2.new(0.0, NAN).nan?.should be_true
    Egui::Vec2.new(0.0, 1.0).nan?.should be_false
    Egui::Pos2.new(NAN, 0.0).nan?.should be_true
    Egui::Rect.new(Egui::Pos2.new(0.0, 0.0), Egui::Pos2.new(1.0, NAN)).nan?.should be_true
    Egui::Rect.zero.nan?.should be_false
  end
end
