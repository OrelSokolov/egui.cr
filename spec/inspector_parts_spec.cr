# Inspector coverage of paint-in-place parts: menu rows, title-bar
# tab cards, the Tabs container strip and the terminal grid. These
# sites draw with painter calls (not through `Ui#add`), so they need
# the `StyledPart` meta plumbing — meta recorded per interact, style
# keys read through the class + per-element cascade.

require "spec"
require "../src/egui"

PARTS_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(800.0, 600.0))

# A local fake terminal backend (the terminal_widget_spec twin — specs
# run per file, the class does not leak).
class PartsFakeBackend < Egui::Terminal::Backend
  getter term : Egui::Terminal::Terminal

  def initialize(@term : Egui::Terminal::Terminal)
  end

  def self.with_screen(text : String) : PartsFakeBackend
    new(Egui::Terminal::Terminal.new(20, 5).tap(&.feed(text)))
  end

  def pump : Bool
    false
  end

  def write(bytes : Bytes) : Nil
  end

  def resize(cols : Int32, rows : Int32) : Nil
    @term.resize(cols, rows)
  end

  def alive? : Bool
    true
  end

  def exit_code : Int32?
    0
  end

  def close : Nil
  end
end

def parts_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
                time : Float64 = 0.016, &app : Egui::Context ->)
  raw = Egui::RawInput.new(PARTS_SCREEN, events, time)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

describe "paint-in-place parts in the inspector" do
  it "records menu item meta and styles its hover band via menu.item rules" do
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    parts_frame(ctx) do |c|
      c.menu_bar do |bar|
        bar.menu_button("View") do |m|
          m.menu_item("Tool Box") { }
        end
      end
    end
    # the bar button itself
    metas = ctx.inspector.meta_values
    btn = metas.find(&.kind.==("MenuButton")).not_nil!
    btn.style_class.should eq "menu.button"
    btn.props.any? { |p| p.key == "background" }.should be_true

    # open the menu so the ITEM interacts and records meta
    menu = ->(events : Array(Egui::Event), time : Float64) do
      parts_frame(ctx, events, time) do |c|
        c.menu_bar do |bar|
          bar.menu_button("View") do |m|
            m.menu_item("Tool Box") { }
          end
        end
      end
    end
    menu.call([Egui::Event.pointer_pressed(Egui::Pos2.new(20.0, 12.0))], 0.032)
    menu.call([Egui::Event.pointer_released(Egui::Pos2.new(20.0, 12.0))], 0.048)
    menu.call([] of Egui::Event, 0.080)
    item = ctx.inspector.meta_values.find(&.kind.==("MenuItem"))
    item.should_not be_nil
    item.not_nil!.style_class.should eq "menu.item"
    item.not_nil!.label.should eq "Tool Box"

    # a hover rule restyles the row: move over the item, then a rule
    # swap must change the band fill (rule change → repaint → next
    # frame paints it)
    row_text = ctx.painter.commands.select(Egui::TextCmd)
      .find(&.text.==("Tool Box")).not_nil!
    hover = Egui::Pos2.new(row_text.pos.x + 10.0, row_text.pos.y)
    red = Egui::Color32.rgb(255, 0, 0)
    ctx.stylesheet.rule("menu.item:hover",
      Egui::StyleVars{"background" => red})
    menu.call([Egui::Event.pointer_moved(hover)], 0.096)
    ctx.painter.commands.select(Egui::RectCmd)
      .any? { |r| r.fill == red }.should be_true
  end

  it "records title-bar tab meta and restyles cards via title_bar.tab rules" do
    Egui::WindowFrame.caption(
      height: Egui::TitleBarTabs::CAPTION_H) do |ctx, area|
      Egui::TitleBarTabs.show(ctx, area, ["one", "two"], 0)
    end
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    frame = ->(time : Float64) do
      raw = Egui::RawInput.new(PARTS_SCREEN, [] of Egui::Event, time)
      ctx.begin_frame(raw)
      Egui::WindowFrame.show(ctx, "spec",
        Egui::WindowFrame::Style::Windows)
      ctx.central_panel { }
      ctx.end_frame
    end
    frame.call(0.016)

    metas = ctx.inspector.meta_values
    tab = metas.find(&.kind.==("Tab")).not_nil!
    tab.style_class.should eq "title_bar.tab"
    tab.props.any? { |p| p.key == "min_width" }.should be_true
    metas.any?(&.kind.==("NewTab")).should be_true

    # min_width rule reflows the cards: the first card grows to the
    # styled minimum (its title is narrower than 220px)
    ctx.stylesheet.rule("title_bar.tab",
      Egui::StyleVars{"min_width" => 220.0})
    frame.call(0.032)
    card = ctx.painter.commands.select(Egui::RectCmd)
      .find { |c| c.fill == ctx.style.visuals.panel_fill &&
                  c.rect.top == Egui::TitleBarTabs::TAB_TOP_GAP }
    card.should_not be_nil
    card.not_nil!.rect.width.should be >= 220.0

    # the active card's fill is the stateless `background` key
    green = Egui::Color32.rgb(0, 255, 0)
    ctx.stylesheet.rule("title_bar.tab",
      Egui::StyleVars{"background" => green})
    frame.call(0.048)
    ctx.painter.commands.select(Egui::RectCmd)
      .any? { |r| r.fill == green }.should be_true
  ensure
    Egui::WindowFrame.caption!
  end

  it "Tabs: per-tab element override beats the class rule for one card" do
    ctx = Egui::Context.new
    blue = Egui::Color32.rgb(0, 0, 255)
    lime = Egui::Color32.rgb(0, 255, 100)
    ctx.stylesheet.rule("tabs.tab:selected",
      Egui::StyleVars{"background" => blue})
    ctx.inspector_enabled = true
    draw = ->(time : Float64) do
      raw = Egui::RawInput.new(PARTS_SCREEN, [] of Egui::Event, time)
      ctx.begin_frame(raw)
      ctx.central_panel do |ui|
        ui.add(Egui::Tabs.new(["a", "b"], 0))
      end
      ctx.end_frame
      ctx.painter.commands.select(Egui::RectCmd)
    end

    draw.call(0.016)
    metas = ctx.inspector.meta_values.select(&.kind.==("Tab"))
    metas.size.should eq(2)
    metas.each do |m|
      m.style_class.should eq("tabs.tab")
      m.props.any? { |p| p.key == "background" }.should be_true
    end

    # an element HOVER override on the SECOND card repaints only that
    # card when hovered; the first keeps the class-selected blue
    ctx.set_id_style(metas[1].id, "background", lime, "hover")
    ctx.inspector_enabled = false
    center = ctx.memory.widget_rects[metas[1].id]?.try(&.center) ||
             ctx.memory.prev_widget_rects[metas[1].id].not_nil!.center
    raw = Egui::RawInput.new(PARTS_SCREEN,
      [Egui::Event.pointer_moved(center)], 0.032)
    ctx.begin_frame(raw)
    ctx.central_panel do |ui|
      ui.add(Egui::Tabs.new(["a", "b"], 0))
    end
    ctx.end_frame
    rects = ctx.painter.commands.select(Egui::RectCmd)
    rects.any? { |r| r.fill == lime }.should be_true
    rects.any? { |r| r.fill == blue }.should be_true
  end

  it "terminal: style keys cover colors and font size, rules restyle the grid" do
    backend = PartsFakeBackend.with_screen("hello")
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    parts_frame(ctx) do |c|
      c.central_panel { |ui| ui.terminal(backend) }
    end
    m = ctx.inspector.meta_values.find(&.kind.==("TermView")).not_nil!
    m.style_class.should eq "terminal"
    keys = m.props.map(&.key)
    {"font_size", "background", "text_color", "cursor_color",
     "selection_overlay", "scrollbar_color"}.each do |k|
      keys.should contain(k)
    end
    # fallback shown while unset = the terminal theme default, not a
    # generic theme slot
    bg_prop = m.props.find(&.key.==("background")).not_nil!
    bg_prop.fallback.as?(Egui::Color32).should eq(
      Egui::Terminal::Theme.new.background)

    # a background rule repaints the grid
    navy = Egui::Color32.rgb(10, 10, 40)
    ctx.stylesheet.rule("terminal", Egui::StyleVars{"background" => navy})
    parts_frame(ctx, time: 0.032) do |c|
      c.central_panel { |ui| ui.terminal(backend) }
    end
    rects = ctx.painter.commands.select(Egui::RectCmd)
    rects.any? { |r| r.fill == navy }.should be_true
    rects.none? { |r| r.fill == Egui::Terminal::Theme.new.background }
      .should be_true
    # text color follows too
    amber = Egui::Color32.rgb(255, 191, 0)
    ctx.stylesheet.rule("terminal", Egui::StyleVars{"text_color" => amber})
    parts_frame(ctx, time: 0.048) do |c|
      c.central_panel { |ui| ui.terminal(backend) }
    end
    ctx.painter.commands.select(Egui::TextCmd)
      .any?(&.color.==(amber)).should be_true
  end

  it "inspector header tabs: InspectorTab meta + inspector.tab rules restyle the cells" do
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    # the panel renders from #before_update — parts_frame skips it
    frame = ->(time : Float64) do
      raw = Egui::RawInput.new(PARTS_SCREEN, [] of Egui::Event, time)
      ctx.begin_frame(raw)
      ctx.inspector.before_update
      ctx.end_frame
    end

    frame.call(0.016)
    metas = ctx.inspector.meta_values.select(&.kind.==("InspectorTab"))
    metas.size.should eq(2) # "Class" + "Element"
    metas.each do |m|
      m.style_class.should eq("inspector.tab")
      m.props.any? { |p| p.key == "background" }.should be_true
    end
    metas.map(&.label).compact.sort.should eq(["Class", "Element"])

    # a rule restyles the ACTIVE cell (the element tab is on by default)
    pink = Egui::Color32.rgb(255, 0, 255)
    ctx.stylesheet.rule("inspector.tab:selected",
      Egui::StyleVars{"background" => pink})
    frame.call(0.032)
    active = ctx.painter.commands.select(Egui::RectCmd)
      .find { |r| r.fill == pink }.not_nil!
    active.rect.width.should be_close(Egui::Inspector::TAB_W, 0.01)
    active.rect.height.should be_close(Egui::Inspector::TAB_H, 0.01)
  end

  it "sidebar: tabs and close X record their own meta, rules restyle both" do
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    sections = [Egui::Sidebar::Section.new("One", ["A", "B"], closable: true)]
    draw = ->(time : Float64) do
      raw = Egui::RawInput.new(PARTS_SCREEN, [] of Egui::Event, time)
      ctx.begin_frame(raw)
      ctx.central_panel do |ui|
        ui.sidebar(sections, 0, 0) { |_s, _t| }
      end
      ctx.end_frame
      ctx.painter.commands.select(Egui::RectCmd)
    end

    draw.call(0.016)
    metas = ctx.inspector.meta_values
    tabs = metas.select(&.kind.==("SidebarTab"))
    tabs.size.should eq(2)
    tabs.each do |m|
      m.style_class.should eq("sidebar.tab")
      m.props.any? { |p| p.key == "background" }.should be_true
    end
    xs = metas.select(&.kind.==("SidebarCloseButton"))
    xs.size.should eq(2)
    xs.each do |m|
      m.style_class.should eq("sidebar.close")
      m.props.any? { |p| p.key == "background" }.should be_true
    end

    # the selected row takes the class fill, its X the per-element
    # hover override (pointer parked on the first X)
    lime = Egui::Color32.rgb(0, 255, 100)
    cyan = Egui::Color32.rgb(0, 255, 255)
    ctx.stylesheet.rule("sidebar.tab:selected",
      Egui::StyleVars{"background" => lime})
    x_rect = ctx.memory.widget_rects[xs[0].id]? ||
             ctx.memory.prev_widget_rects[xs[0].id].not_nil!
    ctx.set_id_style(xs[0].id, "background", cyan, "hover")
    raw = Egui::RawInput.new(PARTS_SCREEN,
      [Egui::Event.pointer_moved(x_rect.center)], 0.032)
    ctx.begin_frame(raw)
    ctx.central_panel do |ui|
      ui.sidebar(sections, 0, 0) { |_s, _t| }
    end
    ctx.end_frame
    rects = ctx.painter.commands.select(Egui::RectCmd)
    rects.any? { |r| r.fill == lime }.should be_true
    rects.any? { |r| r.fill == cyan }.should be_true
  end
end
