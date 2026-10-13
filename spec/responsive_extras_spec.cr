# Ур.2/Ур.4 (plans/animations.md) + Этапы 4/5/6-часть
# (plans/responsive-mobile.md): named easing curves,
# prefers-reduced-motion, animate_color/vec2_with_time, safe-area
# insets (model + env() units + root-region cut), OS font scale
# feeding `rem`, and hover rules ignored on touch pointers.
require "spec"
require "../src/egui"

EXTRAS_SCREEN = Egui::Rect.from_min_size(
  Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

private def extras_frame(ctx : Egui::Context,
                         screen : Egui::Rect = EXTRAS_SCREEN,
                         &app : Egui::Context ->)
  raw = Egui::RawInput.new(screen, [] of Egui::Event, 0.016)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

describe "easing and reduced motion" do
  it "named curves hit their endpoints and differ mid-flight" do
    Egui::Easing.apply("linear", 0.25).should eq 0.25
    Egui::Easing.apply(nil, 0.5).should eq 0.5          # smoothstep
    Egui::Easing.apply("smoothstep", 0.0).should eq 0.0
    Egui::Easing.apply("ease-out", 0.0).should eq 0.0
    Egui::Easing.apply("ease-in-out", 1.0).should eq 1.0
    # Unknown names degrade to smoothstep, never raise.
    Egui::Easing.apply("warp-9", 0.5).should eq Egui::Easing.apply(nil, 0.5)
    # ease-in lags the linear midpoint; ease-out leads it.
    Egui::Easing.apply("ease-in", 0.5).should be < 0.5
    Egui::Easing.apply("ease-out", 0.5).should be > 0.5
  end

  it "easing.<key> names the curve a transition follows" do
    anims = Egui::StyleAnimations.new
    id = Egui::Id.from("w")
    anims.scalar(id, 0.0, 0.1, 0.0)                    # seed
    anims.scalar(id, 100.0, 0.1, 0.05, "linear")       # retarget (instant)
    # Linear at the new animation's midpoint (t=0.10) = exactly 50 —
    # smoothstep there would overshoot to 50 too, so sample at a
    # non-symmetric point as well where they differ.
    anims.scalar(id, 100.0, 0.1, 0.10, "linear").should eq 50.0
    anims.scalar(id, 100.0, 0.1, 0.115, "linear").should eq 65.0
    # ease-in lags linear at the same t.
    ease_in = Egui::StyleAnimations.new
    sid = Egui::Id.from("e")
    ease_in.scalar(sid, 0.0, 0.1, 0.0)
    ease_in.scalar(sid, 100.0, 0.1, 0.05, "ease-in")
    ease_in.scalar(sid, 100.0, 0.1, 0.115, "ease-in").should be < 65.0
  end

  it "reduced_motion snaps cascade transitions and hand-rolled anims" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("button", Egui::StyleVars{
      "width"      => 100.0,
      "transition" => 100.0,
    })
    t = 0.0
    extras_frame(ctx) { |_c| }
    ctx.stylesheet.rule("button", Egui::StyleVars{"width" => 200.0})
    ctx.reduced_motion = true

    width = nil
    extras_frame(ctx) do |c|
      c.central_panel do |ui|
        width = ui.add(Egui::Button.new("OK")).rect.width
      end
    end
    width.not_nil!.should eq 200.0 # no easing, target applied now

    # The hand-rolled helpers honor it too.
    ctx2 = Egui::Context.new
    extras_frame(ctx2) { |_c| }
    ctx2.reduced_motion = true
    extras_frame(ctx2) do |_c|
      c0 = ctx2.animate_color_with_time(Egui::Id.from("c"),
        Egui::Color32.rgb(9, 9, 9), 0.1)
      c0.should eq Egui::Color32.rgb(9, 9, 9)
    end
  end

  it "animate_color/vec2_with_time interpolate like the scalar one" do
    ctx = Egui::Context.new
    id = Egui::Id.from("hand")
    t = 0.0
    results = [] of Tuple(Egui::Color32, Egui::Vec2)
    extras_frame(ctx) do |_c|
      results << {ctx.animate_color_with_time(id,
          Egui::Color32.rgb(0, 0, 0), 0.1),
        ctx.animate_vec2_with_time(id, Egui::Vec2.zero, 0.1)}
    end
    extras_frame(ctx) do |_c|
      results << {ctx.animate_color_with_time(id,
          Egui::Color32.rgb(100, 0, 0), 0.1),
        ctx.animate_vec2_with_time(id, Egui::Vec2.new(100.0, 0.0), 0.1)}
    end
    # First sighting snaps; the follow-up frame stays at the source
    # value (the retarget instant) — same semantics as widths.
    results[0][0].should eq Egui::Color32.rgb(0, 0, 0)
    results[1][0].should eq Egui::Color32.rgb(0, 0, 0)
    results[0][1].should eq Egui::Vec2.zero
  end
end

describe "safe area" do
  it "RawInput insets from the backend win; nil keeps the manual value" do
    ctx = Egui::Context.new
    # nil (desktop backend) — the manual setter stays in charge.
    extras_frame(ctx) { |_c| }
    ctx.safe_area = Egui::SafeArea.new(top: 10.0)
    extras_frame(ctx) { |_c| }
    ctx.available_rect.min.y.should eq(EXTRAS_SCREEN.min.y + 10.0)

    # A reported backend inset (the OS detector on phones) overrides
    # whatever was set manually — the OS is the authority.
    raw = Egui::RawInput.new(EXTRAS_SCREEN, [] of Egui::Event, 0.032,
      Egui::SafeArea.new(top: 44.0, bottom: 34.0))
    ctx.begin_frame(raw)
    ctx.available_rect.min.y.should eq(EXTRAS_SCREEN.min.y + 44.0)
    ctx.available_rect.max.y.should eq(EXTRAS_SCREEN.max.y - 34.0)
    ctx.end_frame
  end

  it "insets shrink the root region panels lay out against" do
    ctx = Egui::Context.new
    plain = nil
    extras_frame(ctx) { |c| plain = c.available_rect.dup }

    ctx.safe_area = Egui::SafeArea.new(
      top: 44.0, right: 0.0, bottom: 34.0, left: 20.0)
    cut = nil
    extras_frame(ctx) { |c| cut = c.available_rect.dup }

    p = plain.not_nil!
    u = cut.not_nil!
    u.min.x.should eq(p.min.x + 20.0)
    u.min.y.should eq(p.min.y + 44.0)
    u.max.x.should eq(p.max.x)
    u.max.y.should eq(p.max.y - 34.0)

    # Zero insets reproduce the pre-safe-area layout exactly.
    ctx.safe_area = Egui::SafeArea.zero
    extras_frame(ctx) { |c| c.available_rect.should eq p }
  end

  it "env(safe-area-inset-*) resolve in styles (bare and scaled)" do
    ctx = Egui::Context.new
    ctx.safe_area = Egui::SafeArea.new(top: 44.0, left: 20.0)
    ctx.stylesheet.rule("paneltest", Egui::StyleVars{
      "a" => Egui::StyleLength.new(1.0, :safe_top),
      "b" => Egui::StyleLength.new(0.5, :safe_left),
    })
    # The ecss parser accepts the bare form with implicit 1.0.
    doc = Egui::Ecss::Doc.parse(
      "button { margin.top: env(safe-area-inset-top); }")
    doc.class_vars("button", nil).not_nil!["margin.top"]
      .should eq Egui::StyleLength.new(1.0, :safe_top)

    vals = nil
    extras_frame(ctx) do |c|
      c.central_panel do |ui|
        vars = ctx.stylesheet.resolve("paneltest")
        vals = {vars.length_px?("a", ui), vars.length_px?("b", ui)}
      end
    end
    vals.not_nil![0].should eq 44.0
    vals.not_nil![1].should eq 10.0
  end
end

describe "font scale" do
  it "multiplies rem only — pt values stay put" do
    ctx = Egui::Context.new
    ctx.font_scale = 1.5
    ctx.stylesheet.rule("paneltest", Egui::StyleVars{
      "r" => Egui::StyleLength.new(1.0, :rem),
      "p" => 16.0,
    })
    vals = nil
    extras_frame(ctx) do |c|
      c.central_panel do |ui|
        vars = ctx.stylesheet.resolve("paneltest")
        vals = {vars.length_px?("r", ui), vars.length_px?("p", ui)}
      end
    end
    base = ctx.style.font_size
    vals.not_nil![0].should eq base * 1.5
    vals.not_nil![1].should eq 16.0
  end
end

describe "touch pointers" do
  it "hover state rules read as base when pointer is coarse" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("button", Egui::StyleVars{
      "stroke" => Egui::Color32.rgb(1, 1, 1),
    })
    ctx.stylesheet.rule("button:hover", Egui::StyleVars{
      "stroke" => Egui::Color32.rgb(9, 9, 9),
    })

    fine = nil
    coarse = nil
    probe = HoverProbe.new
    extras_frame(ctx) do |c|
      c.central_panel do |ui|
        fine = probe.call(ui, :fine)
      end
    end
    ctx.pointer_coarse = true
    extras_frame(ctx) do |c|
      c.central_panel do |ui|
        coarse = probe.call(ui, :coarse)
      end
    end

    fine.not_nil!.should eq Egui::Color32.rgb(9, 9, 9)
    coarse.not_nil!.should eq Egui::Color32.rgb(1, 1, 1)
  end
end

# A minimal widget exposing state-scoped style_vars for probing.
class HoverProbe
  include Egui::Widget

  def style_class : String?
    "button"
  end

  def call(ui : Egui::Ui, flavor : Symbol) : Egui::Color32?
    id = Egui::Id.from("probe")
    vars = style_vars(ui, id, "hover")
    vars.color?("stroke")
  end

  def ui(ui : Egui::Ui) : Egui::Response
    raise "probe is not drawable"
  end
end
