require "spec"
require "../src/egui"

BOUNDS_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(900.0, 700.0))

def bounds_frame(ctx : Egui::Context, &app : Egui::Context ->)
  raw = Egui::RawInput.new(BOUNDS_SCREEN, [] of Egui::Event, 0.016)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

# A widget placed through `add_sized` gets an exact-size cell — that
# cell is a hard bound, inherited `v_overflow` (scrollable panel
# content) must not loosen it. The regression: the Inspector header's
# ✕ cell is 26px tall, but the natural-size button inside grew to
# ~29px and stuck out over the panel body.
describe "widget bounds (an explicit size is a hard bound)" do
  it "add_sized cell is never exceeded inside a scrollable panel" do
    ctx = Egui::Context.new
    cell = Egui::Vec2.new(26.0, 26.0)
    rect = nil

    bounds_frame(ctx) do |c|
      c.central_panel do |ui|
        # a plain button is ~29px tall at the default style — taller
        # than the cell it is asked to fit
        rect = ui.add_sized(cell, Egui::Button.new("OK")).rect
      end
    end

    r = rect.not_nil!
    r.height.should be <= cell.y
    r.width.should be <= cell.x
  end

  it "inspector header buttons stay inside the 26px header row" do
    ctx = Egui::Context.new
    ctx.inspector_enabled = true

    raw = Egui::RawInput.new(BOUNDS_SCREEN, [] of Egui::Event, 0.016)
    ctx.begin_frame(raw)
    ctx.inspector.before_update
    ctx.window("w") { |ui| ui.button("OK", id: "save") }
    ctx.end_frame

    header_bottom = 10.0 + Egui::Inspector::TAB_H
    ctx.painter.commands.select(Egui::RectCmd)
      .select { |cmd| cmd.rect.top < header_bottom }       # header strip
      .select { |cmd| cmd.rect.width <= 200.0 }            # (skip panel bg)
      .each { |cmd| cmd.rect.bottom.should be <= header_bottom }
  end

  it "icon-only button centers its glyph in the rect" do
    ctx = Egui::Context.new
    rect = nil

    bounds_frame(ctx) do |c|
      c.central_panel do |ui|
        rect = ui.add(Egui::Button.new("", id: "x").icon(:close)).rect
      end
    end

    r = rect.not_nil!
    # :close is the Lucide x — its diagonals cross at the icon box
    # center; a centered glyph puts that at the button center
    diag = ctx.painter.commands.select(Egui::LineCmd).last.not_nil!
    center = Egui::Pos2.new((diag.p1.x + diag.p2.x) / 2.0, (diag.p1.y + diag.p2.y) / 2.0)
    center.x.should be_close(r.center.x, 0.5)
    center.y.should be_close(r.center.y, 0.5)
  end
end
