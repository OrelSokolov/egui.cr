# Canvas widget specs: raster operations, interaction reporting in
# pixel coordinates (primary + secondary button drags), zoom scaling,
# nearest-sampled ImageCmd, undo across resizes.
require "spec"
require "../src/egui"

CANVAS_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(900.0, 700.0))
SPACER = 20.0 # the canvas is placed after this offset inside the panel

# One frame on a SHARED context (widgets must be registered by an
# earlier frame for press/hover classification — exactly like the real
# frame loop). Typical shape: a no-events probe frame captures the
# canvas rect, later frames deliver pointer events at rect-relative
# offsets.
def canvas_step(ctx : Egui::Context, canvas : Egui::Canvas,
                events : Array(Egui::Event),
                &app : Egui::Context, Egui::Canvas::Interaction ->) : Nil
  raw = Egui::RawInput.new(CANVAS_SCREEN, events, 0.016)
  ctx.begin_frame(raw)
  ctx.central_panel do |ui|
    ui.allocate_space(Egui::Vec2.new(SPACER, SPACER))
    ui.canvas(canvas) { |ia| app.call(ctx, ia) }
  end
  ctx.end_frame
end

def canvas_probe(ctx : Egui::Context, canvas : Egui::Canvas) : Egui::Rect
  rect = nil
  canvas_step(ctx, canvas, [] of Egui::Event) { |_c, ia| rect = ia.response.rect }
  rect.not_nil!
end

describe Egui::Canvas do
  it "starts white and marks dirty on mutation" do
    c = Egui::Canvas.new("t", 4, 4)
    c[0, 0].should eq Egui::Color32.rgb(255, 255, 255)
    c[0, 0] = Egui::Color32.rgb(1, 2, 3)
    c.dirty?.should be_true
    c[0, 0].should eq Egui::Color32.rgb(1, 2, 3)
    c[9, 9] = Egui::Color32.rgb(9, 9, 9) # out of bounds: ignored
  end

  it "line/rect/ellipse/flood_fill rasterize expected pixels" do
    c = Egui::Canvas.new("t", 10, 10)
    c.line(0, 0, 9, 0, Egui::Color32.rgb(255, 0, 0))
    (0..9).each { |x| c[x, 0].should eq Egui::Color32.rgb(255, 0, 0) }

    c.rect_outline(0, 0, 4, 4, Egui::Color32.rgb(0, 255, 0))
    c[0, 0].should eq Egui::Color32.rgb(0, 255, 0)
    c[3, 3].should eq Egui::Color32.rgb(0, 255, 0)
    c[1, 1].should eq Egui::Color32.rgb(255, 255, 255) # interior untouched

    c.ellipse_fill(2, 2, 5, 5, Egui::Color32.rgb(0, 0, 255))
    c[4, 4].should eq Egui::Color32.rgb(0, 0, 255)

    c[5, 0].should eq Egui::Color32.rgb(255, 0, 0) # line outside the rect
    c.flood_fill(0, 5, Egui::Color32.rgb(9, 9, 9)) # white region
    c[0, 5].should eq Egui::Color32.rgb(9, 9, 9)
    c[5, 0].should eq Egui::Color32.rgb(255, 0, 0) # line not overwritten
  end

  it "invert flips every channel" do
    c = Egui::Canvas.new("t", 1, 1)
    c[0, 0] = Egui::Color32.rgb(10, 20, 200)
    c.invert
    c[0, 0].should eq Egui::Color32.rgb(245, 235, 55)
  end

  it "region/blit round-trips and honors transparency" do
    c = Egui::Canvas.new("t", 4, 2)
    c[0, 0] = Egui::Color32.rgb(1, 1, 1)
    c[1, 0] = Egui::Color32.rgb(2, 2, 2)
    region = c.region(0, 0, 2, 1)
    c.erase_region(0, 0, 2, 1, Egui::Color32.rgb(255, 255, 255))
    c.blit(2, 1, region, 2, 1,
      transparent_color: Egui::Color32.rgb(2, 2, 2))
    c[2, 1].should eq Egui::Color32.rgb(1, 1, 1)
    c[3, 1].should eq Egui::Color32.rgb(255, 255, 255) # transparent skip
  end

  it "show paints a nearest-sampled ImageCmd and reports pixel coords" do
    ctx = Egui::Context.new
    canvas = Egui::Canvas.new("test", 32, 24)
    rect = canvas_probe(ctx, canvas)
    canvas_step(ctx, canvas, [
      Egui::Event.pointer_moved(rect.min + Egui::Vec2.new(10.0, 8.0)),
    ]) do |_c, ia|
      ia.pointer_px.should eq Egui::Pos2.new(10.0, 8.0)
    end
    img = ctx.painter.commands.select(Egui::ImageCmd)
    img.should_not be_empty
    img.last.nearest?.should be_true
    img.last.rect.width.should eq 32.0
  end

  it "scales positions and rect by zoom" do
    ctx = Egui::Context.new
    canvas = Egui::Canvas.new("zoomtest", 32, 24)
    canvas.scale = 2
    rect = canvas_probe(ctx, canvas)
    canvas_step(ctx, canvas, [
      Egui::Event.pointer_moved(rect.min + Egui::Vec2.new(12.0, 14.0)),
    ]) do |_c, ia|
      ia.pointer_px.should eq Egui::Pos2.new(6.0, 7.0)
      ia.response.rect.width.should eq 64.0
    end
  end

  it "tracks a primary drag in pixel coordinates" do
    ctx = Egui::Context.new
    canvas = Egui::Canvas.new("dragtest", 32, 24)
    rect = canvas_probe(ctx, canvas)
    canvas_step(ctx, canvas, [
      Egui::Event.pointer_pressed(rect.min + Egui::Vec2.new(2.0, 12.0)),
    ]) do |_c, ia|
      ia.drag_started?.should be_true # a press IS a stroke start
      ia.drag_button.should eq :primary
      ia.drag_start_px.should eq Egui::Pos2.new(2.0, 12.0)
    end
  end

  it "tracks a secondary (right-button) drag through press and release" do
    ctx = Egui::Context.new
    canvas = Egui::Canvas.new("sectest", 32, 24)
    rect = canvas_probe(ctx, canvas)
    inside = rect.min + Egui::Vec2.new(2.0, 12.0)
    canvas_step(ctx, canvas, [
      Egui::Event.pointer_pressed(inside, :secondary),
    ]) do |_c, ia|
      ia.drag_started?.should be_true
      ia.drag_button.should eq :secondary
    end
    canvas_step(ctx, canvas, [
      Egui::Event.pointer_released(inside, :secondary),
    ]) do |_c, ia|
      ia.drag_stopped?.should be_true
      ia.secondary_click_px.should eq Egui::Pos2.new(2.0, 12.0)
    end
  end

  it "restore_sized handles undo across a resize" do
    c = Egui::Canvas.new("t", 4, 4)
    snap = c.snapshot
    c[0, 0] = Egui::Color32.rgb(7, 7, 7)
    c.resize(8, 2)
    c.width.should eq 8
    c.restore_sized(4, 4, snap)
    c.width.should eq 4
    c[0, 0].should eq Egui::Color32.rgb(255, 255, 255)
  end
end
