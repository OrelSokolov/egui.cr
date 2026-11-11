# egui.cr html positions — the CSS `position` showcase: elements
# collected in every positioning flavor the engine now speaks
# natively (`fixed` against the window, `absolute` against the
# nearest positioned ancestor, `relative` shifts, stretch axes,
# `%` offsets, an ECSS-driven rule). The spellings are the literal
# CSS ones — every pin below rides the inline `style:` parser, the
# same declarations the HTML oracle (examples/html_positions.html)
# uses. `ui.box(position: …, top: …)` is the named-arg twin.

require "../../src/egui"
require "../../src/egui/html"
require "../icon"

class HtmlPositionsApp < Egui::App
  @rules_ready = false

  def update(ctx : Egui::Context) : Nil
    setup_rules(ctx) unless @rules_ready

    ctx.central_panel do |ui|
      # --- flow content: what the pinned elements float over -------
      ui.div(style: "padding: 16") do |page|
        page.rich(Egui::RichText.new("html positions")
          .size(page.style.font_size * 1.6))
        page.rich(Egui::RichText.new(
          "Every chip below is pinned with the CSS spellings — position: " \
          "fixed | absolute | relative and top/right/bottom/left offsets " \
          "(px, %, vw/vh). The flow never sees them: this text column's " \
          "cursor and bounds are untouched by anything pinned around it."),
          wrap: true)
        page.separator

        # --- the positioned stage: a `relative` parent that becomes
        # the containing block for its `absolute` children (CSS
        # semantics: the nearest positioned ancestor).
        page.div(style: "position: relative; background: #1e1e24; " \
                     "stroke: #3a3a44; border-radius: 8; padding: 14") do |stage|
          stage.rich(Egui::RichText.new(
            "the stage is position: relative — the containing block for " \
            "its absolute children").weak(stage.style.visuals))
          stage.rich(Egui::RichText.new(
            "badge pinned top: 6 / right: 6 · strip stretched left: 8 + " \
            "right: 8 at bottom: 8 · marker at top: 50% / left: 50% (the " \
            "near edge — no translate in v1)").weak(stage.style.visuals),
            wrap: true)

          # absolute: a corner badge, a stretched strip, a % marker
          stage.div(style: "position: absolute; top: 6; right: 6; " \
                           "background: #e01b4c; border-radius: 4; " \
                           "padding-x: 8; padding-y: 2") do |b|
            b.small("NEW")
          end
          stage.div(style: "position: absolute; left: 8; right: 8; " \
                           "bottom: 8; background: #3584e4; " \
                           "border-radius: 4; padding-x: 8; padding-y: 3") do |s|
            s.small("stretched — left: 8 + right: 8 (width comes from the offsets)")
          end
          stage.div(style: "position: absolute; top: 50%; left: 50%; " \
                           "background: #9141ac; border-radius: 4; " \
                           "padding-x: 6; padding-y: 2") do |m|
            m.small("50% / 50%")
          end
        end

        # --- relative: in flow, shifted — space stays reserved, the
        # next row never moves.
        ui.horizontal(wrap: false) do |row|
          row.div(style: "background: #33333c; border-radius: 6; padding: 6") do |d|
            d.small("flow slot")
          end
          row.div(style: "position: relative; top: -14; " \
                         "background: #f5c211; border-radius: 6; padding: 6") do |d|
            d.small("relative top: -14")
          end
          row.div(style: "background: #33333c; border-radius: 6; padding: 6") do |d|
            d.small("next in flow — unmoved")
          end
        end

        ui.rich(Egui::RichText.new(
          "…the window is the viewport for the pinned chips — resize the " \
          "window and they stay at their offsets, the flow column reflows " \
          "underneath.").weak(ui.style.visuals), wrap: true)
      end

      # --- fixed against the WINDOW (the viewport): four corners,
      # one % pin, one ECSS-ruled chip -------------------------------
      ui.div(style: "position: fixed; top: 12; right: 12; " \
                    "background: #33d17a; border-radius: 6; padding: 6") do |d|
        d.small("fixed · top: 12 right: 12")
      end
      ui.div(style: "position: fixed; bottom: 12; left: 12; " \
                    "background: #e01b4c; border-radius: 6; padding: 6") do |d|
        d.small("fixed · bottom: 12 left: 12")
      end
      ui.div(style: "position: fixed; bottom: 12; right: 12; " \
                    "background: #3584e4; border-radius: 6; padding: 6") do |d|
        d.small("fixed · bottom: 12 right: 12")
      end
      ui.div(style: "position: fixed; top: 96; left: 25%; " \
                    "background: #f5c211; border-radius: 6; padding: 6") do |d|
        d.small("fixed · top: 96 left: 25%")
      end
      # ECSS-driven: the rule below pins this chip — no layout args,
      # no inline position declaration.
      ui.div(classes: "hud_rule",
             style: "background: #9141ac; border-radius: 6; padding: 6") do |d|
        d.small("hud_rule class · ecss pins it")
      end
    end
  end

  # The `.hud_rule { position: fixed; top: 12; left: 12 }` — a class
  # rule alone takes a plain div out of the flow.
  private def setup_rules(ctx : Egui::Context) : Nil
    ctx.stylesheet.rule("hud_rule", Egui::StyleVars{
      "position" => "fixed",
      "top"      => 12.0,
      "left"     => 12.0,
    })
    @rules_ready = true
  end
end
