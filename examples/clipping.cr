# Rounded per-side блок (left 3 / bottom 6, radius 10), два способа —
# БЕЗ клипа и БЕЗ маски-кольца, чистое наложение двух rect:
#
#   СЛЕВА — инвариант inner + borders = outer по каждой оси +
#     per-corner радиусы внутреннего: радиус угла = внешний радиус
#     минус смежная граница (сверху рамки нет → 10 и 10−3=7 сверху,
#     10−6=4 снизу). Внутренняя кривая целиком внутри внешней дуги.
#   СПРАВА — маска-кольцо движка (RectCmd#stroke_sides) для сверки.
require "../src/egui/driver_selector"

module Cl
  BLACK = Egui::Color32.rgb(0, 0, 0)
  GRAY  = Egui::Color32.rgb(0x80, 0x80, 0x80)
  BG    = Egui::Color32.rgb(0xec, 0xec, 0xec)
  TEXT  = Egui::Color32.rgb(0x33, 0x33, 0x33)

  # Rounded-блок с per-side рамкой — рамка маской-кольцом движка.
  def self.block(painter : Egui::Painter, outer : Egui::Rect) : Nil
    sides = Egui::StrokeSides.new(
      top: Egui::SideStroke.new(0.0, BLACK),
      right: Egui::SideStroke.new(0.0, BLACK),
      bottom: Egui::SideStroke.new(6.0, BLACK),
      left: Egui::SideStroke.new(3.0, BLACK))
    painter.rect(outer, 10.0, GRAY, BLACK, 1.0, stroke_sides: sides)
  end
end

class ClippingApp < Egui::App
  @themed = false

  def update(ctx : Egui::Context) : Nil
    unless @themed
      Egui::DefaultTheme.build("clipping", dark: false) do |v|
        v.window_fill = Cl::BG
        v.panel_fill = Cl::BG
        v.text_color = Cl::TEXT
        v.window_stroke = Cl::BG
      end.tap { |t| ctx.theme = t }
      @themed = true
    end

    ctx.central_panel do |ui|
      ui.heading("rounded l3/b6: слева наложение с per-corner радиусами — справа маска-кольцо")
      ui.horizontal do |row|
        # ЛЕВЫЙ — простое наложение двух rect, без клипа: внутренний
        # по размеру = внешний минус границы (3 слева, 6 снизу), а его
        # угловые радиусы = внешний минус смежная граница:
        # TL 10−3=7, TR 10−0=10, BR/BL 10−6=4.
        left = row.allocate_at_least(Egui::Vec2.new(340.0, 90.0))
        row.painter.rect(left, 10.0, Cl::BLACK)
        inner = Egui::Rect.new(
          Egui::Pos2.new(left.min.x + 3.0, left.min.y),
          Egui::Pos2.new(left.max.x, left.max.y - 6.0))
        row.painter.rect(inner, 0.0, Cl::GRAY, corners: Egui::CornerRadii.new(
          top_left: 7.0, top_right: 10.0,
          bottom_right: 4.0, bottom_left: 4.0))

        row.label(" ")

        # ПРАВЫЙ — маска-кольцо движка: тот же блок для сверки.
        right = row.allocate_at_least(Egui::Vec2.new(340.0, 90.0))
        Cl.block(row.painter, right)
      end
    end
  end
end

Egui.run(ClippingApp.new,
  title: "egui.cr — rounded: overlay corners vs mask ring", inspector: :hidden)
