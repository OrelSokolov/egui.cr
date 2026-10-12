# Canvas drag-to-scroll (ScrollArea): a drag on the empty canvas moves
# the offset (touch finger / mouse), a drag that starts on an
# interactive widget belongs to the widget and never scrolls, and the
# release velocity carries into the kinetic glide.

require "spec"
require "../src/egui"

SD_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(300.0, 300.0))

SD_VALUE = [0.5]

def sd_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
             time : Float64 = 0.016, with_slider : Bool = false)
  ctx.begin_frame(Egui::RawInput.new(SD_SCREEN, events, time))
  ui = Egui::Ui.new(ctx, Egui::Id.from("spec"), SD_SCREEN)
  ui.scroll_area(max_height: 150.0) do |area|
    # A drag-sensing widget at the top: pressing IT must claim the drag
    # (sliders engage immediately) and cancel the canvas scroll.
    area.slider(SD_VALUE[0], 0.0..1.0, "s") { |t| SD_VALUE[0] = t } if with_slider
    40.times { |i| area.button("btn #{i}") }
  end
  ctx.end_frame
end

# The scroll area's stored offset (y) by id.
def sd_offset(ctx : Egui::Context) : Float64
  ctx.memory.data.get_vec2(
    ctx.memory.scroll_rects.each_key.first, Egui::Vec2.zero).y
end

# A BUTTON's rect (the scroll canvas registers first — filter it out by
# its size: the canvas is viewport-tall, buttons are one line high).
def sd_button_rect(ctx : Egui::Context) : Egui::Rect
  ctx.memory.widget_rects.each_value.find { |r| r.height < 60.0 }.not_nil!
end

describe "ScrollArea canvas drag" do
  it "drag on empty canvas scrolls the content (finger follows)" do
    ctx = Egui::Context.new
    2.times { |i| sd_frame(ctx, time: 0.016 * (i + 1)) }
    # Grab a spot right of a button — inside the viewport, over nothing
    # (labels/background are paint-only; only the canvas senses drag).
    btn_rect = sd_button_rect(ctx)
    grab = Egui::Pos2.new(btn_rect.right + 10.0, btn_rect.top + 4.0)

    sd_frame(ctx, [Egui::Event.pointer_moved(grab),
      Egui::Event.pointer_pressed(grab)], 0.048)
    moved = Egui::Pos2.new(grab.x, grab.y - 60.0)
    sd_frame(ctx, [Egui::Event.pointer_moved(moved)], 0.064)
    # Natural touch scroll: finger up → the content follows → later
    # content is revealed → the offset INCREASES.
    sd_offset(ctx).should be > 0.0
  end

  # Upstream-egui semantics: a press on a drag-SENSING widget (slider,
  # text selection, paint canvas) claims the drag and cancels the
  # scroll. Click-only widgets (buttons, labels) let a finger swipe
  # scroll the list — the standard mobile-list behavior.
  it "drag starting on a drag-sensing widget is the widget's, not a scroll" do
    ctx = Egui::Context.new
    2.times { |i| sd_frame(ctx, time: 0.016 * (i + 1), with_slider: true) }
    on_slider = sd_button_rect(ctx).center

    sd_frame(ctx, [Egui::Event.pointer_moved(on_slider),
      Egui::Event.pointer_pressed(on_slider)], 0.048, with_slider: true)
    moved = Egui::Pos2.new(on_slider.x, on_slider.y - 60.0)
    sd_frame(ctx, [Egui::Event.pointer_moved(moved)], 0.064,
      with_slider: true)
    # The slider engaged the drag on press; the offset must not move.
    sd_offset(ctx).should eq(0.0)
  end
end
