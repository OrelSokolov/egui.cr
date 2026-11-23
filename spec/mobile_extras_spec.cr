# Mobile extras (plans/todo/mobile_widgets.md Phase 6): headless
# geometry, state and callbacks for the five small widgets — range
# slider (incl. the lo <= hi invariant), PIN input (focus advance over
# the existing focus machinery), rating bar (star taps, 1/0.5 steps),
# circular progress (clamping, static) and skeleton (geometry + the
# spinner repaint contract).

require "spec"
require "../src/egui"
require "../src/egui/widgets/range_slider"
require "../src/egui/widgets/pin_input"
require "../src/egui/widgets/rating_bar"
require "../src/egui/widgets/circular_progress"
require "../src/egui/widgets/skeleton"

EXTRAS_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

def extras_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
                 time : Float64 = 0.016, &)
  ctx.begin_frame(Egui::RawInput.new(EXTRAS_SCREEN, events, time))
  yield ctx
  ctx.end_frame
end

# Click helpers: a tap is move+press+release in one frame; a drag is
# press on the grab point, a move frame, then a release frame.
def tap_events(at : Egui::Pos2) : Array(Egui::Event)
  [
    Egui::Event.pointer_moved(at),
    Egui::Event.pointer_pressed(at),
    Egui::Event.pointer_released(at),
  ] of Egui::Event
end

describe Egui::RangeSlider do
  it "lays out on the slider rail geometry" do
    ctx = Egui::Context.new
    rail_h = 0.0
    extras_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.range_slider(20.0, 80.0, 0.0..100.0, id: "rs")
        rail_h = ui.style.spacing.interact_size.y
        r.rect.height.should eq rail_h
        r.rect.width.should be > 0.0
        r.changed?.should be_false
      end
    end
  end

  it "drags the nearest thumb and reports the pair" do
    ctx = Egui::Context.new
    rect = nil
    extras_frame(ctx) do
      ctx.window("demo") do |ui|
        rect = ui.range_slider(0.0, 100.0, 0.0..100.0, id: "rs2").rect
      end
    end
    r = rect.not_nil!
    grab = Egui::Pos2.new(r.left + 6.0, r.center.y) # the lo thumb
    mid = Egui::Pos2.new(r.center.x, r.center.y)    # maps to exactly 50
    extras_frame(ctx, [Egui::Event.pointer_moved(grab),
                       Egui::Event.pointer_pressed(grab)]) do
      ctx.window("demo") do |ui|
        ui.range_slider(0.0, 100.0, 0.0..100.0, id: "rs2")
      end
    end
    lo = 0.0
    hi = 0.0
    extras_frame(ctx, [Egui::Event.pointer_moved(mid)]) do
      ctx.window("demo") do |ui|
        ui.range_slider(0.0, 100.0, 0.0..100.0, id: "rs2") do |a, b|
          lo = a
          hi = b
        end
      end
    end
    lo.should eq 50.0
    hi.should eq 100.0
    extras_frame(ctx, [Egui::Event.pointer_released(mid)]) do
      ctx.window("demo") do |ui|
        ui.range_slider(0.0, 100.0, 0.0..100.0, id: "rs2")
      end
    end
  end

  it "enforces the lo <= hi invariant on drag" do
    ctx = Egui::Context.new
    rect = nil
    extras_frame(ctx) do
      ctx.window("demo") do |ui|
        rect = ui.range_slider(0.0, 100.0, 0.0..100.0, id: "rs3").rect
      end
    end
    r = rect.not_nil!
    grab = Egui::Pos2.new(r.left + 6.0, r.center.y)
    beyond = Egui::Pos2.new(r.right - 1.0, r.center.y)
    extras_frame(ctx, [Egui::Event.pointer_moved(grab),
                       Egui::Event.pointer_pressed(grab)]) do
      ctx.window("demo") do |ui|
        ui.range_slider(0.0, 100.0, 0.0..100.0, id: "rs3")
      end
    end
    lo = 0.0
    hi = 0.0
    extras_frame(ctx, [Egui::Event.pointer_moved(beyond)]) do
      ctx.window("demo") do |ui|
        ui.range_slider(0.0, 100.0, 0.0..100.0, id: "rs3") do |a, b|
          lo = a
          hi = b
        end
      end
    end
    # The lo thumb clamps at hi — an inverted range is unreachable.
    lo.should eq 100.0
    hi.should eq 100.0
  end

  it "normalizes an inverted constructor pair" do
    w = Egui::RangeSlider.new(80.0, 20.0, 0.0..100.0)
    w.last_lo.should eq 20.0
    w.last_hi.should eq 80.0
  end

  it "resolves the range_slider class style keys" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("range_slider", Egui::StyleVars{
      "width" => 300.0,
      "height" => 40.0,
    })
    extras_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.range_slider(0.0, 100.0, 0.0..100.0, id: "rs4")
        r.rect.width.should eq 300.0
        r.rect.height.should eq 40.0
      end
    end
  end
end

describe Egui::PinInput do
  it "lays out N cells with the gap" do
    ctx = Egui::Context.new
    extras_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.pin_input("", count: 4, id: "pin0")
        r.rect.width.should eq 4 * 44.0 + 3 * 8.0
        r.rect.height.should eq 44.0
      end
    end
  end

  it "resolves the pin_input class style keys" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("pin_input", Egui::StyleVars{
      "cell_size" => 40.0,
      "gap"       => 6.0,
    })
    extras_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.pin_input("", count: 4, id: "pin1")
        r.rect.width.should eq 4 * 40.0 + 3 * 6.0
        r.rect.height.should eq 40.0
      end
    end
  end

  it "focuses a clicked cell, then types and auto-advances" do
    ctx = Egui::Context.new
    rect = nil
    extras_frame(ctx) do
      ctx.window("demo") do |ui|
        rect = ui.pin_input("", count: 4, id: "pin2").rect
      end
    end
    base = Egui::Id.from("pin2")
    first_cell = rect.not_nil!.left + 22.0 # center of cell 0

    # Tap the first cell: focus lands on it the NEXT frame.
    extras_frame(ctx, tap_events(Egui::Pos2.new(first_cell, rect.not_nil!.center.y))) do
      ctx.window("demo") do |ui|
        ui.pin_input("", count: 4, id: "pin2")
      end
    end
    extras_frame(ctx) do
      ctx.window("demo") do |ui|
        # The widget must be created every frame — the focus dead-man's
        # switch drops ids whose widget stops being created.
        ui.pin_input("", count: 4, id: "pin2")
        ctx.memory.focus.has_focus?(base.child(1)).should be_true
      end
    end
    text = ""
    filled = false
    extras_frame(ctx, [Egui::Event.text_input("1")]) do
      ctx.window("demo") do |ui|
        r = ui.pin_input(text, count: 4, id: "pin2") do |new_text, done|
          text = new_text
          filled = done
        end
        r.changed?.should be_true
        r.widget_text.should eq "1"
      end
    end
    text.should eq "1"
    filled.should be_false
    extras_frame(ctx) do
      ctx.window("demo") do |ui|
        # Advanced to cell 1 (and kept alive by this very frame).
        ui.pin_input(text, count: 4, id: "pin2")
        ctx.memory.focus.has_focus?(base.child(2)).should be_true
      end
    end
  end

  it "completes and drops focus when the last cell is filled" do
    ctx = Egui::Context.new
    rect = nil
    extras_frame(ctx) do
      ctx.window("demo") do |ui|
        rect = ui.pin_input("", count: 4, id: "pin3").rect
      end
    end
    base = Egui::Id.from("pin3")
    extras_frame(ctx, tap_events(Egui::Pos2.new(rect.not_nil!.left + 22.0,
      rect.not_nil!.center.y))) do
      ctx.window("demo") do |ui|
        ui.pin_input("", count: 4, id: "pin3")
      end
    end
    text = ""
    filled = false
    ["7", "8", "9"].each do |digit|
      extras_frame(ctx, [Egui::Event.text_input(digit)]) do
        ctx.window("demo") do |ui|
          ui.pin_input(text, count: 4, id: "pin3") do |new_text, done|
            text = new_text
            filled = done
          end
        end
      end
    end
    text.should eq "789"
    filled.should be_false
    # The fourth digit completes the PIN: focus is dropped (the
    # on-screen keyboard goes with it) and the block sees done = true.
    extras_frame(ctx, [Egui::Event.text_input("4")]) do
      ctx.window("demo") do |ui|
        ui.pin_input(text, count: 4, id: "pin3") do |new_text, done|
          text = new_text
          filled = done
        end
      end
    end
    text.should eq "7894"
    filled.should be_true
    extras_frame(ctx) do
      ctx.window("demo") do |ui|
        ui.pin_input(text, count: 4, id: "pin3")
        ctx.memory.focus.has_focus?(base.child(1)).should be_false
        ctx.memory.focus.has_focus?(base.child(4)).should be_false
      end
    end
  end

  it "backspaces backward and pulls the focus with it" do
    ctx = Egui::Context.new
    rect = nil
    extras_frame(ctx) do
      ctx.window("demo") do |ui|
        rect = ui.pin_input("", count: 4, id: "pin4").rect
      end
    end
    base = Egui::Id.from("pin4")
    extras_frame(ctx, tap_events(Egui::Pos2.new(rect.not_nil!.left + 22.0,
      rect.not_nil!.center.y))) do
      ctx.window("demo") do |ui|
        ui.pin_input("", count: 4, id: "pin4")
      end
    end
    text = ""
    ["3", "1"].each do |digit|
      extras_frame(ctx, [Egui::Event.text_input(digit)]) do
        ctx.window("demo") do |ui|
          ui.pin_input(text, count: 4, id: "pin4") do |new_text, _|
            text = new_text
          end
        end
      end
    end
    text.should eq "31"
    extras_frame(ctx, [Egui::Event.key_pressed(Egui::KeyCode::Backspace)]) do
      ctx.window("demo") do |ui|
        ui.pin_input(text, count: 4, id: "pin4") do |new_text, _|
          text = new_text
        end
      end
    end
    text.should eq "3"
    extras_frame(ctx) do
      ctx.window("demo") do |ui|
        # The caret follows the deletion: it sat after "31" (cell 2),
        # backspace deleted the "1" and pulled the caret to cell 1 —
        # the end of the remaining "3".
        ui.pin_input(text, count: 4, id: "pin4")
        ctx.memory.focus.has_focus?(base.child(2)).should be_true
      end
    end
  end

  it "ignores non-digits when numeric (default)" do
    ctx = Egui::Context.new
    rect = nil
    extras_frame(ctx) do
      ctx.window("demo") do |ui|
        rect = ui.pin_input("", count: 4, id: "pin5").rect
      end
    end
    extras_frame(ctx, tap_events(Egui::Pos2.new(rect.not_nil!.left + 22.0,
      rect.not_nil!.center.y))) do
      ctx.window("demo") do |ui|
        ui.pin_input("", count: 4, id: "pin5")
      end
    end
    text = ""
    extras_frame(ctx, [Egui::Event.text_input("a")]) do
      ctx.window("demo") do |ui|
        ui.pin_input(text, count: 4, id: "pin5") do |new_text, _|
          text = new_text
        end
      end
    end
    text.should eq ""
    extras_frame(ctx, [Egui::Event.text_input("5")]) do
      ctx.window("demo") do |ui|
        ui.pin_input(text, count: 4, id: "pin5") do |new_text, _|
          text = new_text
        end
      end
    end
    text.should eq "5"
  end
end

describe Egui::RatingBar do
  it "lays out a row of stars" do
    ctx = Egui::Context.new
    extras_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.rating_bar(0.0, id: "rb0")
        r.rect.width.should eq 5 * 28.0 + 4 * 4.0
        r.rect.height.should eq 28.0
      end
    end
  end

  it "resolves the rating_bar class style keys" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("rating_bar", Egui::StyleVars{
      "star_size" => 20.0,
      "gap"       => 2.0,
    })
    extras_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.rating_bar(0.0, id: "rb1")
        r.rect.width.should eq 5 * 20.0 + 4 * 2.0
        r.rect.height.should eq 20.0
      end
    end
  end

  it "taps a star to rate (step 1)" do
    ctx = Egui::Context.new
    rect = nil
    extras_frame(ctx) do
      ctx.window("demo") do |ui|
        rect = ui.rating_bar(0.0, id: "rb2").rect
      end
    end
    r = rect.not_nil!
    star_w = 28.0 + 4.0
    third = Egui::Pos2.new(r.left + 2 * star_w + 14.0, r.center.y)
    value = 0.0
    extras_frame(ctx, tap_events(third)) do
      ctx.window("demo") do |ui|
        res = ui.rating_bar(0.0, id: "rb2") do |v|
          value = v
        end
        res.changed?.should be_true
        res.widget_value.should eq 3.0
      end
    end
    value.should eq 3.0
  end

  it "rates half values from the left half of a star (step 0.5)" do
    ctx = Egui::Context.new
    rect = nil
    extras_frame(ctx) do
      ctx.window("demo") do |ui|
        rect = ui.rating_bar(0.0, step: 0.5, id: "rb3").rect
      end
    end
    r = rect.not_nil!
    star_w = 28.0 + 4.0
    # The left quarter of the second star → 1.5.
    at = Egui::Pos2.new(r.left + 1 * star_w + 7.0, r.center.y)
    extras_frame(ctx, tap_events(at)) do
      ctx.window("demo") do |ui|
        res = ui.rating_bar(0.0, step: 0.5, id: "rb3") { |v| }
        res.widget_value.should eq 1.5
      end
    end
  end

  it "rejects steps outside the 1.0 / 0.5 grid" do
    expect_raises(ArgumentError) do
      Egui::RatingBar.new(0.0, step: 0.25)
    end
  end
end

describe Egui::CircularProgress do
  it "lays out a square ring" do
    ctx = Egui::Context.new
    extras_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.circular_progress(0.42, id: "cp0")
        r.rect.width.should eq 32.0
        r.rect.height.should eq 32.0
        r.widget_value.should eq 0.42
      end
    end
  end

  it "resolves the circular_progress class style keys" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("circular_progress", Egui::StyleVars{
      "size" => 48.0,
    })
    extras_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.circular_progress(0.42, id: "cp1")
        r.rect.width.should eq 48.0
        r.rect.height.should eq 48.0
      end
    end
  end

  it "clamps the fraction into 0..1" do
    ctx = Egui::Context.new
    extras_frame(ctx) do
      ctx.window("demo") do |ui|
        ui.circular_progress(1.5, id: "cp2").widget_value.should eq 1.0
        ui.circular_progress(-0.2, id: "cp3").widget_value.should eq 0.0
      end
    end
  end

  it "paints a center caption without growing the footprint" do
    ctx = Egui::Context.new
    extras_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.circular_progress(0.42, text: "42%", id: "cp4")
        r.rect.width.should eq 32.0
        r.rect.height.should eq 32.0
      end
    end
  end
end

describe Egui::Skeleton do
  it "lays out a bar and a circle" do
    ctx = Egui::Context.new
    extras_frame(ctx) do
      ctx.window("demo") do |ui|
        bar = ui.add(Egui::Skeleton.new(:bar, width: 160.0, id: "sk0"))
        bar.rect.width.should eq 160.0
        bar.rect.height.should eq 12.0
        circle = ui.add(Egui::Skeleton.new(:circle, height: 40.0, id: "sk1"))
        circle.rect.width.should eq 40.0
        circle.rect.height.should eq 40.0
      end
    end
  end

  it "rejects unknown shapes" do
    expect_raises(ArgumentError) do
      Egui::Skeleton.new(:blob)
    end
  end

  it "keeps frames coming while shimmering, and stops when static" do
    ctx = Egui::Context.new
    extras_frame(ctx) do
      ctx.window("demo") do |ui|
        ui.add(Egui::Skeleton.new(:bar, width: 120.0, shimmer: true, id: "sk2"))
      end
    end
    ctx.needs_repaint?.should be_true

    ctx2 = Egui::Context.new
    extras_frame(ctx2) do
      ctx2.window("demo") do |ui|
        ui.add(Egui::Skeleton.new(:bar, width: 120.0, shimmer: false, id: "sk3"))
      end
    end
    ctx2.needs_repaint?.should be_false
  end

  it "resolves the skeleton class style keys" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("skeleton", Egui::StyleVars{
      "height" => 16.0,
    })
    extras_frame(ctx) do
      ctx.window("demo") do |ui|
        bar = ui.add(Egui::Skeleton.new(:bar, width: 100.0, id: "sk4"))
        bar.rect.height.should eq 16.0
      end
    end
  end

  it "skeleton_list rows stack vertically" do
    ctx = Egui::Context.new
    extras_frame(ctx) do
      ctx.window("demo") do |ui|
        ui.skeleton_list(3, id: "skl")
        spacing = ui.style.spacing.item_spacing.y
        expected = 3 * 12.0 + 2 * spacing
        ui.min_rect.height.should be_close(expected, 0.5)
      end
    end
  end
end
