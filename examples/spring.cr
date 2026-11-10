# egui-cr spring — демо-пруф spring-примитива (инкремент 1 плана
# plans/NATIVE_HTML_DEMO.md §3.2): значение `spring(…)` в `transition`
# вместо duration+easing.
#
# Три ряда чипов на hover:
#   1. фон — spring(bouncy) / spring(smooth);
#   2. фон — обычный ease-out 150ms (тот же контраст цветов);
#   3. ширина — spring(wobbly) против ease-out.
#
# Качайте указатель туда-сюда по ряду: easing-переход при каждом
# входе/выходе перезапускается с нулевой производной (скачок скорости),
# пружина продолжает с текущей скоростью — прерывание без рывка, у
# bouncy ещё и перелетает цель. Это и есть ключевое свойство
# «живости» Raven: непрерывность по скорости при смене цели mid-flight.

require "../src/egui/driver_selector"

# Чип с собственным классом — правила ниже вешают переходы на класс.
class SpringChip < Egui::Button
  def initialize(text : String, @chip_class : String, id : String? = nil)
    super(text, id: id)
  end

  def style_class : String?
    @chip_class
  end
end

class SpringApp < Egui::App
  BG   = Egui::Color32.rgb(0x16, 0x17, 0x1a)
  TEXT = Egui::Color32.rgb(0xe8, 0xe8, 0xe8)

  BASE = {
    "background" => Egui::Color32.rgb(0x2d, 0x6c, 0x46),
    "stroke"     => Egui::Color32.rgb(0x43, 0x9c, 0x64),
    "text_color" => TEXT,
    "rounding"   => 10.0,
  }
  HOVER = Egui::Color32.rgb(0x53, 0xb9, 0x77)
  GROW  = {
    "width"      => 120.0,
    "height"     => 36.0,
    "background" => Egui::Color32.rgb(0x39, 0x4b, 0x6d),
    "stroke"     => Egui::Color32.rgb(0x58, 0x74, 0xa4),
    "text_color" => TEXT,
    "rounding"   => 10.0,
  }

  @themed = false

  def update(ctx : Egui::Context) : Nil
    unless @themed
      Egui::DefaultTheme.build("spring", dark: true) do |v|
        v.window_fill = BG
        v.panel_fill = BG
        v.text_color = TEXT
        v.window_stroke = BG
      end.tap { |t| ctx.theme = t }

      s = ctx.stylesheet

      # Ряд 1: фон на пружинах — bouncy перелетает, smooth приземляется.
      s.rule("chip-bouncy", Egui::StyleVars{
        "background" => BASE["background"].as(Egui::Color32),
        "stroke"     => BASE["stroke"].as(Egui::Color32),
        "text_color" => TEXT,
        "rounding"   => 10.0,
        "transition" => "spring(bouncy)",
      })
      s.rule("chip-bouncy:hover",
        Egui::StyleVars{"background" => HOVER})

      s.rule("chip-smooth", Egui::StyleVars{
        "background" => BASE["background"].as(Egui::Color32),
        "stroke"     => BASE["stroke"].as(Egui::Color32),
        "text_color" => TEXT,
        "rounding"   => 10.0,
        "transition" => "spring(smooth)",
      })
      s.rule("chip-smooth:hover",
        Egui::StyleVars{"background" => HOVER})

      # Ряд 2: тот же контраст, но классический ease-out — при
      # прерывании производная обнуляется, «дёргано» против ряда 1.
      s.rule("chip-ease", Egui::StyleVars{
        "background" => BASE["background"].as(Egui::Color32),
        "stroke"     => BASE["stroke"].as(Egui::Color32),
        "text_color" => TEXT,
        "rounding"   => 10.0,
        "transition" => 150.0,
        "easing"     => "ease-out",
      })
      s.rule("chip-ease:hover",
        Egui::StyleVars{"background" => HOVER})

      # Ряд 3: ширина — spring(wobbly) против ease-out. У spring-версии
      # compound-спеллинг: «width spring(…)» называет ключ.
      s.rule("grow-spring", Egui::StyleVars{
        "width"      => 120.0,
        "height"     => 36.0,
        "background" => GROW["background"].as(Egui::Color32),
        "stroke"     => GROW["stroke"].as(Egui::Color32),
        "text_color" => TEXT,
        "rounding"   => 10.0,
        "transition" => "width spring(wobbly)",
      })
      s.rule("grow-spring:hover", Egui::StyleVars{"width" => 220.0})

      s.rule("grow-ease", Egui::StyleVars{
        "width"           => 120.0,
        "height"          => 36.0,
        "background"      => GROW["background"].as(Egui::Color32),
        "stroke"          => GROW["stroke"].as(Egui::Color32),
        "text_color"      => TEXT,
        "rounding"        => 10.0,
        "transition.width" => 150.0,
        "easing.width"    => "ease-out",
      })
      s.rule("grow-ease:hover", Egui::StyleVars{"width" => 220.0})

      @themed = true
    end

    ctx.central_panel do |ui|
      ui.heading("spring(…) в transition — прерывание без скачка")
      ui.label("Проведите указателем по ряду туда-сюда: пружина продолжает")
      ui.label("с текущей скоростью, easing перезапускается с нулевой.")
      ui.separator

      ui.heading("Фон: spring(bouncy) · spring(smooth) · ease-out 150ms")
      ui.horizontal do |h|
        h.add(SpringChip.new("bouncy", "chip-bouncy", id: "chip-bouncy"))
        h.add(SpringChip.new("smooth", "chip-smooth", id: "chip-smooth"))
        h.add(SpringChip.new("ease-out", "chip-ease", id: "chip-ease"))
      end
      ui.separator

      ui.heading("Ширина на hover: spring(wobbly) · ease-out 150ms")
      ui.horizontal do |h|
        h.add(SpringChip.new("spring", "grow-spring", id: "grow-spring"))
        h.add(SpringChip.new("ease-out", "grow-ease", id: "grow-ease"))
      end
      ui.separator

      ui.label("Спеллинги: transition: spring(bouncy) · transition: width")
      ui.label("spring(0.3, 0.8) 50ms · transition.width: spring(smooth)")
    end
  end
end

Egui.run(SpringApp.new,
  title: "egui.cr — spring transitions", inspector: :hidden)
