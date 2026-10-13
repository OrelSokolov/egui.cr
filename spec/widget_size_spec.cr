# Этап 2 of plans/responsive-mobile.md: `width`/`min_width`/`max_width`
# (+ height trio) as common style keys — a plain number is points, a
# unit length (`%`, `vw/vh/vmin/vmax`, `rem`) resolves against the
# containing Ui (see spec/length_units_spec.cr for the units layer).
require "spec"
require "../src/egui"

SIZED_SCREEN = Egui::Rect.from_min_size(
  Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

private def sized_frame(ctx : Egui::Context, &app : Egui::Context ->)
  raw = Egui::RawInput.new(SIZED_SCREEN, [] of Egui::Event, 0.016)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

describe "widget size style keys" do
  it "width rule overrides the button's natural size" do
    ctx = Egui::Context.new
    natural = nil
    sized_frame(ctx) do |c|
      c.central_panel do |ui|
        natural = ui.add(Egui::Button.new("OK")).rect.size
      end
    end

    ctx2 = Egui::Context.new
    ctx2.stylesheet.rule("button", Egui::StyleVars{"width" => 300.0})
    sized2 = nil
    sized_frame(ctx2) do |c|
      c.central_panel do |ui|
        sized2 = ui.add(Egui::Button.new("OK")).rect.size
      end
    end

    n = natural.not_nil!.dup
    s = sized2.not_nil!.dup
    s.x.should eq 300.0
    s.x.should_not eq n.x
    s.y.should eq n.y # height untouched
  end

  it "min_width floors and max_width caps" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("button", Egui::StyleVars{
      "min_width" => 500.0,
      "max_width" => 520.0,
    })
    rect = nil
    sized_frame(ctx) do |c|
      c.central_panel do |ui|
        rect = ui.add(Egui::Button.new("OK")).rect
      end
    end
    r = rect.not_nil!
    # natural (text + padding) < 500 → floored to 500, below 520 cap.
    r.width.should eq 500.0
  end

  it "percent width resolves against the containing panel" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("button",
      Egui::StyleVars{"width" => Egui::StyleLength.new(50.0, :percent)})
    panel_w = nil
    rect = nil
    sized_frame(ctx) do |c|
      c.central_panel do |ui|
        panel_w = ui.max_rect.width
        rect = ui.add(Egui::Button.new("OK")).rect
      end
    end
    rect.not_nil!.width.should eq panel_w.not_nil! / 2.0
  end

  it "vw width resolves against the viewport, a 50/50 pair tiles a row" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("button",
      Egui::StyleVars{"width" => Egui::StyleLength.new(50.0, :percent)})
    rects = [] of Float64
    row_w = nil
    sized_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.horizontal do |row|
          row_w = row.max_rect.width
          2.times { rects << row.add(Egui::Button.new("A")).rect.width }
        end
      end
    end
    spacing = ctx.style.spacing.item_spacing.x
    want = (row_w.not_nil! - spacing) / 2.0
    rects[0].should eq want
    rects[1].should eq want # NOT clamped — both tile the row exactly
  end

  it "separator: stroke_width sizes the hairline, width sizes the layout" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("separator", Egui::StyleVars{
      "stroke_width" => 3.0,
      "width"        => Egui::StyleLength.new(50.0, :percent),
    })
    rect = nil
    panel_w = nil
    sized_frame(ctx) do |c|
      c.central_panel do |ui|
        panel_w = ui.max_rect.width
        rect = ui.add(Egui::Separator.new).rect
      end
    end
    # horizontal separator: height = stroke thickness, width = layout
    # (50% of the panel, not the full fill anymore).
    rect.not_nil!.height.should eq 3.0
    rect.not_nil!.width.should eq panel_w.not_nil! / 2.0
  end

  it "old plain-number separator width still sizes the hairline" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("separator", Egui::StyleVars{"width" => 2.0})
    rect = nil
    sized_frame(ctx) do |c|
      c.central_panel do |ui|
        rect = ui.add(Egui::Separator.new).rect
      end
    end
    rect.not_nil!.height.should eq 2.0 # legacy spelling keeps working
  end

  it "checkbox and progress_bar honor min_width" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("checkbox", Egui::StyleVars{"min_width" => 400.0})
    ctx.stylesheet.rule("progressbar",
      Egui::StyleVars{"width" => 600.0})
    cb = nil
    pb = nil
    sized_frame(ctx) do |c|
      c.central_panel do |ui|
        cb = ui.add(Egui::Checkbox.new(false, "x")).rect
        pb = ui.progress_bar(0.5).rect
      end
    end
    cb.not_nil!.width.should eq 400.0
    pb.not_nil!.width.should eq 600.0
  end
end
