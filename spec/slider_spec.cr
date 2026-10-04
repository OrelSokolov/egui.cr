require "spec"
require "../src/egui"

# Slider extras beyond the plain upstream port: macOS-style tips
# ({left, right} captions under the rail) and the quantized flavor
# (value restricted to a list the handle snaps onto).

SLIDER_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

def slider_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event, time : Float64 = 0.016, &)
  ctx.begin_frame(Egui::RawInput.new(SLIDER_SCREEN, events, time))
  yield ctx
  ctx.end_frame
end

describe Egui::Slider do
  it "refuses quantized without a values list" do
    expect_raises(ArgumentError) do
      Egui::Slider.new(0.5, 0.0..1.0, quantized: true)
    end
    expect_raises(ArgumentError) do
      Egui::Slider.new(0.5, 0.0..1.0, quantized: true, values: [] of Float64)
    end
  end

  it "refuses ticks without a values list" do
    expect_raises(ArgumentError) do
      Egui::Slider.new(0.5, 0.0..1.0, ticks: true)
    end
  end

  it "snaps the initial value onto the list" do
    ctx = Egui::Context.new
    value = 0.0_f64
    slider_frame(ctx) do |c|
      c.window("demo") do |ui|
        value = ui.slider(0.3, 0.0..1.0, quantized: true,
          values: [0.0, 0.5, 1.0]) { |v| value = v }.widget_value.not_nil!
      end
    end
    value.should eq(0.5) # nearest list entry, not the raw 0.3
  end

  it "quantizes a drag to the nearest list entry" do
    ctx = Egui::Context.new
    values = [0.0, 0.25, 0.5, 0.75, 1.0]
    rail = nil
    value = 0.0_f64

    slider_frame(ctx) do |c|
      c.window("demo") do |ui|
        rail = ui.slider(0.5, 0.0..1.0, quantized: true,
          values: values) { |v| value = v }.rect
      end
    end
    r = rail.not_nil!

    # Press at the left end, drag to the right end.
    events = [Egui::Event.pointer_moved(Egui::Pos2.new(r.left, r.center.y)),
              Egui::Event.pointer_pressed(Egui::Pos2.new(r.left, r.center.y))]
    slider_frame(ctx, events: events, time: 0.048) do |c|
      c.window("demo") do |ui|
        ui.slider(value, 0.0..1.0, quantized: true, values: values) { |v| value = v }
      end
    end
    events = [Egui::Event.pointer_moved(Egui::Pos2.new(r.right, r.center.y))]
    slider_frame(ctx, events: events, time: 0.064) do |c|
      c.window("demo") do |ui|
        ui.slider(value, 0.0..1.0, quantized: true, values: values) { |v| value = v }
      end
    end

    value.should eq(1.0) # exactly the last entry, not 0.99-something
  end

  it "paints tips under the rail, left and right" do
    ctx = Egui::Context.new
    rail = nil

    slider_frame(ctx) do |c|
      c.window("demo") do |ui|
        rail = ui.slider(0.5, 0.0..100.0, tips: {"Quiet", "Loud"}) { |_v| }.rect
      end
    end
    r = rail.not_nil!

    texts = ctx.painter.commands.select(Egui::TextCmd)
    quiet = texts.find(&.text.==("Quiet")).should_not be_nil
    loud = texts.find(&.text.==("Loud")).should_not be_nil

    # Both sit BELOW the rail row, not beside it.
    quiet.pos.y.should be > r.center.y
    loud.pos.y.should be > r.center.y

    # Flush to the rail ends: left caption at the left edge, the right
    # one not past the right edge.
    quiet.pos.x.should be_close(r.left, 1.0)
    loud.pos.x.should be <= r.right
  end

  it "records tip meta as slider.tip and restyles captions via class rules" do
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    draw = ->(time : Float64) do
      slider_frame(ctx, time: time) do |c|
        c.window("demo") do |ui|
          ui.slider(0.5, 0.0..100.0, tips: {"Quiet", "Loud"}) { |_v| }
        end
      end
    end
    draw.call(0.016)

    # Each caption is a pickable sub-widget: kind, class, textlike
    # props — so the inspector's Element and Class tabs can edit it.
    tips = ctx.inspector.meta_values.select(&.kind.==("SliderTip"))
    tips.size.should eq(2)
    tips.map(&.style_class).uniq.should eq(["slider.tip"])
    tips.map(&.label).compact.sort.should eq(["Loud", "Quiet"])
    tips.first.props.any? { |p| p.key == "text_color" }.should be_true

    # A `slider.tip` rule restyles both captions on the next frame.
    red = Egui::Color32.rgb(255, 0, 0)
    ctx.stylesheet.rule("slider.tip",
      Egui::StyleVars{"text_color" => red, "font_size" => 20.0})
    draw.call(0.032)
    texts = ctx.painter.commands.select(Egui::TextCmd)
    quiet = texts.find(&.text.==("Quiet")).not_nil!
    loud = texts.find(&.text.==("Loud")).not_nil!
    quiet.color.should eq(red)
    loud.color.should eq(red)
    quiet.size.should eq(20.0)
    loud.size.should eq(20.0)
  end

  it "draws one vertical tick stroke per quant, stylable as slider.tick" do
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    values = [0.0, 0.25, 0.5, 0.75, 1.0]
    rail = nil
    draw = ->(time : Float64) do
      slider_frame(ctx, time: time) do |c|
        c.window("demo") do |ui|
          rail = ui.slider(0.5, 0.0..1.0, quantized: true, ticks: true,
            values: values) { |_v| }.rect
        end
      end
    end
    draw.call(0.016)
    r = rail.not_nil!

    # One stroke per entry, under the rail, vertical, evenly spaced at
    # the handle's own quant spots (first flush left, last flush right).
    strokes = ctx.painter.commands.select(Egui::LineCmd)
      .select { |l| l.p1.y > r.bottom && l.p2.y > l.p1.y &&
                    l.p2.x == l.p1.x }
    strokes.size.should eq(values.size)
    handle_r = 6.0
    span = r.width - 2 * handle_r
    strokes.first.p1.x.should be_close(r.left + handle_r, 0.5)
    strokes.last.p1.x.should be_close(r.left + handle_r + span, 0.5)
    # evenly index-spaced
    gaps = [] of Float64
    strokes.each_cons(2) { |pair| gaps << pair[1].p1.x - pair[0].p1.x }
    (gaps.max - gaps.min).should be < 0.5

    # The row records inspector meta under the slider.tick class, and a
    # rule restyles the strokes on the next frame.
    tick = ctx.inspector.meta_values.find(&.kind.==("SliderTick")).not_nil!
    tick.style_class.should eq("slider.tick")
    tick.props.any? { |p| p.key == "stroke" }.should be_true

    red = Egui::Color32.rgb(255, 0, 0)
    ctx.stylesheet.rule("slider.tick",
      Egui::StyleVars{"stroke" => red, "height" => 9.0})
    draw.call(0.032)
    strokes = ctx.painter.commands.select(Egui::LineCmd)
      .select { |l| l.color == red }
    strokes.size.should eq(values.size)
    strokes.each { |l| (l.p2.y - l.p1.y).should be_close(9.0, 0.5) }
  end
end
