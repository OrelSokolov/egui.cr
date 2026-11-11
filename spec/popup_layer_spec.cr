# Popup layering specs: a popup borrows the painter, so it must return
# the caller's layer/clip on exit — content painted AFTER the popup in
# the same host (a wizard footer inside an embedded window) must stay
# on the host's layer, not drop under its fill. And the open list's
# selected row keeps its selection band under the pointer.

require "spec"
require "../src/egui"

PL_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 400.0))

def pl_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
             time : Float64 = 0.016, &)
  ctx.begin_frame(Egui::RawInput.new(PL_SCREEN, events, time))
  yield ctx
  ctx.end_frame
end

# The host under test: a floating window whose content paints a combo
# followed by a label — the label is the layering canary.
def pl_host(ctx : Egui::Context, value : String) : Nil
  ctx.embedded_window("w", title: "T", width: 300.0) do |ui|
    v = value
    ui.combo_box("cb", v, %w[a b c]) { |picked| value = picked }
    ui.label("after")
  end
end

describe "popup layering" do
  it "keeps content painted after the popup on the host's layer" do
    ctx = Egui::Context.new
    value = "b"
    3.times { |i| pl_frame(ctx, time: 0.016 * (i + 1)) { |c| pl_host(c, value) } }

    # Open the combo list by clicking its button (the only scroll sink).
    btn = ctx.memory.scroll_rects.each_value.first.rect.center
    pl_frame(ctx, [Egui::Event.pointer_moved(btn),
      Egui::Event.pointer_pressed(btn)], 0.064) { |c| pl_host(c, value) }
    pl_frame(ctx, [Egui::Event.pointer_released(btn)], 0.080) { |c| pl_host(c, value) }
    ctx.popup_open?("cb").should be_true

    cmds = ctx.painter.commands_in_layer_order
    after = cmds.find { |c| c.is_a?(Egui::TextCmd) && c.text == "after" }
        .as(Egui::TextCmd)
    # The host window's own fill: the window_fill rect under the label.
    fill = cmds.each_with_index.find do |c, _|
      c.is_a?(Egui::RectCmd) && c.fill == ctx.style.visuals.window_fill &&
        c.rect.contains?(after.pos)
    end
    fill.should_not be_nil
    cmds.index(after).not_nil!.should be > fill.not_nil![1]
  end

  it "keeps the selected row's band when the pointer hovers it" do
    ctx = Egui::Context.new
    value = "b"
    3.times { |i| pl_frame(ctx, time: 0.016 * (i + 1)) { |c| pl_host(c, value) } }

    btn = ctx.memory.scroll_rects.each_value.first.rect.center
    pl_frame(ctx, [Egui::Event.pointer_moved(btn),
      Egui::Event.pointer_pressed(btn)], 0.064) { |c| pl_host(c, value) }
    pl_frame(ctx, [Egui::Event.pointer_released(btn)], 0.080) { |c| pl_host(c, value) }
    ctx.popup_open?("cb").should be_true

    # Hover the selected row ("b" — the focused combo's Enter candidate).
    # Two "b" texts are painted (the closed button and the list row):
    # pick the one inside the popup.
    popup = ctx.memory.popup_rects[Egui::Id.from("popup/cb")].not_nil!
    row_b = ctx.painter.commands.select(Egui::TextCmd)
      .find { |c| c.text == "b" && popup.contains?(c.pos) }.not_nil!
    pos = Egui::Pos2.new(row_b.pos.x + 5.0, row_b.pos.y)
    pl_frame(ctx, [Egui::Event.pointer_moved(pos)], 0.096) { |c| pl_host(c, value) }

    band = ctx.painter.commands.select(Egui::RectCmd).find do |c|
      c.fill == ctx.style.visuals.selection_fill && c.rect.contains?(row_b.pos)
    end
    band.should_not be_nil
  end
end
