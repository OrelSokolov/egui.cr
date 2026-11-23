# Phase 3 mobile content widgets (plans/todo/mobile_widgets.md
# #7–#12): Card / Chip / Badge / Stepper / Avatar / SearchBar —
# headless geometry, callbacks and style-key resolution.

require "spec"
require "../src/egui"
require "../src/egui/widgets/card"
require "../src/egui/widgets/chip"
require "../src/egui/widgets/badge"
require "../src/egui/widgets/stepper"
require "../src/egui/widgets/avatar"
require "../src/egui/widgets/search_bar"

CONTENT_SCREEN = Egui::Rect.from_min_size(
  Egui::Pos2.zero, Egui::Vec2.new(402.0, 874.0))

def content_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
                  time : Float64 = 0.016, &)
  ctx.begin_frame(Egui::RawInput.new(CONTENT_SCREEN, events, time))
  yield ctx
  ctx.end_frame
end

def click_events(at : Egui::Pos2) : Array(Egui::Event)
  [
    Egui::Event.pointer_moved(at),
    Egui::Event.pointer_pressed(at),
    Egui::Event.pointer_released(at),
  ] of Egui::Event
end

describe Egui::Card do
  it "hosts a block and reserves its padding" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("card", Egui::StyleVars{"padding" => 20.0})
    outer = nil.as(Egui::Rect?)
    label = nil.as(Egui::Rect?)
    content_frame(ctx) do
      ctx.window("demo") do |ui|
        outer = ui.card(id: "c1") { |c| label = c.label("hello").rect }
      end
    end
    o = outer.not_nil!
    l = label.not_nil!
    # The label sits inside the card, inset by the 20pt padding box.
    l.left.should be >= o.left + 19.0
    o.contains?(l.center).should be_true
    o.height.should eq(l.height + 40.0)
    # Block container: full remaining width of the window.
    o.width.should be > 300.0
  end

  it "advances the flow so siblings stack below" do
    ctx = Egui::Context.new
    rects = [] of Egui::Rect
    content_frame(ctx) do
      ctx.window("demo") do |ui|
        rects << ui.card(id: "a") { |c| c.label("one") }
        rects << ui.card(id: "b") { |c| c.label("two") }
      end
    end
    rects[1].top.should be >= rects[0].bottom
  end
end

describe Egui::Chip do
  it "lays a capsule at the styled height" do
    ctx = Egui::Context.new
    r = nil.as(Egui::Response?)
    content_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.chip(Egui::Chip.new("Filter"))
      end
    end
    r.not_nil!.rect.height.should eq(32.0)
    r.not_nil!.rect.width.should be > 10.0
  end

  it "toggles the filter state on click and reports changed" do
    ctx = Egui::Context.new
    chip = Egui::Chip.new("Wi-Fi", icon: :wifi, selected: false, id: "f1")
    center = nil.as(Egui::Pos2?)
    content_frame(ctx) do
      ctx.window("demo") do |ui|
        center = ui.chip(chip).rect.center
      end
    end
    chip.selected.should eq(false)
    changed = false
    content_frame(ctx, click_events(center.not_nil!)) do
      ctx.window("demo") do |ui|
        r = ui.chip(chip)
        changed = r.changed?
      end
    end
    changed.should be_true
    chip.selected.should be_true
    # A settled frame: no second flip.
    content_frame(ctx) do
      ctx.window("demo") do |ui|
        ui.chip(chip).changed?.should be_false
      end
    end
    chip.selected.should be_true
  end

  it "fires the close X without selecting the chip" do
    ctx = Egui::Context.new
    chip = Egui::Chip.new("Input", closable: true, selected: false, id: "c2")
    x_center = nil.as(Egui::Pos2?)
    content_frame(ctx) do
      ctx.window("demo") do |ui|
        ui.chip(chip)
        x_center = chip.close_rect.not_nil!.center
      end
    end
    content_frame(ctx, click_events(x_center.not_nil!)) do
      ctx.window("demo") do |ui|
        r = ui.chip(chip)
        chip.closed?.should be_true
        r.changed?.should be_true
      end
    end
    # The X click is not a chip click: no filter toggle.
    chip.selected.should eq(false)
  end

  it "wraps onto several lines when the row overflows" do
    ctx = Egui::Context.new
    chips = (0...8).map { |i| Egui::Chip.new("filter #{i} long label") }
    rects = [] of Egui::Rect
    content_frame(ctx) do
      ctx.window("demo") do |ui|
        rects = ui.chip_row(chips).map(&.rect)
      end
    end
    rects.each do |r|
      r.width.should be > 10.0
      r.right.should be <= 402.0 + 0.01
    end
    rects.map(&.top).uniq.size.should be > 1
  end

  it "reports the closed chip's index through chip_row" do
    ctx = Egui::Context.new
    chips = [
      Egui::Chip.new("a", closable: true),
      Egui::Chip.new("b", closable: true, id: "row-b"),
      Egui::Chip.new("c", closable: true),
    ]
    x_center = nil.as(Egui::Pos2?)
    content_frame(ctx) do
      ctx.window("demo") do |ui|
        ui.chip_row(chips)
        x_center = chips[1].close_rect.not_nil!.center
      end
    end
    closed_at = nil.as(Int32?)
    content_frame(ctx, click_events(x_center.not_nil!)) do
      ctx.window("demo") do |ui|
        ui.chip_row(chips) { |i| closed_at = i }
      end
    end
    closed_at.should eq(1)
  end
end

describe Egui::Badge do
  it "renders standalone at the badge size" do
    ctx = Egui::Context.new
    r = nil.as(Egui::Response?)
    content_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.badge(3, id: "b1")
      end
    end
    r.not_nil!.rect.width.should eq(18.0)
    r.not_nil!.rect.height.should eq(18.0)
  end

  it "caps the count label at 99+" do
    Egui::Badge.label_for(120).should eq("99+")
    Egui::Badge.label_for(99).should eq("99")
    Egui::Badge.label_for(0).should eq("0")
  end

  it "hides for a zero count" do
    ctx = Egui::Context.new
    content_frame(ctx) do
      ctx.window("demo") do |ui|
        ui.badge(0, id: "b2").rect.should eq(Egui::Rect.zero)
      end
    end
  end

  it "anchors over a rect corner without touching the flow" do
    ctx = Egui::Context.new
    icon = Egui::Rect.from_min_size(Egui::Pos2.new(100.0, 100.0),
      Egui::Vec2.new(24.0, 24.0))
    dot = nil.as(Egui::Rect?)
    content_frame(ctx) do
      ctx.window("demo") do |ui|
        dot = ui.badge(5, on: icon).rect
        # The anchor call reserves no flow space (a paint-over).
        ui.badge(5, on: icon, align: :bottom_left)
      end
    end
    d = dot.not_nil!
    # Centered ON the top-right corner: straddles it.
    d.right.should be > icon.right
    d.top.should be < icon.top
  end
end

describe Egui::Stepper do
  it "steps up on plus and reports the new value" do
    ctx = Egui::Context.new
    plus = nil.as(Egui::Pos2?)
    got = nil.as(Float64?)
    content_frame(ctx) do
      ctx.window("demo") do |ui|
        s = Egui::Stepper.new(5.0, 0.0, 10.0, 1.0, id: "st")
        ui.add(s)
        plus = s.plus_rect.not_nil!.center
      end
    end
    content_frame(ctx, click_events(plus.not_nil!)) do
      ctx.window("demo") do |ui|
        r = ui.stepper(5.0, range: (0.0..10.0), step: 1.0, id: "st") { |v| got = v }
        r.changed?.should be_true
        r.widget_value.should eq(6.0)
      end
    end
    got.should eq(6.0)
  end

  it "steps down on minus" do
    ctx = Egui::Context.new
    minus = nil.as(Egui::Pos2?)
    got = nil.as(Float64?)
    content_frame(ctx) do
      ctx.window("demo") do |ui|
        s = Egui::Stepper.new(5.0, 0.0, 10.0, 1.0, id: "st3")
        ui.add(s)
        minus = s.minus_rect.not_nil!.center
      end
    end
    content_frame(ctx, click_events(minus.not_nil!)) do
      ctx.window("demo") do |ui|
        r = ui.stepper(5.0, range: (0.0..10.0), id: "st3") { |v| got = v }
        r.widget_value.should eq(4.0)
      end
    end
    got.should eq(4.0)
  end

  it "honors min/max bounds honestly" do
    ctx = Egui::Context.new
    minus = nil.as(Egui::Pos2?)
    plus = nil.as(Egui::Pos2?)
    content_frame(ctx) do
      ctx.window("demo") do |ui|
        s = Egui::Stepper.new(0.0, 0.0, 10.0, 1.0, id: "st4")
        ui.add(s)
        minus = s.minus_rect.not_nil!.center
        plus = s.plus_rect.not_nil!.center
      end
    end
    # At min: minus does nothing, plus moves.
    content_frame(ctx, click_events(minus.not_nil!)) do
      ctx.window("demo") do |ui|
        ui.stepper(0.0, range: (0.0..10.0), id: "st4") { |_v| }.changed?.should be_false
      end
    end
    content_frame(ctx, click_events(plus.not_nil!)) do
      ctx.window("demo") do |ui|
        r = ui.stepper(0.0, range: (0.0..10.0), id: "st4") { |_v| }
        r.changed?.should be_true
        r.widget_value.should eq(1.0)
      end
    end
  end

  it "styles through the stepper class geometry keys" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("stepper", Egui::StyleVars{
      "button_size" => 40.0,
      "height"      => 44.0,
    })
    content_frame(ctx) do
      ctx.window("demo") do |ui|
        s = Egui::Stepper.new(1.0, 0.0, 2.0, 1.0, id: "st5")
        r = ui.add(s)
        r.rect.height.should eq(44.0)
        s.minus_rect.not_nil!.width.should eq(40.0)
        s.plus_rect.not_nil!.width.should eq(40.0)
      end
    end
  end
end

describe Egui::Avatar do
  it "derives two-letter uppercase initials" do
    Egui::Avatar.initials("Гриша Иванов").should eq("ГИ")
    Egui::Avatar.initials("cher").should eq("C")
    Egui::Avatar.initials("ada lovelace").should eq("AL")
    Egui::Avatar.initials("").should eq("")
  end

  it "lays a square at the default 40pt size" do
    ctx = Egui::Context.new
    r = nil.as(Egui::Response?)
    content_frame(ctx) do
      ctx.window("demo") do |ui|
        r = ui.avatar("Гриша Иванов")
      end
    end
    r.not_nil!.rect.width.should eq(40.0)
    r.not_nil!.rect.height.should eq(40.0)
  end

  it "resolves the avatar class size key" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("avatar", Egui::StyleVars{"size" => 56.0})
    content_frame(ctx) do
      ctx.window("demo") do |ui|
        ui.avatar("ada lovelace").rect.width.should eq(56.0)
      end
    end
  end
end

describe Egui::SearchBar do
  it "shows the clear X only when the text is non-empty" do
    ctx = Egui::Context.new
    content_frame(ctx) do
      ctx.window("demo") do |ui|
        sb = Egui::SearchBar.new("", id: "s1")
        r = ui.add(sb)
        r.rect.width.should be > 300.0
        sb.clear_rect.should be_nil
      end
    end
    content_frame(ctx) do
      ctx.window("demo") do |ui|
        sb = Egui::SearchBar.new("query", id: "s2")
        ui.add(sb)
        sb.clear_rect.not_nil!.right.should be > 350.0
      end
    end
  end

  it "bubbles edits through changed? + widget_text" do
    ctx = Egui::Context.new
    field = nil.as(Egui::Pos2?)
    content_frame(ctx) do
      ctx.window("demo") do |ui|
        field = ui.add(Egui::SearchBar.new("", id: "s3")).rect.center
      end
    end
    # Click focuses the wrapped TextEdit; the next frame carries the
    # typed characters.
    content_frame(ctx, click_events(field.not_nil!)) do
      ctx.window("demo") do |ui|
        ui.add(Egui::SearchBar.new("", id: "s3"))
      end
    end
    typed = [Egui::Event.text_input("hi")] of Egui::Event
    got = nil.as(String?)
    content_frame(ctx, typed) do
      ctx.window("demo") do |ui|
        r = ui.search_bar("", id: "s3") { |t| got = t }
        r.changed?.should be_true
        r.widget_text.should eq("hi")
      end
    end
    got.should eq("hi")
  end

  it "clears through the X and reports the empty text" do
    ctx = Egui::Context.new
    x_center = nil.as(Egui::Pos2?)
    content_frame(ctx) do
      ctx.window("demo") do |ui|
        sb = Egui::SearchBar.new("query", id: "s4")
        ui.add(sb)
        x_center = sb.clear_rect.not_nil!.center
      end
    end
    got = nil.as(String?)
    content_frame(ctx, click_events(x_center.not_nil!)) do
      ctx.window("demo") do |ui|
        r = ui.search_bar("query", id: "s4") { |t| got = t }
        r.changed?.should be_true
        r.widget_text.should eq("")
      end
    end
    got.should eq("")
  end
end
