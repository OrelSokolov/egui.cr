# menu.popup class specs: the popup FRAME behind dropdown and context
# menus reads ecss rules (background, stroke + stroke_width, rounding,
# shadow.*) with the Visuals frame as the per-key fallback, while
# non-menu popups (combo boxes) keep the plain Visuals frame.

require "spec"
require "../src/egui"

MPS_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 300.0))

def mps_frame(ctx : Egui::Context, events : Array(Egui::Event),
              time : Float64, &block : Egui::Ui ->)
  ctx.begin_frame(Egui::RawInput.new(MPS_SCREEN, events, time))
  ctx.central_panel { |ui| block.call(ui) }
  ctx.end_frame
end

describe "menu.popup frame styling" do
  it "styles the context-menu frame and paints the shadow under it" do
    ctx = Egui::Context.new
    red = Egui::Color32.rgb(255, 0, 0)
    blue = Egui::Color32.rgb(0, 0, 255)
    shadow_c = Egui::Color32.rgba(0, 0, 0, 80)
    ctx.stylesheet.rule("menu.popup", Egui::StyleVars{
      "background"   => red,
      "stroke"       => blue,
      "stroke_width" => 2.0,
      "rounding"     => 10.0,
      "shadow.color" => shadow_c,
      "shadow.blur"  => 12.0,
    })

    menu = Egui::ContextMenu.new.item("Alpha") { }
    btn_id = [Egui::Id.from("x")]
    draw = ->(events : Array(Egui::Event), time : Float64) do
      mps_frame(ctx, events, time) do |ui|
        r = ui.button("target").context_menu(menu)
        btn_id[0] = r.id
      end
    end

    draw.call([] of Egui::Event, 0.016) # widget rects registered
    pos = Egui::Pos2.new(30.0, 20.0)
    draw.call([Egui::Event.pointer_pressed(pos, :secondary)], 0.032)

    outer = ctx.memory.popup_rects[Egui::Id.from("popup/context_menu_#{btn_id[0].value}")].not_nil!
    frame = ctx.painter.commands.select(Egui::RectCmd)
      .find { |c| c.rect == outer }.not_nil!
    frame.fill.should eq(red)
    frame.stroke_color.should eq(blue)
    frame.stroke_width.should eq(2.0)
    frame.rounding.should eq(10.0)

    # The box-shadow rides UNDER the frame (CSS paint order) over the
    # same rect, unclipped by the frame itself.
    shadow = ctx.painter.commands.select(Egui::ShadowCmd)
      .find { |c| c.rect == outer && c.color == shadow_c }.not_nil!
    shadow.blur.should eq(12.0)
    shadow.rounding.should eq(10.0)
    cmds = ctx.painter.commands_in_layer_order
    cmds.index(shadow).not_nil!.should be < cmds.index(frame).not_nil!
  end

  it "stroke_width 0 drops the border entirely" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("menu.popup", Egui::StyleVars{
      "background"   => Egui::Color32.rgb(0, 255, 0),
      "stroke_width" => 0.0,
    })

    menu = Egui::ContextMenu.new.item("Alpha") { }
    draw = ->(events : Array(Egui::Event), time : Float64) do
      mps_frame(ctx, events, time) { |ui| ui.button("target").context_menu(menu) }
    end
    draw.call([] of Egui::Event, 0.016)
    pos = Egui::Pos2.new(30.0, 20.0)
    draw.call([Egui::Event.pointer_pressed(pos, :secondary)], 0.032)

    ctx.painter.commands.select(Egui::RectCmd)
      .find { |c| c.fill == Egui::Color32.rgb(0, 255, 0) }
      .not_nil!.stroke_color.should be_nil
  end

  it "leaves non-menu popups (combo box) on the Visuals frame" do
    ctx = Egui::Context.new
    ctx.stylesheet.rule("menu.popup", Egui::StyleVars{
      "background" => Egui::Color32.rgb(255, 0, 0),
    })
    value = "b"
    draw = ->(events : Array(Egui::Event), time : Float64) do
      ctx.begin_frame(Egui::RawInput.new(MPS_SCREEN, events, time))
      ui = Egui::Ui.new(ctx, Egui::Id.from("spec"), MPS_SCREEN)
      ui.combo_box("cb", value, %w[a b c]) { |picked| value = picked }
      ctx.end_frame
    end

    3.times { |i| draw.call([] of Egui::Event, 0.016 * (i + 1)) }
    btn = ctx.memory.scroll_rects.each_value.first.rect.center
    draw.call([Egui::Event.pointer_moved(btn),
      Egui::Event.pointer_pressed(btn)], 0.064)
    draw.call([Egui::Event.pointer_released(btn)], 0.080)
    ctx.popup_open?("cb").should be_true

    outer = ctx.memory.popup_rects[Egui::Id.from("popup/cb")].not_nil!
    frame = ctx.painter.commands.select(Egui::RectCmd)
      .find { |c| c.rect == outer }.not_nil!
    frame.fill.should eq(ctx.style.visuals.window_fill)
    frame.rounding.should eq(4.0)
  end
end
