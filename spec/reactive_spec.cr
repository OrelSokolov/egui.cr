require "spec"
require "../src/egui"

REACTIVE_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 300.0))

def reactive_frame(ctx : Egui::Context, &)
  ctx.begin_frame(Egui::RawInput.new(REACTIVE_SCREEN, [] of Egui::Event, 0.016))
  yield
  ctx.end_frame
end

class ReactiveApp < Egui::App
  reactive count = 0
  reactive name = "a"
  # Independent input: writes to it must not dirty `doubled`.
  reactive other = 0

  # How many times the `doubled` block ran (memoization probe).
  class_property doubled_runs = 0
  class_property chain_runs = 0

  computed doubled : Int32 = begin
    ReactiveApp.doubled_runs += 1
    count * 2
  end

  # computed-of-computed: chain → doubled → count.
  computed chain : Int32 = begin
    ReactiveApp.chain_runs += 1
    doubled + 1
  end

  computed self_ref : Int32 = self_ref_value

  def self_ref_value : Int32
    self_ref
  end

  def update(ctx : Egui::Context) : Nil
  end
end

describe Egui::Signal do
  it "bumps the version only on a real change" do
    sig = Egui::Signal.new(1)
    v0 = sig.version
    sig.value = 1
    sig.version.should eq v0
    sig.value = 2
    sig.version.should eq v0 + 1
    sig.value.should eq 2
  end

  it "requests a repaint on an out-of-frame write, not for the same value" do
    app = ReactiveApp.new
    ctx = app.ctx
    ctx.needs_repaint?.should be_false
    reactive_frame(ctx) { } # no writes → no repaint request
    ctx.needs_repaint?.should be_false
    app.name = "b"
    ctx.needs_repaint?.should be_true
  end

  it "skips the repaint request for writes made inside a frame" do
    app = ReactiveApp.new
    ctx = app.ctx
    ctx.in_frame?.should be_false
    reactive_frame(ctx) do
      ctx.in_frame?.should be_true
      app.count = 5
      ctx.needs_repaint?.should be_false
    end
    ctx.in_frame?.should be_false
    app.count.should eq 5
  end

  it "works without a context (headless signals)" do
    sig = Egui::Signal.new("x")
    sig.value = "y"
    sig.value.should eq "y"
  end
end

describe Egui::Computed do
  it "computes lazily, once, and only recomputes after an input changes" do
    app = ReactiveApp.new
    ReactiveApp.doubled_runs = 0
    app.doubled.should eq 0
    app.doubled.should eq 0
    ReactiveApp.doubled_runs.should eq 1

    app.count = 7
    app.doubled.should eq 14
    ReactiveApp.doubled_runs.should eq 2
    app.doubled.should eq 14
    ReactiveApp.doubled_runs.should eq 2
  end

  it "cascades dirty marks through computed-of-computed" do
    app = ReactiveApp.new
    app.chain # warm both levels
    ReactiveApp.doubled_runs = 0
    ReactiveApp.chain_runs = 0

    app.count = 10
    app.@chain_cell.dirty?.should be_true
    app.chain.should eq 21
    ReactiveApp.chain_runs.should eq 1
    ReactiveApp.doubled_runs.should eq 1
  end

  it "does not dirty on writes to unrelated signals" do
    app = ReactiveApp.new
    app.chain
    app.other = 99
    app.@doubled_cell.dirty?.should be_false
    app.@chain_cell.dirty?.should be_false
  end

  it "does not propagate when a recompute yields the old value" do
    app = ReactiveApp.new
    len = Egui::Computed.new { app.name.size }
    len.value.should eq 1
    node = len.as(Egui::ComputedBase)
    v = node.version

    app.name = "c" # different input, same output
    node.dirty?.should be_true
    len.value.should eq 1
    node.version.should eq v # no bump → dependents stay clean
  end

  it "raises on a computed that reads itself" do
    app = ReactiveApp.new
    expect_raises(Egui::RecursionError) { app.self_ref }
  end

  it "drops stale dependencies after a recompute" do
    app = ReactiveApp.new
    # `doubled` depends on count; make a fresh computed whose deps we
    # control directly through signal reads.
    a = Egui::Signal.new(1)
    b = Egui::Signal.new(100)
    use_b = Egui::Signal.new(false)
    c = Egui::Computed.new { use_b.value ? b.value : a.value }
    c.value.should eq 1
    c.as(Egui::ComputedBase).deps.size.should eq 2 # a + use_b

    use_b.value = true
    c.value.should eq 100
    c.as(Egui::ComputedBase).deps.size.should eq 2 # b + use_b
    c.as(Egui::ComputedBase).deps.should_not contain(a)

    # a is no longer a dependency: writing it must not dirty c.
    a.value = 2
    c.as(Egui::ComputedBase).dirty?.should be_false
    b.value = 200
    c.as(Egui::ComputedBase).dirty?.should be_true
  end
end

describe "reactive macro fields" do
  it "generates plain-looking getter/setter pairs" do
    app = ReactiveApp.new
    app.count.should eq 0
    app.count += 1
    app.count.should eq 1
    app.name.should eq "a"
    app.name = "b"
    app.name.should eq "b"
  end

  it "typed setters reject wrong types at compile time" do
    # Compile-time behavior; runtime assertion keeps the spec honest
    # that the macro preserved the declared type.
    app = ReactiveApp.new
    typeof(app.count).should eq Int32
    typeof(app.name).should eq String
  end
end

describe "reactive ui bindings" do
  it "checkbox binding writes the signal back on click" do
    app = ReactiveApp.new
    ctx = app.ctx
    checked = Egui::Signal.new(false)
    center = nil

    reactive_frame(ctx) do
      ctx.window("demo") do |ui|
        center = ui.checkbox(checked, "Toggle").rect.center
      end
    end

    # press + release over the checkbox
    events = [Egui::Event.pointer_moved(center.not_nil!),
              Egui::Event.pointer_pressed(center.not_nil!)]
    ctx.begin_frame(Egui::RawInput.new(REACTIVE_SCREEN, events, 0.048))
    ctx.window("demo") { |ui| ui.checkbox(checked, "Toggle") }
    ctx.end_frame
    ctx.begin_frame(Egui::RawInput.new(REACTIVE_SCREEN,
      [Egui::Event.pointer_released(center.not_nil!)], 0.064))
    ctx.window("demo") { |ui| ui.checkbox(checked, "Toggle") }
    ctx.end_frame

    checked.value.should be_true
    # A second click toggles it back off.
    events = [Egui::Event.pointer_pressed(center.not_nil!)]
    ctx.begin_frame(Egui::RawInput.new(REACTIVE_SCREEN, events, 0.08))
    ctx.window("demo") { |ui| ui.checkbox(checked, "Toggle") }
    ctx.end_frame
    ctx.begin_frame(Egui::RawInput.new(REACTIVE_SCREEN,
      [Egui::Event.pointer_released(center.not_nil!)], 0.096))
    ctx.window("demo") { |ui| ui.checkbox(checked, "Toggle") }
    ctx.end_frame
    checked.value.should be_false
  end

  it "slider binding follows a drag" do
    app = ReactiveApp.new
    ctx = app.ctx
    speed = Egui::Signal.new(0.0)
    rail = nil

    # frame 1: layout, learn the rail rect
    reactive_frame(ctx) do
      ctx.window("demo") do |ui|
        rail = ui.slider(speed, 0.0..1.0).rect
      end
    end

    r = rail.not_nil!
    # frame 2: move + press at the left end
    events = [Egui::Event.pointer_moved(Egui::Pos2.new(r.left, r.center.y)),
              Egui::Event.pointer_pressed(Egui::Pos2.new(r.left, r.center.y))]
    ctx.begin_frame(Egui::RawInput.new(REACTIVE_SCREEN, events, 0.048))
    ctx.window("demo") { |ui| ui.slider(speed, 0.0..1.0) }
    ctx.end_frame

    # frame 3: still down, drag to the right end — value follows
    events = [Egui::Event.pointer_moved(Egui::Pos2.new(r.right, r.center.y))]
    ctx.begin_frame(Egui::RawInput.new(REACTIVE_SCREEN, events, 0.064))
    ctx.window("demo") { |ui| ui.slider(speed, 0.0..1.0) }
    ctx.end_frame

    speed.value.should be > 0.9
  end
end
