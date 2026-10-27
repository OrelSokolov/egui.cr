# Touch gesture semantics in Textarea (Android): the finger-specific
# routing introduced with Event#from_touch —
#   * a finger tap never drags a selection (touch slop),
#   * a plain finger drag scrolls the viewport instead of selecting,
#   * a long-press selects the word and shows handles but NO menu,
#   * the NEXT long-press (a selection exists) opens the menu,
#   * dragging a selection handle moves that selection edge.
# The mouse path must keep selecting on drag as before.

require "spec"
require "../src/egui"

TSEL_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(400.0, 300.0))
TSEL_TEXT = "alpha beta gamma delta epsilon zeta\n" * 12

def tsel_frame(ctx : Egui::Context,
               events : Array(Egui::Event) = [] of Egui::Event,
               time : Float64 = 0.016)
  ctx.begin_frame(Egui::RawInput.new(TSEL_SCREEN, events, time))
  ctx.central_panel do |ui|
    ui.textarea(TSEL_TEXT, rows: 6) { |_t| }
  end
  ctx.end_frame
end

# The textarea's rect — the only tall widget on screen.
def tsel_rect(ctx : Egui::Context) : Egui::Rect
  ctx.memory.widget_rects.each_value.max_by(&.height)
end

# Focused textarea's {cursor, anchor} via the IME mirror.
def tsel_selection(ctx : Egui::Context) : {Int32, Int32}
  ti = ctx.memory.focused_text_input.not_nil!
  {ti[:cursor], ti[:anchor]}
end

def tsel_offset(ctx : Egui::Context) : Float64
  # The textarea's own scroll cell (other scroll registrations may
  # share the table) — the greatest stored offset on screen is it.
  ctx.memory.scroll_rects.each_key
    .max_of { |k| ctx.memory.data.get_vec2(k, Egui::Vec2.zero).y }
end

def tsel_press(pos : Egui::Pos2, touch : Bool) : Array(Egui::Event)
  [Egui::Event.pointer_pressed(pos, from_touch: touch)]
end

# Run a long-press to completion: press at `pos`, hold still past
# LONG_PRESS_TIME. `t0` is the press frame's time.
def tsel_long_press(ctx : Egui::Context, pos : Egui::Pos2, t0 : Float64)
  tsel_frame(ctx, tsel_press(pos, true), t0)
  tsel_frame(ctx, time: t0 + 0.2)
  tsel_frame(ctx, time: t0 + 0.4)
  tsel_frame(ctx, time: t0 + 0.55) # >= LONG_PRESS_TIME: fires here
end

describe "textarea touch gestures" do
  it "a mouse drag past CLICK_MAX_DIST selects" do
    ctx = Egui::Context.new
    2.times { |i| tsel_frame(ctx, time: 0.016 * (i + 1)) }
    rect = tsel_rect(ctx)
    grab = Egui::Pos2.new(rect.left + 30.0, rect.top + 14.0)

    tsel_frame(ctx, tsel_press(grab, false), 0.064)
    tsel_frame(ctx, [Egui::Event.pointer_moved(
      Egui::Pos2.new(grab.x + 40.0, grab.y))], 0.08)
    cursor, anchor = tsel_selection(ctx)
    anchor.should_not eq(cursor)
  end

  it "a finger wobble inside the touch slop stays a tap (no selection)" do
    ctx = Egui::Context.new
    2.times { |i| tsel_frame(ctx, time: 0.016 * (i + 1)) }
    rect = tsel_rect(ctx)
    grab = Egui::Pos2.new(rect.left + 30.0, rect.top + 14.0)

    tsel_frame(ctx, tsel_press(grab, true), 0.064)
    # 10px: past the mouse 6px threshold, well inside the 16px slop.
    tsel_frame(ctx, [Egui::Event.pointer_moved(
      Egui::Pos2.new(grab.x + 10.0, grab.y), from_touch: true)], 0.08)
    cursor, anchor = tsel_selection(ctx)
    anchor.should eq(cursor)
  end

  it "a plain finger drag scrolls the content instead of selecting" do
    ctx = Egui::Context.new
    2.times { |i| tsel_frame(ctx, time: 0.016 * (i + 1)) }
    rect = tsel_rect(ctx)
    grab = Egui::Pos2.new(rect.left + 100.0, rect.top + 60.0)

    tsel_frame(ctx, tsel_press(grab, true), 0.064)
    # Flick up 60px: content follows the finger up → offset grows.
    tsel_frame(ctx, [Egui::Event.pointer_moved(
      Egui::Pos2.new(grab.x, grab.y - 60.0), from_touch: true)], 0.08)
    tsel_offset(ctx).should be > 0.0
    cursor, anchor = tsel_selection(ctx)
    anchor.should eq(cursor) # no accidental selection
  end

  it "long-press selects the word, shows handles and NO menu" do
    ctx = Egui::Context.new
    2.times { |i| tsel_frame(ctx, time: 0.016 * (i + 1)) }
    rect = tsel_rect(ctx)
    pos = Egui::Pos2.new(rect.left + 100.0, rect.top + 14.0)

    tsel_long_press(ctx, pos, 0.064)
    cursor, anchor = tsel_selection(ctx)
    anchor.should_not eq(cursor) # word under the finger selected
    ctx.popup_opened_this_frame?.should be_false

    # Handles register the frame AFTER the selection appears (their
    # hit-rects come from the previous frame's geometry): two 40×44
    # grab zones under the edges.
    tsel_frame(ctx, time: 0.63)
    handles = ctx.memory.widget_rects.each_value
      .select { |r| r.width == 40.0 && r.height == 44.0 }.to_a
    handles.size.should eq(2)
  end

  it "the second long-press over a selection opens the menu" do
    ctx = Egui::Context.new
    2.times { |i| tsel_frame(ctx, time: 0.016 * (i + 1)) }
    rect = tsel_rect(ctx)
    pos = Egui::Pos2.new(rect.left + 100.0, rect.top + 14.0)

    tsel_long_press(ctx, pos, 0.064)
    before = tsel_selection(ctx)
    tsel_frame(ctx, [Egui::Event.pointer_released(pos, from_touch: true)],
      0.66)

    # Long-press #2: a selection already exists → the menu opens and
    # the selection survives the press.
    tsel_long_press(ctx, pos, 0.8)
    tsel_selection(ctx).should eq(before)
    ctx.popup_opened_this_frame?.should be_true
  end

  it "dragging the left handle moves the selection's left edge" do
    ctx = Egui::Context.new
    2.times { |i| tsel_frame(ctx, time: 0.016 * (i + 1)) }
    rect = tsel_rect(ctx)
    pos = Egui::Pos2.new(rect.left + 100.0, rect.top + 14.0)

    tsel_long_press(ctx, pos, 0.064)
    # Still holding the long-press: sweep right to widen the selection
    # (long-press-drag extends it), then lift the finger.
    far = Egui::Pos2.new(pos.x + 100.0, pos.y)
    tsel_frame(ctx, [Egui::Event.pointer_moved(far, from_touch: true)], 0.63)
    tsel_frame(ctx, [Egui::Event.pointer_released(far, from_touch: true)],
      0.66)
    tsel_frame(ctx, time: 0.68)
    cursor_before, anchor_before = tsel_selection(ctx)
    anchor_before.should be < cursor_before # wide selection: handles apart

    # Grab the LEFT handle (smaller x) and drag it right along the row.
    handles = ctx.memory.widget_rects.each_value
      .select { |r| r.width == 40.0 && r.height == 44.0 }.to_a.sort_by(&.left)
    left, right = handles.first, handles.last
    left.right.should be < right.left # zones don't overlap
    grab = left.center
    tsel_frame(ctx, tsel_press(grab, true), 0.7)
    tsel_frame(ctx, [Egui::Event.pointer_moved(
      Egui::Pos2.new(grab.x + 50.0, grab.y), from_touch: true)], 0.72)

    cursor, anchor = tsel_selection(ctx)
    cursor.should eq(cursor_before)   # right edge untouched…
    anchor.should be > anchor_before  # …left edge followed the finger
  end
end
