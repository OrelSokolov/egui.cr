# The style-scope cascade: `Ui#with_style_scope` chains a widget's
# base `style_class` with a scoped path ("button" + "sidebar.button"),
# `Widget#part` names the scope segment, and `StyleSheet#resolve_chain`
# merges the paths least-specific-first. Everything is headless — plain
# Context + Ui, rules and RectCmds prove the chain end to end.

require "spec"
require "../src/egui"

SCOPE_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(400.0, 300.0))

def scope_frame(ctx : Egui::Context, &app : Egui::Context ->)
  raw = Egui::RawInput.new(SCOPE_SCREEN, [] of Egui::Event, 0.016)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

describe "style scope cascade" do
  it "resolve_chain: scoped path beats the base class per key, state beats class" do
    sheet = Egui::StyleSheet.new
    sheet.rule("button", Egui::StyleVars{
      "background" => Egui::Color32.rgb(1, 1, 1),
      "padding"    => 4.0,
    })
    sheet.rule("sidebar.button", Egui::StyleVars{
      "background" => Egui::Color32.rgb(2, 2, 2),
    })
    merged = sheet.resolve_chain(["button", "sidebar.button"])
    merged.color("background", Egui::Color32.rgb(0, 0, 0))
      .should eq Egui::Color32.rgb(2, 2, 2) # scoped wins
    merged.f64("padding", 0.0).should eq 4.0 # base key survives

    # State overlay of ANY chain layer applies (the base :hover rule
    # reaches a scoped button too).
    sheet.rule("button:hover", Egui::StyleVars{
      "background" => Egui::Color32.rgb(3, 3, 3),
    })
    sheet.resolve_chain(["button", "sidebar.button"], "hover")
      .color("background", Egui::Color32.rgb(0, 0, 0))
      .should eq Egui::Color32.rgb(3, 3, 3)
  end

  it "resolve_chain is cached until a rule changes" do
    sheet = Egui::StyleSheet.new
    sheet.rule("button", Egui::StyleVars{"padding" => 4.0})
    a = sheet.resolve_chain(["button", "sidebar.button"])
    b = sheet.resolve_chain(["button", "sidebar.button"])
    b.should be(a) # same shared object
    sheet.rule("sidebar.button", Egui::StyleVars{"padding" => 8.0})
    c = sheet.resolve_chain(["button", "sidebar.button"])
    c.should_not be(a)
    c.f64("padding", 0.0).should eq 8.0
  end

  it "a widget inside with_style_scope reads scoped rules with zero per-widget wiring" do
    ctx = Egui::Context.new
    lime = Egui::Color32.rgb(0, 255, 100)
    ctx.stylesheet.rule("panel.button", Egui::StyleVars{
      "background" => lime,
      "padding"    => 20.0,
    })

    scope_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.with_style_scope("panel") do |scoped|
          scoped.add(Egui::Button.new("OK"))
        end
        # outside the scope the rule does not apply
        ui.add(Egui::Button.new("Outside"))
      end
    end

    rects = ctx.painter.commands.select(Egui::RectCmd)
      .select { |r| r.fill == lime }
    rects.size.should eq(1) # only the scoped button
  end

  it "part() names the scope segment explicitly" do
    ctx = Egui::Context.new
    cyan = Egui::Color32.rgb(0, 255, 255)
    ctx.stylesheet.rule("sidebar.close", Egui::StyleVars{
      "background" => cyan,
    })
    ctx.inspector_enabled = true

    scope_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.with_style_scope("sidebar") do |scoped|
          scoped.add(Egui::Button.new("✕").part("close").with_id("x1"))
        end
      end
    end

    rects = ctx.painter.commands.select(Egui::RectCmd)
      .select { |r| r.fill == cyan }
    rects.size.should eq(1)
    # the meta records the chain head, so the inspector edits the
    # scoped class
    m = ctx.inspector.meta_values.find(&.id_name.==("x1")).not_nil!
    m.display_class.should eq("sidebar.close")
    m.style_classes.should eq(["button", "sidebar.close"])
  end

  it "child Ui inherits the scope; the Context mirror follows push/pop" do
    ctx = Egui::Context.new
    seen = nil
    scope_frame(ctx) do |c|
      c.central_panel do |ui|
        ui.style_scope.should be_nil
        ctx.current_style_scope.should be_nil
        ui.with_style_scope("a") do |s1|
          s1.style_scope.should eq("a")
          ctx.current_style_scope.should eq("a")
          s1.with_style_scope("b") do |s2|
            s2.style_scope.should eq("a.b")
            ctx.current_style_scope.should eq("a.b")
            child = s2.child_ui(Egui::Rect.from_min_size(
              Egui::Pos2.zero, Egui::Vec2.new(10.0, 10.0)))
            child.style_scope.should eq("a.b")
            seen = child.style_scope
          end
          s1.style_scope.should eq("a")
          ctx.current_style_scope.should eq("a")
        end
        ui.style_scope.should be_nil
        ctx.current_style_scope.should be_nil
      end
    end
    seen.should eq("a.b")
  end

  it "StyledPart: bare name chains onto the scope, dotted path stays explicit" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("mybox.row", Egui::StyleVars{
      "text_color" => Egui::Color32.rgb(9, 9, 9),
    })
    bare = Egui::StyledPart.new("Row", "row", [] of Egui::StyleProp)
    dotted = Egui::StyledPart.new("Row", "mybox.row", [] of Egui::StyleProp)

    ctx.current_style_scope = "mybox"
    vars = bare.vars(ctx, Egui::Id.from("t"))
    vars.color?("text_color").should eq Egui::Color32.rgb(9, 9, 9)
    bare.style_classes(ctx).should eq(["mybox.row"])
    # dotted is already a full path — unchanged
    dotted.vars(ctx, Egui::Id.from("t2"))
      .color?("text_color").should eq Egui::Color32.rgb(9, 9, 9)
    dotted.style_classes(ctx).should eq(["mybox.row"])
    # without a scope the bare name resolves as-is
    ctx.current_style_scope = nil
    bare.vars(ctx, Egui::Id.from("t3")).color?("text_color").should be_nil
  end

  it "back-compat: a sidebar tab part resolves exactly sidebar.tab rules" do
    ctx = Egui::Context.new
    orange = Egui::Color32.rgb(255, 140, 0)
    ctx.stylesheet.rule("sidebar.tab:selected", Egui::StyleVars{
      "background" => orange,
    })
    part = Egui::Sidebar::TabPart.new("A")
    ctx.current_style_scope = "sidebar"
    part.vars(ctx, Egui::Id.from("row"), "selected")
      .color?("background").should eq orange
    ctx.current_style_scope = nil
  end
end
