# Composited scroll A/B probe (plans/COMPOSITED_SCROLL.md): a long
# ScrollArea with `composited: true` — the content (text rows, rounded
# cards, buttons) renders into the overscan band and the render thread
# owns the scroll offset at replay time.
#
# Run twice for the pixel-identity invariant:
#
#   EGUI_COMPOSITED_SCROLL=0 examples/composited_scroll  # classic
#   EGUI_COMPOSITED_SCROLL=1 examples/composited_scroll  # composited
#
# With no wheel input the replay delta is 0 and both must be
# pixel-identical (twinshot-verifiable). SCROLL_TO=N pre-sets the
# offset so a scrolled state can be compared too.

require "../src/egui/driver_selector"

class CompositedScrollApp < Egui::App
  @scroll_to : Float64? = ENV["SCROLL_TO"]?.try(&.to_f)

  def update(ctx : Egui::Context) : Nil
    # SCROLL_TO: pin the offset cell every frame (the stable `id:`
    # pins it) — a continuous write keeps the probe deterministic for
    # the A/B screenshot (no kinetic settle races).
    if (to = @scroll_to)
      ctx.memory.data.set_vec2(Egui::Id.from("probe"), Egui::Vec2.new(0.0, to))
    end
    ctx.central_panel do |ui|
      Egui::ScrollArea.new(composited: true, id: Egui::Id.from("probe"))
        .content { |inner| build_rows(inner) }.ui(ui)
    end
  end

  def build_rows(ui : Egui::Ui) : Nil
    200.times do |i|
      ui.horizontal do |row|
        row.label("row %03d" % i)
        row.button("action #{i}") if i % 7 == 3
      end
      if i % 15 == 0
        # A rounded block: exercises the stencil clip path inside the
        # bracket (its rect must translate with the composited scroll).
        ui.scope do |card|
          x = card.cursor.x
          y = card.cursor.y
          card.painter.rect(Egui::Rect.from_min_size(
            Egui::Pos2.new(x - 4.0, y - 4.0),
            Egui::Vec2.new(card.available_width + 8.0, 34.0)),
            10.0, Egui::Color32.rgba(40, 44, 52, 255))
          card.label("card block #{i} — rounded clip inside the band")
        end
      end
    end
  end
end

Egui.run(CompositedScrollApp.new,
  title: "composited scroll", width: 800, height: 600)
