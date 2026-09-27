# TitleBarTabs specs: the Windows 11 Notepad-style tab strip in the
# window caption, drawn through the WindowFrame caption hook — caption
# height override, the content area excluding the caption buttons, tab
# selection / close / new-tab callbacks, the dirty-dot marker, and the
# layering contract (tab clicks never drag the window, the empty
# caption around the strip still does). Headless: WindowFrame.show is
# exactly what the sokol backend calls before app frames.

require "spec"
require "../src/egui"

TABS_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(800.0, 600.0))

# One frame: chrome (with the caption hook) + a central panel, driven
# headless. Returns the central panel's remainder (its top edge is the
# caption bottom — the height check).
def tabs_frame(ctx : Egui::Context, events : Array(Egui::Event),
               time : Float64) : Egui::Rect
  raw = Egui::RawInput.new(TABS_SCREEN, events, time)
  ctx.begin_frame(raw)
  Egui::WindowFrame.show(ctx, "notepad", Egui::WindowFrame::Style::Windows)
  remainder = ctx.central_panel { }
  ctx.end_frame
  remainder
end

# Caption-content harness: TitleBarTabs wired to recorders, installed
# through the WindowFrame hook exactly like the notepad example.
class TabsHarness
  property titles = ["one", "two", "three"]
  property selected = 0
  property dirty = [false, false, false]
  property closed : Int32? = nil
  getter new_count = 0
  getter areas = [] of Egui::Rect

  def initialize
    Egui::WindowFrame.caption(
      height: Egui::TitleBarTabs::CAPTION_H) do |ctx, area|
      @areas << area
      Egui::TitleBarTabs.show(ctx, area, titles, selected,
        dirty: dirty,
        on_select: ->(t : Int32) { self.selected = t; nil },
        on_close: ->(t : Int32) { self.closed = t; nil },
        on_new: -> { @new_count += 1; nil })
    end
  end
end

# Card zone center Y (cards hang from the caption's bottom edge).
TAB_CARD_Y = Egui::TitleBarTabs::TAB_TOP_GAP +
             (Egui::TitleBarTabs::CAPTION_H - Egui::TitleBarTabs::TAB_TOP_GAP) / 2.0

# Click targets inside the strip: tab i's center and tab i's X, from
# the same measure formula the widget uses.
def tab_center(ctx : Egui::Context, harness : TabsHarness, i : Int32) : Egui::Pos2
  x = Egui::TitleBarTabs::FIRST_INSET
  harness.titles.each_with_index do |t, j|
    w = {ctx.fonts.measure(t, Egui::TitleBarTabs::FONT).x +
         2 * Egui::TitleBarTabs::PAD_X +
         Egui::TitleBarTabs::ICON + Egui::TitleBarTabs::ICON_GAP,
         Egui::TitleBarTabs::MIN_W}.max
    x += w
    return Egui::Pos2.new(x - w / 2.0, TAB_CARD_Y) if j == i
  end
  raise "no tab #{i}"
end

def close_x(ctx : Egui::Context, harness : TabsHarness, i : Int32) : Egui::Pos2
  x = Egui::TitleBarTabs::FIRST_INSET
  harness.titles.each_with_index do |t, j|
    w = {ctx.fonts.measure(t, Egui::TitleBarTabs::FONT).x +
         2 * Egui::TitleBarTabs::PAD_X +
         Egui::TitleBarTabs::ICON + Egui::TitleBarTabs::ICON_GAP,
         Egui::TitleBarTabs::MIN_W}.max
    x += w
    if j == i
      return Egui::Pos2.new(x - Egui::TitleBarTabs::PAD_X -
        Egui::TitleBarTabs::ICON / 2.0, TAB_CARD_Y)
    end
  end
  raise "no tab #{i}"
end

# Quit port recorder — local to this spec file.
class TabsQuitRecorder < Egui::SystemPorts::Quit::Implementation
  getter count = 0

  def quit : Nil
    @count += 1
  end
end

# Window port recorder (drag counting) — local to this spec file.
class TabsWindowRecorder < Egui::SystemPorts::Window::Implementation
  getter drags = 0

  def minimize : Nil
  end

  def maximize : Nil
  end

  def restore : Nil
  end

  def start_drag : Nil
    @drags += 1
  end

  def start_resize(edge : Symbol) : Nil
  end
end

describe Egui::TitleBarTabs do
  after_each do
    Egui::WindowFrame.caption!
    Egui::WindowFrame.icon = nil
  end
  it "raises the caption to CAPTION_H and hands content the area left of the caption buttons" do
    harness = TabsHarness.new
    ctx = Egui::Context.new
    remainder = tabs_frame(ctx, [] of Egui::Event, 0.016)

    remainder.top.should eq(Egui::TitleBarTabs::CAPTION_H)
    area = harness.areas.last
    btn_w = Egui::WindowFrame::Windows::BTN_W
    area.right.should eq(800.0 - 3 * btn_w)
    area.height.should eq(Egui::TitleBarTabs::CAPTION_H)
  end

  it "hides the title text while content is installed, restores it after" do
    harness = TabsHarness.new
    ctx = Egui::Context.new
    tabs_frame(ctx, [] of Egui::Event, 0.016)
    ctx.painter.commands.select(Egui::TextCmd)
      .any?(&.text.==("notepad")).should be_false

    Egui::WindowFrame.caption!
    ctx2 = Egui::Context.new
    tabs_frame(ctx2, [] of Egui::Event, 0.032)
    ctx2.painter.commands.select(Egui::TextCmd)
      .any?(&.text.==("notepad")).should be_true
    # caption height restored
    tabs_frame(ctx2, [] of Egui::Event, 0.048).top
      .should eq(Egui::WindowFrame::Windows::CAPTION_H)
  end

  it "paints the active card in the menu bar's color with top rounding" do
    harness = TabsHarness.new
    ctx = Egui::Context.new
    tabs_frame(ctx, [] of Egui::Event, 0.016)

    # the active card's fill == the theme's panel_fill (the menu bar's
    # color) — the card merges with the bar below it; pick it out of
    # the other panel_fill rects by the card geometry
    card = ctx.painter.commands.select(Egui::RectCmd)
      .find { |c| c.fill == ctx.style.visuals.panel_fill &&
                  c.rect.top == Egui::TitleBarTabs::TAB_TOP_GAP }
    card.should_not be_nil
    card.not_nil!.rounding.should eq(Egui::TitleBarTabs::ROUNDING)
    # cards hang from the caption's BOTTOM edge, air above them
    card.not_nil!.rect.top.should eq(Egui::TitleBarTabs::TAB_TOP_GAP)
    card.not_nil!.rect.bottom.should eq(Egui::TitleBarTabs::CAPTION_H)
  end

  it "clicks select a tab; the X closes it without selecting" do
    harness = TabsHarness.new
    ctx = Egui::Context.new
    tabs_frame(ctx, [] of Egui::Event, 0.016) # rects registered

    second = tab_center(ctx, harness, 1)
    tabs_frame(ctx, [Egui::Event.pointer_pressed(second)], 0.032)
    tabs_frame(ctx, [Egui::Event.pointer_released(second)], 0.048)
    harness.selected.should eq(1)

    # X of the (now inactive) first tab: closes, never selects
    x0 = close_x(ctx, harness, 0)
    tabs_frame(ctx, [Egui::Event.pointer_moved(x0)], 0.064)
    tabs_frame(ctx, [Egui::Event.pointer_pressed(x0)], 0.080)
    tabs_frame(ctx, [Egui::Event.pointer_released(x0)], 0.096)
    harness.closed.should eq(0)
    harness.selected.should eq(1)
  end

  it "a dirty tab shows a dot; hovering swaps it for the X" do
    harness = TabsHarness.new
    harness.dirty = [false, true, false]
    ctx = Egui::Context.new
    tabs_frame(ctx, [] of Egui::Event, 0.016)

    # no hover: no X on the dirty tab — a dot circle instead
    x1 = close_x(ctx, harness, 1)
    circle = ctx.painter.commands.select(Egui::CircleCmd)
      .find { |c| (c.center.x - x1.x).abs < 2.0 }
    circle.should_not be_nil

    tabs_frame(ctx, [Egui::Event.pointer_moved(x1)], 0.032)
    # hovered: the X came back (lines inside the marker box)
    x_lines = ctx.painter.commands.select(Egui::LineCmd)
      .count { |c| (c.p1.x - x1.x).abs < 6.0 && (c.p2.x - x1.x).abs < 6.0 }
    x_lines.should be >= 2
  end

  it "the inactive tab paints no X; the active tab does" do
    harness = TabsHarness.new
    ctx = Egui::Context.new
    tabs_frame(ctx, [] of Egui::Event, 0.016)

    x_lines_near = ->(x : Float64) do
      ctx.painter.commands.select(Egui::LineCmd)
        .count { |c| (c.p1.x - x).abs < 12.0 && (c.p2.x - x).abs < 12.0 }
    end
    # tab 0 is ACTIVE (selected = 0) → its X is painted
    x_lines_near.call(close_x(ctx, harness, 0).x).should be >= 2
    # tab 1 is inactive, clean, unhovered → no X
    x_lines_near.call(close_x(ctx, harness, 1).x).should eq(0)

    # hovering the inactive tab's marker slot brings the X back
    x1 = close_x(ctx, harness, 1)
    tabs_frame(ctx, [Egui::Event.pointer_moved(x1)], 0.032)
    x_lines_near.call(x1.x).should be >= 2
  end

  it "the + button fires on_new" do
    harness = TabsHarness.new
    ctx = Egui::Context.new
    tabs_frame(ctx, [] of Egui::Event, 0.016)

    total = harness.titles.sum do |t|
      {ctx.fonts.measure(t, Egui::TitleBarTabs::FONT).x +
         2 * Egui::TitleBarTabs::PAD_X +
         Egui::TitleBarTabs::ICON + Egui::TitleBarTabs::ICON_GAP,
       Egui::TitleBarTabs::MIN_W}.max
    end
    plus = Egui::Pos2.new(
      Egui::TitleBarTabs::FIRST_INSET + total + Egui::TitleBarTabs::NEW_GAP +
        Egui::TitleBarTabs::NEW_BOX / 2.0,
      Egui::TitleBarTabs::CAPTION_H - Egui::TitleBarTabs::NEW_BOX / 2.0)
    tabs_frame(ctx, [Egui::Event.pointer_pressed(plus)], 0.032)
    tabs_frame(ctx, [Egui::Event.pointer_released(plus)], 0.048)
    harness.new_count.should eq(1)
  end

  it "caption buttons stay in the top 32pt strip with tabs installed" do
    quit = TabsQuitRecorder.new
    Egui::SystemPorts::Quit.use(quit)
    harness = TabsHarness.new
    ctx = Egui::Context.new
    tabs_frame(ctx, [] of Egui::Event, 0.016)

    # close button: pinned top-right, CAPTION_H tall — not stretched
    # over the taller 44pt caption
    btn_w = Egui::WindowFrame::Windows::BTN_W
    btn_h = Egui::WindowFrame::Windows::CAPTION_H
    close = ctx.painter.commands.select(Egui::RectCmd)
      .find { |c| c.fill == Egui::WindowFrame::Windows::CLOSE_HOVER }
    close_pos = Egui::Pos2.new(800.0 - 0.5 * btn_w, btn_h / 2.0)
    tabs_frame(ctx, [Egui::Event.pointer_moved(close_pos)], 0.032)
    close = ctx.painter.commands.select(Egui::RectCmd)
      .find { |c| c.fill == Egui::WindowFrame::Windows::CLOSE_HOVER }
    close.should_not be_nil
    close.not_nil!.rect.top.should eq(0.0)
    close.not_nil!.rect.height.should eq(btn_h)

    # and it still quits
    tabs_frame(ctx, [Egui::Event.pointer_pressed(close_pos)], 0.048)
    tabs_frame(ctx, [Egui::Event.pointer_released(close_pos)], 0.064)
    quit.count.should eq(1)
  end

  it "an installed app icon takes the left slot; tabs start after it" do
    harness = TabsHarness.new
    Egui::WindowFrame.icon = {rgba: Bytes.new(4 * 64 * 64, 128_u8),
      width: 64, height: 64}
    ctx = Egui::Context.new
    tabs_frame(ctx, [] of Egui::Event, 0.016)

    # the icon is painted: a 16x16 ImageCmd at the left caption edge
    img = ctx.painter.commands.select(Egui::ImageCmd).last?
    img.should_not be_nil
    img.not_nil!.rect.left.should eq(Egui::WindowFrame::Windows::ICON_PAD)
    img.not_nil!.rect.width.should eq(Egui::WindowFrame::Windows::ICON_SIZE)
    # centered against the TAB CARDS (below TitleBarTabs' top gap),
    # not the whole caption bar — same vertical zone as the cards
    img.not_nil!.rect.top.should eq(Egui::TitleBarTabs::TAB_TOP_GAP +
      (Egui::TitleBarTabs::CAPTION_H - Egui::TitleBarTabs::TAB_TOP_GAP -
       Egui::WindowFrame::Windows::ICON_SIZE) / 2.0)

    # the content area starts AFTER the icon slot
    area = harness.areas.last
    area.left.should eq(Egui::WindowFrame::Windows::ICON_PAD +
      Egui::WindowFrame::Windows::ICON_SIZE +
      Egui::WindowFrame::Windows::ICON_GAP)

    # no icon → no ImageCmd, the area starts at the left edge again
    Egui::WindowFrame.icon = nil
    tabs_frame(ctx, [] of Egui::Event, 0.032)
    harness.areas.last.left.should eq(0.0)
    ctx.painter.commands.select(Egui::ImageCmd)
      .any? { |c| c.rect.width == Egui::WindowFrame::Windows::ICON_SIZE }
      .should be_false
  end

  it "with an icon and no tabs, the title moves after the icon slot" do
    Egui::WindowFrame.icon = {rgba: Bytes.new(4 * 64 * 64, 128_u8),
      width: 64, height: 64}
    ctx = Egui::Context.new
    tabs_frame(ctx, [] of Egui::Event, 0.016)
    ctx.painter.commands.select(Egui::TextCmd)
      .find { |c| c.text == "notepad" }.not_nil!.pos.x
      .should be >= Egui::WindowFrame::Windows::ICON_PAD +
        Egui::WindowFrame::Windows::ICON_SIZE +
        Egui::WindowFrame::Windows::ICON_GAP

    # without an icon the title sits at the plain TITLE_PAD
    Egui::WindowFrame.icon = nil
    tabs_frame(ctx, [] of Egui::Event, 0.032)
    ctx.painter.commands.select(Egui::TextCmd)
      .find { |c| c.text == "notepad" }.not_nil!.pos.x
      .should eq(Egui::WindowFrame::Windows::TITLE_PAD)
  end

  it "the caption fill stops exactly at its bottom — no 1px line over the menu bar" do
    harness = TabsHarness.new
    ctx = Egui::Context.new
    tabs_frame(ctx, [] of Egui::Event, 0.016)

    # no caption-BG rect may reach past the caption bottom: the old
    # 1pt overshoot covered the menu bar's top pixel with #202020 and
    # broke the active-card/menu-bar merge (both panel_fill)
    bg = Egui::WindowFrame::Windows::BG
    ctx.painter.commands.select(Egui::RectCmd)
      .count { |c| c.fill == bg &&
                   c.rect.bottom > Egui::TitleBarTabs::CAPTION_H }
      .should eq(0)
  end

  it "tab clicks never drag the window; the empty caption still does" do
    win = TabsWindowRecorder.new
    Egui::SystemPorts::Window.use(win)
    harness = TabsHarness.new
    ctx = Egui::Context.new
    tabs_frame(ctx, [] of Egui::Event, 0.016)

    first = tab_center(ctx, harness, 0)
    tabs_frame(ctx, [Egui::Event.pointer_pressed(first)], 0.032)
    win.drags.should eq(0)

    # the caption drag needs pointer movement (click-vs-drag ambiguity)
    empty = Egui::Pos2.new(600.0, 5.0) # caption air ABOVE the cards
    tabs_frame(ctx, [Egui::Event.pointer_moved(empty),
      Egui::Event.pointer_pressed(empty)], 0.048)
    tabs_frame(ctx, [Egui::Event.pointer_moved(
      Egui::Pos2.new(empty.x + 20.0, empty.y))], 0.064)
    win.drags.should eq(1)
  end
end
