# Vue directive aliases (plans/vue-aliases.md, stage 2 in
# plans/vue-aliases2.md): the Vue WRITING of directives desugars to
# canonical attrs/nodes at parse time. These are parse-level checks —
# rendering of the canonical forms (repeat, bind, on_click) is
# covered by exml_spec's canonical-document specs.

require "spec"
require "../src/egui"

def vue_nodes(markup : String) : Array(Egui::Exml::Node)
  Egui::Exml.parse_fragment(markup)
end

describe "vue attribute aliases" do
  it "renames v-if/v-show → if= (memory survives, like display:none)" do
    n = vue_nodes(%(<column v-if="ready"/><column v-show="draft"/>))
    n[0].if_cond.should eq("ready")
    n[1].if_cond.should eq("draft")
    Egui::Exml.warnings.should be_empty
  end

  it "renames v-model → bind=, v-text → text={name}" do
    n = vue_nodes(%(<input v-model="name"/><label v-text="caption"/>))
    n[0].bind_key.should eq("name")
    n[1].text_attr.should eq("{caption}")
    Egui::Exml.warnings.should be_empty
  end

  it "renames @click / v-on:change → on_click= / on_change=" do
    n = vue_nodes(
      %(<button text="Go" @click="save"/><combo bind="x" options="a,b" v-on:change="apply"/>))
    n[0].on_click.should eq("save")
    n[1].on_change.should eq("apply")
    Egui::Exml.warnings.should be_empty
  end

  it "renames :title / v-bind:title → title={name}" do
    n = vue_nodes(%(<box :title="tip"/><box v-bind:title="hint"/>))
    n[0].attrs["title"].should eq("{tip}")
    n[1].attrs["title"].should eq("{hint}")
    Egui::Exml.warnings.should be_empty
  end

  it "keeps a literal :x= value but points at the plain spelling" do
    n = vue_nodes(%(<box :padding="5"/>))
    n[0].attrs["padding"].should eq("5")
    Egui::Exml.warnings.any?(&.includes?("write padding=\"5\"")).should be_true
  end

  it "warns on JS expression values (no expression engine, by design)" do
    n = vue_nodes(%(<column v-if="count > 0"/>))
    n[0].attrs.has_key?("if").should be_true
    Egui::Exml.warnings.any?(&.includes?("expressions are not supported"))
      .should be_true
  end

  it "drops out-of-subset directives with a warning" do
    n = vue_nodes(%(<label text="x" v-html="raw"/>))
    n[0].attrs.has_key?("v-html").should be_false
    Egui::Exml.warnings.any?(&.includes?("not in the Vue subset")).should be_true
  end
end

describe "vue v-for synthesis" do
  it "wraps the node in a <repeat> taking its path" do
    nodes = vue_nodes(%(<column><row v-for="doc in docs" :key="doc.name">) +
                      %(<label text="{doc.title}"/></row></column>))
    wrap = nodes[0].children[0]
    wrap.kind.should eq(Egui::Exml::Kind::Repeat)
    wrap.repeat_for.should eq("doc")
    wrap.repeat_in.should eq("docs")
    wrap.repeat_key.should eq("name")
    wrap.path.should eq("/column[0]/row[0]") # the wrapper owns the path
    wrap.children.size.should eq(1)
    wrap.children[0].kind.should eq(Egui::Exml::Kind::Row)
    wrap.children[0].attrs.has_key?("v-for").should be_false
  end

  it "exposes the (item, i) index alias as index= on the wrapper" do
    nodes = vue_nodes(%(<column><row v-for="(item, i) in items"/></column>))
    wrap = nodes[0].children[0]
    wrap.repeat_for.should eq("item")
    wrap.repeat_in.should eq("items")
    wrap.repeat_index_alias.should eq("i")
  end

  it "warns on a malformed v-for value and keeps the bare element" do
    nodes = vue_nodes(%(<column><row v-for="item of items"/></column>))
    row = nodes[0].children[0]
    row.kind.should eq(Egui::Exml::Kind::Row)
    Egui::Exml.warnings.any?(&.includes?("v-for=")).should be_true
  end
end

describe "vue v-else mirror" do
  it "inverts the previous sibling's condition" do
    nodes = vue_nodes(
      %(<column><label text="a" if="on"/><label text="b" v-else/></column>))
    nodes[0].children[0].if_cond.should eq("on")
    nodes[0].children[1].unless_cond.should eq("on")
  end

  it "warns without a conditional sibling" do
    nodes = vue_nodes(%(<column><label text="b" v-else/></column>))
    Egui::Exml.warnings.any?(&.includes?("v-else without")).should be_true
  end
end

describe "canonical documents skip the desugar" do
  it "parses without warnings and unchanged" do
    nodes = vue_nodes(
      %(<column><repeat for="doc" in="docs" key="id">) +
      %(<label text="{doc.title}" if="seen"/></repeat></column>))
    Egui::Exml.warnings.should be_empty
    wrap = nodes[0].children[0]
    wrap.kind.should eq(Egui::Exml::Kind::Repeat)
    wrap.repeat_key.should eq("id")
  end
end

# ── stage 2 (plans/vue-aliases2.md) ─────────────────────────────────

describe "vue ref alias" do
  it "renames ref= → id= (the template-ref registry) keeping the path tag" do
    n = vue_nodes(%(<button text="Go" ref="go"/>))
    n[0].ref_name.should eq("go")
    n[0].path.should eq("/button[0]:go")
    Egui::Exml.warnings.should be_empty
  end

  it "keeps a real id= when both are present (warned)" do
    n = vue_nodes(%(<button text="Go" id="real" ref="alias"/>))
    n[0].ref_name.should eq("real")
    Egui::Exml.warnings.any?(&.includes?("ref dropped")).should be_true
  end
end

describe "vue <template> group" do
  it "splices children into the parent, the group if= copied onto each" do
    nodes = vue_nodes(
      %(<column><template v-if="ready">) +
      %(<label text="a"/><button text="b"/></template></column>))
    col = nodes[0]
    col.children.size.should eq(2) # the template itself is gone
    col.children.each do |c|
      c.if_cond.should eq("ready")
      c.path.should start_with("/column[0]/template[0]/") # parse paths kept
    end
    Egui::Exml.warnings.should be_empty
  end

  it "keeps a child's own gate with a warning (AND is an expression)" do
    nodes = vue_nodes(
      %(<column><template v-if="ready"><label text="a" if="own"/>) +
      %(</template></column>))
    nodes[0].children[0].if_cond.should eq("own")
    Egui::Exml.warnings.any?(&.includes?("child's own if= wins")).should be_true
  end

  it "mirrors v-else on a template onto the group's children" do
    nodes = vue_nodes(
      %(<column><label text="a" if="on"/><template v-else>) +
      %(<label text="b"/></template></column>))
    nodes[0].children[1].unless_cond.should eq("on")
  end

  it "splices a bare template (grouping wrapper, no gate)" do
    nodes = vue_nodes(%(<column><template><label text="a"/></template></column>))
    nodes[0].children.size.should eq(1)
    nodes[0].children[0].kind.should eq(Egui::Exml::Kind::Label)
    Egui::Exml.warnings.should be_empty
  end
end

describe "vue <template v-for> over several children" do
  it "synthesizes one repeat wrapping ALL the group's children" do
    nodes = vue_nodes(
      %(<column><template v-for="doc in docs" :key="doc.id">) +
      %(<label text="{doc.title}"/><button text="del" on_click="rm"/>) +
      %(</template></column>))
    wrap = nodes[0].children[0]
    wrap.kind.should eq(Egui::Exml::Kind::Repeat)
    wrap.repeat_for.should eq("doc")
    wrap.repeat_in.should eq("docs")
    wrap.repeat_key.should eq("id")
    wrap.children.size.should eq(2)
    wrap.children.map(&.kind).should eq(
      [Egui::Exml::Kind::Label, Egui::Exml::Kind::Button])
    wrap.children[0].path.should eq( # children keep their parse paths
      "/column[0]/template[0]/label[0]")
    Egui::Exml.warnings.should be_empty
  end
end

describe "vue v-model modifiers" do
  it "v-model.number binds the float slot (numeric=true)" do
    n = vue_nodes(%(<input v-model.number="age"/>))
    n[0].bind_key.should eq("age")
    n[0].numeric.should be_true
    Egui::Exml.warnings.should be_empty
  end

  it "v-model.trim strips the write-back; both modifiers combine" do
    n = vue_nodes(%(<input v-model.trim="name"/><input v-model.number.trim="x"/>))
    n[0].trim.should be_true
    n[1].numeric.should be_true
    n[1].trim.should be_true
    Egui::Exml.warnings.should be_empty
  end

  it "rejects .lazy with a warning (on_change is already event-shaped)" do
    n = vue_nodes(%(<input v-model.lazy="q"/>))
    n[0].bind_key.should eq("q") # the bind survives, the modifier drops
    Egui::Exml.warnings.any?(&.includes?(".lazy")).should be_true
  end
end

describe "vue key-event modifiers" do
  it "@keyup.enter → hotkey= + on_keyup= (a key NAME, not an expression)" do
    n = vue_nodes(%(<input bind="q" @keyup.enter="save"/>))
    n[0].hotkey_attr.should eq("enter")
    n[0].on_key_event.should eq("save")
    Egui::Exml.warnings.should be_empty
  end

  it "joins several modifiers into one Hotkey spelling" do
    n = vue_nodes(%(<input bind="q" @keydown.ctrl.enter="save"/>))
    n[0].hotkey_attr.should eq("ctrl+enter")
    n[0].on_key_event.should eq("save")
    Egui::Exml.warnings.should be_empty
  end

  it "keeps warning on non-key event modifiers (.stop and friends)" do
    n = vue_nodes(%(<button text="Go" @click.stop="save"/>))
    n[0].on_click.should eq("save")
    n[0].attrs.has_key?("hotkey").should be_false
    Egui::Exml.warnings.any?(&.includes?("event modifiers")).should be_true
  end

  it "falls back to the bare event for an unknown key modifier" do
    n = vue_nodes(%(<input bind="q" @keyup.pause="save"/>))
    n[0].on_key_event.should eq("save")
    n[0].attrs.has_key?("hotkey").should be_false
    Egui::Exml.warnings.any?(&.includes?("event modifiers")).should be_true
  end
end
