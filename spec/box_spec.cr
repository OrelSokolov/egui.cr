# `ui.box` / `<box>` — THE generic container: column/row flow over the
# shared core (#scope/#horizontal/#frame semantics), optional chrome.
require "spec"
require "../src/egui"

BOX_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(800.0, 600.0))

def box_frame(&app : Egui::Ui ->) : Nil
  ctx = Egui::Context.new
  ctx.begin_frame(Egui::RawInput.new(BOX_SCREEN, [] of Egui::Event, 0.016))
  ctx.window("w") { |ui| yield ui }
  ctx.end_frame
end

describe "ui.box" do
  it ":column stacks children vertically like scope" do
    rects = [] of Egui::Rect
    box_frame do |ui|
      ui.box(:column) do |b|
        rects << b.label("one").rect
        rects << b.label("two").rect
      end
    end
    rects[1].min.y.should be > rects[0].min.y
    rects[1].min.x.should eq(rects[0].min.x)
  end

  it ":row lays children out side by side like horizontal" do
    rects = [] of Egui::Rect
    box_frame do |ui|
      ui.box(:row) do |b|
        rects << b.label("one").rect
        rects << b.label("two").rect
      end
    end
    rects[1].min.x.should be > rects[0].max.x
  end

  it "without chrome adds no padding (a plain div)" do
    content_min = nil
    outer = nil
    box_frame do |ui|
      outer = ui.box(:column) do |b|
        b.label("x")
        content_min = b.min_rect.min
      end
    end
    # zero margin: the outer rect's top-left IS the content's top-left
    outer.not_nil!.min.should eq(content_min.not_nil!)
  end

  it "with chrome surrounds the content by the margin" do
    content = nil
    outer = nil
    box_frame do |ui|
      outer = ui.box(:column, fill: Egui::Color32.rgb(0, 0, 0),
        margin: Egui::Vec2.new(10.0, 10.0)) do |b|
        b.label("x")
        content = b.min_rect
      end
    end
    o = outer.not_nil!
    c = content.not_nil!
    (c.min.y - o.min.y).should be_close(10.0, 0.5)
    (o.max.y - c.max.y).should be_close(10.0, 0.5)
  end

  it "style_class runs children under a style scope" do
    scope = nil
    box_frame do |ui|
      ui.box(:column, style_class: "card") do |b|
        scope = b.style_scope
        b.label("x")
      end
    end
    scope.should eq("card")
  end
end

describe "exml <box>" do
  it "parses direction/wrap/border/fill/padding/rounding/class" do
    doc = Egui::Exml.parse(%(
      <page id="p">
        <box id="b" direction="row" wrap="false" border="#ff0000"
             fill="#222" padding="8" rounding="3" class="card">
          <label text="a"/>
        </box>
      </page>))
    node = doc.pages[0].children[0]
    node.kind.box?.should be_true
    node.box_row.should be_true
    node.box_wrap.should be_false
    node.box_stroke.should eq(Egui::Color32.new(255, 0, 0, 255))
    node.box_fill.should eq(Egui::Color32.new(0x22, 0x22, 0x22, 255))
    node.box_padding.should eq(8.0)
    node.box_rounding.should eq(3.0)
    node.box_class.should eq("card")
    node.container?.should be_true
  end

  it "defaults to a wrapping column with no chrome" do
    doc = Egui::Exml.parse(%(
      <page id="p"><box><label text="a"/></box></page>))
    node = doc.pages[0].children[0]
    node.box_row.should be_false
    node.box_wrap.should be_true
    node.box_fill.should be_nil
    node.box_stroke.should be_nil
    node.box_padding.should be_nil
  end

  it "renders children (row: side by side)" do
    doc = Egui::Exml.parse(%(
      <page id="p">
        <box direction="row">
          <label id="a" text="a"/><label id="b" text="b"/>
        </box>
      </page>))
    rt = Egui::Exml::Runtime.new
    renderer = Egui::Exml::Renderer.new
    ctx = Egui::Context.new
    ctx.begin_frame(Egui::RawInput.new(BOX_SCREEN, [] of Egui::Event, 0.016))
    ctx.window("w") do |ui|
      doc.pages[0].children.each { |n| renderer.render(n, ui, ctx, rt) }
    end
    ctx.end_frame
    a = renderer.ref("a").not_nil!.rect
    b = renderer.ref("b").not_nil!.rect
    b.min.x.should be > a.max.x
  end

  it "lints bad attribute values" do
    doc = Egui::Exml.parse(%(
      <page id="p">
        <box direction="sideways" wrap="maybe" fill="red"
             padding="lots" rounding="none"><label text="a"/></box>
      </page>))
    issues = Egui::Exml.validate(doc)
    issues.join("\n").should contain "direction"
    issues.join("\n").should contain "wrap"
    issues.join("\n").should contain "fill"
    issues.join("\n").should contain "padding"
    issues.join("\n").should contain "rounding"
  end
end
