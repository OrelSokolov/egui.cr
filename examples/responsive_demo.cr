# egui-cr responsive demo — всё, что дали plans/responsive-mobile.md
# (Этапы 1–6) и plans/animations.md (Ур.1–2) в одном окне:
#
#  - единицы длин в стилях: пара 50%+50% делит ряд ровно, рядом
#    30vw / 6rem / 8vmin и кнопка с min/max-клампами;
#  - медиа-условия: (orientation: portrait) разворачивает кнопку на
#    всю ширину, (max-width: 700px) перекрашивает ряд;
#  - переходы: hover-заливка четырьмя easing-кривыми рядом (видно
#    разницу характера), ширина кнопки анимируется 30% ↔ 70%;
#  - safe area: тумблер «чёлки» сдвигает панели, env()-кнопка растёт
#    на величину инсета;
#  - font scale: слайдер крутит ctx.font_scale — растёт всё, что
#    задано в rem, пунктовые размеры стоят;
#  - pointer: coarse — hover-правила читаются как base (липких
#    подсветок от тапа нет), reduced motion снапит все переходы.
#
# Стили объявлены кодом через ctx.stylesheet.rule (класс-каскад тот
# же, что читает .ecss-файлы инспектора) и скоуп "demo": каждая
# кнопка адресуется как "demo.<part>".

require "../src/egui/backend_selector"

class ResponsiveApp < Egui::App
  @styled = false
  @coarse = false
  @reduced = false
  @notch = false
  @font_scale = 1.0
  @wide = false

  def update(ctx : Egui::Context) : Nil
    style_once(ctx)

    # Системные тумблеры демки: применяются к Context каждый кадр.
    ctx.pointer_coarse = true if @coarse
    ctx.reduced_motion = @reduced
    ctx.font_scale = @font_scale
    {% unless flag?(:ios) || flag?(:android) %}
      # Desktop: the toggle SIMULATES a phone's safe area. On iOS and
      # Android the real insets arrive per frame from the OS detector
      # (backend/sokol_shim.c → RawInput.safe_area → begin_frame) and
      # must not be overridden here.
      ctx.safe_area = @notch ? Egui::SafeArea.new(
        top: 44.0, bottom: 34.0) : Egui::SafeArea.zero
    {% end %}

    orientation = ctx.input.screen_rect.width >= ctx.input.screen_rect.height
    ctx.top_panel("hud", height: 92.0) do |ui|
      ui.label("viewport #{"%.0f" % ctx.input.screen_rect.width}×" \
               "#{"%.0f" % ctx.input.screen_rect.height} — " \
               "#{orientation ? "landscape" : "portrait"},  " \
               "pointer: #{@coarse ? "coarse (тач)" : "fine (мышь)"}")
      {% if flag?(:ios) || flag?(:android) %}
        # On phones the OS detector is the authority — show its numbers.
        sa = ctx.safe_area
        unless sa.zero?
          ui.label("safe area (детектор ОС): top #{"%.0f" % sa.top} / " \
                   "right #{"%.0f" % sa.right} / " \
                   "bottom #{"%.0f" % sa.bottom} / " \
                   "left #{"%.0f" % sa.left}")
        end
      {% end %}
      ui.horizontal do |row|
        row.checkbox(@coarse, "pointer: coarse") { |v| @coarse = v }
        row.checkbox(@reduced, "reduced motion") { |v| @reduced = v }
        row.checkbox(@notch, "safe area (чёлка)") { |v| @notch = v }
      end
      ui.slider(@font_scale, 0.8..2.0, text: "font scale (×rem)") do |v|
        @font_scale = v
      end
    end

    ctx.central_panel do |ui|
      ui.with_style_scope("demo") do |s|
        ui.heading("Единицы: %, vw, rem, vmin")
        ui.label("Пара width: 50% делит ряд ровно (spacing учтён); " \
                 "соседи — 30vw, 6rem (следит за font scale) и 8vmin.")
        ui.horizontal do |row|
          row.add(Egui::Button.new("50%").part("half"))
          row.add(Egui::Button.new("50%").part("half"))
        end
        ui.horizontal do |row|
          row.add(Egui::Button.new("30vw").part("vw30"))
          row.add(Egui::Button.new("6rem").part("rem6"))
          row.add(Egui::Button.new("8vmin").part("vmin8"))
        end
        ui.add(Egui::Button.new(
          "50%, но min 120 / max 200 — окно узкое → кламп").part("clamped"))
        ui.separator

        ui.heading("Медиа-условия")
        ui.label("(orientation: portrait) разворачивает кнопку на всю " \
                 "ширину; (max-width: 700px) красит ряд — потяните окно.")
        ui.add(Egui::Button.new(
          "media: portrait → 100%, иначе 50%").part("media"))
        ui.separator

        ui.heading("Переходы: transition + easing")
        ui.label("Наведите по очереди — четыре кривые на 400 мс. " \
          "Кнопка ниже анимирует width 30% ↔ 70%.")
        ui.horizontal do |row|
          row.add(Egui::Button.new("linear").part("lin"))
          row.add(Egui::Button.new("ease-in").part("ein"))
          row.add(Egui::Button.new("ease-out").part("eout"))
          row.add(Egui::Button.new("ease-in-out").part("einout"))
        end
        if ui.add(Egui::Button.new(@wide ? "width: 70% ← клик" : "width: 30% ← клик")
               .part(@wide ? "wide" : "narrow")).clicked?
          @wide = !@wide
        end
        ui.separator

        ui.heading("Safe area + env()")
        ui.label("Тумблер «чёлки» вверху имитирует телефон: контент " \
                 "уходит от статус-бара (top 44) и home-индикатора " \
                 "(bottom 34); высота кнопки = env(safe-area-inset-top) " \
                 "+ floor 20.")
        ui.add(Egui::Button.new("env(safe-area-inset-top)").part("envh"))
      end
    end
  end

  # Стили демки — один раз, при первом кадре. Класс-цепочка виджета:
  # "button" (тема) + "demo.<part>" (эти правила).
  private def style_once(ctx : Egui::Context) : Nil
    return if @styled
    s = ctx.stylesheet
    ease = {"lin" => "linear", "ein" => "ease-in",
            "eout" => "ease-out", "einout" => "ease-in-out"}
    ease.each do |part, curve|
      s.rule("demo.#{part}", Egui::StyleVars{
        "background"            => Egui::Color32.rgb(61, 61, 61),
        "transition.background" => 400.0,
        "easing.background"     => curve,
      })
      s.rule("demo.#{part}:hover", Egui::StyleVars{
        "background" => Egui::Color32.rgb(61, 90, 254),
      })
    end
    s.rule("demo.half", Egui::StyleVars{
      "width" => Egui::StyleLength.new(50.0, :percent)})
    s.rule("demo.vw30", Egui::StyleVars{
      "width" => Egui::StyleLength.new(30.0, :vw)})
    s.rule("demo.rem6", Egui::StyleVars{
      "width" => Egui::StyleLength.new(6.0, :rem)})
    s.rule("demo.vmin8", Egui::StyleVars{
      "width" => Egui::StyleLength.new(8.0, :vmin)})
    s.rule("demo.clamped", Egui::StyleVars{
      "width"     => Egui::StyleLength.new(50.0, :percent),
      "min_width" => 120.0,
      "max_width" => 200.0,
    })
    # Медиа: ориентация и брейкпоинт по ширине.
    s.rule("demo.media", Egui::StyleVars{
      "width" => Egui::StyleLength.new(50.0, :percent)})
    s.rule("demo.media", Egui::StyleVars{
      "width" => Egui::StyleLength.new(100.0, :percent),
    }, media: "(orientation: portrait)")
    s.rule("demo.media", Egui::StyleVars{
      "background" => Egui::Color32.rgb(120, 60, 20),
    }, media: "(max-width: 700px)")
    # Анимированная ширина: одна и та же кнопка переезжает между
    # классами по клику — transition.width доезжает плавно.
    s.rule("demo.wide", Egui::StyleVars{
      "width"        => Egui::StyleLength.new(70.0, :percent),
      "transition"   => 400.0,
      "easing.width" => "ease-in-out",
    })
    s.rule("demo.narrow", Egui::StyleVars{
      "width"        => Egui::StyleLength.new(30.0, :percent),
      "transition"   => 400.0,
      "easing.width" => "ease-in-out",
    })
    # Высота от safe-area-инсета (полный инсета + фикс-флор).
    s.rule("demo.envh", Egui::StyleVars{
      "height"     => Egui::StyleLength.new(1.0, :safe_top),
      "min_height" => 20.0,
    })
    @styled = true
  end
end

Egui.run(ResponsiveApp.new, title: "egui-cr — responsive",
  inspector: :hidden)
