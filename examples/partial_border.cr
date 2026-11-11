# Per-side borders — CSS `border-style: solid none none none` in
# egui.cr spelling:
#
#   stroke_width: 1;               /* scalar: all four sides */
#   stroke_width.top: 0;           /* per-side override, 0 = side off */
#   stroke_width.left: 3;          /* = border-left-width: 3px */
#   stroke.left: #ff8800;          /* per-side color (accent bar) */
#
# Three sections: code-side `Ui#box` (a StyleBox stroke_width), the
# same through stylesheet class rules on the standard widgets (Button,
# TextEdit — no custom painting), and rounded corners where a corner
# ring survives only while BOTH adjacent sides are on.

require "../src/egui/driver_selector"

class PartialBorderApp < Egui::App
  @themed = false
  @edit = ""

  GRAY  = Egui::Color32.rgb(0x70, 0x70, 0x70)
  DARK  = Egui::Color32.rgb(0x3a, 0x3a, 0x3a)
  BLUE  = Egui::Color32.rgb(0x11, 0x8a, 0xd6)
  ORANGE = Egui::Color32.rgb(0xff, 0x88, 0x00)

  def update(ctx : Egui::Context) : Nil
    unless @themed
      # The stylesheet section: the standard Button and TextEdit pick
      # the per-side keys up from their class rules — top border off on
      # buttons, an accent left bar + 3px bottom on the edit.
      sheet = ctx.stylesheet
      sheet.rule("button", Egui::StyleVars{
        "stroke_width"     => 1.0,
        "stroke_width.top" => 0.0,
        "stroke_width.bottom" => 2.0,
        "stroke.bottom"    => BLUE,
      })
      sheet.rule("text_edit", Egui::StyleVars{
        "stroke_width"     => 1.0,
        "stroke_width.left" => 3.0,
        "stroke.left"      => ORANGE,
      })
      @themed = true
    end

    ctx.central_panel do |ui|
      ui.heading("Per-side borders — code API")
      ui.label("ui.box stroke_width: StyleBox (solid none none none)")
      ui.box(:column, fill: DARK, stroke: GRAY, rounding: 0.0,
        stroke_width: Egui::StyleBox.new(top: 1.0, right: 0.0,
          bottom: 0.0, left: 0.0),
        margin: Egui::Vec2.new(12.0, 8.0)) { |b| b.label("top only") }
      ui.box(:column, fill: DARK, stroke: GRAY, rounding: 0.0,
        stroke_width: Egui::StyleBox.new(top: 0.0, right: 0.0,
          bottom: 3.0, left: 0.0),
        margin: Egui::Vec2.new(12.0, 8.0)) { |b| b.label("bottom only, 3px") }
      ui.box(:column, fill: DARK, stroke: GRAY, rounding: 0.0,
        stroke_width: Egui::StyleBox.new(top: 0.0, right: 0.0,
          bottom: 0.0, left: 3.0),
        margin: Egui::Vec2.new(12.0, 8.0)) { |b| b.label("left only, 3px") }

      ui.separator
      ui.heading("Stylesheet rules (standard widgets)")
      ui.label("button { stroke_width.top: 0; stroke_width.bottom: 2 }")
      ui.horizontal do |row|
        row.button("One").clicked?
        row.button("Two").clicked?
        row.button("Three").clicked?
      end
      ui.label("text_edit { stroke_width.left: 3; stroke.left: orange }")
      ui.text_edit_singleline(@edit, hint: "accent left bar") do |text|
        @edit = text
      end

      ui.separator
      ui.heading("Rounded corners")
      ui.label("a corner curves while any adjacent side is on")
      ui.box(:column, fill: DARK, stroke: GRAY, rounding: 8.0,
        stroke_width: Egui::StyleBox.new(top: 1.0, right: 1.0,
          bottom: 0.0, left: 0.0),
        margin: Egui::Vec2.new(12.0, 8.0)) { |b| b.label("top + right, rounding 8") }
      ui.box(:column, fill: DARK, stroke: GRAY, rounding: 8.0,
        stroke_width: Egui::StyleBox.new(top: 0.0, right: 0.0,
          bottom: 4.0, left: 4.0),
        margin: Egui::Vec2.new(12.0, 8.0)) { |b| b.label("bottom + left, 4px") }
    end
  end
end

Egui.run(PartialBorderApp.new,
  title: "egui.cr — per-side borders", inspector: :hidden)
