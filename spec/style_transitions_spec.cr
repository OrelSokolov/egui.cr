# Ур.1 of plans/animations.md: cascade-driven `transition` — a
# declared style value eases towards its new target instead of
# snapping (smoothstep, retarget mid-flight restarts from the current
# value, first sighting snaps like CSS).
require "spec"
require "../src/egui"

TRANS_SCREEN = Egui::Rect.from_min_size(
  Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

private def trans_frame(ctx : Egui::Context, t : Float64,
                        events : Array(Egui::Event) = [] of Egui::Event,
                        &app : Egui::Context ->)
  raw = Egui::RawInput.new(TRANS_SCREEN, events, t)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

describe "style transitions" do
  it "StyleAnimations eases colors and scalars, retargets mid-flight" do
    anims = Egui::StyleAnimations.new
    id = Egui::Id.from("w")
    from = Egui::Color32.rgb(0, 0, 0)
    to = Egui::Color32.rgb(100, 0, 0)

    anims.color(id, from, 0.1, 0.0).should eq from # first sighting snaps
    anims.running?(id, 0.05).should be_true

    mid = anims.color(id, to, 0.1, 0.05) # retarget at the midpoint
    mid.r.should eq from.r               # at the retarget instant…
    mid = anims.color(id, to, 0.1, 0.08) # …then it eases towards `to`
    mid.r.should be > from.r
    mid.r.should be < to.r
    anims.color(id, to, 0.1, 0.15).should eq to # settled past duration
    anims.running?(id, 0.2).should be_false

    # Scalars share the semantics (a separate id — the color test
    # above owns "w").
    sid = Egui::Id.from("scalar")
    anims.scalar(sid, 0.0, 0.1, 0.0).should eq 0.0
    anims.scalar(sid, 100.0, 0.1, 0.05).should eq 0.0 # retarget instant
    v = anims.scalar(sid, 100.0, 0.1, 0.08)           # easing underway
    v.should be > 0.0
    v.should be < 100.0
    anims.scalar(sid, 100.0, 0.1, 0.2).should eq 100.0

    # duration 0 = snap and no state kept.
    anims.color(id, from, 0.0, 0.3).should eq from
    anims.running?(id, 0.3).should be_false
  end

  it "transition.width animates a button's declared width across frames" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("button", Egui::StyleVars{
      "width"              => 100.0,
      "transition"         => 100.0, # ms shorthand for every key
    })

    t = 0.0
    widths = [] of Float64
    trans_frame(ctx, t += 0.016) do |c|
      c.central_panel do |ui|
        widths << ui.add(Egui::Button.new("OK")).rect.width
      end
    end
    widths.last.should eq 100.0 # first sighting snaps

    # The declared width changes (a breakpoint flip, a rule edit) —
    # the button eases towards the new target over 100 ms.
    ctx.stylesheet.rule("button", Egui::StyleVars{"width" => 200.0})
    trans_frame(ctx, t += 0.016) do |c|
      c.central_panel do |ui|
        widths << ui.add(Egui::Button.new("OK")).rect.width
      end
    end
    widths.last.should eq 100.0 # retarget instant — still at the start

    trans_frame(ctx, t += 0.05) do |c|
      c.central_panel do |ui|
        widths << ui.add(Egui::Button.new("OK")).rect.width
      end
    end
    widths.last.should be > 100.0   # easing underway at t≈66ms…
    widths.last.should be < 200.0   # …but not there yet

    trans_frame(ctx, t += 0.06) do |c|
      c.central_panel do |ui|
        widths << ui.add(Egui::Button.new("OK")).rect.width
      end
    end
    widths.last.should eq 200.0     # settled past the duration
  end

  it "per-key transition.width beats the shorthand; 0 disables" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("button", Egui::StyleVars{
      "width"             => 100.0,
      "transition"        => 100.0,
      "transition.width"  => 0.0, # disable for the width key
    })
    t = 0.0
    widths = [] of Float64
    trans_frame(ctx, t += 0.016) do |c|
      c.central_panel do |ui|
        widths << ui.add(Egui::Button.new("OK")).rect.width
      end
    end
    ctx.stylesheet.rule("button", Egui::StyleVars{"width" => 200.0})
    trans_frame(ctx, t += 0.016) do |c|
      c.central_panel do |ui|
        widths << ui.add(Egui::Button.new("OK")).rect.width
      end
    end
    widths.last.should eq 200.0 # transition.width: 0 → snap
  end

  it "background_color eases through hover with transition.background" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("button", Egui::StyleVars{
      "background"             => Egui::Color32.rgb(0, 0, 0),
      "transition.background"  => 100.0,
    })
    ctx.stylesheet.rule("button:hover", Egui::StyleVars{
      "background" => Egui::Color32.rgb(100, 0, 0),
    })

    t = 0.0
    rect = nil
    fills = [] of Egui::Color32
    btn = nil
    trans_frame(ctx, t += 0.016) do |c|
      c.central_panel do |ui|
        btn = ui.add(Egui::Button.new("OK", id: "save"))
        rect = btn.not_nil!.rect
      end
    end

    # Hover the button — the fill must be BETWEEN base and hover
    # target mid-transition, not the snapped hover color.
    center = Egui::Pos2.new(rect.not_nil!.center.x, rect.not_nil!.center.y)
    trans_frame(ctx, t += 0.016,
        [Egui::Event.pointer_moved(center)]) do |c|
      c.central_panel do |ui|
        btn = ui.add(Egui::Button.new("OK", id: "save"))
      end
    end
    # The interpolated color is observable through the widget's own
    # resolution path: Widget#background_color via a subclass probe.
    probe = TransProbe.new
    trans_frame(ctx, t += 0.016,
        [Egui::Event.pointer_moved(center)]) do |c|
      c.central_panel do |ui|
        probe.call(ui, Egui::Id.from("save"), "hover")
        fills << probe.fill.not_nil!
        ui.add(Egui::Button.new("OK", id: "save"))
      end
    end
    f = fills.last
    f.r.should be > 0
    f.r.should be < 100
  end
end

# A minimal button-like widget exposing background_color for probing.
class TransProbe
  include Egui::Widget
  property fill : Egui::Color32?

  def style_class : String?
    "button"
  end

  def call(ui : Egui::Ui, id : Egui::Id, state : String) : Nil
    @fill = background_color(ui, id, state, state == "hover", false)
  end

  def ui(ui : Egui::Ui) : Egui::Response
    raise "probe is not drawable"
  end
end
