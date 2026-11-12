# egui-cr transform showcase — демо полного CSS-подобного `transform`
# (Egui::Affine2 / CssTransform): rotate / skew / scale / translate /
# matrix, статикой из CSS-правил каскада и императивно из Crystal.
#
#   * Tilted cards      — статические `transform:` правила каскада
#   * Skew panels       — skewX/skewY (штамп affine + sgl-матрица)
#   * Spinning badge    — императивный rotate по времени (Affine2)
#   * Hover lift        — transition.transform: 200ms lerp при hover
#   * Matrix wave       — matrix(...) как волна карточек
#
# Трансформация paint-only (семантика appear): layout, клип-ректы и
# хит-тестинг остаются на месте — двигается только геометрия.

require "../src/egui/driver_selector"

class TransformShowcaseApp < Egui::App
  BG     = Egui::Color32.rgb(0x16, 0x17, 0x1a)
  PANEL  = Egui::Color32.rgb(0x1f, 0x21, 0x26)
  CARD   = Egui::Color32.rgb(0x27, 0x2a, 0x31)
  STROKE = Egui::Color32.rgb(0x33, 0x36, 0x3d)
  TEXT   = Egui::Color32.rgb(0xe8, 0xe8, 0xe8)
  MUTED  = Egui::Color32.rgb(0x9a, 0x9a, 0xa2)
  ACCENT = Egui::Color32.rgb(0x3b, 0x82, 0xf6)
  WARM   = Egui::Color32.rgb(0xf5, 0x9e, 0x0b)
  COOL   = Egui::Color32.rgb(0x10, 0xb9, 0x81)

  @themed = false

  def update(ctx : Egui::Context) : Nil
    theme_once(ctx)
    rules_once(ctx)
    now = ctx.input.time

    ctx.central_panel do |ui|
      ui.box(:column, fill: BG, margin: Egui::Vec2.new(12.0, 12.0),
        rounding: 0.0, stroke: nil) do |col|
        heading(col, "CSS transform — rotate · skew · scale · translate · matrix")

        # -- row 1: static CSS-rule transforms ---------------------------
        col.box(:row, wrap: true, margin: Egui::Vec2.new(0.0, 0.0)) do |row|
          tilted(row)
          tilted_back(row)
          skewed(row)
        end

        # -- row 2: live animations --------------------------------------
        col.box(:row, wrap: true, margin: Egui::Vec2.new(0.0, 8.0)) do |row|
          spinning(row, now)
          pulsing(row, now)
          wave(row, now)
        end

        # -- row 3: hover + transition -----------------------------------
        col.box(:row, wrap: true, margin: Egui::Vec2.new(0.0, 8.0)) do |row|
          4.times do |i|
            hover_lift(row, ctx, i)
          end
        end

        hint(col,
          "Paint-only: layout and hit-testing stay in place — hover the bottom row")
      end
    end
  end

  # --- static rules from the cascade -----------------------------------

  private def tilted(row : Egui::Ui) : Nil
    row.box(:column, style_class: "tilt",
      fill: CARD, stroke: STROKE, rounding: 12.0,
      margin: Egui::Vec2.new(10.0, 10.0)) do |c|
      big(c, "rotate(-4deg)", ACCENT)
      body(c, "transform: rotate(-4deg)\ntransform-origin: center")
    end
  end

  private def tilted_back(row : Egui::Ui) : Nil
    row.box(:column, style_class: "tilt-corner",
      fill: CARD, stroke: STROKE, rounding: 12.0,
      margin: Egui::Vec2.new(10.0, 10.0)) do |c|
      big(c, "rotate(5deg)", COOL)
      body(c, "transform: rotate(5deg)\ntransform-origin: bottom right")
    end
  end

  private def skewed(row : Egui::Ui) : Nil
    row.box(:column, style_class: "skewcard",
      fill: CARD, stroke: STROKE, rounding: 12.0,
      margin: Egui::Vec2.new(10.0, 10.0)) do |c|
      big(c, "skewX(-8deg)", WARM)
      body(c, "transform: skewX(-8deg) translateY(6px)")
    end
  end

  # --- live imperative transforms ---------------------------------------

  private def spinning(row : Egui::Ui, now : Float64) : Nil
    row.box(:row, wrap: false, margin: Egui::Vec2.new(10.0, 10.0)) do |wrap|
      xf = Egui::Affine2.rotation(now % (2 * Math::PI),
        Egui::Pos2.new(44.0, 44.0))
      wrap.box(:column, transform: xf, fill: ACCENT,
        rounding: 16.0, margin: Egui::Vec2.new(0.0, 0.0)) do |c|
        c.box(:row, margin: Egui::Vec2.new(26.0, 26.0)) { }
      end
      wrap.box(:column, fill: CARD, stroke: STROKE, rounding: 12.0,
        margin: Egui::Vec2.new(12.0, 0.0)) do |c|
        big(c, "rotate ∞", ACCENT)
        body(c, "Affine2.rotation(t)\nrebuilt every frame")
      end
    end
  end

  private def pulsing(row : Egui::Ui, now : Float64) : Nil
    s = 1.0 + 0.12 * Math.sin(now * 2.4)
    row.box(:column, transform: "scale(#{s.round(3)})",
      fill: CARD, stroke: STROKE, rounding: 12.0,
      margin: Egui::Vec2.new(10.0, 10.0)) do |c|
      big(c, "scale pulse", COOL)
      body(c, "scale(1 + 0.12·sin t)")
    end
  end

  private def wave(row : Egui::Ui, now : Float64) : Nil
    row.box(:row, wrap: false, margin: Egui::Vec2.new(10.0, 10.0)) do |wrap|
      5.times do |i|
        phase = now * 1.8 + i * 0.55
        dy = 10.0 * Math.sin(phase)
        sh = 0.06 * Math.cos(phase)
        xf = "translateY(#{dy.round(2)}px) skewX(#{(sh * 180 / Math::PI).round(2)}deg)"
        wrap.box(:column, transform: xf,
          fill: i.even? ? WARM : MUTED, rounding: 8.0,
          margin: Egui::Vec2.new(3.0, 3.0)) do |c|
          c.box(:row, margin: Egui::Vec2.new(6.0, 16.0)) { }
        end
      end
      wrap.box(:column, fill: CARD, stroke: STROKE, rounding: 12.0,
        margin: Egui::Vec2.new(12.0, 0.0)) do |c|
        big(c, "wave", WARM)
        body(c, "translate + skewX\nper-card phase")
      end
    end
  end

  # --- hover + transition.transform -------------------------------------
  #
  # The hover state rides a per-card map updated AFTER each box runs
  # (its ORIGINAL rect — paint-only means hit-testing never follows the
  # animation), and the map feeds the NEXT frame's `transform:` — the
  # box's own `transition.transform` run does the easing in between.

  LIFT_DOWN = Egui::CssTransform.parse?("translateY(0px) scale(1)").not_nil!
  LIFT_UP   = Egui::CssTransform.parse?("translateY(-10px) scale(1.06)").not_nil!
  @hovered  = Hash(Int32, Bool).new(false)

  private def hover_lift(row : Egui::Ui, ctx : Egui::Context, i : Int32) : Nil
    rect = row.box(:column, style_class: "lift",
      transform: @hovered[i] ? LIFT_UP : LIFT_DOWN,
      fill: CARD, stroke: STROKE, rounding: 12.0,
      margin: Egui::Vec2.new(10.0, 10.0)) do |c|
      big(c, "hover #{i + 1}", ACCENT)
      body(c, "transition.transform: 200ms\nhover → translateY(-10px) scale(1.06)")
    end
    if (pt = ctx.input.pointer_pos)
      @hovered[i] = rect.contains?(pt)
    end
  end

  # --- shared chrome -----------------------------------------------------

  private def heading(ui : Egui::Ui, text : String) : Nil
    ui.rich(Egui::RichText.new(text).size(20.0).color(TEXT))
  end

  private def big(ui : Egui::Ui, text : String, color : Egui::Color32) : Nil
    ui.rich(Egui::RichText.new(text).size(15.0).color(color))
  end

  private def body(ui : Egui::Ui, text : String) : Nil
    text.each_line do |line|
      ui.rich(Egui::RichText.new(line).size(11.0).color(MUTED))
    end
  end

  private def hint(ui : Egui::Ui, text : String) : Nil
    ui.rich(Egui::RichText.new(text).size(11.0).color(MUTED))
  end

  private def theme_once(ctx : Egui::Context) : Nil
    return if @themed
    Egui::DefaultTheme.build("transform-showcase", dark: true) do |v|
      v.window_fill = BG
      v.panel_fill = BG
      v.text_color = TEXT
      v.window_stroke = BG
    end.tap { |t| ctx.theme = t }
    @themed = true
  end

  # The static rules of the showcase (the cascade the demo styles
  # through — an .ecss file would carry the same declarations).
  private def rules_once(ctx : Egui::Context) : Nil
    return if @ruled
    @ruled = true
    s = ctx.stylesheet
    s.rule("tilt", Egui::StyleVars{
      "transform" => Egui::CssTransform.parse?("rotate(-4deg)").not_nil!,
    })
    s.rule("tilt-corner", Egui::StyleVars{
      "transform"         => Egui::CssTransform.parse?("rotate(5deg)").not_nil!,
      "transform-origin"  => Egui::TransformOrigin.parse?("bottom right").not_nil!,
    })
    s.rule("skewcard", Egui::StyleVars{
      "transform" => Egui::CssTransform.parse?("skewX(-8deg) translateY(6px)").not_nil!,
    })
    s.rule("lift", Egui::StyleVars{
      "transition.transform" => 200.0,
    })
  end

  @ruled = false
end

Egui.run(TransformShowcaseApp.new,
  title: "egui.cr — CSS transform showcase", inspector: :hidden)
