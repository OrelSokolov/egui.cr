# The spring primitive (plans/NATIVE_HTML_DEMO.md §3.2, port of
# Raven's anim.c): damped-oscillator physics — overshoot/monotonic
# presets, settling, velocity-preserving retargets — and the
# `spring(…)` transition-value spelling.
require "spec"
require "../src/egui"

describe "spring" do
  it "bouncy overshoots the target, smooth never does" do
    bouncy = Egui::Spring.new
    bouncy.set(0.0)
    max = 0.0
    240.times do # 2s in 1/120 substeps
      bouncy.step(1.0 / 120.0, 1.0, 0.38, 0.52)
      max = {max, bouncy.value}.max
    end
    max.should be > 1.01 # runs past the target and swings back

    smooth = Egui::Spring.new
    smooth.set(0.0)
    max = 0.0
    240.times do
      smooth.step(1.0 / 120.0, 1.0, 0.30, 1.0)
      max = {max, smooth.value}.max
    end
    max.should be <= 1.0 # critically damped: lands without overshoot
    max.should be > 0.99 # …and it did land
  end

  it "settles exactly at the target" do
    s = Egui::Spring.new
    s.set(0.0)
    600.times { s.step(1.0 / 120.0, 250.0, 0.50, 0.32) } # wobbling 5s
    s.moving?(250.0).should be_false
    s.track(1.0 / 120.0, 250.0, 0.50, 0.32).should eq 250.0
    s.velocity.should eq 0.0
  end

  it "retargets mid-flight without a jump, keeping the velocity" do
    s = Egui::Spring.new
    s.set(0.0)
    12.times { s.step(1.0 / 120.0, 100.0, 0.38, 0.52) }
    value_before = s.value
    vel_before = s.velocity
    vel_before.abs.should be > 1.0 # in flight

    # The target flips mid-flight. At the retarget INSTANT the state
    # is continuous: a vanishing step moves the value by ~v·dt and
    # leaves the velocity intact (an easing curve would restart from
    # a zero derivative — that is the whole difference).
    s.step(1.0 / 100_000.0, -100.0, 0.38, 0.52)
    (s.value - value_before).abs.should be < vel_before.abs * 3e-5
    s.velocity.should be_close(vel_before, vel_before.abs * 0.01)

    # A full step later it still flows in the SAME direction (no
    # snap to the new target's side).
    s2 = Egui::Spring.new
    s2.value = value_before
    s2.velocity = vel_before
    s2.step(1.0 / 120.0, -100.0, 0.38, 0.52)
    (s2.value - value_before).sign.should eq vel_before.sign
  end

  it "set snaps and kick adds velocity" do
    s = Egui::Spring.new
    s.set(5.0)
    s.value.should eq 5.0
    s.velocity.should eq 0.0
    s.started?.should be_true
    s.kick(2.5)
    s.velocity.should eq 2.5
    s.kick(-0.5)
    s.velocity.should eq 2.0
  end

  it "an unstarted spring is not moving; exact solution is dt-stable" do
    s = Egui::Spring.new
    s.moving?(0.0).should be_false

    # The closed form does not depend on the frame rate: one big step
    # ≈ many small ones (this is why long frames never explode).
    big = Egui::Spring.new
    big.set(0.0)
    big.step(0.25, 1.0, 0.38, 0.52)
    small = Egui::Spring.new
    small.set(0.0)
    30.times { small.step(1.0 / 120.0, 1.0, 0.38, 0.52) }
    (big.value - small.value).abs.should be < 0.01
  end

  describe "Spec" do
    it "parses presets, numbers, bare spring and the delay suffix" do
      Egui::Spring::Spec.parse?("spring(bouncy)").try(&.response).should eq 0.38
      Egui::Spring::Spec.parse?("spring(bouncy)").try(&.damping).should eq 0.52
      Egui::Spring::Spec.parse?("spring").should eq Egui::Spring::Spec.snappy
      Egui::Spring::Spec.parse?("spring(smooth)").should eq Egui::Spring::Spec.smooth
      Egui::Spring::Spec.parse?("spring(0.3, 0.8)").try(&.response).should eq 0.3
      Egui::Spring::Spec.parse?("spring(0.3, 0.8)").try(&.damping).should eq 0.8
      Egui::Spring::Spec.parse?("spring(0.42)").try(&.response).should eq 0.42

      d = Egui::Spring::Spec.parse?("spring(bouncy) 100ms")
      d.try(&.delay).should eq 0.1
      Egui::Spring::Spec.parse?("spring(bouncy) 0.1s").try(&.delay).should eq 0.1

      Egui::Spring::Spec.parse?("ease-out").should be_nil
      Egui::Spring::Spec.parse?("springy").should be_nil
      Egui::Spring::Spec.parse?("spring(fast)").should be_nil
      Egui::Spring::Spec.parse?("spring(0.3,)").should be_nil
    end

    it "round-trips through to_s" do
      {"spring(bouncy)", "spring", "spring(0.3, 0.8)",
       "spring(bouncy) 50ms"}.each do |spelling|
        spec = Egui::Spring::Spec.parse?(spelling).not_nil!
        Egui::Spring::Spec.parse?(spec.to_s).should eq spec
      end
      Egui::Spring::Spec.parse?("spring(0.3, 0.8)").not_nil!.to_s
        .should eq "spring(0.3, 0.8)"
      Egui::Spring::Spec.parse?("spring(bouncy) 50ms").not_nil!.to_s
        .should eq "spring(bouncy) 50ms"
    end

    it "splits the `transition: <key> spring(…)` shorthand" do
      Egui::Spring::Spec.split_shorthand("background spring(bouncy)")
        .should eq({"background", "spring(bouncy)"})
      Egui::Spring::Spec.split_shorthand("width spring(0.3, 0.8) 50ms")
        .should eq({"width", "spring(0.3, 0.8) 50ms"})
      # per-key spellings and non-spring values are not the shorthand
      Egui::Spring::Spec.split_shorthand("spring(bouncy)").should be_nil
      Egui::Spring::Spec.split_shorthand("background 120").should be_nil
      Egui::Spring::Spec.split_shorthand("background").should be_nil
    end
  end

  it "StyleAnimations springs scalars: snap, glide, settle, hold delay" do
    anims = Egui::StyleAnimations.new
    id = Egui::Id.from("w")
    spec = Egui::Spring::Spec.snappy

    anims.spring_scalar(id, 0.0, spec, 0.0).should eq 0.0 # first sighting snaps
    anims.running?(id, 0.0).should be_false
    anims.spring_scalar(id, 100.0, spec, 0.016).should be > 0.0
    anims.running?(id, 0.016).should be_true

    # Retarget mid-flight: the value is continuous across the call…
    mid = anims.spring_scalar(id, 100.0, spec, 0.10)
    anims.spring_scalar(id, -100.0, spec, 0.10).should eq mid
    anims.running?(id, 0.10).should be_true
    anims.spring_scalar(id, -100.0, spec, 0.116).should_not eq mid
    # …and it settles exactly. (Frame-sized steps: a big time gap is
    # CLAMPED to 1/30 s like Raven's `rvn_animation_dt` — a hidden
    # window never fast-forwards through the missed time.)
    t = 0.116
    120.times { anims.spring_scalar(id, -100.0, spec, t += 1.0 / 60.0) }
    anims.spring_scalar(id, -100.0, spec, t += 1.0 / 60.0).should eq -100.0
    anims.running?(id, t).should be_false

    # A spec delay holds the value before the motion starts.
    did = Egui::Id.from("delayed")
    delayed = Egui::Spring::Spec.new(0.16, 0.9, 0.1)
    anims.spring_scalar(did, 0.0, delayed, 0.0).should eq 0.0
    anims.spring_scalar(did, 50.0, delayed, 0.016).should eq 0.0 # in delay
    anims.running?(did, 0.016).should be_true                   # still waiting
    t = 0.016
    held = 0
    loop do # ~0.1 s of delay at ~60 fps, then the motion starts
      t += 1.0 / 60.0
      break if anims.spring_scalar(did, 50.0, delayed, t) > 0.0
      held += 1
    end
    held.should be > 3
    held.should be < 10
  end

  it "StyleAnimations springs colors channel-wise" do
    anims = Egui::StyleAnimations.new
    id = Egui::Id.from("c")
    spec = Egui::Spring::Spec.smooth
    from = Egui::Color32.rgb(0, 0, 0)
    to = Egui::Color32.rgb(100, 0, 0)

    anims.spring_color(id, from, spec, 0.0).should eq from # snaps
    mid = anims.spring_color(id, to, spec, 0.016)
    mid.r.should be > 0
    mid.r.should be < 100
    anims.running?(id, 0.016).should be_true
    t = 0.016
    120.times { anims.spring_color(id, to, spec, t += 1.0 / 60.0) }
    anims.spring_color(id, to, spec, t += 1.0 / 60.0).should eq to
    anims.running?(id, t).should be_false
  end
end
