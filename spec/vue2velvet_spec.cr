# vue2velvet specs: the port tool's 1:1 half — a Vue SFC's
# template+style halves converted to .exml/.ecss, with the report
# (slots/rows/actions) the Crystal Component half is written from.
# The Vue directive aliases the output leans on are covered by
# spec/vue_aliases_spec.cr.

require "spec"
require "../src/egui/vue2velvet"

FIXTURE = File.read("#{__DIR__}/dataset/hello_card.vue")

describe "vue2velvet template conversion" do
  result = Egui::Vue2Velvet.convert(FIXTURE, "hello_card")

  it "maps HTML elements onto the exml vocabulary" do
    result.exml.should contain(%(<box class="card.settings">))
    result.exml.should contain(%(<button @click="save" text="Save"/>))
  end

  it "rewrites {{ x }} interpolations to {x} and lifts text into text=" do
    result.exml.should contain(%(<heading text="{title}"/>))
    result.exml.should contain(%(<label v-if="subtitle" class="muted" text="{subtitle}"/>))
    result.exml.should contain(%(<label text="{item.name}"/>))
  end

  it "chains class=\"a b\" to the dotted ECSS class path" do
    result.exml.should contain(%(class="card.settings"))
  end

  it "lifts <option> rows into options= on a <combo>" do
    combo = result.nodes[0].children.find(&.kind.combo?).should_not be_nil
  end

  it "keeps Vue directive spellings verbatim (exml desugars them)" do
    result.exml.should contain(%(v-for="(item, i) in items"))
    result.exml.should contain(%(:key="item.id"))
    result.exml.should contain(%(v-model="filter"))
  end

  it "output parses: v-for → repeat wrapper with key and index alias" do
    result.nodes.size.should eq(1) # one root box
    box = result.nodes[0]
    box.kind.should eq(Egui::Exml::Kind::Box)

    ul = box.children.find { |c| c.name == "ul" }.should_not be_nil
    wrap = ul.not_nil!.children[0]
    wrap.kind.should eq(Egui::Exml::Kind::Repeat)
    wrap.repeat_for.should eq("item")
    wrap.repeat_in.should eq("items")
    wrap.repeat_key.should eq("id")
    wrap.repeat_index_alias.should eq("i")

    row = wrap.children[0]
    row.name.should eq("li")
    row.children.size.should eq(2) # the two <span>s → labels
  end

  it "combo options survive the desugar (bind + options)" do
    combo = result.nodes[0].children.find { |c| c.kind.combo? }.should_not be_nil
    c = combo.not_nil!.as(Egui::Exml::Node)
    c.bind_key.should eq("filter")
    c.combo_options.should eq(%w[All Active Done])
  end

  it "collects no parse warnings from the clean fixture" do
    Egui::Exml.warnings.should be_empty
  end
end

describe "vue2velvet report" do
  it "names unmapped HTML and the port checklist" do
    result = Egui::Vue2Velvet.convert(FIXTURE, "hello_card")
    result.ok?.should be_true
    result.report.join("\n").should contain("unmapped HTML")
    result.report.join("\n").should contain("ul")
    result.report.join("\n").should contain("slots to publish")
    result.report.join("\n").should contain("filter")
    result.report.join("\n").should contain("lists to publish (rt.rows): items")
    result.report.join("\n").should contain("actions to register (rt.actions): save")
    # row fields and index aliases are rt.rows territory, not slots
    result.report.join("\n").should_not contain("item.name")
  end

  it "says the script half is never translated" do
    src = "<template><p>hi</p></template>\n<script>\nexport default {}\n</script>\n"
    result = Egui::Vue2Velvet.convert(src, "x")
    result.report.join("\n").should contain("script: skipped")
    result.report.join("\n").should contain("class X < Egui::Exml::Component")
  end

  it "notes scoped styles and passes CSS through verbatim" do
    result = Egui::Vue2Velvet.convert(FIXTURE, "hello_card")
    result.ecss.not_nil!.should contain(".card { background: #ffffff; }")
    result.report.join("\n").should contain("scoped ignored")
  end

  it "fails loudly (report) without a template block" do
    result = Egui::Vue2Velvet.convert("<script>export default {}</script>", "x")
    result.ok?.should be_false
  end
end
