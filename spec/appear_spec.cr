# Appear transitions (plans/NATIVE_HTML_DEMO.md §3.2, increment 2):
# `appear:`/`appear-delay:` ECSS properties drive a painter transform
# around a freshly shown box — first frame transformed, settled output
# byte-identical to the plain one, delay holds the start state, the
# transform never touches clip rects or hit-testing (Raven's
# widget/anim.c semantics).
require "spec"
require "../src/egui"

APPEAR_SCREEN = Egui::Rect.from_min_size(
  Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

private def ap_frame(ctx : Egui::Context, t : Float64,
                     events : Array(Egui::Event) = [] of Egui::Event,
                     &app : Egui::Context ->)
  raw = Egui::RawInput.new(APPEAR_SCREEN, events, t)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

# Draw one card box (chrome + a label + a button) over a direct Ui —
# the central PANEL is deferred (its block runs at end_frame), which
# would hide the button's Response from the caller; a plain Ui emits
# inline.
private def ap_card(ctx : Egui::Context, cls : String? = "card",
                    appear : String? = nil,
                    appear_delay : Float64? = nil) : Egui::Response
  resp = nil
  ui = Egui::Ui.new(ctx, Egui::Id.from("appear-root"), APPEAR_SCREEN)
  ui.box(:column, fill: Egui::Color32.rgb(60, 120, 220),
    stroke: Egui::Color32.rgb(20, 40, 90), rounding: 10.0,
    margin: Egui::Vec2.new(16.0, 16.0), style_class: cls,
    appear: appear, appear_delay: appear_delay) do |b|
    b.label("Card")
    resp = b.button("OK", id: "ok")
  end
  resp.not_nil!
end

# The card's chrome RectCmd (the filled box background), matched by its
# fill rgb — the appear transform scales the fill's ALPHA, so the match
# must not look at it.
private def card_rect_cmd(ctx : Egui::Context) : Egui::RectCmd
  ctx.painter.commands.find do |c|
    c.is_a?(Egui::RectCmd) && (f = c.fill) &&
      f.r == 60 && f.g == 120 && f.b == 220
  end.as(Egui::RectCmd)
end

describe "appear" do
  it "painter push_transform scales around the pivot, fades, keeps clip" do
    p = Egui::Painter.new
    clip = Egui::Rect.from_min_size(Egui::Pos2.new(5.0, 5.0),
      Egui::Vec2.new(100.0, 100.0))
    p.clip = clip
    pivot = Egui::Pos2.new(100.0, 100.0)
    p.push_transform(pivot, 0.5, 0.5, 10.0, 20.0, 0.5)
    p.rect(Egui::Rect.from_min_size(Egui::Pos2.zero,
      Egui::Vec2.new(10.0, 10.0)), 4.0,
      fill: Egui::Color32.rgb(200, 100, 50))
    p.text(Egui::Pos2.new(0.0, 0.0), "hi", 20.0, Egui::Color32.rgb(255, 255, 255))
    p.circle(Egui::Pos2.new(100.0, 100.0), 8.0,
      fill: Egui::Color32.rgb(10, 10, 10))
    p.pop_transform

    r = p.commands[0].as(Egui::RectCmd)
    # (0,0) → 100 + (0-100)·0.5 + 10 = 60; (10,10) → 65
    r.rect.min.x.should eq 60.0
    r.rect.min.y.should eq 70.0
    r.rect.max.x.should eq 65.0
    r.rect.max.y.should eq 75.0
    r.rounding.should eq 2.0 # 4 × avg scale
    r.fill.not_nil!.a.should eq 128 # 255 × 0.5
    r.clip.should eq clip # clip rects never transform

    t = p.commands[1].as(Egui::TextCmd)
    t.pos.x.should eq 60.0
    t.size.should eq 10.0
    t.color.a.should eq 128

    c = p.commands[2].as(Egui::CircleCmd)
    c.center.x.should eq 110.0 # at the pivot → pure offset
    c.center.y.should eq 120.0
    c.radius.should eq 4.0

    # Without a frame the painter is untouched.
    before = p.commands.size
    p.rect(Egui::Rect.from_min_size(Egui::Pos2.zero,
      Egui::Vec2.new(10.0, 10.0)), fill: Egui::Color32.rgb(1, 2, 3))
    p.commands.last.as(Egui::RectCmd).rect.min.x.should eq 0.0
    p.commands.size.should eq(before + 1)
  end

  it "fade: first frame is faded, settled output is byte-identical" do
    animated = Egui::Context.new
    animated.stylesheet.rule("card", Egui::StyleVars{
      "appear"        => "fade",
      "appear-delay"  => "0s",
    })
    plain = Egui::Context.new

    t = 0.0
    ap_frame(animated, t += 0.016) { |c| ap_card(c) }
    ap_frame(plain, t) { |c| ap_card(c) }
    cmd = card_rect_cmd(animated)
    cmd.fill.not_nil!.a.should eq 0 # t=0 → opacity clamp(0·2.2) = 0
    plain_cmd = card_rect_cmd(plain)
    cmd.rect.should eq plain_cmd.rect # fade never moves geometry

    # ~1.5 s of frames: the smooth spring (0.30 s) is long settled.
    95.times do
      ap_frame(animated, t += 0.016) { |c| ap_card(c) }
      ap_frame(plain, t += 0.016) { |c| ap_card(c) }
    end
    animated.painter.commands.should eq plain.painter.commands
    animated.painter.commands.size.should be > 2 # real content compared
  end

  it "fly-right shifts the rect on the first frame" do
    ctx = Egui::Context.new
    plain = Egui::Context.new
    t = 0.0
    ap_frame(plain, t += 0.016) { |c| ap_card(c) }
    ap_frame(ctx, t) do |c|
      ap_card(c, appear: "fly-right")
    end
    moved = card_rect_cmd(ctx)
    base = card_rect_cmd(plain)
    # fly-right at t=0: dx = -72, scale 0.92 around the box center —
    # the x offset is the shift PLUS the scale contraction towards
    # the pivot.
    pivot = base.rect.center
    expected_x = pivot.x + (base.rect.min.x - pivot.x) * 0.92 - 72.0
    moved.rect.min.x.should be_close(expected_x, 1e-6)
    moved.rect.width.should be_close(base.rect.width * 0.92, 1e-6)
    moved.fill.not_nil!.a.should eq 0 # starts invisible (opacity ramp)
  end

  it "pop settles to the plain output and mid-flight differs" do
    ctx = Egui::Context.new
    plain = Egui::Context.new
    ctx.stylesheet.rule("card", Egui::StyleVars{"appear" => "pop"})
    t = 0.0
    ap_frame(ctx, t += 0.016) { |c| ap_card(c) }
    ap_frame(plain, t) { |c| ap_card(c) }
    (card_rect_cmd(ctx).rect.width < card_rect_cmd(plain).rect.width)
      .should be_true # 0.55 + 0.45·0 ≈ 0.55 scale on frame 1

    60.times do
      ap_frame(ctx, t += 0.032) { |c| ap_card(c) }
      ap_frame(plain, t += 0.032) { |c| ap_card(c) }
    end
    # bouncy lands past 1 and wobbles back — but after ~2 s it settled.
    ctx.painter.commands.should eq plain.painter.commands
  end

  it "appear-delay holds the start state, then plays" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("card", Egui::StyleVars{
      "appear"        => "pop",
      "appear-delay"  => "0.1s",
    })
    t = 0.0
    first = nil
    ap_frame(ctx, t += 0.016) do |c|
      ap_card(c)
      first = card_rect_cmd(c).dup
    end
    # Within the delay window: the start state holds (scale 0.55).
    4.times do
      ap_frame(ctx, t += 0.016) do |c|
        ap_card(c)
        card_rect_cmd(c).rect.should eq first.not_nil!.rect
      end
    end
    t.should be < 0.12
    # Past the delay the spring runs.
    8.times { ap_frame(ctx, t += 0.016) { |c| ap_card(c) } }
    card_rect_cmd(ctx).rect.width.should be > first.not_nil!.rect.width
  end

  it "numeric appear-delay is milliseconds" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("card", Egui::StyleVars{
      "appear"        => "fade",
      "appear-delay"  => 80.0,
    })
    t = 0.0
    ap_frame(ctx, t += 0.016) { |c| ap_card(c) }
    3.times do
      ap_frame(ctx, t += 0.016) { |c| ap_card(c) }
    end
    t.should be < 0.08 # still inside the 80 ms delay → start state
    card_rect_cmd(ctx).fill.not_nil!.a.should eq 0
    10.times { ap_frame(ctx, t += 0.016) { |c| ap_card(c) } }
    # ~0.22 s in: the 0.3 s smooth spring is mid-flight — visible.
    card_rect_cmd(ctx).fill.not_nil!.a.should be > 0
  end

  it "appear: none paints identically from the first frame" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("card", Egui::StyleVars{"appear" => "none"})
    plain = Egui::Context.new
    t = 0.0
    ap_frame(ctx, t += 0.016) { |c| ap_card(c) }
    ap_frame(plain, t) { |c| ap_card(c) }
    ctx.painter.commands.should eq plain.painter.commands
  end

  it "no appear style at all paints identically (the fast path)" do
    ctx = Egui::Context.new
    plain = Egui::Context.new
    # The class exists (so resolve_chain runs) but carries no appear —
    # an inert key, so nothing the widgets read changes.
    ctx.stylesheet.rule("card", Egui::StyleVars{"appear-slot" => 1.0})
    t = 0.0
    ap_frame(ctx, t += 0.016) { |c| ap_card(c) }
    ap_frame(plain, t) { |c| ap_card(c) }
    ctx.painter.commands.should eq plain.painter.commands
  end

  it "the transform never touches clip or hit-testing" do
    ctx = Egui::Context.new
    plain = Egui::Context.new
    t = 0.0
    base_btn = nil
    ap_frame(plain, t += 0.016) { |c| base_btn = ap_card(c) }
    resp = nil
    ap_frame(ctx, t) do |c|
      resp = ap_card(c, appear: "fly-right")
    end
    btn = resp.not_nil!
    base_btn_rect = base_btn.not_nil!.rect
    # The button LIVES at its layout place from the first frame —
    # the painter transform is paint-only.
    btn.rect.should eq base_btn_rect
    center = Egui::Pos2.new(base_btn_rect.center.x, base_btn_rect.center.y)
    # A click on the untransformed place works while mid-transition.
    ap_frame(ctx, t += 0.016,
        [Egui::Event.pointer_moved(center),
         Egui::Event.pointer_pressed(center)]) do |c|
      resp = ap_card(c, appear: "fly-right")
    end
    ap_frame(ctx, t += 0.016,
        [Egui::Event.pointer_released(center)]) do |c|
      resp = ap_card(c, appear: "fly-right")
    end
    resp.not_nil!.clicked?.should be_true
    # The emitted clip rects are the plain run's — never transformed.
    card_rect_cmd(ctx).clip.should eq card_rect_cmd(plain).clip
  end

  it "ecss parses appear properties, including the time delay" do
    doc = Egui::Ecss::Doc.parse(<<-ECSS)
      card {
        appear: fly-right;
        appear-delay: 0.08s;
      }
      plain { appear: none; }
      staggered { appear-delay: 80ms; }
    ECSS
    vars = doc.class_vars("card", nil).not_nil!
    vars["appear"].should eq "fly-right"
    vars["appear-delay"].should eq "0.08s"
    doc.class_vars("plain", nil).not_nil!["appear"].should eq "none"
    doc.class_vars("staggered", nil).not_nil!["appear-delay"].should eq "80ms"
    # Round trip: the written file re-parses to the same values.
    io = IO::Memory.new
    doc.to_s(io)
    Egui::Ecss::Doc.parse(io.to_s)
      .class_vars("card", nil).not_nil!["appear-delay"].should eq "0.08s"
  end

  it "kind names parse kebab-case and Raven PascalCase" do
    Egui::AppearAnims.kind?("fly-right").should eq :fly_right
    Egui::AppearAnims.kind?("FlyRight").should eq :fly_right
    Egui::AppearAnims.kind?("slide-left").should eq :slide_left
    Egui::AppearAnims.kind?("SlideLeft").should eq :slide_left
    Egui::AppearAnims.kind?("Drop").should eq :drop
    Egui::AppearAnims.kind?("none").should be_nil
    Egui::AppearAnims.kind?("bogus").should be_nil
  end

  it "drop squashes below identity on the wobbly overshoot" do
    # away runs negative while the wobbly progress overshoots 1 —
    # sy dips under 1 (the landing squash), sx runs past it.
    synth = Egui::AppearAnims.curves(:drop, 1.1)
    synth[:sy].should be < 1.0
    synth[:sx].should be > 1.0
    rest = Egui::AppearAnims.curves(:drop, 0.0)
    rest[:dy].should eq -140.0
    rest[:sy].should eq 1.15
    rest[:sx].should eq 0.928
  end

  it "the widget id rule and the * theme default resolve in the cascade" do
    ctx = Egui::Context.new
    # The global default fades, the card class overrides with fly-up.
    ctx.stylesheet.rule("*", Egui::StyleVars{"appear" => "fade"})
    ctx.stylesheet.rule("card", Egui::StyleVars{"appear" => "fly-up"})
    t = 0.0
    ap_frame(ctx, t += 0.016) { |c| ap_card(c) }
    cmd = card_rect_cmd(ctx)
    # fly-up: dy = +56 and scale 0.92 around the center at t=0 — the
    # class beat the global fade.
    base = Egui::Context.new
    ap_frame(base, t) { |c| ap_card(c) }
    b = card_rect_cmd(base)
    pivot = b.rect.center
    expected_y = pivot.y + (b.rect.min.y - pivot.y) * 0.92 + 56.0
    cmd.rect.min.y.should be_close(expected_y, 1e-6)
    cmd.rect.width.should be_close(b.rect.width * 0.92, 1e-6)
  end
end
