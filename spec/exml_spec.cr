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
