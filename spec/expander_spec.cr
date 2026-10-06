# Expander specs: the open flag is system state (Memory, keyed by the
# header's id), the content block runs only while open (or while the
# reveal animation still shows it), and the block gets a real child Ui
# arbitrary widgets can live in.

require "spec"
require "../src/egui"

EXPANDER_SPEC_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(400.0, 300.0))

private def expander_frame(ctx : Egui::Context, events : Array(Egui::Event),
                           time : Float64, default_open : Bool = false) : Nil
  raw = Egui::RawInput.new(EXPANDER_SPEC_SCREEN, events, time)
  ctx.begin_frame(raw)
  ctx.central_panel do |ui|
    ui.expander("Advanced", default_open: default_open) do |body|
      body.label("content row")
    end
  end
  ctx.end_frame
end

private def header_text_pos(ctx : Egui::Context) : Egui::Pos2?
  ctx.painter.commands.each do |cmd|
    next unless cmd.is_a?(Egui::TextCmd) && cmd.text == "Advanced"
    return cmd.pos
  end
  nil
end

describe Egui::Expander do
  it "shows content only when open" do
    ctx = Egui::Context.new
    expander_frame(ctx, [] of Egui::Event, 0.016)
    header_text_pos(ctx).should_not be_nil
    ctx.painter.commands.any?(&.as?(Egui::TextCmd).try &.text.==("content row"))
      .should be_false

    # Click the header row (at the header's own text position); the
    # click lands one frame after the release. The very first open is
    # a MEASURE frame — the block runs under a collapsed clip, nothing
    # visible — then a retarget frame at amount 0, and only from the
    # next frame does the reveal slide in: no full-height flash on the
    # first toggle.
    pos = header_text_pos(ctx).not_nil!
    expander_frame(ctx,
      [Egui::Event.pointer_pressed(pos)], 0.032)
    expander_frame(ctx,
      [Egui::Event.pointer_released(pos)], 0.048)
    expander_frame(ctx, [] of Egui::Event, 0.064)
    content = ctx.painter.commands.select(Egui::TextCmd)
      .find(&.text.==("content row"))
    # Laid out (measured) but clipped to a degenerate window —
    # nothing is visible yet on the measure frame.
    content.should_not be_nil
    content.not_nil!.clip.max.y.should be <= content.not_nil!.clip.min.y + 0.5
    expander_frame(ctx, [] of Egui::Event, 0.080)
    expander_frame(ctx, [] of Egui::Event, 0.400)
    ctx.painter.commands.any?(&.as?(Egui::TextCmd).try &.text.==("content row"))
      .should be_true
  end

  it "keeps the open flag across frames without app state" do
    ctx = Egui::Context.new
    expander_frame(ctx, [] of Egui::Event, 0.016)
    pos = header_text_pos(ctx).not_nil!
    expander_frame(ctx, [Egui::Event.pointer_pressed(pos)], 0.032)
    expander_frame(ctx, [Egui::Event.pointer_released(pos)], 0.048)
    # Idle frames, no events — still open (past the first-open measure
    # frame, the retarget frame and the 0.2s slide).
    expander_frame(ctx, [] of Egui::Event, 0.064)
    expander_frame(ctx, [] of Egui::Event, 0.080)
    expander_frame(ctx, [] of Egui::Event, 0.400)
    ctx.painter.commands.any?(&.as?(Egui::TextCmd).try &.text.==("content row"))
      .should be_true

    # Click again — closes, and the 0.2s reveal animation must run out
    # before the content disappears (time keeps flowing headless).
    expander_frame(ctx, [Egui::Event.pointer_pressed(pos)], 0.416)
    expander_frame(ctx, [Egui::Event.pointer_released(pos)], 0.432)
    expander_frame(ctx, [] of Egui::Event, 0.464)
    expander_frame(ctx, [] of Egui::Event, 0.800)
    ctx.painter.commands.any?(&.as?(Egui::TextCmd).try &.text.==("content row"))
      .should be_false
  end

  it "honors default_open" do
    ctx = Egui::Context.new
    # default_open must ride EVERY frame (it is only the fallback for
    # a missing Memory cell — the cell appears once the user clicks).
    expander_frame(ctx, [] of Egui::Event, 0.016, default_open: true)
    expander_frame(ctx, [] of Egui::Event, 0.032, default_open: true)
    expander_frame(ctx, [] of Egui::Event, 0.400, default_open: true)
    ctx.painter.commands.any?(&.as?(Egui::TextCmd).try &.text.==("content row"))
      .should be_true
  end

  it "flips the chevron and clips the reveal while animating shut" do
    ctx = Egui::Context.new
    expander_frame(ctx, [] of Egui::Event, 0.016)
    # The chevron is two stroked segments + round-cap dots — it must
    # paint next to the header's right edge from frame one.
    ctx.painter.commands.count(&.is_a?(Egui::LineCmd)).should be >= 2

    # Open, let the first-open reveal settle (measured height stored,
    # animation amount at 1), then close and catch the animation
    # mid-flight: the content is still laid out, but clipped to the
    # shrinking reveal window (its clip bottom sits well above the
    # 300px screen bottom the panel clip would give it).
    pos = header_text_pos(ctx).not_nil!
    expander_frame(ctx, [Egui::Event.pointer_pressed(pos)], 0.032)
    expander_frame(ctx, [Egui::Event.pointer_released(pos)], 0.048)
    expander_frame(ctx, [] of Egui::Event, 0.064)
    expander_frame(ctx, [] of Egui::Event, 0.400)
    expander_frame(ctx, [Egui::Event.pointer_pressed(pos)], 0.416)
    expander_frame(ctx, [Egui::Event.pointer_released(pos)], 0.432)
    expander_frame(ctx, [] of Egui::Event, 0.520)

    content = ctx.painter.commands.select(Egui::TextCmd)
      .find(&.text.==("content row"))
    content.should_not be_nil
    content.not_nil!.clip.max.y.should be < 150.0
  end

  it "paints a left icon when icon: is given" do
    ctx = Egui::Context.new
    raw = Egui::RawInput.new(EXPANDER_SPEC_SCREEN,
      [] of Egui::Event, 0.016)
    ctx.begin_frame(raw)
    ctx.central_panel do |ui|
      ui.expander("Advanced", icon: :bluetooth) { |body| body.label("row") }
    end
    ctx.end_frame
    # 2 chevron segments + the bluetooth rune's 5 segments, all LineCmd.
    ctx.painter.commands.count(&.is_a?(Egui::LineCmd)).should be >= 7
    # The icon sits LEFT of the header text (the chevron's segments
    # are the only lines allowed to its right).
    text = ctx.painter.commands.select(Egui::TextCmd)
      .find(&.text.==("Advanced")).not_nil!
    left = ctx.painter.commands.select(Egui::LineCmd)
      .count { |l| l.p2.x < text.pos.x }
    left.should be >= 5
  end

  it "reports the toggle through Response#changed" do
    ctx = Egui::Context.new
    changed = false
    raw = Egui::RawInput.new(EXPANDER_SPEC_SCREEN,
      [] of Egui::Event, 0.016)
    ctx.begin_frame(raw)
    ctx.central_panel do |ui|
      response = ui.expander("Advanced") { |body| body.label("content row") }
      changed = response.changed?
    end
    ctx.end_frame
    changed.should be_false
  end
end
