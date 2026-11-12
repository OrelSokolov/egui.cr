# CSS `transform` (full 2D affine — Egui::Affine2 / CssTransform):
# parsing, painter stamping (rotated commands carry `#xform` instead of
# an axis-aligned rewrite), ecss cascade, and the Ui#box application
# (paint-only — clip rects and hit-testing stay in place, appear
# semantics).
require "spec"
require "../src/egui"

XF_SCREEN = Egui::Rect.from_min_size(
  Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

private def xf_frame(ctx : Egui::Context, t : Float64,
                     events : Array(Egui::Event) = [] of Egui::Event,
                     &app : Egui::Context ->)
  raw = Egui::RawInput.new(XF_SCREEN, events, t)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

describe "Affine2" do
  it "composes matrix multiply (self ∘ other)" do
    rot = Egui::Affine2.rotation(Math::PI / 2, Egui::Pos2.zero)
    move = Egui::Affine2.new(1.0, 0.0, 0.0, 1.0, 10.0, 0.0)
    # rotate first, then translate: (1,0) → (0,1) → (10,1)
    p = move.compose(rot) * Egui::Pos2.new(1.0, 0.0)
    p.x.should be_close 10.0, 1e-9
    p.y.should be_close 1.0, 1e-9
  end

  it "rotation around a pivot" do
    pivot = Egui::Pos2.new(5.0, 5.0)
    rot = Egui::Affine2.rotation(Math::PI, pivot)
    p = rot * Egui::Pos2.new(6.0, 5.0)
    p.x.should be_close 4.0, 1e-9
    p.y.should be_close 5.0, 1e-9
  end

  it "lerps entry-wise" do
    a = Egui::Affine2.new(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
    b = Egui::Affine2.new(2.0, 0.0, 0.0, 3.0, 10.0, -10.0)
    m = a.lerp(b, 0.25)
    m.a.should eq 1.25
    m.d.should eq 1.5
    m.e.should eq 2.5
    m.f.should eq -2.5
  end
end

describe "CssTransform.parse?" do
  it "parses the function list left-to-right" do
    t = Egui::CssTransform.parse?("rotate(90deg) translateY(-6px)").should_not be_nil
    xf = t.resolve(100.0, 50.0)
    # CSS applies the list left-to-right as matrix multiply: M = R·T,
    # so the point sees the TRANSLATE first, then the rotation —
    # (1,0) → translate → (1,-6) → rotate90 → (6,1).
    p = xf * Egui::Pos2.new(1.0, 0.0)
    p.x.should be_close 6.0, 1e-9
    p.y.should be_close 1.0, 1e-9
  end

  it "resolves percentage translate against the element size" do
    t = Egui::CssTransform.parse?("translate(10%, 20%)").not_nil!
    xf = t.resolve(200.0, 100.0)
    xf.e.should eq 20.0
    xf.f.should eq 20.0
  end

  it "parses skew / scale / matrix / rad / turn" do
    Egui::CssTransform.parse?("skewX(10deg) scale(1.2)").should_not be_nil
    Egui::CssTransform.parse?("skew(10deg, -4deg)").should_not be_nil
    Egui::CssTransform.parse?("matrix(1, 0.2, -0.2, 1, 5, 5)").should_not be_nil
    t = Egui::CssTransform.parse?("rotate(0.5turn)").not_nil!
    (t.resolve * Egui::Pos2.new(1.0, 0.0)).y.should be_close 0.0, 1e-9
    t2 = Egui::CssTransform.parse?("rotate(1.5707963267948966rad)").not_nil!
    (t2.resolve * Egui::Pos2.new(1.0, 0.0)).y.should be_close 1.0, 1e-6
  end

  it "none / garbage → nil" do
    Egui::CssTransform.parse?("none").should be_nil
    Egui::CssTransform.parse?("rotate(").should be_nil
    Egui::CssTransform.parse?("flip(10deg)").should be_nil
  end
end

describe "TransformOrigin.parse?" do
  it "keywords, percents, px" do
    Egui::TransformOrigin.parse?("center").not_nil!.resolve(
      Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(100.0, 50.0))
    ).should eq Egui::Pos2.new(50.0, 25.0)
    Egui::TransformOrigin.parse?("top left").not_nil!.resolve(
      Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(100.0, 50.0))
    ).should eq Egui::Pos2.new(0.0, 0.0)
    Egui::TransformOrigin.parse?("25% 75%").not_nil!.resolve(
      Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(100.0, 50.0))
    ).should eq Egui::Pos2.new(25.0, 37.5)
    Egui::TransformOrigin.parse?("10px 20px").not_nil!.resolve(
      Egui::Rect.from_min_size(Egui::Pos2.new(5.0, 5.0), Egui::Vec2.new(100.0, 50.0))
    ).should eq Egui::Pos2.new(15.0, 25.0)
  end
end

describe "painter affine bracket" do
  it "axis-aligned affine still rewrites on the CPU" do
    p = Egui::Painter.new
    p.push_affine(Egui::Pos2.new(0.0, 0.0),
      Egui::CssTransform.parse?("translate(10px, 20px) scale(2)").not_nil!.resolve)
    p.rect(Egui::Rect.from_min_size(Egui::Pos2.new(10.0, 10.0),
      Egui::Vec2.new(10.0, 10.0)), 2.0, fill: Egui::Color32.rgb(1, 2, 3))
    p.pop_transform
    r = p.commands[0].as(Egui::RectCmd)
    r.xform.should be_nil # CPU path — no stamp
    r.rect.min.x.should eq 30.0
    r.rect.width.should eq 20.0
  end

  it "rotation stamps the affine and fades, geometry untouched" do
    p = Egui::Painter.new
    p.push_affine(Egui::Pos2.new(50.0, 50.0),
      Egui::Affine2.rotation(Math::PI / 4, Egui::Pos2.new(50.0, 50.0)),
      opacity: 0.5)
    p.rect(Egui::Rect.from_min_size(Egui::Pos2.new(40.0, 40.0),
      Egui::Vec2.new(20.0, 20.0)), 4.0, fill: Egui::Color32.rgb(200, 100, 50))
    p.text(Egui::Pos2.new(50.0, 50.0), "hi", 20.0,
      Egui::Color32.rgb(255, 255, 255))
    p.pop_transform

    r = p.commands[0].as(Egui::RectCmd)
    xf = r.xform.not_nil!
    xf.b.should be_close(Math.sin(Math::PI / 4), 1e-9)
    r.rect.min.x.should eq 40.0 # geometry NOT rewritten CPU-side
    r.rect.width.should eq 20.0
    r.fill.not_nil!.a.should eq 128 # fade still CPU-side

    t = p.commands[1].as(Egui::TextCmd)
    t.xform.should_not be_nil
    t.pos.should eq Egui::Pos2.new(50.0, 50.0)
    t.size.should eq 20.0
  end

  it "an outer axis-aligned frame composes into an existing stamp" do
    p = Egui::Painter.new
    # inner: rotate 90° around origin
    p.push_affine(Egui::Pos2.new(0.0, 0.0),
      Egui::Affine2.rotation(Math::PI / 2, Egui::Pos2.zero))
    p.rect(Egui::Rect.from_min_size(Egui::Pos2.new(1.0, 0.0),
      Egui::Vec2.new(1.0, 1.0)), 0.0, fill: Egui::Color32.rgb(9, 9, 9))
    p.pop_transform(Egui::Pos2.new(0.0, 0.0))
    # now an outer scale 2x over the SAME (already stamped) command:
    # re-emit via a deferred frame over the list — use a second bracket
    # around a copy
    p.push_transform(Egui::Pos2.new(0.0, 0.0), 2.0, 2.0, 0.0, 0.0, 1.0)
    p.push_affine(Egui::Pos2.new(0.0, 0.0),
      Egui::Affine2.rotation(Math::PI / 2, Egui::Pos2.zero))
    p.rect(Egui::Rect.from_min_size(Egui::Pos2.new(1.0, 0.0),
      Egui::Vec2.new(1.0, 1.0)), 0.0, fill: Egui::Color32.rgb(9, 9, 9))
    p.pop_transform(Egui::Pos2.new(0.0, 0.0))
    p.pop_transform(Egui::Pos2.new(0.0, 0.0))

    cmd = p.commands[1].as(Egui::RectCmd)
    cmd.rect.min.x.should eq 1.0 # stamped path: geometry never rewritten
    xf = cmd.xform.not_nil!
    # scale∘rotate: (1,0) → rotate → (0,1) → scale → (0,2)
    m = xf * Egui::Pos2.new(1.0, 0.0)
    m.x.should be_close 0.0, 1e-9
    m.y.should be_close 2.0, 1e-9
  end
end

describe "ecss transform cascade" do
  it "parses transform / origin / transition shorthand into vars" do
    doc = Egui::Ecss::Doc.parse(<<-ECSS)
      tilt {
        transform: rotate(-3deg) translateY(4px);
        transform-origin: top left;
        transition: transform 250ms;
      }
    ECSS
    vars = doc.classes["tilt"].vars
    t = vars["transform"]?.as?(Egui::CssTransform).should_not be_nil
    o = vars["transform-origin"]?.as?(Egui::TransformOrigin).should_not be_nil
    d = vars["transition.transform"]?
    d.should_not be_nil
    d.as?(Float64 | Int32).should_not be_nil
  end
end

describe "Ui#box transform" do
  it "applies a rotated transform paint-only (stamp, no layout change)" do
    ctx = Egui::Context.new
    plain_rect = nil
    tilted_rect = nil
    xf_frame(ctx, 0.0) do |c|
      ui = Egui::Ui.new(c, Egui::Id.from("xf-root"), XF_SCREEN)
      ui.box(transform: "none") { |b| b.label("plain") }
      plain_rect = ui.min_rect
    end
    xf_frame(ctx, 0.0) do |c|
      ui = Egui::Ui.new(c, Egui::Id.from("xf-root"), XF_SCREEN)
      ui.box(transform: "rotate(8deg)") { |b| b.label("tilt") }
      tilted_rect = ui.min_rect
    end
    # layout identical — the transform is paint-only
    plain_rect.not_nil!.size.should eq tilted_rect.not_nil!.size

    stamped = ctx.painter.commands.any?(&.xform)
    stamped.should be_true
  end

  it "a transformed box skips its OWN rounded clip (browser semantics)" do
    ctx = Egui::Context.new
    # plain rounded box: the subtree is re-clipped to the rounded shape
    xf_frame(ctx, 0.0) do |c|
      ui = Egui::Ui.new(c, Egui::Id.from("clip-a"), XF_SCREEN)
      ui.box(rounding: 14.0, fill: Egui::Color32.rgb(1, 1, 1)) do |b|
        b.label("clipped")
      end
    end
    plain = ctx.painter.commands.select(Egui::TextCmd).first
    plain.clip_corners.should_not be_nil

    # same box carrying a transform: the content moves WITH the box —
    # its own untransformed rect must not cut it
    xf_frame(ctx, 0.0) do |c|
      ui = Egui::Ui.new(c, Egui::Id.from("clip-b"), XF_SCREEN)
      ui.box(rounding: 14.0, fill: Egui::Color32.rgb(1, 1, 1),
        transform: "scale(1.1)") do |b|
        b.label("free")
      end
    end
    moved = ctx.painter.commands.select(Egui::TextCmd).first
    moved.clip_corners.should be_nil
    moved.xform.should be_nil # scale is axis-aligned — CPU path, no stamp
  end

  it "overflow: visible skips the bracket, :hidden keeps it" do
    ctx = Egui::Context.new
    xf_frame(ctx, 0.0) do |c|
      ui = Egui::Ui.new(c, Egui::Id.from("ovf-a"), XF_SCREEN)
      ui.box(rounding: 14.0, overflow: :visible,
        fill: Egui::Color32.rgb(1, 1, 1)) do |b|
        b.label("v")
      end
    end
    ctx.painter.commands.select(Egui::TextCmd).first
      .clip_corners.should be_nil

    xf_frame(ctx, 0.0) do |c|
      ui = Egui::Ui.new(c, Egui::Id.from("ovf-b"), XF_SCREEN)
      ui.box(rounding: 14.0, overflow: :hidden,
        transform: "rotate(2deg)",
        fill: Egui::Color32.rgb(1, 1, 1)) do |b|
        b.label("h")
      end
    end
    ctx.painter.commands.select(Egui::TextCmd).first
      .clip_corners.should_not be_nil
  end

  it "resolves overflow from the class chain" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("frame", Egui::StyleVars{"overflow" => "visible"})
    xf_frame(ctx, 0.0) do |c|
      ui = Egui::Ui.new(c, Egui::Id.from("ovf-c"), XF_SCREEN)
      ui.box(rounding: 14.0, style_class: "frame",
        fill: Egui::Color32.rgb(1, 1, 1)) do |b|
        b.label("v")
      end
    end
    ctx.painter.commands.select(Egui::TextCmd).first
      .clip_corners.should be_nil
  end

  it "z lifts the box's commands into a higher paint layer and restores it" do
    ctx = Egui::Context.new
    xf_frame(ctx, 0.0) do |c|
      ui = Egui::Ui.new(c, Egui::Id.from("z-a"), XF_SCREEN)
      ui.box(fill: Egui::Color32.rgb(1, 1, 1), z: 7) { |b| b.label("up") }
      # after the box: the ambient layer must be back where it was
      c.painter.layer.should eq Egui::Order::Background.z
      ui.label("after")
    end
    _cmds, layers = ctx.painter.take_bucket(0).not_nil!
    # the lifted box's label rides layer 7, the later sibling stays base
    i_up = ctx.painter.commands.index(&.is_a?(Egui::TextCmd))
    layers[i_up.not_nil!].should eq 7
    ctx.painter.layer = Egui::Order::Background.z
  end

  it "a z-lifted transformed child stays clipped by the ancestor bracket" do
    ctx = Egui::Context.new
    # CSS: z-index does NOT escape an ancestor's overflow: hidden —
    # a rounded panel's bracket must reach the lifted card too
    xf_frame(ctx, 0.0) do |c|
      ui = Egui::Ui.new(c, Egui::Id.from("z-clip"), XF_SCREEN)
      ui.box(rounding: 16.0, fill: Egui::Color32.rgb(1, 1, 1)) do |p|
        p.box(transform: "rotate(-7deg) translateY(34px)", z: 3,
          fill: Egui::Color32.rgb(2, 2, 2)) do |card|
          card.label("esc")
        end
      end
    end
    esc = ctx.painter.commands.select(Egui::TextCmd).first
    esc.clip_corners.should_not be_nil # the ancestor bracket reached it
    esc.xform.should_not be_nil        # …without dropping the rotation

    # …while a POPUP-layer command still escapes the bracket (a menu
    # opened inside a rounded card must not be cut by the card).
    # rounding: 0 — the inner box must not mint its own bracket.
    xf_frame(ctx, 0.0) do |c|
      ui = Egui::Ui.new(c, Egui::Id.from("z-esc"), XF_SCREEN)
      ui.box(rounding: 16.0, fill: Egui::Color32.rgb(1, 1, 1)) do |p|
        p.box(fill: Egui::Color32.rgb(2, 2, 2), rounding: 0.0, z: 99) do |card|
          card.label("menu")
        end
      end
    end
    ctx.painter.commands.select(Egui::TextCmd).first
      .clip_corners.should be_nil
  end

  it "resolves via the class chain (stylesheet rule)" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("badge", Egui::StyleVars{
      "transform" => Egui::CssTransform.parse?("rotate(-2deg)").not_nil!,
    })
    xf_frame(ctx, 0.0) do |c|
      ui = Egui::Ui.new(c, Egui::Id.from("xf-root2"), XF_SCREEN)
      ui.box(style_class: "badge") { |b| b.label("badge") }
    end
    ctx.painter.commands.any?(&.xform).should be_true
  end

  it "animates between targets (transition.transform)" do
    ctx = Egui::Context.new
    down = Egui::CssTransform.parse?("translateY(0px)").not_nil!
    far = Egui::CssTransform.parse?("translateY(100px)").not_nil!
    # The duration rides the class chain from the START, so the box's
    # first frames register a run at `down` (held — no from-state to
    # animate on first sighting).
    ctx.stylesheet.rule("mover", Egui::StyleVars{
      "transition.transform" => 200.0,
    })
    3.times do
      xf_frame(ctx, 0.0) do |c|
        ui = Egui::Ui.new(c, Egui::Id.from("xf-root3"), XF_SCREEN)
        ui.box(transform: down, style_class: "mover") { |b| b.label("m") }
      end
    end
    # the label's unshifted baseline (the transform is paint-only, the
    # layout never moves — deltas below are the translation's doing)
    y0 = ctx.painter.commands.select(Egui::TextCmd).first.pos.y
    # retarget: the drive lerps from the held `down` (y=0) towards 100
    xf_frame(ctx, 1.0) do |c|
      ui = Egui::Ui.new(c, Egui::Id.from("xf-root3"), XF_SCREEN)
      ui.box(transform: far, style_class: "mover") { |b| b.label("m") }
    end
    xf_frame(ctx, 1.1) do |c|
      ui = Egui::Ui.new(c, Egui::Id.from("xf-root3"), XF_SCREEN)
      ui.box(transform: far, style_class: "mover") { |b| b.label("m") }
    end
    y = ctx.painter.commands.select(Egui::TextCmd).first.pos.y - y0
    y.should be > 0.0
    y.should be < 100.0
    # and settle at the target once the duration passed
    xf_frame(ctx, 5.0) do |c|
      ui = Egui::Ui.new(c, Egui::Id.from("xf-root3"), XF_SCREEN)
      ui.box(transform: far, style_class: "mover") { |b| b.label("m") }
    end
    y2 = ctx.painter.commands.select(Egui::TextCmd).first.pos.y - y0
    y2.should be >= 100.0
  end
end
