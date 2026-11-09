# @keyframes (plans/NativeHTML.md §7): named tracks of StyleVars
# stops, played onto the cascade through the `animation:*` rule keys.
# The timing machinery (delay/direction/iterations/play-state) lives
# in KeyframeAnims; the value interpolation in KeyframeTrack; the
# overlay rides Widget#vars_for on top of the class+id layers.

require "spec"
require "../src/egui"

KEYFRAMES_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(400.0, 300.0))

def keyframes_frame(ctx : Egui::Context, time : Float64,
                    &app : Egui::Context ->)
  raw = Egui::RawInput.new(KEYFRAMES_SCREEN, [] of Egui::Event, time)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

# A minimal widget exposing its resolved vars for probing.
class KeyframesProbe
  include Egui::Widget
  property vars : Egui::StyleVars?

  def style_class : String?
    "button"
  end

  def call(ui : Egui::Ui, id : Egui::Id, state : String? = nil) : Nil
    @vars = style_vars(ui, id, state)
  end

  def ui(ui : Egui::Ui) : Egui::Response
    raise "probe is not drawable"
  end
end

describe "keyframes" do
  it "interpolates colors and numbers between stops" do
    track = Egui::KeyframeTrack.new("fade", {
      "from" => Egui::StyleVars{
        "background" => Egui::Color32.rgb(0, 0, 0),
        "rounding"   => 0.0,
      },
      "to"   => Egui::StyleVars{
        "background" => Egui::Color32.rgb(100, 0, 0),
        "rounding"   => 10.0,
      },
    })
    mid = track.vars_at(0.5)
    mid.color?("background").should eq(Egui::Color32.rgb(50, 0, 0))
    mid.f64("rounding", -1.0).should eq(5.0)
  end

  it "brackets multi-stop tracks (from/50%/to)" do
    track = Egui::KeyframeTrack.new("pulse", {
      "from" => Egui::StyleVars{"rounding" => 0.0},
      "50%"  => Egui::StyleVars{"rounding" => 10.0},
      "to"   => Egui::StyleVars{"rounding" => 0.0},
    })
    track.vars_at(0.25).f64("rounding", -1.0).should eq(5.0)
    track.vars_at(0.75).f64("rounding", -1.0).should eq(5.0)
    track.vars_at(1.0).f64("rounding", -1.0).should eq(0.0)
  end

  it "delay holds the base values; the run then interpolates" do
    ctx = Egui::Context.new
    spec = Egui::Keyframes::Spec.new("fade", 1.0, 0.5, 1.0, "normal",
      false, "linear")
    anims = ctx.memory.keyframe_anims
    id = Egui::Id.from("w")
    # The run starts at the FIRST sighting; the 0.5s delay counts
    # from there (CSS: the delay elapses once the animation applies).
    anims.evaluate(id, spec, 0.2).progress.should be_nil # inside delay
    anims.evaluate(id, spec, 0.6).progress.should be_nil # still < 0.7
    anims.evaluate(id, spec, 1.2).progress.should eq(0.5) # 0.5s in
    # t=2.0: finished (1 iteration), fill-mode none.
    anims.evaluate(id, spec, 2.0).tap do |ev|
      ev.running.should be_false
      ev.progress.should be_nil
    end
  end

  it "paused freezes the progress; resuming continues from there" do
    ctx = Egui::Context.new
    running = Egui::Keyframes::Spec.new("fade", 1.0, 0.0, -1.0,
      "normal", false, "linear")
    paused = Egui::Keyframes::Spec.new("fade", 1.0, 0.0, -1.0,
      "normal", true, "linear")
    anims = ctx.memory.keyframe_anims
    id = Egui::Id.from("w")
    anims.evaluate(id, running, 0.0) # first sighting: the run starts
    anims.evaluate(id, running, 0.4).progress.should eq(0.4)
    anims.evaluate(id, paused, 0.5).progress.should eq(0.5) # pause now
    anims.evaluate(id, paused, 0.9).progress.should eq(0.5) # frozen
    # Resume: the pause never counts as elapsed (start shifts by the
    # paused span) — and the toggle did NOT restart the run.
    anims.evaluate(id, running, 1.0).progress.should eq(0.5)
    anims.evaluate(id, running, 1.2).progress.should eq(0.7)
  end

  it "direction reverse and alternate flip the track" do
    ctx = Egui::Context.new
    anims = ctx.memory.keyframe_anims
    id = Egui::Id.from("w")
    rev = Egui::Keyframes::Spec.new("fade", 1.0, 0.0, -1.0, "reverse",
      false, "linear")
    anims.evaluate(id, rev, 0.0) # start the run
    anims.evaluate(id, rev, 0.25).progress.should eq(0.75)
    alt = Egui::Keyframes::Spec.new("fade", 1.0, 0.0, -1.0, "alternate",
      false, "linear")
    anims.evaluate(id, alt, 0.0) # start the run
    anims.evaluate(id, alt, 0.25).progress.should eq(0.25) # iter 1
    anims.evaluate(id, alt, 1.25).progress.should eq(0.75) # iter 2, flipped
  end

  it "a rule playing an animation overlays the interpolated values" do
    ctx = Egui::Context.new
    ctx.stylesheet.keyframes("fade", {
      "from" => Egui::StyleVars{"background" => Egui::Color32.rgb(0, 0, 0)},
      "to"   => Egui::StyleVars{"background" => Egui::Color32.rgb(100, 0, 0)},
    })
    ctx.stylesheet.rule("button", Egui::StyleVars{
      "animation" => "fade 200ms",
      "animation.easing" => "linear",
    })
    probe = KeyframesProbe.new

    keyframes_frame(ctx, 0.016) do |c|
      c.central_panel { |ui| probe.call(ui, Egui::Id.from("p")) }
    end
    # First sighting at ~0ms: progress ≈ 0 — the from value.
    probe.vars.not_nil!.color?("background")
      .should eq(Egui::Color32.rgb(0, 0, 0))

    keyframes_frame(ctx, 0.116) do |c|
      c.central_panel { |ui| probe.call(ui, Egui::Id.from("p")) }
    end
    # 100ms into the 200ms linear run: exactly halfway.
    probe.vars.not_nil!.color?("background")
      .should eq(Egui::Color32.rgb(50, 0, 0))

    keyframes_frame(ctx, 1.0) do |c|
      c.central_panel { |ui| probe.call(ui, Egui::Id.from("p")) }
    end
    # Finished (fill-mode none): the base cascade value applies again
    # — the default theme's button background.
    probe.vars.not_nil!.color?("background")
      .should eq(ctx.style.visuals.button_weak)
  end

  it "reduced_motion skips the overlay" do
    ctx = Egui::Context.new
    ctx.reduced_motion = true
    ctx.stylesheet.keyframes("fade", {
      "from" => Egui::StyleVars{"background" => Egui::Color32.rgb(0, 0, 0)},
      "to"   => Egui::StyleVars{"background" => Egui::Color32.rgb(100, 0, 0)},
    })
    ctx.stylesheet.rule("button", Egui::StyleVars{"animation" => "fade 200ms"})
    probe = KeyframesProbe.new

    keyframes_frame(ctx, 0.116) do |c|
      c.central_panel { |ui| probe.call(ui, Egui::Id.from("p")) }
    end
    # Reduced motion: no overlay at all — the base cascade value.
    probe.vars.not_nil!.color?("background")
      .should eq(ctx.style.visuals.button_weak)
  end

  it "ecss parses @keyframes blocks (nested braces) and applies them" do
    doc = Egui::Ecss::Doc.parse(<<-ECSS)
      @keyframes slide {
        from { background: #000000ff; }
        50% { background: #320000ff; }
        to { background: #640000ff; }
      }
      button {
        animation: "slide 400ms";
        animation.easing: linear;
      }
    ECSS
    track = doc.keyframes["slide"].not_nil!
    track.stops.size.should eq(3)
    mid = track.vars_at(0.25) # halfway between from (0) and 50% (50)
    mid.color?("background").should eq(Egui::Color32.rgb(25, 0, 0))

    # The rule side parses into the animation spec (duration in
    # seconds inside the Spec).
    vars = doc.class_vars("button", nil).not_nil!
    spec = Egui::Keyframes::Spec.from_vars(vars).not_nil!
    spec.name.should eq("slide")
    spec.duration.should eq(0.4)
    spec.easing.should eq("linear")

    # Round-trip: the serialized document keeps the block.
    doc.to_s.should contain("@keyframes slide {")
  end
end
