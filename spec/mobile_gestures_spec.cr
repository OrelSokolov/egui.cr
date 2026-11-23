# Mobile gestures (plans/todo/mobile_widgets.md Phase 5, #16/#17):
# SwipeItem reveal/tap/dismiss through simulated pointer drags, Pager
# page switching on a horizontal drag, and the PageIndicator dots
# reflecting the active index. Headless logic only — geometry, state,
# callbacks, ECSS keys (visual check happens by eye via an example, per
# AGENTS.md). Animations snap (EGUI_NOANIMATIONS=1) so the settle
# states are reachable deterministically; the drag paths bypass the
# animation manager entirely. EVERY frame renders the demo window —
# hit-testing resolves against the previous frame's registration, so a
# frame without the window would leave the widget un-hittable.

require "spec"
require "../src/egui"
require "../src/egui/widgets/swipe_item"
require "../src/egui/containers/pager"
require "../src/egui/widgets/page_indicator"

ENV["EGUI_NOANIMATIONS"] = "1"

G_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

def g_run(ctx : Egui::Context, draw : Egui::Context ->,
          events : Array(Egui::Event) = [] of Egui::Event) : Nil
  ctx.begin_frame(Egui::RawInput.new(G_SCREEN, events, 0.016))
  draw.call(ctx)
  ctx.end_frame
end

def g_moved(p : Egui::Pos2, touch : Bool = false) : Egui::Event
  Egui::Event.pointer_moved(p, touch)
end

def g_pressed(p : Egui::Pos2, touch : Bool = false) : Egui::Event
  Egui::Event.pointer_pressed(p, :primary, touch)
end

def g_released(p : Egui::Pos2, touch : Bool = false) : Egui::Event
  Egui::Event.pointer_released(p, :primary, touch)
end

# A red/blue action pair shared by the SwipeItem examples.
def g_actions : Array(Egui::SwipeItem::Action)
  [
    Egui::SwipeItem::Action.new("Delete", Egui::Color32.rgb(220, 50, 50)),
    Egui::SwipeItem::Action.new("Archive", Egui::Color32.rgb(60, 120, 220)),
  ]
end

describe Egui::SwipeItem do
  it "reveals the actions after a horizontal drag past half the reveal" do
    ctx = Egui::Context.new
    swipe = nil.as(Egui::SwipeItem?)
    draw = ->(c : Egui::Context) do
      c.window("demo") do |ui|
        w = Egui::SwipeItem.new(g_actions, id: "row") do |row|
          row.label("Row one")
        end
        swipe = w
        ui.add(w)
      end
    end
    2.times { g_run(ctx, draw) }
    row_id = Egui::Id.from("row")
    grab = ctx.memory.widget_rects[row_id].center

    # Press, then drag left in two steps (-40, then -120 total): past
    # half the 160pt reveal (80pt), so release settles OPEN.
    g_run(ctx, draw, [g_moved(grab), g_pressed(grab)])
    g_run(ctx, draw, [g_moved(grab - Egui::Vec2.new(40.0, 0.0))])
    g_run(ctx, draw, [g_moved(grab - Egui::Vec2.new(120.0, 0.0))])
    g_run(ctx, draw, [g_released(grab - Egui::Vec2.new(120.0, 0.0))])
    g_run(ctx, draw) # settle frame — the animated offset reaches target
    swipe.not_nil!.open?.should be_true

    # The revealed action button is where the id contract says.
    a0 = ctx.memory.widget_rects[row_id.child(Egui::SwipeItem::ACTION_SALT)]?
    a0.should_not be_nil
    a0.not_nil!.width.should eq 80.0

    # Tapping the revealed action reports the index.
    at = a0.not_nil!.center
    g_run(ctx, draw, [g_moved(at), g_pressed(at)])
    g_run(ctx, draw, [g_released(at)])
    swipe.not_nil!.action_tapped.should eq 0
  end

  it "fires the action callback through the Ui helper" do
    ctx = Egui::Context.new
    tapped = [false, false]
    actions = [
      Egui::SwipeItem::Action.new("Delete", Egui::Color32.rgb(220, 50, 50)) {
        tapped[0] = true },
      Egui::SwipeItem::Action.new("Archive",
        Egui::Color32.rgb(60, 120, 220)) { tapped[1] = true },
    ]
    draw = ->(c : Egui::Context) do
      c.window("demo") do |ui|
        ui.swipe_item(id: "helper_row", actions: actions) do |row|
          row.label("Helper row")
        end
      end
    end
    2.times { g_run(ctx, draw) }
    row_id = Egui::Id.from("helper_row")
    grab = ctx.memory.widget_rects[row_id].center
    g_run(ctx, draw, [g_moved(grab), g_pressed(grab)])
    g_run(ctx, draw, [g_moved(grab - Egui::Vec2.new(140.0, 0.0))])
    g_run(ctx, draw, [g_released(grab - Egui::Vec2.new(140.0, 0.0))])
    g_run(ctx, draw)

    a1 = ctx.memory.widget_rects[
      row_id.child(Egui::SwipeItem::ACTION_SALT + 1_u64)].center
    g_run(ctx, draw, [g_moved(a1), g_pressed(a1)])
    g_run(ctx, draw, [g_released(a1)])
    tapped[1].should be_true
  end

  it "reports a plain tap through Response#changed?" do
    ctx = Egui::Context.new
    changed = false
    draw = ->(c : Egui::Context) do
      c.window("demo") do |ui|
        r = ui.add(Egui::SwipeItem.new(g_actions, id: "tap_row") do |row|
          row.label("Tap me")
        end)
        changed = r.changed?
      end
    end
    2.times { g_run(ctx, draw) }
    at = ctx.memory.widget_rects[Egui::Id.from("tap_row")].center
    g_run(ctx, draw, [g_moved(at), g_pressed(at), g_released(at)])
    changed.should be_true
  end

  it "dismisses when released past the dismiss ratio" do
    ctx = Egui::Context.new
    dismissed = false
    draw = ->(c : Egui::Context) do
      c.window("demo") do |ui|
        ui.swipe_item(id: "dismiss_row", actions: g_actions,
          on_dismiss: -> { dismissed = true; nil }) do |row|
          row.label("Swipe me away")
        end
      end
    end
    2.times { g_run(ctx, draw) }
    row_id = Egui::Id.from("dismiss_row")
    grab = ctx.memory.widget_rects[row_id].center
    g_run(ctx, draw, [g_moved(grab), g_pressed(grab)])
    # A long pull: the drag clamps to the dismiss distance, which is
    # past the reveal, so release counts as dismiss.
    g_run(ctx, draw, [g_moved(grab - Egui::Vec2.new(400.0, 0.0))])
    g_run(ctx, draw, [g_released(grab - Egui::Vec2.new(400.0, 0.0))])
    dismissed.should be_true
  end

  it "keeps touch taps below the finger slop from engaging the drag" do
    ctx = Egui::Context.new
    swipe = nil.as(Egui::SwipeItem?)
    drag_verdict = false
    draw = ->(c : Egui::Context) do
      c.window("demo") do |ui|
        w = Egui::SwipeItem.new(g_actions, id: "touch_row") do |row|
          row.label("Touch row")
        end
        swipe = w
        r = ui.add(w)
        drag_verdict = r.dragged?
      end
    end
    2.times { g_run(ctx, draw) }
    row_id = Egui::Id.from("touch_row")
    grab = ctx.memory.widget_rects[row_id].center
    # Finger events, 10pt of jitter: under TOUCH_MAX_DIST (16) the
    # drag never engages — a wobbling tap stays a tap.
    g_run(ctx, draw, [g_moved(grab, true), g_pressed(grab, true)])
    g_run(ctx, draw, [g_moved(grab - Egui::Vec2.new(10.0, 0.0), true)])
    g_run(ctx, draw, [g_released(grab - Egui::Vec2.new(10.0, 0.0), true)])
    drag_verdict.should be_false
    swipe.not_nil!.open?.should be_false
  end

  it "resolves the swipe_item class style keys" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("swipe_item", Egui::StyleVars{"action_width" => 120.0})
    swipe = nil.as(Egui::SwipeItem?)
    draw = ->(c : Egui::Context) do
      c.window("demo") do |ui|
        w = Egui::SwipeItem.new(g_actions, id: "styled_row") do |row|
          row.label("Styled row")
        end
        swipe = w
        ui.add(w)
      end
    end
    2.times { g_run(ctx, draw) }
    row_id = Egui::Id.from("styled_row")
    grab = ctx.memory.widget_rects[row_id].center
    g_run(ctx, draw, [g_moved(grab), g_pressed(grab)])
    # Reveal is 240 now; half is 120 — a 130pt drag opens, and the
    # action button lays out at the styled width.
    g_run(ctx, draw, [g_moved(grab - Egui::Vec2.new(130.0, 0.0))])
    g_run(ctx, draw, [g_released(grab - Egui::Vec2.new(130.0, 0.0))])
    g_run(ctx, draw)
    swipe.not_nil!.open?.should be_true
    ctx.memory.widget_rects[
      row_id.child(Egui::SwipeItem::ACTION_SALT)].width.should eq 120.0
  end
end

describe Egui::Pager do
  it "switches the page on a horizontal drag and reports the change" do
    ctx = Egui::Context.new
    page = 0
    changed = false
    draw = ->(c : Egui::Context) do
      c.window("demo") do |ui|
        r = ui.pager(3, page, id: "pg",
          on_change: ->(p : Int32) { page = p }) do |pu, i|
          pu.label("Page #{i}")
        end
        changed = r.changed?
      end
    end
    2.times { g_run(ctx, draw) }
    changed.should be_false
    vp = ctx.memory.widget_rects[Egui::Id.from("pg")]
    w = vp.width

    # Press right of center, drag ~70% of the viewport left, release:
    # the nearest page is 1.
    grab = Egui::Pos2.new(vp.center.x + w * 0.25, vp.center.y)
    g_run(ctx, draw, [g_moved(grab), g_pressed(grab)])
    3.times do |n|
      g_run(ctx, draw, [g_moved(
        Egui::Pos2.new(grab.x - w * 0.7 * (n + 1) / 3.0, grab.y))])
    end
    g_run(ctx, draw, [g_released(Egui::Pos2.new(grab.x - w * 0.7, grab.y))])
    changed.should be_true
    page.should eq 1

    # Settled: no further change, the strip rests on the new page.
    g_run(ctx, draw)
    changed.should be_false
  end

  it "animates to an app-driven selection without reporting a change" do
    ctx = Egui::Context.new
    changed = true
    draw = ->(c : Egui::Context) do
      c.window("demo") do |ui|
        r = ui.pager(3, 2, id: "app_pg") { |pu, i| pu.label("Page #{i}") }
        changed = r.changed?
      end
    end
    2.times do
      g_run(ctx, ->(c : Egui::Context) do
        c.window("demo") do |ui|
          ui.pager(3, 0, id: "app_pg") { |pu, i| pu.label("Page #{i}") }
        end
      end)
    end
    g_run(ctx, draw)
    changed.should be_false
  end

  it "resolves the pager class height key" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("pager", Egui::StyleVars{"height" => 120.0})
    g_run(ctx, ->(c : Egui::Context) do
      c.window("demo") do |ui|
        r = ui.pager(2, 0, id: "styled_pg") { |pu, i| pu.label("Page #{i}") }
        r.rect.height.should eq 120.0
      end
    end)
  end
end

describe Egui::PageIndicator do
  it "elongates the active dot and reflects the index" do
    ctx = Egui::Context.new
    dots_id = Egui::Id.from("dots")
    salt = Egui::PageIndicator::DOT_SALT
    g_run(ctx, ->(c : Egui::Context) do
      c.window("demo") do |ui|
        r = ui.page_indicator(3, 1, id: "dots")
        r.rect.width.should eq 52.0 # 3×8 + 2×6 + the 16pt elongation
      end
    end)
    # Second frame: the animated progress has settled at 1 (snapped).
    g_run(ctx, ->(c : Egui::Context) do
      c.window("demo") do |ui|
        ui.page_indicator(3, 1, id: "dots")
      end
    end)
    d0 = ctx.memory.widget_rects[dots_id.child(salt)]
    d1 = ctx.memory.widget_rects[dots_id.child(salt + 1_u64)]
    d2 = ctx.memory.widget_rects[dots_id.child(salt + 2_u64)]
    d0.width.should eq 8.0
    d1.width.should eq 24.0 # the active slot elongates to 3×
    d2.width.should eq 8.0
  end

  it "stays in sync with the Pager's page through app state" do
    ctx = Egui::Context.new
    page = 0
    draw = ->(c : Egui::Context) do
      c.window("demo") do |ui|
        ui.pager(3, page, id: "sync_pg",
          on_change: ->(p : Int32) { page = p }) do |pu, i|
          pu.label("Page #{i}")
        end
        ui.page_indicator(3, page, id: "sync_dots")
      end
    end
    2.times { g_run(ctx, draw) }
    vp = ctx.memory.widget_rects[Egui::Id.from("sync_pg")]
    w = vp.width
    grab = Egui::Pos2.new(vp.center.x + w * 0.25, vp.center.y)
    g_run(ctx, draw, [g_moved(grab), g_pressed(grab)])
    3.times do |n|
      g_run(ctx, draw, [g_moved(
        Egui::Pos2.new(grab.x - w * 0.8 * (n + 1) / 3.0, grab.y))])
    end
    g_run(ctx, draw, [g_released(Egui::Pos2.new(grab.x - w * 0.8, grab.y))])
    g_run(ctx, draw)
    # The app mirrored the swipe into `page` (through on_change); the
    # indicator's second dot is the elongated one now.
    page.should eq 1
    dots_id = Egui::Id.from("sync_dots")
    ctx.memory.widget_rects[
      dots_id.child(Egui::PageIndicator::DOT_SALT)].width.should eq 8.0
    ctx.memory.widget_rects[
      dots_id.child(Egui::PageIndicator::DOT_SALT + 1_u64)].width
      .should eq 24.0
  end
end
