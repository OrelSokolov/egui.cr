# Engine-level rounded content clipping: a container with a non-zero
# border radius clips its whole subtree to the ROUNDED shape, not just
# the rect bounds — scrolled/nested content must not bleed past the
# curved corners (CSS `overflow: hidden` + `border-radius` semantics).
#
# Two levels are covered:
#   - commands: the subtree's cmds carry `clip_corners` (the painter's
#     subtree-clip brackets bake them once the box rect exists);
#   - pixels: the CPU rasterizer honors them per pixel (the same shape
#     the GPU backend enforces through its stencil mask).

require "spec"
require "../src/egui"
require "../src/egui/capybara"
require "../src/egui/capybara/fonts"

private CLIP_BG = Egui::Color32.rgb(10, 10, 10)
private GREEN   = Egui::Color32.rgb(0, 255, 0)
private RED     = Egui::Color32.rgb(255, 0, 0)

# App under test: a rounded box whose child paints a SQUARE full-bleed
# plate — without the engine clip the red floods the rounded corners.
class RoundedClipApp < Egui::App
  property mode = :plate

  def update(ctx : Egui::Context) : Nil
    ctx.window("R", Egui::Pos2.new(20.0, 20.0), width: 300.0) do |ui|
      case mode
      when :plate
        ui.box(rounding: 20.0, fill: GREEN,
            margin: Egui::Vec2.new(0.0, 0.0)) do |b|
          rect = b.allocate_space(Egui::Vec2.new(260.0, 200.0))
          b.painter.rect(rect, 0.0, RED)
        end
      when :nested
        # Outer rounded box, inner SQUARE box: the inner chrome (and any
        # content) still has to respect the outer curve.
        ui.box(rounding: 20.0, fill: GREEN,
            margin: Egui::Vec2.new(0.0, 0.0)) do |b|
          b.box(rounding: 0.0, fill: RED,
              margin: Egui::Vec2.new(0.0, 0.0)) do |c|
            c.allocate_space(Egui::Vec2.new(240.0, 180.0))
          end
        end
      when :scroll
        ui.box(rounding: 18.0, fill: GREEN,
            margin: Egui::Vec2.new(0.0, 0.0)) do |b|
          Egui::ScrollArea.new(max_height: 200.0).show(b) do |scroll|
            40.times { |i| scroll.label("row #{i}") }
          end
        end
      end
    end
  end
end

private def clip_session(mode : Symbol) : Egui::Capybara::Session
  app = RoundedClipApp.new
  app.mode = mode
  Egui::Capybara::Fonts.install!(app.ctx)
  Egui::Capybara::Session.new(app, width: 360, height: 300, settle_frames: 0)
end

private def render_commands(commands) : Egui::Capybara::Raster
  raster = Egui::Capybara::Raster.new(360, 300, CLIP_BG)
  raster.render(commands)
  raster
end

private def px_at(raster : Egui::Capybara::Raster, x : Int32, y : Int32) : Egui::Color32
  i = (y * raster.width + x) * 4
  Egui::Color32.new(raster.pixels[i], raster.pixels[i + 1],
    raster.pixels[i + 2], raster.pixels[i + 3])
end

private def chrome_cmd(commands, fill : Egui::Color32) : Egui::RectCmd?
  commands.each do |cmd|
    next unless cmd.is_a?(Egui::RectCmd)
    return cmd if cmd.fill == fill && cmd.rounding > 0.0
  end
  commands.each do |cmd|
    next unless cmd.is_a?(Egui::RectCmd)
    return cmd if cmd.fill == fill
  end
  nil
end

describe "rounded subtree clip" do
  it "bakes clip_corners into every subtree command" do
    t = clip_session(:plate)
    t.step
    chrome = chrome_cmd(t.commands, GREEN).should_not be_nil
    content = t.commands.select(Egui::RectCmd)
      .find { |c| c.fill == RED }.should_not be_nil
    # The content cmd rides inside the box's bracket: rounded radii,
    # clip intersected with the box's outer rect.
    content.clip_corners.should_not be_nil
    content.clip_corners.not_nil!.max.should be > 0.0
    content.clip.intersects?(chrome.rect).should be_true
    content.clip.min.x.should be >= chrome.rect.min.x - 1e-9
    content.clip.max.x.should be <= chrome.rect.max.x + 1e-9
    # The chrome itself paints the shape and is NOT re-clipped.
    chrome.clip_corners.should be_nil
  end

  it "keeps content out of the rounded corners (pixels)" do
    t = clip_session(:plate)
    t.step
    chrome = chrome_cmd(t.commands, GREEN).should_not be_nil
    raster = render_commands(t.commands)
    r = chrome.rect
    cx = ((r.min.x + r.max.x) / 2).to_i
    # Center of the box: red content over the green background.
    mid = px_at(raster, cx, ((r.min.y + r.max.y) / 2).to_i)
    mid.r.should be > 200
    mid.g.should be < 80
    # 3px into the top-left corner: outside a 20px arc — the window
    # backdrop (dark), never the bleeding red.
    corner = px_at(raster, (r.min.x + 3).to_i, (r.min.y + 3).to_i)
    corner.r.should be < 80
    corner.g.should be < 80
    # Just inside the straight part of the top edge stays content red.
    top = px_at(raster, cx, (r.min.y + 1).to_i)
    top.r.should be > 200
  end

  it "clips a nested square box by the outer curve" do
    t = clip_session(:nested)
    t.step
    inner = t.commands.select(Egui::RectCmd)
      .find { |c| c.fill == RED }.should_not be_nil
    # The inner box's own rounding is 0 — any radii it carries are the
    # OUTER box's, inherited through the bracket.
    inner.clip_corners.should_not be_nil
    inner.clip_corners.not_nil!.max.should be > 0.0

    chrome = chrome_cmd(t.commands, GREEN).should_not be_nil
    raster = render_commands(t.commands)
    r = chrome.rect
    corner = px_at(raster, (r.min.x + 3).to_i, (r.min.y + 3).to_i)
    corner.r.should be < 80
    corner.g.should be < 80
  end

  it "clips scroll content scrolled under the corners" do
    t = clip_session(:scroll)
    t.step
    t.scroll(Egui::Vec2.new(0.0, 300.0))
    t.step
    # Every label the scroll emitted is inside the box bracket: it
    # carries the box's corner radii merged with the scroll's own
    # viewport clip. (The window's own title text rides outside the
    # box and keeps a plain clip.)
    box_rect = chrome_cmd(t.commands, GREEN).not_nil!.rect
    texts = t.commands.select(Egui::TextCmd)
      .select { |c| box_rect.contains?(c.pos) }
    texts.should_not be_empty
    texts.each do |cmd|
      cmd.clip_corners.should_not be_nil
      cmd.clip_corners.not_nil!.max.should be > 0.0
    end
    # And the pixels: no label ink past the box's top corners.
    chrome = t.commands.select(Egui::RectCmd)
      .find { |c| c.fill == GREEN }.should_not be_nil
    raster = render_commands(t.commands)
    r = chrome.rect
    corner = px_at(raster, (r.min.x + 3).to_i, (r.min.y + 3).to_i)
    corner.g.should be < 80
  end
end
