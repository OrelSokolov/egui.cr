# exml codegen Route A (plans/NativeHTML.md §6): the emitter produces
# the literal Node tree of the parser's output — kind/name/attrs/
# children/path only, every flattened field re-derives in
# `Node#initialize`, so generated literals cannot drift from the
# parser. The equality spec pins that: emitting a hand-built tree
# with the same five constructor arguments must produce EXACTLY the
# emitter's output for the parsed document (the generated code calls
# the very same constructor).

require "spec"
require "../src/egui"

MARKUP = <<-XML
  <exml>
    <partial id="row">
      <row><label text="in partial"/></row>
    </partial>
    <page id="home" title="Home">
      <column>
        <heading>Hi</heading>
        <button label="Save" on_click="save"/>
        <box direction="row" fill="#ff0000" rounding="8">
          <input bind="name" hint="your name"/>
          <combo options="One, Two" bind="pick"/>
        </box>
      </column>
    </page>
  </exml>
XML

describe "exml codegen" do
  it "emits the literal Node tree the parser builds" do
    doc = Egui::Exml.parse(MARKUP)
    src = Egui::Exml.emit_crystal(doc, source: "app.exml")

    src.should contain("module EguiGen")
    src.should contain("Egui::Exml::Kind::Page")
    src.should contain("Egui::Exml::Kind::Button")
    src.should contain(%q{"on_click" => "save"})
    src.should contain(%q{"fill" => "#ff0000"})
    # the partial lands in the partials hash, not the pages
    src.should contain(%q{"row" =>})
    # special characters round-trip through inspect
    escaped = Egui::Exml.parse(
      %(<page id="p" title="quo&quot;te &amp; back\\slash"/>))
    Egui::Exml.emit_crystal(escaped).should contain(
      %q{"title" => "quo\"te & back\\slash"})
  end

  it "parser output and hand-built literals agree (the no-drift proof)" do
    parsed = Egui::Exml.parse(MARKUP)

    # Paths are the parser's indexed form (verified against real
    # parser output) — the index is the SIBLING position: heading[0],
    # button[1], box[2] under the column; input[0]/combo[1] in the box.
    btn = Egui::Exml::Node.new(Egui::Exml::Kind::Button, "button",
      {"label" => "Save", "on_click" => "save"}, [] of Egui::Exml::Node,
      "/exml[0]/page[1]:home/column[0]/button[1]")
    heading = Egui::Exml::Node.new(Egui::Exml::Kind::Heading, "heading",
      {} of String => String, [] of Egui::Exml::Node,
      "/exml[0]/page[1]:home/column[0]/heading[0]")
    input = Egui::Exml::Node.new(Egui::Exml::Kind::Input, "input",
      {"bind" => "name", "hint" => "your name"}, [] of Egui::Exml::Node,
      "/exml[0]/page[1]:home/column[0]/box[2]/input[0]")
    combo = Egui::Exml::Node.new(Egui::Exml::Kind::Combo, "combo",
      {"options" => "One, Two", "bind" => "pick"}, [] of Egui::Exml::Node,
      "/exml[0]/page[1]:home/column[0]/box[2]/combo[1]")
    box = Egui::Exml::Node.new(Egui::Exml::Kind::Box, "box",
      {"direction" => "row", "fill" => "#ff0000", "rounding" => "8"},
      [input, combo], "/exml[0]/page[1]:home/column[0]/box[2]")
    column = Egui::Exml::Node.new(Egui::Exml::Kind::Column, "column",
      {} of String => String, [heading, btn, box],
      "/exml[0]/page[1]:home/column[0]")
    page = Egui::Exml::Node.new(Egui::Exml::Kind::Page, "page",
      {"id" => "home", "title" => "Home"}, [column],
      "/exml[0]/page[1]:home")
    p_label = Egui::Exml::Node.new(Egui::Exml::Kind::Label, "label",
      {"text" => "in partial"}, [] of Egui::Exml::Node,
      "/exml[0]/partial[0]:row/row[0]/label[0]")
    p_row = Egui::Exml::Node.new(Egui::Exml::Kind::Row, "row",
      {} of String => String, [p_label],
      "/exml[0]/partial[0]:row/row[0]")
    partial = Egui::Exml::Node.new(Egui::Exml::Kind::Partial, "partial",
      {"id" => "row"}, [p_row], "/exml[0]/partial[0]:row")
    manual = Egui::Exml::Document.new([page], {"row" => partial})

    Egui::Exml.emit_crystal(manual, source: "app.exml")
      .should eq(Egui::Exml.emit_crystal(parsed, source: "app.exml"))
  end

  it "Document.hybrid picks file, then generated literals, then empty" do
    with_tempfile = File.join(Dir.tempdir,
      "egui_exml_gen_#{Random.rand(1_000_000)}.exml")
    File.write(with_tempfile, MARKUP)

    # 1. the live file wins (dev/hot-reload).
    doc = Egui::Exml::Document.hybrid(with_tempfile)
    doc.pages.size.should eq(1)

    # 2. no file → the generated block (release).
    generated = Egui::Exml::Document.hybrid("/nonexistent/no.exml",
      ->{ Egui::Exml::Document.new([] of Egui::Exml::Node) })
    generated.pages.size.should eq(0)

    # 3. neither → empty document (the missing file is reported).
    Egui::Exml::Document.hybrid("/nonexistent/no.exml").pages
      .should be_empty
  ensure
    with_tempfile.try { |p| File.delete(p) if File.exists?(p) }
  end
end
