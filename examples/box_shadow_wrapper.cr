# box-shadow wrapper — the egui.cr twin of examples/box_shadow_wrapper.html:
# a shadowed product card inside a wrapper box with a border + border-
# radius. The question: does the card's shadow escape the wrapper?
#
#   A: wrapper, ENGINE DEFAULT      — a painted rounded box clips its
#      subtree (engine-level overflow:hidden semantics, see Ui#box);
#      the shadow is cut by the rounded shape.
#   B: wrapper, overflow: :visible  — the CSS default; matches browser
#      case A — the shadow escapes.
#   C: wrapper, overflow: :hidden   — matches browser case B.
#
# Browser truth (case A of the html file): border-radius clips only the
# element's OWN background/border; a descendant's box-shadow is cut only
# by an ancestor with overflow hidden/scroll/auto. Open the html next to
# this window and compare.

require "../src/egui/driver_selector"

class BoxShadowWrapperApp < Egui::App
  BG      = Egui::Color32.rgb(0x23, 0x23, 0x29) # page
  CARD    = Egui::Color32.rgb(0x2e, 0x2e, 0x36) # card fill
  THUMB   = Egui::Color32.rgb(0x3a, 0x3a, 0x44) # image placeholder
  WRAP_BR = Egui::Color32.rgb(0x8a, 0x8a, 0x94) # wrapper border
  TEXT    = Egui::Color32.rgb(0xe8, 0xe8, 0xec)
  DIM     = Egui::Color32.rgb(0x9a, 0x9a, 0xa6)
  SHADOW  = Egui::BoxShadowSpec.new(
    Egui::Color32.rgba(0, 255, 158, 140), # rgb(0 255 158 / 55%)
    blur: 24.0, spread: 4.0,
    offset: Egui::Vec2.new(0.0, 8.0))

  # The product card: thumb + name + price, shadowed like the html
  # `.card` (0 8px 24px 4px rgb(0 255 158 / 55%)).
  def card(ui : Egui::Ui) : Nil
    ui.box(fill: CARD, rounding: 12.0, shadow: SHADOW,
           margin: Egui::Vec2.new(12.0, 12.0)) do |c|
      c.box(fill: THUMB, rounding: 8.0, height: 70.0,
            margin: Egui::Vec2.zero) { |t| t.label(" ", userselect: false) }
      c.rich(Egui::RichText.new("Product").color(TEXT))
      c.rich(Egui::RichText.new("$99.00").color(DIM))
    end
  end

  # One case: the caption, the wrapper (border + radius 16, the box's
  # own overflow mode), the card inside, and the footnote.
  def case_row(ui : Egui::Ui, title : String, ovf : Symbol?,
               note : String) : Nil
    ui.box(fill: nil, stroke: nil, rounding: 0.0,
           margin: Egui::Vec2.new(0.0, 0.0)) do |col|
      col.rich(Egui::RichText.new(title).color(DIM))
      col.box(stroke: WRAP_BR, rounding: 16.0, overflow: ovf,
              margin: Egui::Vec2.new(16.0, 16.0)) { |w| card(w) }
      col.rich(Egui::RichText.new(note).color(DIM))
    end
  end

  def update(ctx : Egui::Context) : Nil
    ctx.central_panel do |ui|
      p = ui.painter
      p.rect(Egui::Rect.from_min_size(Egui::Pos2.new(0, 0),
        Egui::Vec2.new(ctx.input.screen_rect.width,
          ctx.input.screen_rect.height)), 0.0, BG)
      # The h1 — IN FLOW like the html (16px text, 16px margin-bottom),
      # not painter-drawn at absolute coords: the row below must see it
      # in the cursor flow to keep the page geometry.
      ui.rich(Egui::RichText.new(
        "box-shadow on a card inside a rounded wrapper").size(16.0).color(DIM))
      # h1's margin-bottom: 16, minus the 6px item spacing already
      # between the two blocks.
      ui.allocate_at_least(Egui::Vec2.new(0.0, 10.0))

      # .cases — a real flexbox row (the html's `display: flex; gap:
      # 48px; align-items: flex-start`): `ui.flex` gives the CSS knobs,
      # each case a fixed 300px column via flex-basis. `ui.horizontal`
      # would center the columns on one line and space them by
      # item_spacing — the old global-layout mismatch.
      ui.flex(align: :start, gap: 48.0) do |f|
        f.child(basis: 300.0) do |cell|
          case_row(cell, "A: wrapper, engine default", nil,
            "clipped — painted rounded box = overflow:hidden")
        end
        f.child(basis: 300.0) do |cell|
          case_row(cell, "B: wrapper, overflow: :visible", :visible,
            "escapes — the CSS/browser default")
        end
        f.child(basis: 300.0) do |cell|
          case_row(cell, "C: wrapper, overflow: :hidden", :hidden,
            "clipped — matches browser overflow:hidden")
        end
      end
    end
  end
end

Egui.run(BoxShadowWrapperApp.new,
  title: "egui.cr — box-shadow in a rounded wrapper",
  width: 1020, height: 460, inspector: :hidden)
