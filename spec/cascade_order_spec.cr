# The cascade CONTRACT (plans/NativeHTML.md §4.2): one layer order
# for EVERY style key — inline `#style` → per-element override (`id`)
# → class rules (states included) → theme. The order must not depend
# on the key: `background` and `stroke` resolve identically (inline
# beats `:hover`, CSS `style="…"` semantics). Everything is headless —
# a probe widget reads the protected resolvers directly.

require "spec"
require "../src/egui"

CASCADE_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(400.0, 300.0))

def cascade_frame(ctx : Egui::Context, &app : Egui::Context ->)
  raw = Egui::RawInput.new(CASCADE_SCREEN, [] of Egui::Event, 0.016)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

# A minimal button-like widget exposing the two resolvers for probing.
class CascadeProbe
  include Egui::Widget
  property fill : Egui::Color32?
  property stroke : Egui::Color32?

  def style_class : String?
    "button"
  end

  def call(ui : Egui::Ui, id : Egui::Id, state : String?) : Nil
    @fill = background_color(ui, id, state, state == "hover", false)
    @stroke = cascade_color("stroke", ui, id, state,
      ui.ctx.style.visuals.button_stroke)
  end

  def effective(ui : Egui::Ui, id : Egui::Id, class_vars : Egui::StyleVars) : Egui::Style
    effective_style(ui, id, class_vars)
  end

  def ui(ui : Egui::Ui) : Egui::Response
    raise "probe is not drawable"
  end
end

describe "cascade layer order" do
  it "is the same for every key: inline beats class :hover (CSS style=\"…\")" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("button:hover", Egui::StyleVars{
      "background" => Egui::Color32.rgb(1, 1, 1),
      "stroke"     => Egui::Color32.rgb(2, 2, 2),
    })
    inline_bg = Egui::Color32.rgb(10, 10, 10)
    inline_stroke = Egui::Color32.rgb(20, 20, 20)
    probe = CascadeProbe.new
    probe.style do |s|
      s.background = inline_bg
      s.stroke = inline_stroke
    end

    cascade_frame(ctx) do |c|
      c.central_panel do |ui|
        probe.call(ui, Egui::Id.from("p"), "hover")
      end
    end
    probe.fill.should eq(inline_bg)
    probe.stroke.should eq(inline_stroke)
  end

  it "puts the per-element override (id) above class rules, states included" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("button", Egui::StyleVars{
      "background" => Egui::Color32.rgb(1, 1, 1),
    })
    ctx.stylesheet.rule("button:hover", Egui::StyleVars{
      "background" => Egui::Color32.rgb(2, 2, 2),
    })
    id_bg = Egui::Color32.rgb(30, 30, 30)
    ctx.set_id_style(Egui::Id.from("p"), "background", id_bg)
    probe = CascadeProbe.new

    cascade_frame(ctx) do |c|
      c.central_panel do |ui|
        probe.call(ui, Egui::Id.from("p"), nil)
      end
    end
    probe.fill.should eq(id_bg)

    # …at hover too: the element layer outranks the class :hover rule.
    cascade_frame(ctx) do |c|
      c.central_panel do |ui|
        probe.call(ui, Egui::Id.from("p"), "hover")
      end
    end
    probe.fill.should eq(id_bg)
  end

  it "puts inline above the per-element override" do
    ctx = Egui::Context.new
    ctx.set_id_style(Egui::Id.from("p"), "background",
      Egui::Color32.rgb(30, 30, 30))
    inline_bg = Egui::Color32.rgb(40, 40, 40)
    probe = CascadeProbe.new
    probe.style { |s| s.background = inline_bg }

    cascade_frame(ctx) do |c|
      c.central_panel do |ui|
        probe.call(ui, Egui::Id.from("p"), nil)
      end
    end
    probe.fill.should eq(inline_bg)
  end

  it "falls back to the theme slot when no layer styles the key" do
    ctx = Egui::Context.new
    probe = CascadeProbe.new

    cascade_frame(ctx) do |c|
      c.central_panel do |ui|
        probe.call(ui, Egui::Id.from("p"), nil)
      end
    end
    probe.fill.should eq(ctx.style.visuals.button_fill(false, false))
    probe.stroke.should eq(ctx.style.visuals.button_stroke)
  end

  it "effective_style stacks theme → class → id → inline for Style slots" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("button", Egui::StyleVars{
      "text_color" => Egui::Color32.rgb(1, 1, 1),
    })
    ctx.set_id_style(Egui::Id.from("p"), "text_color",
      Egui::Color32.rgb(2, 2, 2))
    inline = Egui::Color32.rgb(3, 3, 3)
    probe = CascadeProbe.new
    probe.style { |s| s.text_color = inline }

    style = nil
    cascade_frame(ctx) do |c|
      c.central_panel do |ui|
        style = probe.effective(ui, Egui::Id.from("p"),
          ctx.stylesheet.resolve("button"))
      end
    end
    style.not_nil!.visuals.text_color.should eq(inline)
  end

  it "WidgetStyle#merge_over and StyleVars#apply_over are one merge" do
    base = Egui::Context.new.style
    ws = Egui::WidgetStyle.new
    ws.text_color = Egui::Color32.rgb(1, 2, 3)
    ws.stroke = Egui::Color32.rgb(4, 5, 6)
    ws.font_size = 15.0
    ws.font_family = "Inter"
    bag = Egui::StyleVars{
      "text_color"  => Egui::Color32.rgb(1, 2, 3),
      "stroke"      => Egui::Color32.rgb(4, 5, 6),
      "font_size"   => 15.0,
      "font_family" => "Inter",
    }
    a = ws.merge_over(base)
    b = bag.apply_over(base)
    a.visuals.text_color.should eq(b.visuals.text_color)
    a.visuals.button_stroke.should eq(b.visuals.button_stroke)
    a.font_size.should eq(b.font_size)
    a.font_family.should eq(b.font_family)
    # and the base is never mutated
    base.visuals.text_color.should_not eq(Egui::Color32.rgb(1, 2, 3))
  end

  it "cancel_rule drops a media rule instead of re-declaring it" do
    sheet = Egui::StyleSheet.new
    sheet.rule("button", Egui::StyleVars{"padding.top" => 4.0})
    sheet.rule("button", Egui::StyleVars{"padding.top" => 14.0},
      media: "(max-width: 600px)")
    sheet.viewport_width = 400.0 # inside the media band
    sheet.resolve("button").f64("padding.top", 0.0).should eq(14.0)

    sheet.cancel_rule("button", media: "(max-width: 600px)")
    sheet.resolve("button").f64("padding.top", 0.0).should eq(4.0)

    # …and without `media` every declaration of the selector goes.
    sheet.cancel_rule("button")
    sheet.resolve("button").f64?("padding.top").should be_nil
  end

  it "Ecss::Doc and StyleSheet share the one selector splitter" do
    Egui::Ecss::Doc.split_selector("button:hover")
      .should eq(Egui::StyleSheet.split_selector("button:hover"))
    Egui::StyleSheet.split_selector("sidebar.tab")
      .should eq({"sidebar.tab", nil})
  end
end
