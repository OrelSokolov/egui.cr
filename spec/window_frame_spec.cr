# WindowFrame specs: the default client-side chrome — caption
# geometry, caption buttons wired to the Window/Quit ports,
# double-click maximize, hover fills and the edge resize grips — for
# all three styles (Windows 11 dark, Ubuntu Ambiance, macOS traffic
# lights). Driven headless: Egui::WindowFrame.show is exactly what the
# sokol backend calls before app frames.

require "spec"
require "../src/egui"

FRAME_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(800.0, 600.0))

class FrameQuitRecorder < Egui::SystemPorts::Quit::Implementation
  getter count = 0

  def quit : Nil
    @count += 1
  end
end

class FrameWindowRecorder < Egui::SystemPorts::Window::Implementation
  getter minimized = 0
  getter maximized = 0
  getter restored = 0
  getter drags = 0
  getter resizes = [] of Symbol

  def minimize : Nil
    @minimized += 1
  end

  def maximize : Nil
    @maximized += 1
  end

  def restore : Nil
    @restored += 1
  end

  def start_drag : Nil
    @drags += 1
  end

  def start_resize(edge : Symbol) : Nil
    @resizes << edge
  end
end

def frame_draw(ctx : Egui::Context, style : Egui::WindowFrame::Style,
               events : Array(Egui::Event), time : Float64) : Egui::Rect
  raw = Egui::RawInput.new(FRAME_SCREEN, events, time)
  ctx.begin_frame(raw)
  Egui::WindowFrame.show(ctx, "egui-cr — borderless", style)
  remainder = ctx.central_panel { }
  ctx.end_frame
  remainder
end

describe Egui::WindowFrame do
  it "windows: reserves a 32pt caption strip and fills it #202020" do
    ctx = Egui::Context.new
    remainder = frame_draw(ctx, Egui::WindowFrame::Style::Windows,
      [] of Egui::Event, 0.016)
    remainder.top.should eq(Egui::WindowFrame::Windows::CAPTION_H)

    caption = ctx.painter.commands.select(Egui::RectCmd)
      .find { |c| c.fill == Egui::WindowFrame::Windows::BG }
    caption.should_not be_nil
    caption.not_nil!.rect.top.should be <= 0.0
    caption.not_nil!.rect.bottom.should be >= Egui::WindowFrame::Windows::CAPTION_H

    texts = ctx.painter.commands.select(Egui::TextCmd)
    title = texts.find { |c| c.text == "egui-cr — borderless" }.should_not be_nil
  end

  it "windows: buttons minimize / quit, double-click maximizes then restores" do
    quit = FrameQuitRecorder.new
    win = FrameWindowRecorder.new
    Egui::SystemPorts::Quit.use(quit)
    Egui::SystemPorts::Window.use(win)

    ctx = Egui::Context.new
    style = Egui::WindowFrame::Style::Windows
    frame_draw(ctx, style, [] of Egui::Event, 0.016) # rects registered

    # minimize button center (46pt-wide buttons from the right edge)
    btn_w = Egui::WindowFrame::Windows::BTN_W
    min_pos = Egui::Pos2.new(800.0 - 2.5 * btn_w, 16.0)
    frame_draw(ctx, style, [Egui::Event.pointer_pressed(min_pos)], 0.032)
    frame_draw(ctx, style, [Egui::Event.pointer_released(min_pos)], 0.048)
    win.minimized.should eq(1)

    # close button center
    close_pos = Egui::Pos2.new(800.0 - 0.5 * btn_w, 16.0)
    frame_draw(ctx, style, [Egui::Event.pointer_pressed(close_pos)], 0.064)
    frame_draw(ctx, style, [Egui::Event.pointer_released(close_pos)], 0.080)
    quit.count.should eq(1)

    # double-click on the caption toggles maximize, then restore
    cap = Egui::Pos2.new(400.0, 10.0)
    frame_draw(ctx, style, [Egui::Event.pointer_pressed(cap)], 0.096)
    frame_draw(ctx, style, [Egui::Event.pointer_released(cap)], 0.112)
    win.maximized.should eq(0)
    frame_draw(ctx, style, [Egui::Event.pointer_pressed(cap)], 0.128)
    frame_draw(ctx, style, [Egui::Event.pointer_released(cap)], 0.144)
    win.maximized.should eq(1)
    Egui::WindowFrame.maximized?.should be_true
    # beyond the double-click window the count resets to 1
    frame_draw(ctx, style, [Egui::Event.pointer_pressed(cap)], 0.500)
    frame_draw(ctx, style, [Egui::Event.pointer_released(cap)], 0.516)
    frame_draw(ctx, style, [Egui::Event.pointer_pressed(cap)], 0.532)
    frame_draw(ctx, style, [Egui::Event.pointer_released(cap)], 0.548)
    win.restored.should eq(1)
    Egui::WindowFrame.maximized?.should be_false
  end

  it "windows: close hover paints the #C42B1C fill" do
    ctx = Egui::Context.new
    style = Egui::WindowFrame::Style::Windows
    frame_draw(ctx, style, [] of Egui::Event, 0.016)
    close_pos = Egui::Pos2.new(
      800.0 - 0.5 * Egui::WindowFrame::Windows::BTN_W, 16.0)
    frame_draw(ctx, style, [Egui::Event.pointer_moved(close_pos)], 0.032)

    close_fill = ctx.painter.commands.select(Egui::RectCmd)
      .find { |c| c.fill == Egui::WindowFrame::Windows::CLOSE_HOVER }
    close_fill.should_not be_nil
  end

  it "ubuntu: gradient titlebar, round buttons, orange close quits" do
    quit = FrameQuitRecorder.new
    win = FrameWindowRecorder.new
    Egui::SystemPorts::Quit.use(quit)
    Egui::SystemPorts::Window.use(win)

    ctx = Egui::Context.new
    style = Egui::WindowFrame::Style::Ubuntu
    remainder = frame_draw(ctx, style, [] of Egui::Event, 0.016)
    remainder.top.should eq(Egui::WindowFrame::Ubuntu::CAPTION_H)

    # gradient fill (fill + fill2 on one rect) + the orange close circle
    gradient = ctx.painter.commands.select(Egui::RectCmd)
      .find { |c| c.fill == Egui::WindowFrame::Ubuntu::BG_TOP &&
                   c.fill2 == Egui::WindowFrame::Ubuntu::BG_BOTTOM }
    gradient.should_not be_nil
    close_circle = ctx.painter.commands.select(Egui::CircleCmd)
      .find { |c| c.fill == Egui::WindowFrame::Ubuntu::CLOSE }
    close_circle.should_not be_nil

    # click the orange close circle (rightmost, 8pt inset, d=14)
    ub = Egui::WindowFrame::Ubuntu
    close_pos = Egui::Pos2.new(
      800.0 - Egui::WindowFrame::Ubuntu::INSET - Egui::WindowFrame::Ubuntu::BTN_D / 2.0,
      Egui::WindowFrame::Ubuntu::CAPTION_H / 2.0)
    frame_draw(ctx, style, [Egui::Event.pointer_pressed(close_pos)], 0.032)
    frame_draw(ctx, style, [Egui::Event.pointer_released(close_pos)], 0.048)
    quit.count.should eq(1)

    # minimize is the leftmost of the three round buttons
    min_pos = Egui::Pos2.new(
      800.0 - Egui::WindowFrame::Ubuntu::INSET -
        2.5 * Egui::WindowFrame::Ubuntu::BTN_D -
        2 * Egui::WindowFrame::Ubuntu::BTN_GAP,
      Egui::WindowFrame::Ubuntu::CAPTION_H / 2.0)
    frame_draw(ctx, style, [Egui::Event.pointer_pressed(min_pos)], 0.064)
    frame_draw(ctx, style, [Egui::Event.pointer_released(min_pos)], 0.080)
    win.minimized.should eq(1)
  end

  it "macos: traffic lights left, close first, separator hairline" do
    quit = FrameQuitRecorder.new
    Egui::SystemPorts::Quit.use(quit)

    ctx = Egui::Context.new
    style = Egui::WindowFrame::Style::Macos
    remainder = frame_draw(ctx, style, [] of Egui::Event, 0.016)
    remainder.top.should eq(Egui::WindowFrame::Macos::CAPTION_H)

    mac = Egui::WindowFrame::Macos
    # three lights: red, yellow, green — in that order from the left
    fills = ctx.painter.commands.select(Egui::CircleCmd)
      .select { |c| c.fill == Egui::WindowFrame::Macos::CLOSE ||
                     c.fill == Egui::WindowFrame::Macos::MIN ||
                     c.fill == Egui::WindowFrame::Macos::ZOOM }
      .map { |c| {c.fill, c.center.x} }
    fills.size.should eq(3)
    ordered = fills.sort_by { |(_, x)| x }
    ordered[0][0].should eq(Egui::WindowFrame::Macos::CLOSE) # close is the LEFTMOST light
    ordered[1][0].should eq(Egui::WindowFrame::Macos::MIN)
    ordered[2][0].should eq(Egui::WindowFrame::Macos::ZOOM)

    # separator hairline under the titlebar
    separator = ctx.painter.commands.select(Egui::RectCmd)
      .find { |c| c.fill == Egui::WindowFrame::Macos::SEPARATOR }
    separator.should_not be_nil

    # each light reacts to its OWN hover only: no glyphs without hover,
    # and hovering one light reveals just that glyph (no group coupling)
    step = Egui::WindowFrame::Macos::LIGHT_D + Egui::WindowFrame::Macos::LIGHT_GAP
    group_right = Egui::WindowFrame::Macos::FIRST_CX + 2 * step + 10.0
    glyph_lines = ->do
      ctx.painter.commands.select(Egui::LineCmd)
        .count { |c| c.p1.x < group_right && c.p2.x < group_right }
    end
    glyph_lines.call.should eq(0)

    hover_pos = Egui::Pos2.new(
      Egui::WindowFrame::Macos::FIRST_CX + step,
      Egui::WindowFrame::Macos::CAPTION_H / 2.0)
    frame_draw(ctx, style, [Egui::Event.pointer_moved(hover_pos)], 0.032)
    # hovered the MINIMIZE light: its glyph is a rect, no X / triangle
    # lines from the neighbors may appear
    glyph_lines.call.should eq(0)
    min_glyph = ctx.painter.commands.select(Egui::RectCmd)
      .find { |c| c.fill == Egui::WindowFrame::Macos::MIN_GLYPH }
    min_glyph.should_not be_nil

    # clicking the leftmost (red close) light quits
    close_pos = Egui::Pos2.new(Egui::WindowFrame::Macos::FIRST_CX,
      Egui::WindowFrame::Macos::CAPTION_H / 2.0)
    frame_draw(ctx, style, [Egui::Event.pointer_pressed(close_pos)], 0.032)
    frame_draw(ctx, style, [Egui::Event.pointer_released(close_pos)], 0.048)
    quit.count.should eq(1)
  end

  it "an edge press hands the resize to the native loop" do
    win = FrameWindowRecorder.new
    Egui::SystemPorts::Window.use(win)

    ctx = Egui::Context.new
    frame_draw(ctx, Egui::WindowFrame::Style::Windows,
      [] of Egui::Event, 0.016) # grip rects registered
    # left-edge grip (drag-only sense: the drag starts on press)
    frame_draw(ctx, Egui::WindowFrame::Style::Windows,
      [Egui::Event.pointer_pressed(Egui::Pos2.new(2.0, 300.0))], 0.032)
    win.resizes.should eq([:left])
  end
end
