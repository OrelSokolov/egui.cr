# <openfile>/<savefile> specs: parse/lint, the three button-text
# states, the path label and its `visible: false` style key (plus the
# same key on a plain class-carrying element) — headless, real widgets.

require "spec"
require "../src/egui"

EXML_FILE_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(800.0, 600.0))

def exml_file_frame(ctx : Egui::Context, nodes : Array(Egui::Exml::Node),
                    rt : Egui::Exml::Runtime,
                    renderer : Egui::Exml::Renderer) : Nil
  ctx.begin_frame(Egui::RawInput.new(EXML_FILE_SCREEN,
    [] of Egui::Event, 0.016))
  ctx.window("w") do |ui|
    nodes.each { |n| renderer.render(n, ui, ctx, rt) }
  end
  ctx.end_frame
end

def exml_file_texts(ctx : Egui::Context) : Array(String)
  ctx.painter.commands.select(Egui::TextCmd).map(&.text)
end

describe Egui::Exml do
  it "parses <openfile>/<savefile> attrs and lints clean" do
    doc = Egui::Exml.parse(%(
      <page id="p">
        <openfile bind="src" text="Открыть…" text_choosing="Выбор…"
                  text_done="Готово" filters="*.png|*.jpg"
                  title="Pick" label_class="path"/>
        <savefile bind="dst" default_name="report.txt"/>
      </page>
    ))
    kids = doc.pages.first.children
    kids[0].kind.open_file?.should be_true
    kids[1].kind.save_file?.should be_true
    kids[0].file_filters.should eq(%w(*.png *.jpg))
    kids[1].file_filters.should be_empty
    kids[0].file_label_class.should eq("path")
    kids[1].file_default_name.should eq("report.txt")
    Egui::Exml.validate(doc).should be_empty
  end

  it "walks the button text through idle → chosen → choosing" do
    doc = Egui::Exml.parse(%(
      <page id="p">
        <openfile bind="src" text="Открыть…" text_choosing="Выбор…"
                  text_done="Открыть другой…"/>
      </page>
    ))
    nodes = doc.pages.first.children
    rt = Egui::Exml::Runtime.new
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new

    exml_file_frame(ctx, nodes, rt, renderer)
    exml_file_texts(ctx).should contain("Открыть…")

    # a chosen path switches to the done text
    rt.strings["src"] = "/tmp/photo.png"
    exml_file_frame(ctx, nodes, rt, renderer)
    exml_file_texts(ctx).should contain("Открыть другой…")

    # the choosing flag (set by the click, cleared by the callback)
    # wins while the dialog is up
    rt.bools["src/choosing"] = true
    exml_file_frame(ctx, nodes, rt, renderer)
    exml_file_texts(ctx).should contain("Выбор…")

    # cancel: flag cleared, old value keeps the done state
    rt.bools["src/choosing"] = false
    exml_file_frame(ctx, nodes, rt, renderer)
    exml_file_texts(ctx).should contain("Открыть другой…")
  end

  it "shows the path label only when a path is chosen" do
    doc = Egui::Exml.parse(%(
      <page id="p"><openfile bind="src" text="Open…"/></page>
    ))
    nodes = doc.pages.first.children
    rt = Egui::Exml::Runtime.new
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new

    exml_file_frame(ctx, nodes, rt, renderer)
    exml_file_texts(ctx).should_not contain("/tmp/a.png")

    rt.strings["src"] = "/tmp/a.png"
    exml_file_frame(ctx, nodes, rt, renderer)
    exml_file_texts(ctx).should contain("/tmp/a.png")
  end

  it "turns the path label off with the visible style key" do
    doc = Egui::Exml.parse(%(
      <page id="p">
        <openfile bind="src" text="Open…" label_class="path"/>
        <openfile bind="dst" text="Open2…"/>
      </page>
    ))
    nodes = doc.pages.first.children
    rt = Egui::Exml::Runtime.new
    rt.strings["src"] = "/tmp/a.png"
    rt.strings["dst"] = "/tmp/b.png"
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new

    # only the custom class is hidden — the default file-label stays
    ctx.stylesheet.rule("path", Egui::StyleVars{"visible" => false})
    exml_file_frame(ctx, nodes, rt, renderer)
    texts = exml_file_texts(ctx)
    texts.should_not contain("/tmp/a.png")
    texts.should contain("/tmp/b.png")

    # the default class hides the other one too
    ctx.stylesheet.rule("file-label", Egui::StyleVars{"visible" => false})
    exml_file_frame(ctx, nodes, rt, renderer)
    exml_file_texts(ctx).should_not contain("/tmp/b.png")
  end

  it "parses the multiple attr on <openfile> only where it belongs" do
    doc = Egui::Exml.parse(%(
      <page id="p">
        <openfile bind="src" multiple/>
        <openfile bind="one"/>
        <savefile bind="dst"/>
      </page>
    ))
    kids = doc.pages.first.children
    kids[0].file_multiple?.should be_true
    kids[1].file_multiple?.should be_false
    kids[2].file_multiple?.should be_false
    Egui::Exml.validate(doc).should be_empty
  end

  it "labels a multiple pick as first path (+N)" do
    doc = Egui::Exml.parse(%(
      <page id="p"><openfile bind="src" multiple text="Add…"/></page>
    ))
    nodes = doc.pages.first.children
    rt = Egui::Exml::Runtime.new
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new

    # the joined wire format in the bound slot; the label compresses
    # it to the first path plus a count
    rt.strings["src"] = "/tmp/a.png\n/tmp/b.png\n/tmp/c.png"
    exml_file_frame(ctx, nodes, rt, renderer)
    texts = exml_file_texts(ctx)
    texts.should contain("/tmp/a.png (+2)")
    texts.should_not contain("/tmp/a.png\n/tmp/b.png\n/tmp/c.png")

    # a single pick shows the plain path
    rt.strings["src"] = "/tmp/a.png"
    exml_file_frame(ctx, nodes, rt, renderer)
    exml_file_texts(ctx).should contain("/tmp/a.png")
  end

  it "understands visible: false on any class-carrying element" do
    doc = Egui::Exml.parse(%(
      <page id="p">
        <box class="hideme"><label text="secret"/></box>
        <box class="shown"><label text="visible"/></box>
      </page>
    ))
    nodes = doc.pages.first.children
    rt = Egui::Exml::Runtime.new
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new
    ctx.stylesheet.rule("hideme", Egui::StyleVars{"visible" => false})

    exml_file_frame(ctx, nodes, rt, renderer)
    texts = exml_file_texts(ctx)
    texts.should_not contain("secret")
    texts.should contain("visible")
  end
end
