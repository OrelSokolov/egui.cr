# `background-gradient` — the CSS-like gradient value: parse/eval,
# ECSS pipeline (parse, states, round-trip), raster smoke and the
# Button/box consumers.
require "spec"
require "../src/egui"

GRAD_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(800.0, 600.0))

private def rect_at(x : Float64, y : Float64, w : Float64, h : Float64) : Egui::Rect
  Egui::Rect.from_min_size(Egui::Pos2.new(x, y), Egui::Vec2.new(w, h))
end

describe "Gradient" do
  it "parses linear with deg angles and stop positions" do
    g = Egui::Gradient.parse?(
      "linear-gradient(135deg, #E92236, #571DC6 60%, #ffffffcc)").should_not be_nil
    g.kind.should eq :linear
    g.angle_deg.should eq 135.0
    g.stops.size.should eq 3
    # missing first/last positions default to 0/1, the explicit 60% stays
    g.stops[0].pos.should eq 0.0
    g.stops[1].pos.should eq 0.6
    g.stops[2].pos.should eq 1.0
    g.stops[0].color.should eq Egui::Color32.rgb(0xE9, 0x22, 0x36)
    g.stops[2].color.a.should eq 0xCC_u8
  end

  it "parses to-directions and the bare two-stop default" do
    to_br = Egui::Gradient.parse?("linear-gradient(to bottom right, #aabbcc, #001122)").should_not be_nil
    to_br.angle_deg.should eq 135.0
    plain = Egui::Gradient.parse?("linear-gradient(#abc, #bcd)").should_not be_nil
    plain.angle_deg.should eq 180.0 # CSS default: to bottom
    plain.stops.map(&.pos).should eq [0.0, 1.0]
  end

  it "distributes missing stop positions evenly (the CSS rule)" do
    g = Egui::Gradient.parse?(
      "linear-gradient(90deg, #abc 20%, #bcd, #cde, #def 80%)").should_not be_nil
    g.stops.map(&.pos.round(4)).should eq [0.2, 0.4, 0.6, 0.8]
  end

  it "parses radial with at %% center and extent keywords" do
    g = Egui::Gradient.parse?(
      "radial-gradient(circle at 30% 20%, #abc, #bcd 80%)").should_not be_nil
    g.kind.should eq :radial
    g.cx.should eq 0.3
    g.cy.should eq 0.2
    g.stops.map(&.pos.round(4)).should eq [0.0, 0.8]
    far = Egui::Gradient.parse?(
      "radial-gradient(ellipse farthest-side at 50% 50%, #abc, #bcd)").should_not be_nil
    far.extent.should eq :farthest_side
  end

  it "rejects malformed spellings" do
    Egui::Gradient.parse?("linear-gradient(90deg, #a)").should be_nil        # one stop
    Egui::Gradient.parse?("linear-gradient(banana, #abc, #b)").should be_nil   # bad direction
    Egui::Gradient.parse?("linear-gradient(90deg, red, #b)").should be_nil   # non-hex color
    Egui::Gradient.parse?("radial-gradient(circle)").should be_nil           # no stops
    Egui::Gradient.parse?("conic-gradient(#abc, #bcd)").should be_nil           # out of scope
    Egui::Gradient.parse?("#aabbcc").should be_nil
  end

  it "evaluates color_at along the axis (linear)" do
    r = rect_at(0, 0, 100, 100)
    down = Egui::Gradient.parse?("linear-gradient(#000000, #ffffff)").should_not be_nil
    down.color_at(50, 0.5, r).r.to_i.should be < 10       # top ≈ black
    down.color_at(50, 99.5, r).r.to_i.should be > 245     # bottom ≈ white
    down.color_at(50, 50, r).r.to_i.should be_close 128, 6

    diag = Egui::Gradient.parse?("linear-gradient(135deg, #000000, #ffffff)").should_not be_nil
    diag.color_at(1, 1, r).r.to_i.should be < 10          # TL ≈ first stop
    diag.color_at(98, 98, r).r.to_i.should be > 220       # BR ≈ last stop

    three = Egui::Gradient.parse?("linear-gradient(90deg, #000000, #808080, #ffffff)").should_not be_nil
    # 90deg = to right: middle of the rect ≈ the middle stop
    three.color_at(50, 50, r).r.to_i.should be_close 128, 6
  end

  it "evaluates color_at radially from the center" do
    r = rect_at(0, 0, 100, 100)
    g = Egui::Gradient.parse?("radial-gradient(circle at 50% 50%, #000000, #ffffff)").should_not be_nil
    g.color_at(50, 50, r).r.to_i.should be < 10                 # center = first stop
    # farthest corner from the center is the radius basis: t = 1 there
    g.color_at(0.5, 0.5, r).r.to_i.should be > 240
    g.color_at(99.5, 99.5, r).r.to_i.should be > 240
  end

  it "round-trips through the canonical spelling" do
    src = "linear-gradient(135deg, #E92236, #571DC6 60%, #ffffffcc)"
    g = Egui::Gradient.parse?(src).should_not be_nil
    again = Egui::Gradient.parse?(g.to_s).should_not be_nil
    again.kind.should eq g.kind
    again.angle_deg.should eq g.angle_deg
    again.stops.map(&.pos).should eq g.stops.map(&.pos)
    again.stops.map(&.color).should eq g.stops.map(&.color)

    rsrc = "radial-gradient(circle at 30% 20%, #112233, #445566 80%)"
    rg = Egui::Gradient.parse?(rsrc).should_not be_nil
    ragain = Egui::Gradient.parse?(rg.to_s).should_not be_nil
    ragain.cx.should eq rg.cx
    ragain.cy.should eq rg.cy
    ragain.stops.map(&.pos).should eq rg.stops.map(&.pos)
  end

  it "maps a plain two-stop to-bottom onto the legacy fast path" do
    g = Egui::Gradient.parse?("linear-gradient(#123456, #654321)").should_not be_nil
    pair = g.simple_vertical?.should_not be_nil
    pair[0].should eq Egui::Color32.rgb(0x12, 0x34, 0x56)
    pair[1].should eq Egui::Color32.rgb(0x65, 0x43, 0x21)
    Egui::Gradient.parse?("linear-gradient(90deg, #abc, #bcd)").not_nil!
      .simple_vertical?.should be_nil
  end
end

describe "ecss background-gradient" do
  it "parses into class rules and survives the doc round-trip" do
    src = <<-ECSS
      panel {
        background-gradient: linear-gradient(135deg, #E92236, #571DC6 60%);
      }
      panel:hover {
        background-gradient: radial-gradient(circle at 50% 0%, #6d28d9, #16161c);
      }
    ECSS
    doc = Egui::Ecss::Doc.parse(src)
    base = doc.class_vars("panel", nil).not_nil!
    g = base.gradient?("background-gradient").should_not be_nil
    g.kind.should eq :linear
    g.angle_deg.should eq 135.0
    hover = doc.class_vars("panel", "hover").not_nil!
    hg = hover.gradient?("background-gradient").should_not be_nil
    hg.kind.should eq :radial

    again = Egui::Ecss::Doc.parse(doc.to_s)
    rg = again.class_vars("panel", nil).not_nil!.gradient?("background-gradient").should_not be_nil
    rg.stops.map(&.pos.round(4)).should eq g.stops.map(&.pos)
    rg.stops.map(&.color).should eq g.stops.map(&.color)
  end

  it "ignores malformed gradients (lenient parse)" do
    doc = Egui::Ecss::Doc.parse(<<-ECSS)
      panel {
        background-gradient: linear-gradient(oops);
        background: #0d0d12;
      }
    ECSS
    vars = doc.class_vars("panel", nil).not_nil!
    vars.gradient?("background-gradient").should be_nil
    vars.color?("background").should_not be_nil
  end
end

describe "background-gradient raster (CPU reference)" do
  render = ->(cmd : Egui::RectCmd) do
    raster = Egui::Capybara::Raster.new(80, 80, Egui::Color32.rgb(0, 255, 0))
    raster.render([cmd])
    ->(x : Int32, y : Int32) : Egui::Color32 do
      i = (y * raster.width + x) * 4
      Egui::Color32.new(raster.pixels[i], raster.pixels[i + 1],
        raster.pixels[i + 2], raster.pixels[i + 3])
    end
  end
  full_clip = Egui::Rect.from_min_size(Egui::Pos2.new(-1e5, -1e5),
    Egui::Vec2.new(2e5, 2e5))
  r = rect_at(10, 10, 60, 60)

  it "paints a linear gradient corner to corner" do
    g = Egui::Gradient.parse?("linear-gradient(135deg, #000000, #ffffff)").should_not be_nil
    px = render.call(Egui::RectCmd.new(full_clip, r, 0.0, nil, nil, 0.0,
      gradient: g))
    px.call(11, 11).r.to_i.should be < 40
    px.call(68, 68).r.to_i.should be > 200
    mid = px.call(40, 40).r
    mid.should be > 90
    mid.should be < 170
  end

  it "paints gradient-only cmds (no fill) with stroke untouched" do
    g = Egui::Gradient.parse?("linear-gradient(#000000, #ffffff)").should_not be_nil
    cmd = Egui::RectCmd.new(full_clip, r, 0.0, nil,
      Egui::Color32.rgb(255, 0, 0), 2.0, gradient: g)
    px = render.call(cmd)
    px.call(40, 10).r.to_i.should be > 180 # stroke band at the top edge
    px.call(40, 20).r.to_i.should be < 100 # interior: the gradient, no stroke
  end

  it "matches the legacy fill/fill2 path for a two-stop to-bottom" do
    g = Egui::Gradient.parse?("linear-gradient(#123456, #654321)").should_not be_nil
    legacy = render.call(Egui::RectCmd.new(full_clip, r, 0.0,
      Egui::Color32.rgb(0x12, 0x34, 0x56), nil, 0.0,
      Egui::Color32.rgb(0x65, 0x43, 0x21)))
    modern = render.call(Egui::RectCmd.new(full_clip, r, 0.0, nil, nil, 0.0,
      gradient: g))
    max_diff = 0
    (10...70).each do |y|
      (10...70).each do |x|
        a = legacy.call(x, y)
        b = modern.call(x, y)
        max_diff = {max_diff,
                     (a.r.to_i - b.r.to_i).abs,
                     (a.g.to_i - b.g.to_i).abs,
                     (a.b.to_i - b.b.to_i).abs}.max
      end
    end
    max_diff.should be <= 2
  end

  it "paints radial from the center out" do
    g = Egui::Gradient.parse?(
      "radial-gradient(circle at 50% 50%, #000000, #ffffff)").should_not be_nil
    px = render.call(Egui::RectCmd.new(full_clip, r, 0.0, nil, nil, 0.0,
      gradient: g))
    px.call(40, 40).r.to_i.should be < 30
    px.call(11, 11).r.to_i.should be > 230
  end

  it "keeps rounded corners transparent outside the shape" do
    g = Egui::Gradient.parse?("linear-gradient(90deg, #ff0000, #0000ff)").should_not be_nil
    px = render.call(Egui::RectCmd.new(full_clip, r, 10.0, nil, nil, 0.0,
      gradient: g))
    px.call(11, 11).g.to_i.should be > 200 # the green background shows: corner cut
    px.call(40, 40).g.to_i.should be < 60   # interior is the gradient, not bg
    px.call(15, 40).r.to_i.should be > 200  # red end of the horizontal ramp
  end
end

describe "background-gradient consumers" do
  it "Button paints the sheet gradient (wins over the flat fill)" do
    grad = Egui::Gradient.parse?("linear-gradient(90deg, #E92236, #571DC6)").should_not be_nil
    app = GradButtonApp.new
    app.ctx.stylesheet.rule("button",
      Egui::StyleVars{"background-gradient" => grad})
    session = Egui::Capybara::Session.new(app, settle_frames: 0)
    session.step
    session.step
    painted = false
    session.commands.each do |cmd|
      next unless cmd.is_a?(Egui::RectCmd)
      if (g = cmd.gradient)
        g.should eq grad
        painted = true
      end
    end
    painted.should be_true
  end

  it "exml <box fill=gradient> parses into the gradient fill" do
    g = Egui::Exml.parse_box_color("linear-gradient(135deg, #aabbcc, #001122)")
    g.should be_a Egui::Gradient
    Egui::Exml.parse_box_color("#aabbcc").should be_a Egui::Color32
    Egui::Exml.parse_box_color("nope").should be_nil
  end
end

# A one-button app for the consumer spec above: its class rule carries
# the gradient, the app itself only renders the button.
class GradButtonApp < Egui::App
  def update(ctx : Egui::Context) : Nil
    ctx.window("w") { |ui| ui.button("Go") }
  end
end
