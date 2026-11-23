# Phase 4 overlays (plans/todo/mobile_widgets.md #13–#15): headless
# state-machine and geometry checks — Dialog opens/closes on scrim tap
# and its buttons fire; BottomSheet slides, settles at the bottom
# edge, re-slides after a dismissal; PullToRefresh reserves/collapses
# its spinner strip and resolves its class style keys.

require "spec"
require "../src/egui"
require "../src/egui/containers/bottom_sheet"
require "../src/egui/widgets/dialog"
require "../src/egui/widgets/pull_to_refresh"

SHEET_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 600.0))

def overlay_frame(ctx : Egui::Context,
                  events : Array(Egui::Event) = [] of Egui::Event,
                  time : Float64 = 0.016, &)
  ctx.begin_frame(Egui::RawInput.new(SHEET_SCREEN, events, time))
  yield ctx
  ctx.end_frame
end

def tap_events(at : Egui::Pos2) : Array(Egui::Event)
  [
    Egui::Event.pointer_moved(at),
    Egui::Event.pointer_pressed(at),
    Egui::Event.pointer_released(at),
  ] of Egui::Event
end

describe Egui::Dialog do
  it "centers the card and fires the clicked button once" do
    ctx = Egui::Context.new
    dialog = Egui::Dialog.new(title: "Delete file?",
      body: "This cannot be undone.",
      buttons: ["Cancel", "Delete"], id: "d1")
    result = nil
    overlay_frame(ctx) { result = dialog.show(ctx) }
    result.should be_nil
    overlay_frame(ctx, time: 0.032) { result = dialog.show(ctx) }
    result.should be_nil

    card = dialog.card_rect.not_nil!
    card.width.should eq 320.0
    card.center.x.should eq 200.0
    card.center.y.should be_close(300.0, 0.5)

    # Both buttons laid out in the row: Delete is the LAST button, so
    # its right edge hugs the card's inner padding edge.
    cancel = dialog.button_rect("Cancel").not_nil!
    del = dialog.button_rect("Delete").not_nil!
    del.left.should be > cancel.right
    card.right.should be > del.right
    del.height.should eq 40.0

    overlay_frame(ctx, tap_events(del.center), 0.048) do
      result = dialog.show(ctx)
    end
    result.should eq "Delete"
    # Nothing still held: a quiet frame fires nothing.
    overlay_frame(ctx, time: 0.064) { result = dialog.show(ctx) }
    result.should be_nil
  end

  it "closes on a scrim tap with the SCRIM marker" do
    ctx = Egui::Context.new
    dialog = Egui::Dialog.new(title: "Sign out?",
      body: "You will need to sign in again.",
      buttons: ["Cancel"], id: "d2")
    overlay_frame(ctx) { dialog.show(ctx) }
    overlay_frame(ctx, time: 0.032) { dialog.show(ctx) }
    result = nil
    # Top-left corner: outside the centered card.
    overlay_frame(ctx, tap_events(Egui::Pos2.new(5.0, 5.0)), 0.048) do
      result = dialog.show(ctx)
    end
    result.should eq Egui::Dialog::SCRIM
  end

  it "caps the button row at three" do
    ctx = Egui::Context.new
    dialog = Egui::Dialog.new(title: "t", body: "b",
      buttons: ["a", "b", "c", "d"], id: "d3")
    overlay_frame(ctx) { dialog.show(ctx) }
    dialog.button_rect("c").should_not be_nil
    dialog.button_rect("d").should be_nil
  end
end

describe Egui::BottomSheet do
  it "slides up from the edge, settles, and dismisses on a scrim tap" do
    ctx = Egui::Context.new
    sheet = Egui::BottomSheet.new(id: "s1")
    closed = false
    body_ran = false
    body = ->(ui : Egui::Ui) do
      body_ran = true
      ui.label("Filters")
      ui.label("Price range")
    end
    overlay_frame(ctx) do
      closed = sheet.show(ctx, &body)
    end
    closed.should be_false
    body_ran.should be_true
    # Still rising: the sheet's bottom edge hangs below the screen.
    r1 = sheet.sheet_rect.not_nil!
    r1.width.should eq 400.0
    r1.left.should eq 0.0
    r1.bottom.should be > 600.0

    t = 0.032
    30.times do
      overlay_frame(ctx, time: t) { sheet.show(ctx, &body) }
      t += 0.016
    end
    r = sheet.sheet_rect.not_nil!
    r.bottom.should be_close(600.0, 1.0)
    r.top.should be < 600.0
    # Handle bar: top center, inside the reserved strip above the body.
    hr = sheet.handle_rect.not_nil!
    hr.center.x.should eq 200.0
    hr.width.should eq 36.0
    hr.height.should eq 4.0
    hr.top.should be >= r.top
    hr.bottom.should be <= r.top + 32.0

    # A quiet frame: no dismissal.
    quiet = false
    overlay_frame(ctx, time: t) { quiet = sheet.show(ctx, &body) }
    quiet.should be_false

    # Tap the top-left corner — the scrim, outside the sheet.
    overlay_frame(ctx, tap_events(Egui::Pos2.new(5.0, 5.0)), t + 0.016) do
      quiet = sheet.show(ctx, &body)
    end
    quiet.should be_true
  end

  it "re-opens with a fresh slide after a scrim dismissal" do
    ctx = Egui::Context.new
    sheet = Egui::BottomSheet.new(id: "s2")
    body = ->(ui : Egui::Ui) { ui.label("Sort by") }
    t = 0.016
    32.times do
      overlay_frame(ctx, time: t) { sheet.show(ctx, &body) }
      t += 0.016
    end
    sheet.sheet_rect.not_nil!.bottom.should be_close(600.0, 1.0)

    # Dismiss, then re-open: the very first frame is mid-slide again
    # (bottom edge below the screen), not a snap at the settled spot.
    overlay_frame(ctx, tap_events(Egui::Pos2.new(5.0, 5.0)), t) do
      sheet.show(ctx, &body).should be_true
    end
    t += 0.016
    overlay_frame(ctx, time: t) do
      sheet.show(ctx, &body)
    end
    sheet.sheet_rect.not_nil!.bottom.should be > 600.0
    # And it settles again.
    30.times do
      t += 0.016
      overlay_frame(ctx, time: t) { sheet.show(ctx, &body) }
    end
    sheet.sheet_rect.not_nil!.bottom.should be_close(600.0, 1.0)
  end

  it "honors the bottom_sheet class style keys" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("bottom_sheet", Egui::StyleVars{
      "corner_radius"  => 20.0,
      "handle_width"   => 48.0,
      "handle_height"  => 6.0,
      "slide_response" => 0.1,
    })
    sheet = Egui::BottomSheet.new(id: "s3")
    body = ->(ui : Egui::Ui) { ui.label("x") }
    t = 0.016
    40.times do
      overlay_frame(ctx, time: t) { sheet.show(ctx, &body) }
      t += 0.016
    end
    hr = sheet.handle_rect.not_nil!
    hr.width.should eq 48.0
    hr.height.should eq 6.0
  end
end

describe Egui::PullToRefresh do
  it "reserves the strip while refreshing and collapses when idle" do
    ctx = Egui::Context.new
    idle_r = nil
    busy_r = nil
    overlay_frame(ctx) do
      ctx.window("demo") do |ui|
        idle_r = ui.pull_to_refresh(false, id: "ptr").rect
      end
    end
    idle_r.not_nil!.height.should eq 0.0
    expected_w = 0.0
    overlay_frame(ctx) do
      ctx.window("demo") do |ui|
        expected_w = ui.available_width
        busy_r = ui.pull_to_refresh(true, id: "ptr",
          label: "Refreshing…").rect
      end
    end
    busy_r.not_nil!.height.should eq 56.0
    busy_r.not_nil!.width.should eq expected_w
  end

  it "resolves the pull_to_refresh class style keys" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("pull_to_refresh", Egui::StyleVars{
      "strip_height" => 80.0,
      "spinner_size" => 32.0,
    })
    r = nil
    overlay_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.pull_to_refresh(true, id: "ptr2").rect
      end
    end
    r.not_nil!.height.should eq 80.0
  end

  it "keeps the flow: content below the strip advances past it" do
    ctx = Egui::Context.new
    below = nil
    overlay_frame(ctx) do
      ctx.window("demo") do |ui|
        ui.pull_to_refresh(true, id: "ptr3")
        below = ui.label("list item").rect
      end
    end
    below.not_nil!.top.should be > 56.0
  end
end
