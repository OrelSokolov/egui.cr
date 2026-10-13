# Этап 6/7 (plans/responsive-mobile.md): horizontal rows wrap by
# default — a widget that cannot fit the remaining row width breaks
# onto a fresh line instead of collapsing into a zero-width rect at
# the region edge; a nested row inside a horizontal parent is a
# full-width line-break block.
require "spec"
require "../src/egui"

WRAP_SCREEN = Egui::Rect.from_min_size(
  Egui::Pos2.zero, Egui::Vec2.new(402.0, 874.0))

private def wrap_frame(ctx : Egui::Context,
                       screen : Egui::Rect = WRAP_SCREEN,
                       &app : Egui::Context ->)
  raw = Egui::RawInput.new(screen, [] of Egui::Event, 0.016)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

describe "horizontal row wrap" do
  it "breaks widgets that do not fit onto a new line" do
    ctx = Egui::Context.new
    rects = [] of Egui::Rect
    wrap_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.horizontal do |row|
          4.times do |i|
            rects << row.add(Egui::Button.new("кнопка #{i}")).rect
          end
        end
      end
    end

    # Every button has a real (non-zero) width and none crosses the
    # panel's right edge — the pre-wrap behavior pinned the trailing
    # widgets into zero-width rects at the edge.
    panel_right = rects.map(&.right).max
    rects.each do |r|
      r.width.should be > 10.0
      r.right.should be <= panel_right + 0.01
    end
    # At ~400pt four text buttons cannot share one line: some pair
    # sits on different lines (one starts below another's top).
    ys = rects.map(&.top)
    ys.uniq.size.should be > 1
  end

  it "wrap: false keeps the single-line behavior" do
    ctx = Egui::Context.new
    rects = [] of Egui::Rect
    wrap_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.horizontal(wrap: false) do |row|
          4.times do |i|
            rects << row.add(Egui::Button.new("кнопка #{i}")).rect
          end
        end
      end
    end
    # All on one line — later widgets clamp at the edge as before.
    rects.map(&.top).uniq.size.should eq 1
  end

  it "a nested row inside a horizontal parent starts on a fresh full-width line" do
    ctx = Egui::Context.new
    label_rect = nil
    cb = [] of Egui::Rect
    wrap_frame(ctx) do |c|
      c.top_panel("hud", height: 92.0) do |ui|
        # top_panel lays out horizontally: the long label eats the
        # line, the checkbox row must NOT cram into the remaining
        # sliver — it starts below, with the full panel width.
        label_rect = ui.label(
          "viewport 402×874 — portrait, pointer: fine (мышь)").rect
        ui.horizontal do |row|
          cb << row.checkbox(false, "pointer: coarse").rect
          cb << row.checkbox(false, "reduced motion").rect
          cb << row.checkbox(false, "safe area (чёлка)").rect
        end
      end
    end

    lr = label_rect.not_nil!
    cb.each do |r|
      r.width.should be > 10.0            # real rects, not edge slivers
      r.right.should be <= lr.right + 0.01
      r.top.should be > lr.bottom         # below the label line
    end
  end

  it "a horizontal strip panel wraps its own content" do
    ctx = Egui::Context.new
    rects = [] of Egui::Rect
    wrap_frame(ctx) do |c|
      c.top_panel("hud", height: 160.0) do |ui|
        6.times do |i|
          rects << ui.add(Egui::Button.new("поле #{i}")).rect
        end
      end
    end
    rects.each { |r| r.width.should be > 10.0 }
    rects.map(&.top).uniq.size.should be > 1 # overflow broke lines
  end

  it "a long wrapped label after a full-width label takes a fresh line" do
    # Regression (iOS HUD): a label whose wrapped galley overshoots the
    # row width by a hair (a word wider than the wrap limit) used to
    # fail the break condition and collapse into the end-of-row sliver
    # — painting the text as a one-glyph-wide vertical column.
    ctx = Egui::Context.new
    r2 = nil
    wrap_frame(ctx) do |c|
      c.top_panel("hud", height: 140.0) do |ui|
        ui.label("viewport 402×874 — portrait, pointer: fine (мышь)")
        r2 = ui.label(
          "safe area (детектор ОС): top 62 / right 0 / bottom 34 / left 0").rect
      end
    end
    rect = r2.not_nil!
    rect.width.should be > 350.0    # the full row, not a sliver
    rect.height.should be <= 60.0   # a couple of lines, not a column
  end
end
