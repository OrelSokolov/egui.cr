# exml window-frame specs: the frame as markup — the stock
# `<window-frame>` (one line, the style's default caption) and the
# composable `<window-frame-custom>` (an explicit `<window-button>`
# set plus caption content children). Headless, real widgets.

require "spec"
require "../src/egui"

WFX_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(800.0, 600.0))

class WfxQuitRecorder < Egui::SystemPorts::Quit::Implementation
  getter count = 0

  def quit : Nil
    @count += 1
  end
end

class WfxWindowRecorder < Egui::SystemPorts::Window::Implementation
  getter minimized = 0

  def minimize : Nil
    @minimized += 1
  end
end

def wfx_frame(ctx : Egui::Context, nodes : Array(Egui::Exml::Node),
              rt : Egui::Exml::Runtime, renderer : Egui::Exml::Renderer,
              events : Array(Egui::Event) = [] of Egui::Event,
              time : Float64 = 0.016) : Nil
  ctx.begin_frame(Egui::RawInput.new(WFX_SCREEN, events, time))
  ctx.window("w") do |ui|
    nodes.each { |n| renderer.render(n, ui, ctx, rt) }
  end
  ctx.end_frame
end

def wfx_texts(ctx : Egui::Context) : Array(String)
  ctx.painter.commands.select(Egui::TextCmd).map(&.text)
end

describe "exml <window-frame>" do
  it "parses and lints clean" do
    doc = Egui::Exml.parse(%(
      <page id="root">
        <window-frame style="windows-xp" title="App"/>
        <central><label text="hi"/></central>
      </page>
    ))
    Egui::Exml.validate(doc).should be_empty
    doc.pages.first.children.first.kind.window_frame?.should be_true
  end

  it "flags bad style values, bad button types and stock-frame children" do
    doc = Egui::Exml.parse(%(
      <page id="root">
        <window-frame style="vista" title="App"><label text="x"/></window-frame>
        <window-frame-custom style="ubuntu">
          <window-button type="hup"/>
        </window-frame-custom>
      </page>
    ))
    issues = Egui::Exml.validate(doc)
    issues.any?(&.includes?(%(style="vista"))).should be_true
    issues.any?(&.includes?("takes no children")).should be_true
    issues.any?(&.includes?(%(type="hup"))).should be_true
    issues.none?(&.includes?(%(style="ubuntu"))).should be_true
  end

  it "renders the stock chrome: the style's caption with its title" do
    doc = Egui::Exml.parse(%(
      <page id="root"><window-frame style="windows" title="egui"/></page>
    ))
    rt = Egui::Exml::Runtime.new
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new
    wfx_frame(ctx, doc.pages.first.children, rt, renderer)

    title = ctx.painter.commands.select(Egui::TextCmd)
      .find { |c| c.text == "egui" }.should_not be_nil
    title.not_nil!.pos.y.should be < Egui::WindowFrame::Windows::CAPTION_H
  end

  it "renders custom frame: content in the caption, title not painted" do
    doc = Egui::Exml.parse(%(
      <page id="root">
        <window-frame-custom style="windows" title="App" height="44">
          <label text="Tabs!"/>
        </window-frame-custom>
      </page>
    ))
    rt = Egui::Exml::Runtime.new
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new
    wfx_frame(ctx, doc.pages.first.children, rt, renderer)

    texts = wfx_texts(ctx)
    texts.should contain("Tabs!")
    texts.should_not contain("App") # content replaces the title
    # the height= override widened the caption strip
    label = ctx.painter.commands.select(Egui::TextCmd)
      .find { |c| c.text == "Tabs!" }.not_nil!
    label.pos.y.should be < 44.0
  end

  it "custom frame: on_click= replaces the native close action" do
    quit = WfxQuitRecorder.new
    Egui::SystemPorts::Quit.use(quit)
    doc = Egui::Exml.parse(%(
      <page id="root">
        <window-frame-custom style="windows" title="App">
          <label text="Tabs!"/>
          <window-button type="close" on_click="no_close"/>
        </window-frame-custom>
      </page>
    ))
    rt = Egui::Exml::Runtime.new
    fired = 0
    rt.actions["no_close"] = ->{ fired += 1; nil }
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new
    wfx_frame(ctx, doc.pages.first.children, rt, renderer) # rects registered

    btn_w = Egui::WindowFrame::Windows::BTN_W
    close_pos = Egui::Pos2.new(800.0 - 0.5 * btn_w, 16.0)
    wfx_frame(ctx, doc.pages.first.children, rt, renderer,
      [Egui::Event.pointer_pressed(close_pos)], 0.032)
    wfx_frame(ctx, doc.pages.first.children, rt, renderer,
      [Egui::Event.pointer_released(close_pos)], 0.048)
    fired.should eq(1)
    quit.count.should eq(0) # the native quit was suppressed
  end

  it "custom frame: buttons keep native actions without on_click" do
    quit = WfxQuitRecorder.new
    win = WfxWindowRecorder.new
    Egui::SystemPorts::Quit.use(quit)
    Egui::SystemPorts::Window.use(win)
    doc = Egui::Exml.parse(%(
      <page id="root">
        <window-frame-custom style="windows" title="App">
          <window-button type="minimize" if="can_min"/>
        </window-frame-custom>
      </page>
    ))
    rt = Egui::Exml::Runtime.new
    rt.bools["can_min"] = true
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new
    wfx_frame(ctx, doc.pages.first.children, rt, renderer) # rects registered

    btn_w = Egui::WindowFrame::Windows::BTN_W
    # a single listed button: leftmost AND rightmost — its slot is at
    # the right edge (cluster of one)
    min_pos = Egui::Pos2.new(800.0 - 0.5 * btn_w, 16.0)
    wfx_frame(ctx, doc.pages.first.children, rt, renderer,
      [Egui::Event.pointer_pressed(min_pos)], 0.032)
    wfx_frame(ctx, doc.pages.first.children, rt, renderer,
      [Egui::Event.pointer_released(min_pos)], 0.048)
    win.minimized.should eq(1)

    # if= gates the button out: the same click now hits nothing
    rt.bools["can_min"] = false
    wfx_frame(ctx, doc.pages.first.children, rt, renderer,
      [Egui::Event.pointer_pressed(min_pos)], 0.064)
    wfx_frame(ctx, doc.pages.first.children, rt, renderer,
      [Egui::Event.pointer_released(min_pos)], 0.080)
    win.minimized.should eq(1) # still one — the button was hidden
  end

  it "window-button outside a custom frame is ignored with a warn-once" do
    doc = Egui::Exml.parse(%(
      <page id="root"><window-button type="close"/></page>
    ))
    Egui::Exml.validate(doc).should be_empty # structure is a render-time thing
    rt = Egui::Exml::Runtime.new
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new
    wfx_frame(ctx, doc.pages.first.children, rt, renderer)
    wfx_texts(ctx).should eq(["w"]) # the window's own title, nothing else
  end
end
