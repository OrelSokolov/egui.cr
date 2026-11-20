# Popup layer/clip restore + nested-popup z (plans/todo/render_fixes.md):
# a popup borrows the painter — content painted after it inside its
# host keeps the host's layer/clip (no reset to Background+infinite) —
# and a popup opened from a Foreground host (modal / embedded window)
# rides one notch above it (z=100), so paint order AND hit-tests put it
# over the opener.

require "spec"
require "../src/egui"

PR_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 400.0))

def pr_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
             time : Float64 = 0.016, &)
  ctx.begin_frame(Egui::RawInput.new(PR_SCREEN, events, time))
  yield ctx
  ctx.end_frame
end

# The first TextCmd with exactly this text plus its RAW command-list
# index — Painter#layer_at reads the pre-sort z tag.
def pr_text_at(ctx : Egui::Context, text : String) : Tuple(Egui::TextCmd, Int32)
  ctx.painter.commands.each_with_index do |c, i|
    return {c.as(Egui::TextCmd), i} if c.is_a?(Egui::TextCmd) && c.text == text
  end
  raise "no text command #{text.inspect}"
end

# The regression host: an embedded window whose first label opens a
# context menu (selectable labels attach Copy / Select all), the second
# label painted after the popup — the original canary.
def pr_embedded_host(ctx : Egui::Context, first_rect : Array(Egui::Rect)) : Nil
  ctx.embedded_window("w", title: "T", width: 300.0) do |ui|
    resp = ui.label("first")
    first_rect[0] = resp.rect
    ui.label("second")
  end
end

def pr_modal_host(ctx : Egui::Context, first_rect : Array(Egui::Rect)) : Nil
  ctx.modal("m", width: 300.0, title: "M") do |ui|
    resp = ui.label("first")
    first_rect[0] = resp.rect
    ui.label("second")
  end
end

def pr_open_context_menu(ctx : Egui::Context,
                         first_rect : Array(Egui::Rect),
                         &host : Egui::Context -> Nil) : Nil
  2.times { |i| pr_frame(ctx, time: 0.016 * (i + 1)) { |c| host.call(c) } }
  p = first_rect[0].center
  pr_frame(ctx, [Egui::Event.pointer_moved(p),
    Egui::Event.pointer_pressed(p, :secondary)], 0.048) { |c| host.call(c) }
end

describe "popup layer restore" do
  it "keeps host content painted after the popup on the host's layer and clip" do
    ctx = Egui::Context.new
    rect = [Egui::Rect.zero]
    pr_open_context_menu(ctx, rect) { |c| pr_embedded_host(c, rect) }

    ctx.memory.open_popups.should_not be_empty

    # The first label's galley (painted AFTER the popup attach) and the
    # next label stay on the embedded window's Foreground layer (99),
    # clipped to the card — not dropped to Background+infinite.
    gal, gi = pr_text_at(ctx, "first")
    ctx.painter.layer_at(gi).should eq(99)
    gal.clip.width.should be < 1e6
    nxt, ni = pr_text_at(ctx, "second")
    ctx.painter.layer_at(ni).should eq(99)
    nxt.clip.width.should be < 1e6

    # The menu itself rides ABOVE the host (nested-popup z rule).
    _, mi = pr_text_at(ctx, "Copy")
    ctx.painter.layer_at(mi).should eq(100)
  end

  it "reaches menu rows with clicks while the host blocks below" do
    ctx = Egui::Context.new
    rect = [Egui::Rect.zero]
    pr_open_context_menu(ctx, rect) { |c| pr_embedded_host(c, rect) }

    # Click the enabled "Select all" row: the handler must fire even
    # though the embedded window's card click-claim sits in the same
    # Foreground band at a lower z.
    pos = pr_text_at(ctx, "Select all")[0].pos
    pr_frame(ctx, [Egui::Event.pointer_moved(pos),
      Egui::Event.pointer_pressed(pos)], 0.064) { |c| pr_embedded_host(c, rect) }
    pr_frame(ctx, [Egui::Event.pointer_released(pos)], 0.080) do |c|
      pr_embedded_host(c, rect)
    end

    ctx.text_selection.any_selection?.should be_true
  end

  it "does the same for a modal host" do
    ctx = Egui::Context.new
    rect = [Egui::Rect.zero]
    pr_open_context_menu(ctx, rect) { |c| pr_modal_host(c, rect) }

    ctx.memory.open_popups.should_not be_empty

    gal, gi = pr_text_at(ctx, "first")
    ctx.painter.layer_at(gi).should eq(99)
    gal.clip.width.should be < 1e6
    nxt, ni = pr_text_at(ctx, "second")
    ctx.painter.layer_at(ni).should eq(99)
    nxt.clip.width.should be < 1e6
    _, mi = pr_text_at(ctx, "Copy")
    ctx.painter.layer_at(mi).should eq(100)
  end
end
