# clip_child_demo — engine-level rounded content clipping
# (border-radius + overflow:hidden semantics).
#
# A container with a non-zero border radius clips everything its
# subtree paints to the ROUNDED shape — not just the rect bounds.
# Scrolled/nested content no longer bleeds past the curved corners:
#
#   .card {
#     border-radius: 24px;   /* != 0 → the subtree is clip-bracketed */
#     overflow: hidden;      /* implied by the engine, not opt-in */
#   }
#
# The clip is recursive by construction: an inner box's commands are
# re-clipped by its own bracket first, then the outer bracket
# intersects again (per-corner radii merge). Popups riding the
# Foreground layer deliberately ESCAPE the bracket — a menu opened
# inside a rounded card must not be cut by the card.
#
# Scenes below (drag the radius slider while they run):
#   1. square plate     — a full-bleed square child inside a rounded
#                         box: the corners show the backdrop, the
#                         curve is the clip edge;
#   2. scroll           — a tall list scrolled under the curve: rows
#                         vanish at the rounded corners, not past them;
#   3. nested boxes     — an inner SQUARE box inside a rounded one
#                         still respects the outer curve;
#   4. per-corner       — CSS `border-radius: 0 24 0 24` clips by the
#                         same per-corner shape;
#   5. popup escape     — the combo's dropdown opens OVER the card,
#                         uncut (it lives in another layer).

require "../src/egui/driver_selector"

module ClipChild
  BACKDROP = Egui::Color32.rgb(0x1b, 0x1b, 0x1e)
  CARD     = Egui::Color32.rgb(0x3f, 0x6b, 0x52) # sage green card
  PLATE    = Egui::Color32.rgb(0xb0, 0x5c, 0x4a) # terracotta square plate
  NESTED   = Egui::Color32.rgb(0x4a, 0x5f, 0x8a) # slate-blue inner box
  SCROLLBG = Egui::Color32.rgb(0x2b, 0x2b, 0x31)

  ZERO = Egui::Vec2.new(0.0, 0.0)
end

class ClipChildDemoApp < Egui::App
  property radius = 24.0
  property picked = "option A"

  def update(ctx : Egui::Context) : Nil
    ctx.window("clip_child", Egui::Pos2.new(24.0, 24.0), width: 560.0) do |ui|
      ui.heading("rounded clip — border-radius ≠ 0 clips the subtree")
      ui.label("box(rounding: r) clips everything inside to the rounded " \
               "shape; nested elements recursively. Drag the slider:")
      ui.slider(@radius, 0.0..48.0, "radius") { |v| @radius = v }
      r = @radius
      ui.separator

      # 1. Square full-bleed plate: without the clip the red would
      # flood the corners the card curves away from.
      ui.heading("1. square child, rounded parent")
      ui.box(rounding: r, fill: ClipChild::CARD, margin: ClipChild::ZERO) do |b|
        rect = b.allocate_space(Egui::Vec2.new(b.available_width, 120.0))
        b.painter.rect(rect, 0.0, ClipChild::PLATE)
      end

      ui.separator
      # 2. A scroll whose rows run under the curve — the classic bug
      # scene (content escaping the rounded viewport while scrolling).
      ui.heading("2. scroll under the curve")
      ui.box(rounding: r, fill: ClipChild::SCROLLBG,
          margin: ClipChild::ZERO) do |b|
        Egui::ScrollArea.new(max_height: 120.0).show(b) do |scroll|
          60.times { |i| scroll.label("row #{i} — scrolls INSIDE the curve") }
        end
      end

      ui.separator
      # 3. Nested: the inner box is square (rounding 0), yet its blue
      # plate is cut by the OUTER curve — radii merge per corner.
      ui.heading("3. nested square box")
      ui.box(rounding: r, fill: ClipChild::CARD, margin: ClipChild::ZERO) do |b|
        b.box(rounding: 0.0, fill: ClipChild::NESTED,
            margin: ClipChild::ZERO) do |c|
          c.allocate_space(Egui::Vec2.new(c.available_width, 90.0))
        end
      end

      ui.separator
      # 4. Per-corner CSS shorthand: the clip follows the same shape
      # as the painted background (0 24 0 24 — two square corners).
      ui.heading("4. per-corner: 0 #{r.to_i} 0 #{r.to_i}")
      ui.box(rounding: 0.0, fill: ClipChild::CARD, margin: ClipChild::ZERO,
          corners: Egui::CornerRadii.new(0.0, r, 0.0, r)) do |b|
        rect = b.allocate_space(Egui::Vec2.new(b.available_width, 90.0))
        b.painter.rect(rect, 0.0, ClipChild::PLATE)
      end

      ui.separator
      # 5. Popups escape the bracket: the dropdown is Foreground-layer
      # content and must NOT be clipped by the card — open it and
      # watch it cover the rounded corner below.
      ui.heading("5. popup escapes the clip")
      ui.box(rounding: r, fill: ClipChild::SCROLLBG,
          margin: Egui::Vec2.new(12.0, 8.0)) do |b|
        b.label("the combo opens over the card, uncut:")
        b.combo_box("clip_demo_combo", @picked,
          (1..6).map { |i| "option #{'A' + i - 1}" }) { |opt| @picked = opt }
      end
    end
  end
end

Egui.run(ClipChildDemoApp.new,
  title: "egui.cr — clip_child_demo (rounded content clip)",
  inspector: :hidden)
