# exml specs: parse structure, store interpolation, conditional
# rendering and the hot-reload stat loop — headless, real egui
# widgets (the renderer dispatches to the actual Ui API).

require "spec"
require "../src/egui"

EXML_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(800.0, 600.0))

def exml_frame(ctx : Egui::Context, nodes : Array(Egui::Exml::Node),
               rt : Egui::Exml::Runtime, renderer : Egui::Exml::Renderer,
               events : Array(Egui::Event) = [] of Egui::Event,
               time : Float64 = 0.016) : Nil
  ctx.begin_frame(Egui::RawInput.new(EXML_SCREEN, events, time))
  ctx.window("w") do |ui|
    nodes.each { |n| renderer.render(n, ui, ctx, rt) }
  end
  ctx.end_frame
end

# The Vue docs' counter example, ported:
#   <script setup> const count = ref(0) </script>
#   <template> <button @click="count++">…{{ count }}…</button> </template>
class VueCounter < Egui::Exml::Component
  def template : String
    %(<button text="You clicked me {count} times." on_click="inc"/>)
  end

  def setup(rt : Egui::Exml::Runtime) : Nil
    rt.floats["count"] = 0
    rt.actions["inc"] = ->bump
  end

  def bump : Nil
    rt.not_nil!.floats["count"] += 1
  end
end

# The `exml` macro variant: template loaded/embedded from a path.
class MacroFps < Egui::Exml::Component
  exml "assets/components/fps_meter.exml"
end

# Use-site attrs become component props (seeded before setup).
class Propped < Egui::Exml::Component
  def template : String
    %(<label text="precision={precision} label={label} plain={plain}"/>)
  end
end

# A global `widget`-registered element (the spec below renders it
# through a renderer that never called #on — the dispatch must fall
# through to the global registry).
WIDGET_SEEN = [] of String

widget :spec_gauge do |node, ui, ctx, rt, r|
  WIDGET_SEEN << "global:#{node.attrs["frac"]?}"
  ui.progress_bar(rt.floats[node.attrs["frac"]?]? || 0.0)
end

describe Egui::Exml do
  it "parses pages, modals, attributes and nesting" do
    doc = Egui::Exml.parse(%(
      <exml>
        <page id="root/root" title="Main">
          <menubar>
            <menu label="File">
              <item label="New" on_click="new" hint="Ctrl+N"/>
            </menu>
          </menubar>
          <central><label text="hi"/></central>
          <statusbar><label text="{status}"/></statusbar>
        </page>
        <modal id="root/confirm" if="pending" buttons="Save|Cancel"
               on_button="confirm"><label text="unsaved"/></modal>
      </exml>
    ))
    doc.pages.size.should eq(2)
    root = doc.page("root/root").should_not be_nil
    root.kind.page?.should be_true
    root.children.map(&.kind).should eq(
      [Egui::Exml::Kind::MenuBar, Egui::Exml::Kind::Central,
       Egui::Exml::Kind::Statusbar])
    menu = root.children.first.children.first
    menu.attrs["label"].should eq("File")
    item = menu.children.first
    item.attrs["on_click"].should eq("new")
    item.attrs["hint"].should eq("Ctrl+N")

    modal = doc.page("root/confirm").should_not be_nil
    modal.kind.modal?.should be_true
    modal.attrs["buttons"].should eq("Save|Cancel")
    modal.attrs["if"].should eq("pending")
  end

  it "splits options= on a custom delimiter" do
    doc = Egui::Exml.parse(%(
      <page id="p">
        <combo bind="a" options="one|two|three" delimiter="|"/>
        <combo bind="b" options="One two three" delimiter=" "/>
        <combo bind="c" options="x,y" delimiter=","/>
        <combo bind="d" options="x|y"/>
      </page>
    ))
    kids = doc.pages.first.children
    kids[0].combo_options.should eq(%w(one two three))
    kids[1].combo_options.should eq(%w(One two three))
    kids[2].combo_options.should eq(%w(x y))
    kids[3].combo_options.should eq(%w(x y))
  end

  it "renders a combo from a bound :options= list slot, live per frame" do
    doc = Egui::Exml.parse(%(
      <page id="p"><combo bind="sel" :options="genres"/></page>
    ))
    rt = Egui::Exml::Runtime.new
    rt.strings["sel"] = "Jazz"
    rt.lists["genres"] = ["Rock", "Pop", "Jazz"]
    renderer = Egui::Exml::Renderer.new

    ctx = Egui::Context.new
    exml_frame(ctx, doc.pages.first.children, rt, renderer)

    # click the closed button's text → the popup opens in-frame
    label = ctx.painter.commands.select(Egui::TextCmd)
      .find { |c| c.text == "Jazz" }.should_not be_nil
    pos = Egui::Pos2.new(label.pos.x + 2, label.pos.y - label.size / 2)
    exml_frame(ctx, doc.pages.first.children, rt, renderer,
      events: [Egui::Event.pointer_pressed(pos)], time: 0.032)
    exml_frame(ctx, doc.pages.first.children, rt, renderer,
      events: [Egui::Event.pointer_released(pos)], time: 0.048)
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).should contain("Rock")

    # the app mutates the SAME array in place — no realloc, the next
    # frame reads it fresh (the push model: the store owns the data)
    rt.lists["genres"] << "Blues"
    exml_frame(ctx, doc.pages.first.children, rt, renderer, time: 0.064)
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).should contain("Blues")
  end

  it "scoped runtimes fall back to the parent's list slot" do
    parent = Egui::Exml::Runtime.new
    parent.lists["genres"] = %w(a b)
    scope = Egui::Exml::ScopedRuntime.new(parent)
    scope.list?("genres").should eq(%w(a b))
    scope.lists["genres"] = %w(c)
    scope.list?("genres").should eq(%w(c))
  end

  it "splits modal buttons= on a custom delimiter" do
    doc = Egui::Exml.parse(%(
      <modal id="m" buttons="Yes; No; Cancel" delimiter=";"
             on_button="pick"><label text="sure?"/></modal>
    ))
    doc.pages.first.buttons_list.should eq(%w(Yes No Cancel))
  end

  it "resolves entity escapes in attributes" do
    doc = Egui::Exml.parse(
      %(<page id="p"><label text="&quot;q&quot; &amp; &lt;tag&gt;"/></page>)
    )
    doc.pages.first.children.first.attrs["text"]
      .should eq(%("q" & <tag>))
  end

  it "parses unknown names as Custom (no parse-time warning)" do
    doc = Egui::Exml.parse(
      %(<page id="p"><weird><label text="x"/></weird></page>)
    )
    weird = doc.pages.first.children.first
    weird.kind.custom?.should be_true
    weird.name.should eq("weird")
    weird.children.size.should eq(1)
  end

  it "builds globally unique paths across same-shaped siblings" do
    # two identical rows: buttons must never share an egui Id
    doc = Egui::Exml.parse(%(
      <page id="p">
        <row><button text="A"/><label text="x"/></row>
        <row><button text="B"/><label text="y"/></row>
      </page>
    ))
    paths = [] of String
    doc.pages.first.children.each do |row|
      row.children.each { |c| paths << c.path }
    end
    paths.size.should eq(4)
    paths.uniq.size.should eq(4)

    # and the whole tree renders without a DuplicateWidgetIdError
    rt = Egui::Exml::Runtime.new
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new
    3.times do |i|
      exml_frame(ctx, doc.pages.first.children, rt, renderer,
        time: 0.016 * (i + 1))
    end
  end

  it "interpolates strings, floats and bools; unknown keys stay literal" do
    rt = Egui::Exml::Runtime.new
    rt.strings["name"] = "мир"
    rt.floats["speed"] = 0.5
    rt.bools["on"] = true
    rt.interpolate("Привет, {name}! {speed} {on} {nope}")
      .should eq("Привет, мир! 0.50 true {nope}")
  end

  it "renders real widgets and honors if/unless conditions" do
    doc = Egui::Exml.parse(%(
      <page id="p">
        <label if="flag" text="alpha"/>
        <label if="flag" text="beta"/>
        <button text="Go" on_click="go"/>
      </page>
    ))
    rt = Egui::Exml::Runtime.new
    rt.bools["flag"] = true
    fired = 0
    rt.actions["go"] = ->{ fired += 1; nil }
    renderer = Egui::Exml::Renderer.new

    ctx = Egui::Context.new
    exml_frame(ctx, doc.pages.first.children, rt, renderer)
    texts_with_flag = ctx.painter.commands
      .select(Egui::TextCmd).map(&.text)

    rt.bools["flag"] = false
    exml_frame(ctx, doc.pages.first.children, rt, renderer, time: 0.032)
    texts_without_flag = ctx.painter.commands
      .select(Egui::TextCmd).map(&.text)

    texts_with_flag.should contain("alpha")
    texts_with_flag.should contain("beta")
    texts_without_flag.should_not contain("alpha")
    texts_without_flag.should_not contain("beta")
    fired.should eq(0) # nothing clicked — actions never misfire
  end

  it "fires the bound action when a button is clicked" do
    doc = Egui::Exml.parse(%(
      <page id="p"><button text="Go" on_click="go"/></page>
    ))
    rt = Egui::Exml::Runtime.new
    fired = 0
    rt.actions["go"] = ->{ fired += 1; nil }
    renderer = Egui::Exml::Renderer.new

    ctx = Egui::Context.new
    exml_frame(ctx, doc.pages.first.children, rt, renderer)

    # click inside the button's label glyph run
    label = ctx.painter.commands.select(Egui::TextCmd)
      .find { |c| c.text == "Go" }.should_not be_nil
    pos = Egui::Pos2.new(label.pos.x + 2, label.pos.y - label.size / 2)
    exml_frame(ctx, doc.pages.first.children, rt, renderer,
      events: [Egui::Event.pointer_pressed(pos)], time: 0.032)
    exml_frame(ctx, doc.pages.first.children, rt, renderer,
      events: [Egui::Event.pointer_released(pos)], time: 0.048)
    fired.should eq(1)
  end

  it "writes widget values back into the store" do
    doc = Egui::Exml.parse(%(
      <page id="p">
        <slider bind="speed" min="0" max="1"/>
        <checkbox bind="on" text="Enabled"/>
        <input bind="name"/>
      </page>
    ))
    rt = Egui::Exml::Runtime.new
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new

    # a frame with defaults lands the slots' starting values in the UI
    rt.floats["speed"] = 0.25
    rt.bools["on"] = true
    rt.strings["name"] = "abc"
    exml_frame(ctx, doc.pages.first.children, rt, renderer)
    rt.floats["speed"].should eq(0.25)
    rt.bools["on"].should be_true
    rt.strings["name"].should eq("abc")
  end

  it "interpolates <box> fill/width from the store every frame" do
    doc = Egui::Exml.parse(%(
      <page id="p"><box fill="linear-gradient(135deg, {c1}, {c2})" height="10"><label text="g"/></box></page>
    ))
    rt = Egui::Exml::Runtime.new
    rt.strings["c1"] = "#112233"
    rt.strings["c2"] = "#445566"
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new

    exml_frame(ctx, doc.pages.first.children, rt, renderer)
    found = ctx.painter.commands.select(Egui::RectCmd).find(&.gradient)
    found.should_not be_nil
    grad = found.not_nil!.gradient.not_nil!
    grad.stops.first.color.should eq(Egui::Color32.rgb(0x11, 0x22, 0x33))
    grad.stops.last.color.should eq(Egui::Color32.rgb(0x44, 0x55, 0x66))

    # a store change re-resolves the fill next frame (dynamic covers)
    rt.strings["c2"] = "#ff0000"
    exml_frame(ctx, doc.pages.first.children, rt, renderer, time: 0.032)
    found2 = ctx.painter.commands.select(Egui::RectCmd).find(&.gradient)
    found2.should_not be_nil
    grad2 = found2.not_nil!.gradient.not_nil!
    grad2.stops.last.color.should eq(Egui::Color32.rgb(0xff, 0x00, 0x00))
  end

  it "places <box position=absolute> out of the flow" do
    doc = Egui::Exml.parse(%(
      <page id="p">
        <box position="absolute" top="40" left="80" width="60" height="20">
          <label text="pin"/>
        </box>
        <label text="flow"/>
      </page>
    ))
    rt = Egui::Exml::Runtime.new
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new
    exml_frame(ctx, doc.pages.first.children, rt, renderer)
    text_at = ctx.painter.commands.select(Egui::TextCmd)
      .map { |c| {c.text, c.pos.x} }.to_h
    # the pinned label starts at left=80, the flow one does not —
    # and the flow cursor never advanced past the pin
    text_at["pin"].should be >= 80.0
    text_at["flow"].should be < 80.0
  end

  it "<toggle> renders a switch and writes clicks back" do
    doc = Egui::Exml.parse(%(
      <page id="p"><toggle bind="on" on_change="flipped"/></page>
    ))
    rt = Egui::Exml::Runtime.new
    rt.bools["on"] = false
    fired = 0
    rt.actions["flipped"] = ->{ fired += 1; nil }
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new
    exml_frame(ctx, doc.pages.first.children, rt, renderer)
    # click the painted track (the first small capsule near the origin)
    track = ctx.painter.commands.select(Egui::RectCmd)
      .find { |c| c.rect.height < 30 && c.rect.width < 100 }.should_not be_nil
    pos = track.not_nil!.rect.center
    exml_frame(ctx, doc.pages.first.children, rt, renderer,
      events: [Egui::Event.pointer_pressed(pos)], time: 0.032)
    exml_frame(ctx, doc.pages.first.children, rt, renderer,
      events: [Egui::Event.pointer_released(pos)], time: 0.048)
    rt.bools["on"].should be_true
    fired.should eq(1)
  end

  it "central panel content scrolls by default (overflow → bar + wheel)" do
    rows = 40.times.map { |i| %(<label text="row #{i}"/>) }.join
    doc = Egui::Exml.parse(%(
      <exml><page id="root/root"><central>#{rows}</central></page></exml>
    ))
    rt = Egui::Exml::Runtime.new
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new
    screen = Egui::Rect.from_min_size(Egui::Pos2.zero,
      Egui::Vec2.new(300.0, 200.0))
    step = ->(events : Array(Egui::Event), t : Float64) do
      ctx.begin_frame(Egui::RawInput.new(screen, events, t))
      renderer.render_routes(ctx, doc, rt)
      ctx.end_frame
      ctx.painter.commands
    end

    # pointer inside the panel so its viewport owns the wheel
    step.call([Egui::Event.pointer_moved(Egui::Pos2.new(150.0, 100.0))] of Egui::Event, 0.016)
    step.call([] of Egui::Event, 0.032)
    # overflow: the ScrollArea paints its bar, "row 39" stays clipped
    bar_w = Egui::ScrollArea::BAR_W
    ctx.painter.commands.select(Egui::RectCmd)
      .any? { |cmd| cmd.rect.width == bar_w }.should be_true
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("row 0")
    texts.should_not contain("row 39")

    # wheel down → the later rows scroll into view
    scrolled = step.call([Egui::Event.scroll(Egui::Vec2.new(0.0, 400.0))] of Egui::Event, 0.048)
      .select(Egui::TextCmd).map(&.text)
    scrolled.should contain("row 39")
    scrolled.should_not contain("row 0")
  end

  it "hot-reloads when the file's mtime moves" do
    path = "/tmp/exml_spec_#{Process.pid}.exml"
    File.write(path, %(<page id="p"><label text="one"/></page>))
    begin
      doc = Egui::Exml::Document.load(path)
      doc.page("p").should_not be_nil
      doc.reload_if_changed.should be_false

      sleep 5.milliseconds
      File.write(path, %(<page id="p2"><label text="two"/></page>))
      doc.reload_if_changed.should be_true
      doc.page("p").should be_nil
      doc.page("p2").should_not be_nil
    ensure
      File.delete(path)
    end
  end

  it "dispatches custom elements to app-registered handlers" do
    doc = Egui::Exml.parse(%(
      <page id="p">
        <gauge bind="speed" caption="Speed"/>
        <hbox><label text="inside custom container"/></hbox>
      </page>
    ))
    gauge, hbox = doc.pages.first.children
    gauge.kind.custom?.should be_true
    gauge.name.should eq("gauge")

    seen = [] of String
    renderer = Egui::Exml::Renderer.new
    renderer.on("gauge") do |node, ui, ctx, rt, r|
      seen << "gauge:#{node.attrs["bind"]?}"
      ui.progress_bar(rt.floats[node.attrs["bind"]?]? || 0.0)
    end
    renderer.on("hbox") do |node, ui, ctx, rt, r|
      seen << "hbox"
      ui.horizontal { |h| r.render_each(node, h, ctx, rt) }
    end

    rt = Egui::Exml::Runtime.new
    rt.floats["speed"] = 0.7
    ctx = Egui::Context.new
    exml_frame(ctx, doc.pages.first.children, rt, renderer)

    seen.should eq(["gauge:speed", "hbox"])
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).should contain("inside custom container")
  end

  it "skips unregistered custom elements with a warn-once, no crash" do
    doc = Egui::Exml.parse(
      %(<page id="p"><mystery/><label text="survivor"/></page>)
    )
    mystery = doc.pages.first.children.first
    mystery.kind.custom?.should be_true

    rt = Egui::Exml::Runtime.new
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new
    exml_frame(ctx, doc.pages.first.children, rt, renderer)
    exml_frame(ctx, doc.pages.first.children, rt, renderer, time: 0.032)

    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).should contain("survivor")
  end

  # A global `widget`-registered element: no #on call on this
  # renderer — the dispatch must fall through to the global registry.
  it "widget registers a custom element every renderer sees" do
    doc = Egui::Exml.parse(
      %(<page id="p"><spec_gauge frac="g"/><label text="survivor"/></page>)
    )
    Egui::Exml.widgets["spec_gauge"]?.should_not be_nil

    rt = Egui::Exml::Runtime.new
    rt.floats["g"] = 0.5
    renderer = Egui::Exml::Renderer.new # no #on("spec_gauge")!
    ctx = Egui::Context.new
    exml_frame(ctx, doc.pages.first.children, rt, renderer)

    WIDGET_SEEN.should contain("global:g")
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).should contain("survivor")
  end

  it "Renderer#on overrides an widget of the same name" do
    doc = Egui::Exml.parse(%(<page id="p"><spec_gauge frac="g"/></page>))
    rt = Egui::Exml::Runtime.new
    renderer = Egui::Exml::Renderer.new
    renderer.on("spec_gauge") do |node, ui, ctx, r2, r|
      WIDGET_SEEN << "instance:#{node.attrs["frac"]?}"
    end
    ctx = Egui::Context.new
    before = WIDGET_SEEN.size
    exml_frame(ctx, doc.pages.first.children, rt, renderer)

    WIDGET_SEEN.size.should eq(before + 1)
    WIDGET_SEEN.last.should eq("instance:g")
  end

  # Custom vocabulary has priority over builtins: a handler for a
  # BUILT-IN name claims the element — no hyphen convention needed.
  it "custom handler overrides a built-in element" do
    doc = Egui::Exml.parse(
      %(<page id="p"><label text="shadowed"/><label text="kept"/></page>)
    )
    rt = Egui::Exml::Runtime.new
    renderer = Egui::Exml::Renderer.new
    renderer.on("label") do |node, ui, ctx, r2, r|
      ui.label("claimed:#{node.attrs["text"]?}")
    end
    ctx = Egui::Context.new
    exml_frame(ctx, doc.pages.first.children, rt, renderer)

    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("claimed:shadowed")
    texts.should contain("claimed:kept")
    texts.should_not contain("shadowed")
  end

  it "reports a missing file as an empty document, not a crash" do
    doc = Egui::Exml::Document.load("/nonexistent/no.exml")
    doc.pages.should be_empty
    doc.reload_if_changed.should be_false
  end

  # ── partials: parse-time composition ─────────────────────────────

  it "splices <use> at parse time and re-paths per use site" do
    doc = Egui::Exml.parse(%(
      <partial id="pair"><row><label text="a"/><label text="b"/></row></partial>
      <page id="p">
        <column>
          <use partial="pair" id="first"/>
          <use partial="pair" id="second"/>
        </column>
      </page>
    ))
    page = doc.page("p").should_not be_nil
    column = page.children.first
    # uses are gone — replaced by the spliced rows themselves
    column.children.size.should eq(2)
    column.children.all?(&.kind.row?).should be_true

    # each use spliced the row under ITS OWN path prefix
    paths = [] of String
    column.children.each do |row|
      row.children.each { |c| paths << c.path }
    end
    paths.size.should eq(4)
    paths.uniq.size.should eq(4) # independent widget ids per use site
    paths.first.should contain("/use[0]:first/")
    paths.last.should contain("/use[1]:second/")
  end

  it "expands nested partials" do
    doc = Egui::Exml.parse(%(
      <partial id="cell"><label text="cell"/></partial>
      <partial id="row"><row><use partial="cell"/><use partial="cell" id="c2"/></row></partial>
      <page id="p"><use partial="row"/></page>
    ))
    page = doc.page("p").should_not be_nil
    row = page.children.first
    row.kind.row?.should be_true
    row.children.size.should eq(2)
    row.children.all?(&.kind.label?).should be_true
  end

  it "drops a partial cycle with a warning, keeps the rest" do
    doc = Egui::Exml.parse(%(
      <partial id="a"><use partial="b"/></partial>
      <partial id="b"><use partial="a"/></partial>
      <partial id="ok"><label text="fine"/></partial>
      <page id="p"><use partial="a"/><use partial="ok"/></page>
    ))
    page = doc.page("p").should_not be_nil
    page.children.size.should eq(1)
    page.children.first.kind.label?.should be_true
  end

  it "drops a <use> referencing a missing partial" do
    doc = Egui::Exml.parse(
      %(<page id="p"><use partial="ghost"/><label text="survivor"/></page>)
    )
    page = doc.page("p").should_not be_nil
    page.children.size.should eq(1)
    page.children.first.kind.label?.should be_true
  end

  # ── validator: build-time vocabulary checks ──────────────────────

  it "flags unknown attributes, missing required ones, bad values" do
    doc = Egui::Exml.parse(%(
      <page id="p">
        <button txt="typo" on_click="go"/>
        <slider min="0"/>
        <textarea bind="t" rows="many" frame="yes"/>
      </page>
    ))
    issues = Egui::Exml.validate(doc)
    issues.join("\n").tap do |text|
      text.should contain(%(has no attribute "txt"))
      text.should contain(%(<button> requires "text"))
      text.should contain(%(<slider> requires "bind"))
      text.should contain(%(rows="many" is not an integer))
      text.should contain(%(frame="yes" must be true/false))
    end
  end

  it "flags unknown custom elements unless whitelisted" do
    doc = Egui::Exml.parse(%(<page id="p"><fps_meter/></page>))
    Egui::Exml.validate(doc).should_not be_empty
    Egui::Exml.validate(doc, known_custom: %w(fps_meter)).should be_empty
  end

  it "flags duplicate page ids" do
    doc = Egui::Exml.parse(
      %(<page id="p"/><page id="p"/>)
    )
    Egui::Exml.validate(doc).join.should contain("duplicate page id")
  end

  # The shipped markup must stay clean against the widget vocabulary —
  # this is the build-time gate: markup drift fails the suite, not the
  # running app. fps_meter/status_bar are the app's registered custom
  # elements (the components' class-derived names).
  it "assets/notepad.exml lints clean" do
    path = File.join(__DIR__, "..", "assets", "notepad.exml")
    doc = Egui::Exml::Document.load(path)
    doc.pages.size.should eq(3) # root/root, root/settings, root/confirm-close
    issues = Egui::Exml.validate(doc,
      known_custom: %w(fps_meter status_bar))
    issues.should be_empty, issues.join("\n")
  end

  # ── components: the Vue SFC shape, script half in Crystal ────────

  it "a component renders its template and its action mutates the store" do
    doc = Egui::Exml.parse(
      %(<page id="p"><vue_counter/></page>)
    )
    rt = Egui::Exml::Runtime.new
    renderer = Egui::Exml::Renderer.new
    renderer.component(VueCounter.new)
    VueCounter.new.element_name.should eq("vue_counter")

    ctx = Egui::Context.new
    exml_frame(ctx, doc.pages.first.children, rt, renderer)
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).should contain("You clicked me 0.00 times.")

    # click it: find the label's glyphs, press+release inside
    label = ctx.painter.commands.select(Egui::TextCmd)
      .find { |c| c.text.includes?("clicked me") }.should_not be_nil
    pos = Egui::Pos2.new(label.pos.x + 2, label.pos.y - label.size / 2)
    exml_frame(ctx, doc.pages.first.children, rt, renderer,
      events: [Egui::Event.pointer_pressed(pos)], time: 0.032)
    exml_frame(ctx, doc.pages.first.children, rt, renderer,
      events: [Egui::Event.pointer_released(pos)], time: 0.048)
    # the count lives in the component's LOCAL scope now — the global
    # store never sees it (checked below); the button text is the proof
    # the click fires during the release frame AFTER its text was laid
    # out — the NEXT frame shows the new count
    exml_frame(ctx, doc.pages.first.children, rt, renderer, time: 0.064)
    rt.floats["count"]?.should be_nil
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).should contain("You clicked me 1.00 times.")
  end

  it "the exml macro embeds the template and the element name follows the class" do
      comp = MacroFps.new
    comp.element_name.should eq("macro_fps")
    comp.template.should contain("{fps}") # loaded (or the embedded copy)
    comp.nodes.size.should eq(1)          # parsed: one label
    comp.nodes.first.kind.label?.should be_true
  end

  it "two use sites of one component keep independent widget ids" do
    doc = Egui::Exml.parse(
      %(<page id="p"><vue_counter id="a"/><vue_counter id="b"/></page>)
    )
    rt = Egui::Exml::Runtime.new
    renderer = Egui::Exml::Renderer.new
    renderer.component(VueCounter.new)
    ctx = Egui::Context.new
    2.times do |i|
      exml_frame(ctx, doc.pages.first.children, rt, renderer,
        time: 0.016 * (i + 1)) # no DuplicateWidgetIdError
    end
  end

  # ── local component state (ScopedRuntime) ─────────────────────────

  it "two use sites keep INDEPENDENT store state — click one, other stays" do
    doc = Egui::Exml.parse(
      %(<page id="p"><vue_counter id="a"/><vue_counter id="b"/></page>)
    )
    rt = Egui::Exml::Runtime.new
    renderer = Egui::Exml::Renderer.new
    renderer.component(VueCounter.new)
    ctx = Egui::Context.new
    exml_frame(ctx, doc.pages.first.children, rt, renderer)

    # click the FIRST counter's button (its label run)
    labels = ctx.painter.commands.select(Egui::TextCmd)
      .select { |c| c.text.includes?("clicked me 0.00") }
    labels.size.should eq(2)
    pos = Egui::Pos2.new(labels.first.pos.x + 2,
      labels.first.pos.y - labels.first.size / 2)
    exml_frame(ctx, doc.pages.first.children, rt, renderer,
      events: [Egui::Event.pointer_pressed(pos)], time: 0.032)
    exml_frame(ctx, doc.pages.first.children, rt, renderer,
      events: [Egui::Event.pointer_released(pos)], time: 0.048)
    exml_frame(ctx, doc.pages.first.children, rt, renderer, time: 0.064)

    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("You clicked me 1.00 times.") # the clicked one
    texts.should contain("You clicked me 0.00 times.") # the untouched one

    # the local write never leaked into the GLOBAL store
    rt.floats["count"]?.should be_nil
  end

end

# Reads app model slots through the parent fallback; fires a global
# action through the parent fallback.
class GlobalEcho < Egui::Exml::Component
  def template : String
    %(<button text="status: {status}" on_click="global_ping"/>)
  end
end

describe Egui::Exml do
  it "a component reads global slots and fires global actions (fallback)" do
    doc = Egui::Exml.parse(%(<page id="p"><global_echo/></page>))
    rt = Egui::Exml::Runtime.new
    rt.strings["status"] = "Ready."
    pinged = 0
    rt.actions["global_ping"] = ->{ pinged += 1; nil }
    renderer = Egui::Exml::Renderer.new
    renderer.component(GlobalEcho.new)

    ctx = Egui::Context.new
    exml_frame(ctx, doc.pages.first.children, rt, renderer)
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).should contain("status: Ready.")

    label = ctx.painter.commands.select(Egui::TextCmd)
      .find { |c| c.text.includes?("status:") }.should_not be_nil
    pos = Egui::Pos2.new(label.pos.x + 2, label.pos.y - label.size / 2)
    exml_frame(ctx, doc.pages.first.children, rt, renderer,
      events: [Egui::Event.pointer_pressed(pos)], time: 0.032)
    exml_frame(ctx, doc.pages.first.children, rt, renderer,
      events: [Egui::Event.pointer_released(pos)], time: 0.048)
    pinged.should eq(1)
  end

  # ── repeat (v-for) ────────────────────────────────────────────────

  it "renders one row per item with per-row interpolation" do
    doc = Egui::Exml.parse(%(
      <page id="p">
        <repeat for="doc" in="docs">
          <row><label text="{doc.name} — {doc.pages}p"/><label text="[{_i}]"/></row>
        </repeat>
      </page>
    ))
    rt = Egui::Exml::Runtime.new
    rt.rows["docs"] = [
      {"name" => "alpha", "pages" => "12"},
      {"name" => "beta", "pages" => "7"},
    ]
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new
    exml_frame(ctx, doc.pages.first.children, rt, renderer)

    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("alpha — 12p")
    texts.should contain("beta — 7p")
    texts.should contain("[0]")
    texts.should contain("[1]")
  end

  it "an action fired from a row writes _i to the root store" do
    doc = Egui::Exml.parse(%(
      <page id="p">
        <repeat for="item" in="docs">
          <row><button text="rm {item.name}" on_click="remove"/></row>
        </repeat>
      </page>
    ))
    rt = Egui::Exml::Runtime.new
    rt.rows["docs"] = [
      {"name" => "alpha"}, {"name" => "beta"}, {"name" => "gamma"},
    ]
    removed = [] of Int32
    rt.actions["remove"] = ->{ removed << rt.string("_i").to_i; nil }
    renderer = Egui::Exml::Renderer.new

    ctx = Egui::Context.new
    exml_frame(ctx, doc.pages.first.children, rt, renderer)
    # click the SECOND row's button
    label = ctx.painter.commands.select(Egui::TextCmd)
      .find { |c| c.text.includes?("rm beta") }.should_not be_nil
    pos = Egui::Pos2.new(label.pos.x + 2, label.pos.y - label.size / 2)
    exml_frame(ctx, doc.pages.first.children, rt, renderer,
      events: [Egui::Event.pointer_pressed(pos)], time: 0.032)
    exml_frame(ctx, doc.pages.first.children, rt, renderer,
      events: [Egui::Event.pointer_released(pos)], time: 0.048)
    removed.should eq([1])
  end

  it "key= keeps widget identities across a reorder" do
    doc = Egui::Exml.parse(%(
      <page id="p">
        <repeat for="doc" in="docs" key="name">
          <checkbox bind="picked" text="{doc.name}"/>
        </repeat>
      </page>
    ))
    rt = Egui::Exml::Runtime.new
    rt.rows["docs"] = [{"name" => "alpha"}, {"name" => "beta"}]
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new
    # render, reorder (alpha moves last), render again — no
    # DuplicateWidgetIdError, identities follow the names
    2.times { |i| exml_frame(ctx, doc.pages.first.children, rt, renderer, time: 0.016 * (i + 1)) }
    rt.rows["docs"] = [{"name" => "beta"}, {"name" => "alpha"}]
    2.times { |i| exml_frame(ctx, doc.pages.first.children, rt, renderer, time: 0.064 + 0.016 * i) }
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("alpha")
    texts.should contain("beta")
  end

  it "a missing list slot warns once and renders nothing" do
    doc = Egui::Exml.parse(%(
      <page id="p"><repeat in="ghost"><label text="x"/></repeat></page>
    ))
    rt = Egui::Exml::Runtime.new
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new
    3.times { |i| exml_frame(ctx, doc.pages.first.children, rt, renderer, time: 0.016 * (i + 1)) }
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).should_not contain("x")
  end

  # ── Vue directive aliases — render level ─────────────────────────
  # Parse-level desugar checks live in vue_aliases_spec.cr; these pin
  # the RENDER equivalence with the canonical spellings.

  it "v-for synthesizes the same repeat a handwritten markup parses into" do
    vue_doc = Egui::Exml.parse(%(
      <page id="p">
        <row v-for="doc in docs" :key="doc.name"><label text="{doc.name}"/></row>
      </page>
    ))
    canon_doc = Egui::Exml.parse(%(
      <page id="p">
        <repeat for="doc" in="docs" key="name">
          <row><label text="{doc.name}"/></row>
        </repeat>
      </page>
    ))
    Egui::Exml.warnings.should be_empty
    wrap = vue_doc.pages.first.children.first
    wrap.kind.repeat?.should be_true
    wrap.repeat_for.should eq("doc")
    wrap.repeat_in.should eq("docs")
    wrap.repeat_key.should eq("name")
    wrap.children.size.should eq(1)
    child = wrap.children.first
    child.kind.row?.should be_true
    child.attrs.has_key?("v-for").should be_false
    child.attrs.has_key?("key").should be_false
    child.children.first.attrs["text"].should eq("{doc.name}")

    # and renders the same pixels as the handwritten spelling
    rt = Egui::Exml::Runtime.new
    rt.rows["docs"] = [
      {"name" => "alpha"}, {"name" => "beta"},
    ]
    texts = [vue_doc, canon_doc].map do |d|
      ctx = Egui::Context.new
      exml_frame(ctx, d.pages.first.children, rt, Egui::Exml::Renderer.new)
      ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    end
    texts[0].should eq(texts[1])
    texts[0].should contain("alpha")
    texts[0].should contain("beta")
  end

  it "v-for's (item, i) exposes the index as {i} next to {_i}" do
    doc = Egui::Exml.parse(%(
      <page id="p">
        <label v-for="(doc, i) in docs" text="{doc.name} {i}/{_i}"/>
      </page>
    ))
    Egui::Exml.warnings.should be_empty
    wrap = doc.pages.first.children.first
    wrap.kind.repeat?.should be_true
    wrap.repeat_index_alias.should eq("i")

    rt = Egui::Exml::Runtime.new
    rt.rows["docs"] = [{"name" => "alpha"}, {"name" => "beta"}]
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new
    exml_frame(ctx, doc.pages.first.children, rt, renderer)
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("alpha 0/0")
    texts.should contain("beta 1/1")
  end

  # ── props, refs, markdown ─────────────────────────────────────────

  it "use-site attributes become component props" do
    doc = Egui::Exml.parse(
      %(<page id="p"><propped precision="2" plain="x" label="{status}"/></page>)
    )
    rt = Egui::Exml::Runtime.new
    rt.strings["status"] = "Ready"
    renderer = Egui::Exml::Renderer.new
    renderer.component(Propped.new)

    ctx = Egui::Context.new
    exml_frame(ctx, doc.pages.first.children, rt, renderer)
    # label interpolates against the ENCLOSING store, plain attrs pass
    # verbatim, structural attrs (id) never leak in as props
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).should contain("precision=2 label=Ready plain=x")
  end

  it "v-bind spreads a dict slot into props; explicit attrs win" do
    doc = Egui::Exml.parse(
      %(<page id="p"><propped v-bind="settings" label="explicit"/></page>)
    )
    rt = Egui::Exml::Runtime.new
    rt.dicts["settings"] = {"precision" => "3", "label" => "spread",
                            "plain" => "y"}
    renderer = Egui::Exml::Renderer.new
    renderer.component(Propped.new)

    ctx = Egui::Context.new
    exml_frame(ctx, doc.pages.first.children, rt, renderer)
    # spread fields seed the scope, the explicit label= overrides the
    # spread one (Vue 3 precedence), verbatim values (app-formatted)
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).should contain("precision=3 label=explicit plain=y")
  end

  it "the v-bind spread follows the parent store in a component scope" do
    doc = Egui::Exml.parse(
      %(<page id="p"><propped v-bind="settings"/></page>)
    )
    rt = Egui::Exml::Runtime.new
    rt.dicts["settings"] = {"precision" => "1", "plain" => "x"}
    renderer = Egui::Exml::Renderer.new
    renderer.component(Propped.new)

    ctx = Egui::Context.new
    exml_frame(ctx, doc.pages.first.children, rt, renderer)
    texts = ->{ ctx.painter.commands.select(Egui::TextCmd).map(&.text).join }
    texts.call.should contain("precision=1")
    texts.call.should contain("plain=x")

    # the app owns the dict — an in-place mutation shows next frame
    rt.dicts["settings"]["precision"] = "9"
    exml_frame(ctx, doc.pages.first.children, rt, renderer, time: 0.032)
    texts.call.should contain("precision=9")
  end

  it "a dynamic prop follows the enclosing store across frames" do
    doc = Egui::Exml.parse(
      %(<page id="p"><propped label="{status}"/></page>)
    )
    rt = Egui::Exml::Runtime.new
    rt.strings["status"] = "Ready"
    renderer = Egui::Exml::Renderer.new
    renderer.component(Propped.new)

    ctx = Egui::Context.new
    exml_frame(ctx, doc.pages.first.children, rt, renderer)
    # (the label wraps across painter lines — match on the join)
    texts = ->{ ctx.painter.commands.select(Egui::TextCmd).map(&.text).join }
    texts.call.should contain("label=Ready")

    # the store moves — the prop must follow (Vue semantics), not
    # stay frozen at its install-time value
    rt.strings["status"] = "Saving…"
    exml_frame(ctx, doc.pages.first.children, rt, renderer, time: 0.032)
    texts.call.should contain("label=Saving…")
  end

  it "id= registers a template ref the app reads after the frame" do
    doc = Egui::Exml.parse(
      %(<page id="p"><button id="go" text="Go" on_click="go"/></page>)
    )
    rt = Egui::Exml::Runtime.new
    fired = 0
    rt.actions["go"] = ->{ fired += 1; nil }
    renderer = Egui::Exml::Renderer.new

    ctx = Egui::Context.new
    exml_frame(ctx, doc.pages.first.children, rt, renderer)
    ref = renderer.ref("go").should_not be_nil
    ref.rect.width.should be > 0

    # click at the ref's own rect — the app side drives the interaction
    pos = Egui::Pos2.new(ref.rect.center.x, ref.rect.center.y)
    exml_frame(ctx, doc.pages.first.children, rt, renderer,
      events: [Egui::Event.pointer_pressed(pos)], time: 0.032)
    exml_frame(ctx, doc.pages.first.children, rt, renderer,
      events: [Egui::Event.pointer_released(pos)], time: 0.048)
    fired.should eq(1)

    # a widget off this frame leaves no stale ref
    doc2 = Egui::Exml.parse(
      %(<page id="p2"><button id="go" if="flag" text="Go"/></page>)
    )
    renderer2 = Egui::Exml::Renderer.new
    ctx2 = Egui::Context.new
    rt2 = Egui::Exml::Runtime.new
    rt2.bools["flag"] = false
    exml_frame(ctx2, doc2.pages.first.children, rt2, renderer2)
    renderer2.ref("go").should be_nil
  end

  it "renders markdown" do
    doc = Egui::Exml.parse(
      %(<page id="p"><markdown text="Hello **bold** world"/></page>)
    )
    rt = Egui::Exml::Runtime.new
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new
    exml_frame(ctx, doc.pages.first.children, rt, renderer)
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("Hello ")
    texts.should contain("bold")
    texts.should contain(" world")
  end
end

describe "exml flexbox" do
  it "renders <box flex> with justify and <flex-item> factors" do
    doc = Egui::Exml.parse(%(
      <page id="p">
        <box flex="true" justify="space-between" width="400">
          <flex-item order="1"><label text="right"/></flex-item>
          <flex-item order="0" grow="1"><label text="left"/></flex-item>
        </box>
      </page>
    ))
    Egui::Exml.validate(doc).should be_empty
    rt = Egui::Exml::Runtime.new
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new
    exml_frame(ctx, doc.pages.first.children, rt, renderer)
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("left")
    texts.should contain("right")
  end

  it "flags bad flex attrs" do
    doc = Egui::Exml.parse(%(
      <page id="p">
        <box flex="true" direction="sideways" gap="lots">
          <flex-item order="first"><label text="x"/></flex-item>
        </box>
      </page>
    ))
    issues = Egui::Exml.validate(doc)
    issues.any?(&.includes?("direction=")).should be_true
    issues.any?(&.includes?("gap=")).should be_true
    issues.any?(&.includes?("order=")).should be_true
  end
end

# ── Vue aliases, stage 2 render behavior (plans/vue-aliases2.md) ────

describe "exml markup hotkeys" do
  it "fires the action on the key press, no focus needed, and frees the key when hidden" do
    doc = Egui::Exml.parse(
      %(<page id="root/root"><input bind="q" v-if="on" @keyup.enter="save"/></page>)
    )
    rt = Egui::Exml::Runtime.new
    rt.bools["on"] = true
    fired = [] of String
    rt.actions["save"] = ->{ fired << "save" }
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new
    enter = ->{ Egui::Event.new(:key_pressed, key: Egui::KeyCode::Enter) }

    # render_routes is the frame entry — the markup-hotkey lifecycle
    # (bind while visible, lapse when not) hangs off it
    frame = ->(events : Array(Egui::Event)) {
      ctx.begin_frame(Egui::RawInput.new(EXML_SCREEN, events, 0.016))
      renderer.render_routes(ctx, doc, rt)
      ctx.end_frame
    }
    2.times do |i| # bind settles on frame 1, the key fires on frame 2
      frame.call(i == 1 ? [enter.call] of Egui::Event : [] of Egui::Event)
    end
    fired.should eq(["save"])

    # the node's if= goes false → the binding lapses, the key is free
    rt.bools["on"] = false
    frame.call([enter.call] of Egui::Event)
    frame.call([enter.call] of Egui::Event)
    fired.should eq(["save"])
    ctx.hotkeys.action_for(Egui::Hotkey.parse("enter")).should be_nil
  end
end

describe "exml numeric input (v-model.number)" do
  it "renders the float slot's value" do
    doc = Egui::Exml.parse(
      %(<page id="p"><input bind="age" numeric="true"/></page>)
    )
    Egui::Exml.validate(doc).should be_empty
    rt = Egui::Exml::Runtime.new
    rt.floats["age"] = 21.5
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new
    exml_frame(ctx, doc.pages.first.children, rt, renderer)
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("21.5")
  end
end

describe "exml #text nodes (bare text between tags)" do
  it "keeps non-whitespace text as a Label-kind child" do
    nodes = Egui::Exml.parse_fragment(
      "<p>hello <strong>bold</strong> world</p>")
    p = nodes.first
    p.name.should eq("p")
    p.children.map(&.name).should eq(["#text", "strong", "#text"])
    p.children[0].attrs["text"].should eq("hello ")
    p.children[2].attrs["text"].should eq(" world")
    p.children[0].kind.label?.should be_true
  end

  it "drops whitespace-only segments (pretty-printed markup)" do
    nodes = Egui::Exml.parse_fragment(
      "<column>\n  <label text=\"a\"/>\n  <label text=\"b\"/>\n</column>")
    nodes.first.children.map(&.name).should eq(["label", "label"])
  end

  it "unescapes entities in text content" do
    nodes = Egui::Exml.parse_fragment("<p>a &amp; b &lt;c&gt;</p>")
    nodes.first.children.first.attrs["text"].should eq("a & b <c>")
  end
end

# ── lint: store readers/writers (plans/velour-components.md, этап 0) ──
# Everything that used to fail silently: an unknown {name}, a binding
# nobody seeds (the «мёртвый тогл»), a quote that survived into an
# attribute value.

describe "exml lint: store readers/writers" do
  it "errors on a {name} placeholder that is not in scope" do
    doc = Egui::Exml.parse(
      %(<page id="p"><label text="{oops}"/></page>)
    )
    issues = Egui::Exml.validate(doc, written: %w(real))
    issues.join("\n").should contain("error:")
    issues.join("\n").should contain("{oops}")
  end

  it "warns on a bind= slot nobody writes (the dead-toggle shape)" do
    doc = Egui::Exml.parse(
      %(<page id="p"><checkbox bind="never_seeded" text="x"/></page>)
    )
    issues = Egui::Exml.validate(doc, written: %w(other))
    issues.join("\n").should contain("warning:")
    issues.join("\n").should contain("never_seeded")
  end

  it "accepts written slots and interpolated attrs" do
    doc = Egui::Exml.parse(
      %(<page id="p"><label text="wifi: {wifi}" if="shown"/> ) \
      %(<checkbox bind="wifi" text="w"/></page>)
    )
    Egui::Exml.validate(doc, written: %w(wifi shown)).should be_empty
  end

  it "accepts repeat variables and their fields in scope" do
    doc = Egui::Exml.parse(%(
      <page id="p">
        <repeat for="doc" in="docs" index="i">
          <label text="{doc.name} \#{i}/{_i}"/>
        </repeat>
      </page>
    ))
    Egui::Exml.validate(doc, written: %w(docs)).should be_empty
  end

  it "errors on a repeat in= rows slot nobody publishes" do
    doc = Egui::Exml.parse(%(
      <page id="p"><repeat in="ghost"><label text="x"/></repeat></page>
    ))
    issues = Egui::Exml.validate(doc, written: %w(real))
    issues.join("\n").should contain("ghost")
  end

  it "checks if=/unless= and :options= readers" do
    doc = Egui::Exml.parse(%(
      <page id="p">
        <label text="a" if="{flag}"/>
        <label text="b" unless="off"/>
        <combo bind="sel" options="{genres}"/>
      </page>
    ))
    issues = Egui::Exml.validate(doc, written: %w(sel))
    joined = issues.join("\n")
    joined.should contain("flag")
    joined.should contain("off")
    joined.should contain("genres")
  end

  it "checks declared slot attrs of custom tags" do
    Egui::Exml.slot_attr("spec-row", "switch")
    doc = Egui::Exml.parse(%(
      <page id="p"><spec-row title="r" switch="ghost_switch"/></page>
    ))
    issues = Egui::Exml.validate(doc, known_custom: %w(spec-row),
      written: %w(real))
    issues.join("\n").should contain("ghost_switch")
  end

  it "flags a quote that survived into a tag (parse time)" do
    # an unbalanced quote cuts the value short; the fragment with the
    # quotes lands in the tag's unconsumed tail — previously dropped
    # as junk SILENTLY
    Egui::Exml.warnings.clear
    Egui::Exml.parse(
      %(<page id="p"><label text="a "b" c"/></page>)
    )
    Egui::Exml.warnings.join("\n").should contain(
      "an unbalanced quote in an attribute value")
  end

  it "ios_settings.exml: zero errors, warnings only for unseeded switches" do
    Egui::Exml.slot_attr("ios-row", "switch")
    doc = Egui::Exml::Document.load("assets/ios_settings.exml")
    written = %w(tab page query wifi_value bt_value brightness appearance
                 text_size airplane wifi bt true_tone bold)
    issues = Egui::Exml.validate(doc,
      known_custom: %w(ios-screen ios-body ios-group ios-row ios-card
                       ios-search ios-segmented ios-slider),
      written: written)
    issues.each { |i| i.should contain("warning:") }
    # the dead toggles of the original session — exactly the switch=
    # slots the app never seeds
    joined = issues.join("\n")
    %w(wifi_notif notif_mail notif_msg imsg adblock).each do |slot|
      joined.should contain(slot)
    end
  end
end

# ── props with defaults + local state (velour-components.md, этап 1) ──

class PropComponent < Egui::Exml::Component
  prop title, default: "Без имени"
  prop badge

  state open, default: "0"

  def template : String
    %(<label text="{title}: {badge} open={open}"/>)
  end

  def setup(rt : Egui::Exml::Runtime) : Nil
    rt.actions["toggle"] = ->toggle
  end

  def toggle : Nil
    rt.not_nil!.strings["open"] = rt.not_nil!.strings["open"] == "1" ? "0" : "1"
  end
end

describe "exml component props/state (этап 1)" do
  it "seeds a declared prop's default when the use site omits it" do
    renderer = Egui::Exml::Renderer.new
    renderer.component(PropComponent.new)
    nodes = Egui::Exml.parse_fragment(%(<prop_component/>))
    rt = Egui::Exml::Runtime.new
    ctx = Egui::Context.new
    exml_frame(ctx, nodes, rt, renderer)
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.join.should contain("Без имени")
  end

  it "keeps explicit use-site props winning over defaults" do
    renderer = Egui::Exml::Renderer.new
    renderer.component(PropComponent.new)
    nodes = Egui::Exml.parse_fragment(
      %(<prop_component title="Свой" badge="3"/>))
    rt = Egui::Exml::Runtime.new
    ctx = Egui::Context.new
    exml_frame(ctx, nodes, rt, renderer)
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.join.should contain("Свой: 3")
  end

  it "seeds declared local state once at install, before setup" do
    renderer = Egui::Exml::Renderer.new
    renderer.component(PropComponent.new)
    nodes = Egui::Exml.parse_fragment(%(<prop_component title="a" badge="b"/>))
    rt = Egui::Exml::Runtime.new
    ctx = Egui::Context.new
    exml_frame(ctx, nodes, rt, renderer)
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.join.should contain("open=0")
    # the state lives in the site scope, not the global store
    rt.strings.has_key?("open").should be_false
  end

  it "two use sites keep independent local state" do
    renderer = Egui::Exml::Renderer.new
    comp = PropComponent.new
    renderer.component(comp)
    nodes = Egui::Exml.parse_fragment(%(
      <prop_component title="a" badge="1" on_click="noop"/>
    ))
    rt = Egui::Exml::Runtime.new
    ctx = Egui::Context.new
    exml_frame(ctx, nodes, rt, renderer)
    scope = comp.rt.not_nil!
    scope.strings["open"] = "1"
    # re-render: the second frame's seed_props must NOT clobber the
    # local write (the default is seeded only while absent)
    exml_frame(ctx, nodes, rt, renderer)
    comp.rt.not_nil!.strings["open"].should eq("1")
  end

  it "lints a use site missing a required prop" do
    doc = Egui::Exml.parse(%(
      <page id="p"><prop_component title="x"/></page>
    ))
    issues = Egui::Exml.validate(doc)
    issues.join("\n").should contain(%(requires prop "badge"))
  end

  it "lints the component template against its own declarations" do
    Egui::Exml.validate_component(PropComponent).should be_empty
  end
end

# ── the bind= contract (velour-components.md, этап 2) ─────────────────

class BoundComp < Egui::Exml::Component
  bindable :value, :bool

  def template : String
    %(<column><label text="v={value}"/><button text="flip" on_click="flip"/></column>)
  end

  def setup(rt : Egui::Exml::Runtime) : Nil
    rt.actions["flip"] = ->flip
  end

  def flip : Nil
    scope = rt.not_nil!
    scope.bools["value"] = !scope.bool("value")
  end
end

describe "exml bind= contract (этап 2)" do
  it "component: parent slot seeds the scope's bound prop" do
    renderer = Egui::Exml::Renderer.new
    renderer.component(BoundComp.new)
    nodes = Egui::Exml.parse_fragment(%(<bound_comp bind="on"/>))
    rt = Egui::Exml::Runtime.new
    rt.bools["on"] = true
    ctx = Egui::Context.new
    exml_frame(ctx, nodes, rt, renderer)
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.join.should contain("v=true")
  end

  it "component: a scope write flows back to the parent + fires on_change" do
    renderer = Egui::Exml::Renderer.new
    comp = BoundComp.new
    renderer.component(comp)
    nodes = Egui::Exml.parse_fragment(%(<bound_comp bind="on" on_change="child_flipped"/>))
    rt = Egui::Exml::Runtime.new
    fired = 0
    rt.actions["child_flipped"] = ->{ fired += 1 }
    ctx = Egui::Context.new
    exml_frame(ctx, nodes, rt, renderer)
    fired.should eq(0)
    # the component's action wrote the scope (the flip half)
    scope = comp.rt.not_nil!
    scope.bools["value"] = true
    exml_frame(ctx, nodes, rt, renderer)
    # …and the engine wrote the parent slot + fired on_change
    rt.bools["on"].should be_true
    fired.should eq(1)
  end

  it "component: an external parent write wins the frame (props down)" do
    renderer = Egui::Exml::Renderer.new
    comp = BoundComp.new
    renderer.component(comp)
    nodes = Egui::Exml.parse_fragment(%(<bound_comp bind="on"/>))
    rt = Egui::Exml::Runtime.new
    ctx = Egui::Context.new
    exml_frame(ctx, nodes, rt, renderer)
    comp.rt.not_nil!.bools["value"].should be_false
    # the app flips the parent slot directly
    rt.bools["on"] = true
    exml_frame(ctx, nodes, rt, renderer)
    comp.rt.not_nil!.bools["value"].should be_true
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.join.should contain("v=true")
  end

  it "handler tag: bind= seeds 'value', writes echo to the parent, on_change fires" do
    seen = {} of String => String
    widget :spec_bound do |node, ui, ctx, rt, r|
      seen["value"] = rt.bool("value").to_s
      rt.bools["value"] = true # the write-back half
      rt.strings["nav_target"] = "somewhere" # the nav= idiom still lands globally
    end
    doc = Egui::Exml.parse(
      %(<page id="root/root"><spec_bound bind="bound_slot" on_change="pushed"/></page>)
    )
    rt = Egui::Exml::Runtime.new
    fired = 0
    rt.actions["pushed"] = ->{ fired += 1 }
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new
    frame = ->{
      ctx.begin_frame(Egui::RawInput.new(EXML_SCREEN, [] of Egui::Event, 0.016))
      renderer.render_routes(ctx, doc, rt)
      ctx.end_frame
    }
    frame.call
    seen["value"].should eq("false")     # seeded from the (unset) parent slot
    rt.bools["bound_slot"].should be_true # echoed write-back
    rt.strings["nav_target"].should eq("somewhere")
    fired.should eq(1)                    # parent version moved → on_change
    frame.call
    fired.should eq(1)                    # same value again → no change, no fire
  end

  it "component tags skip the generic BoundRuntime wrap" do
    # a component with a bindable must not double-wrap: its rt stays a
    # plain (scoped) runtime, not BoundRuntime
    renderer = Egui::Exml::Renderer.new
    comp = BoundComp.new
    renderer.component(comp)
    nodes = Egui::Exml.parse_fragment(%(<bound_comp bind="on"/>))
    rt = Egui::Exml::Runtime.new
    ctx = Egui::Context.new
    exml_frame(ctx, nodes, rt, renderer)
    comp.rt.not_nil!.should_not be_nil
    comp.rt.not_nil!.is_a?(Egui::Exml::BoundRuntime).should be_false
  end
end

# ── auto-repaint on store writes (velour-components.md, этап 3) ───────

describe "exml auto-repaint (этап 3)" do
  it "a store write during the walk schedules the next frame without manual request_repaint" do
    doc = Egui::Exml.parse(
      %(<page id="root/root"><button text="go" on_click="nav"/><label text="x"/></page>)
    )
    rt = Egui::Exml::Runtime.new
    rt.actions["nav"] = ->{ rt.strings["page"] = "sub" } # a handler write
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new
    frame = ->(events : Array(Egui::Event)) {
      ctx.begin_frame(Egui::RawInput.new(EXML_SCREEN, events, 0.016))
      renderer.render_routes(ctx, doc, rt)
      ctx.end_frame
    }
    # a click fires the action → the write happens mid-frame
    click = ->{ Egui::Event.new(:pointer_button_pressed,
      pos: Egui::Pos2.new(10.0, 10.0)) }
    frame.call([click.call] of Egui::Event)
    ctx.needs_repaint?.should be_true # the dirty write bought a frame
  end

  it "steady state creates no repaint loop (same value → no version bump)" do
    doc = Egui::Exml.parse(
      %(<page id="root/root"><label text="{wifi_value}"/></page>)
    )
    rt = Egui::Exml::Runtime.new
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new
    frame = ->{
      # the ios_settings idiom: the app publishes the SAME derived
      # string every frame, BEFORE the walk — must not loop
      rt.strings["wifi_value"] = "home-5G"
      ctx.begin_frame(Egui::RawInput.new(EXML_SCREEN, [] of Egui::Event, 0.016))
      renderer.render_routes(ctx, doc, rt)
      ctx.end_frame
    }
    frame.call
    ctx.needs_repaint?.should be_false # pre-frame write, not the walk's
    frame.call
    ctx.needs_repaint?.should be_false # same value → no version bump → no loop
  end
end

# ── computed slots (velour-components.md, этап 4) ──────────────────────

describe "exml computed slots (этап 4)" do
  it "derives a slot from its tracked read-set, lazily invalidated" do
    doc = Egui::Exml.parse(
      %(<page id="p"><label text="{wifi_label}"/></page>)
    )
    rt = Egui::Exml::Runtime.new
    rt.bools["wifi_on"] = true
    rt.strings["wifi_name"] = "home-5G"
    rt.computed "wifi_label" do |s|
      s["wifi_on"] == "true" ? s["wifi_name"].to_s : "Not connected"
    end
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new
    exml_frame(ctx, doc.pages.first.children, rt, renderer)
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("home-5G")

    # write to a dependency → the next read recomputes, no manual push
    rt.bools["wifi_on"] = false
    exml_frame(ctx, doc.pages.first.children, rt, renderer)
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("Not connected")
  end

  it "tracks only the branches actually read (conditional deps)" do
    rt = Egui::Exml::Runtime.new
    rt.bools["on"] = true
    rt.strings["a"] = "A"
    rt.strings["b"] = "B"
    rt.computed "c" do |s|
      s["on"] == "true" ? s["a"].to_s : s["b"].to_s
    end
    rt.lookup("c").should eq("A")
    # b is not a dependency of the current read-set — changing it
    # does not invalidate the cached computation
    rt.strings["b"] = "B2"
    rt.lookup("c").should eq("A")
    rt.bools["on"] = false
    rt.lookup("c").should eq("B2") # recompute reads the NEW b
  end

  it "guards against self-reading computeds (stale value, no loop)" do
    rt = Egui::Exml::Runtime.new
    rt.strings["x"] = "base"
    rt.computed "loop_slot" do |s|
      (s["loop_slot"] || "") + s["x"].to_s
    end
    rt.lookup("loop_slot").should eq("base") # no hang, stale self read
  end

  it "computed names are visible for the lint's writer knowledge" do
    rt = Egui::Exml::Runtime.new
    rt.computed "wifi_label" do |s|
      s["wifi_on"] == "true" ? s["wifi_name"].to_s : "off"
    end
    rt.computed_names.should eq(%w(wifi_label))
  end
end

# ── named slots + scoped classes (velour-components.md, этап 5) ───────

class Slotted < Egui::Exml::Component
  prop title, default: "Компонент"

  def template : String
    %(
      <column>
        <label text="{title}"/>
        <slot/>
        <slot name="footer"/>
      </column>
    )
  end
end

describe "exml named slots (этап 5)" do
  it "splices use-site children into <slot> markers" do
    renderer = Egui::Exml::Renderer.new
    renderer.component(Slotted.new)
    nodes = Egui::Exml.parse_fragment(%(
      <slotted>
        <label text="тело" slot="footer"/>
        <label text="по умолчанию"/>
      </slotted>
    ))
    rt = Egui::Exml::Runtime.new
    ctx = Egui::Context.new
    exml_frame(ctx, nodes, rt, renderer)
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("Компонент")
    texts.should contain("по умолчанию")
    texts.should contain("тело")
  end

  it "an empty slot marker renders nothing (Vue semantics)" do
    renderer = Egui::Exml::Renderer.new
    renderer.component(Slotted.new)
    nodes = Egui::Exml.parse_fragment(%(<slotted/>))
    rt = Egui::Exml::Runtime.new
    ctx = Egui::Context.new
    exml_frame(ctx, nodes, rt, renderer)
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("Компонент") # the template chrome is there
    texts.compact_map { |t| t == "w" ? nil : t }.size.should eq(1) # …and only it
  end

  it "spliced children interpolate against the COMPONENT scope" do
    renderer = Egui::Exml::Renderer.new
    renderer.component(Slotted.new)
    nodes = Egui::Exml.parse_fragment(%(
      <slotted title="Заголовок">
        <label text="в скоупе: {title}"/>
      </slotted>
    ))
    rt = Egui::Exml::Runtime.new
    ctx = Egui::Context.new
    exml_frame(ctx, nodes, rt, renderer)
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("в скоупе: Заголовок")
  end
end

class ScopedCls < Egui::Exml::Component
  def template : String
    %(<column class="card"><label text="x" class="title"/></column>)
  end
end

class ScopedDyn < Egui::Exml::Component
  def template : String
    %(<column class="card {variant}"><label text="x"/></column>)
  end
end

class ScopedOff < Egui::Exml::Component
  def template : String
    %(<column class="card" scoped="false"><label text="x"/></column>)
  end
end

describe "exml scoped template classes (этап 5)" do
  it "prefixes literal class tokens with the element name" do
    nodes = ScopedCls.new.nodes
    nodes.first.attrs["class"].should eq("scoped_cls__card")
    label = nodes.first.children.first
    label.attrs["class"].should eq("scoped_cls__title")
  end

  it "leaves store-driven class tokens (app-side names) unprefixed" do
    nodes = ScopedDyn.new.nodes
    nodes.first.attrs["class"].should eq("scoped_dyn__card {variant}")
  end

  it "scoped=false on the template root opts out" do
    nodes = ScopedOff.new.nodes
    nodes.first.attrs["class"].should eq("card")
    nodes.first.attrs.has_key?("scoped").should be_false
  end
end
