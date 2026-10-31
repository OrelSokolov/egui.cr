# AboutModal: a wide modal whose body is markdown in a scroll area —
# long documents cap at a screen share instead of growing past the
# screen, and the dialog reports closing (Close button or scrim).
require "spec"
require "../src/egui"

AM_SCREEN = Egui::Rect.from_min_size(
  Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

private def am_frame(ctx : Egui::Context, events = [] of Egui::Event,
                     &app : Egui::Context ->)
  raw = Egui::RawInput.new(AM_SCREEN, events, 0.016)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

describe "AboutModal" do
  it "is wider than a standard modal" do
    Egui::AboutModal::DEFAULT_WIDTH.should be > 480.0
  end

  it "caps a long markdown body instead of overflowing the screen" do
    ctx = Egui::Context.new
    long_md = (1..60).map { |i| "## Section #{i}\n\n" +
      "Paragraph #{i} — the quick brown fox jumps over the lazy dog " +
      "с русским текстом для переносов, " * 4 }.join("\n")
    modal = Egui::AboutModal.new("About", long_md)
    3.times { am_frame(ctx) { |c| modal.show(c).should be_false } }
    # The card (title + capped body + footer) must fit the screen.
    size = ctx.memory.layer_sizes[Egui::Id.from("modal/about")].not_nil!
    size.y.should be <= AM_SCREEN.height
    # And the body itself is capped at its screen share.
    size.y.should be <= AM_SCREEN.height *
      (Egui::AboutModal::BODY_SCREEN_SHARE + 0.25)
  end

  it "closes on a scrim click" do
    ctx = Egui::Context.new
    modal = Egui::AboutModal.new("About", "# Hello\n\nbody")
    # One frame to lay the card out, then click OUTSIDE it — the
    # click lands on the scrim.
    am_frame(ctx) { |c| modal.show(c).should be_false }
    events = [
      Egui::Event.pointer_moved(Egui::Pos2.new(20.0, 20.0)),
      Egui::Event.pointer_pressed(Egui::Pos2.new(20.0, 20.0)),
      Egui::Event.pointer_released(Egui::Pos2.new(20.0, 20.0)),
    ] of Egui::Event
    closed = false
    am_frame(ctx, events) { |c| closed = modal.show(c) }
    closed.should be_true
  end
end
