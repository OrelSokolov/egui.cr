# border-radius через двухконтейнерную модель — буквальный аналог
# вложенных div из CSS:
#
#   .first  { background: darkgray; width: 500px; height: 200px;
#             border-radius: 10px; }                  /* border color */
#   .second { background: gray; width: 490px; height: 190px;
#             position: relative; left: 5px; top: 5px;
#             border-radius: 10px; }                  /* real bg */
#
# Рамка НЕ рисуется штрихом: сначала внешний скруглённый rect цветом
# рамки, поверх — внутренний rect реального фона, смещённый внутрь на
# ширину border (аналог border-width: 5px). Внутренний radius пока не
# уменьшается (как в примере: оба 10px).

require "../src/egui/driver_selector"

module Br
  BG        = Egui::Color32.rgb(0xec, 0xec, 0xec) # body
  DARKGRAY  = Egui::Color32.rgb(0x00, 0x00, 0x00) # .first — border color
  GRAY      = Egui::Color32.rgb(0x80, 0x80, 0x80) # .second
  TEXT      = Egui::Color32.rgb(0x33, 0x33, 0x33)

  # Пересечение двух rect или nil, когда оно пусто (никогда не
  # возвращает инвертированный Rect — нулевой/отрицательный клип это
  # то, из-за чего угловой патч ломался у кромки панели).
  def self.intersect(a : Egui::Rect, b : Egui::Rect) : Egui::Rect?
    x0 = {a.left, b.left}.max
    y0 = {a.top, b.top}.max
    x1 = {a.right, b.right}.min
    y1 = {a.bottom, b.bottom}.min
    Egui::Rect.new(Egui::Pos2.new(x0, y0), Egui::Pos2.new(x1, y1)) if x1 > x0 && y1 > y0
  end

  # Два наложенных rect: .first (цвет рамки) + .second (фон,
  # сдвинутый внутрь на per-side inset — аналог border-width).
  # Внутренний radius по CSS Backgrounds & Borders: радиус угла
  # внутренней кромки = внешний минус ширина границы, в ноль при
  # толстой рамке.
  #
  # Внутренний rect клипится внешней формой: угловой квадратик
  # radius × radius стирается фоном и пересобирается секторами
  # (внешняя дуга + внутренняя со сдвинутым центром). Патч рисуется
  # только в пересечении квадрата с ТЕКУЩИМ клипом художника — угол
  # за кромкой панели (пустое пересечение) просто пропускается,
  # инвертированный клип не возникает.
  def self.nested(ui : Egui::Ui, size : Egui::Vec2,
                  left : Float64, top : Float64,
                  right : Float64, bottom : Float64,
                  radius : Float64, label : String) : Nil
    outer = ui.allocate_at_least(size)
    ui.painter.rect(outer, radius, DARKGRAY)                    # .first
    inner = Egui::Rect.new(
      Egui::Pos2.new(outer.min.x + left, outer.min.y + top),
      Egui::Pos2.new(outer.max.x - right, outer.max.y - bottom))
    w_max = {left, top, right, bottom}.max
    ui.painter.rect(inner, {radius - w_max, 0.0}.max, GRAY)     # .second

    if radius > 0.0
      corners = {
        {Egui::Pos2.new(outer.min.x, outer.min.y), 1, 1, left, top},
        {Egui::Pos2.new(outer.max.x - radius, outer.min.y), -1, 1, right, top},
        {Egui::Pos2.new(outer.max.x - radius, outer.max.y - radius), -1, -1, right, bottom},
        {Egui::Pos2.new(outer.min.x, outer.max.y - radius), 1, -1, left, bottom},
      }
      prev_clip = ui.painter.clip
      corners.each do |sqo, sx, sy, w_h, w_v|
        sq = Egui::Rect.from_min_size(sqo, Egui::Vec2.new(radius, radius))
        # центр внешней дуги: на радиус внутрь от квадратика
        c_out = Egui::Pos2.new(
          sx > 0 ? sqo.x + radius : sqo.x,
          sy > 0 ? sqo.y + radius : sqo.y)
        # внутренний угол и его радиус: r − более сильная из смежных
        # рамок (угол без рамки: r_in = r, диск совпадает с внешним —
        # угол целиком серый; угол с одной стороной — полоса
        # толщины рамки по дуге)
        icx = sx > 0 ? outer.min.x + w_h : outer.max.x - w_h
        icy = sy > 0 ? outer.min.y + w_v : outer.max.y - w_v
        r_in = {radius - {w_h, w_v}.max, 0.0}.max

        eff = intersect(sq, prev_clip)
        # Патчить только ЦЕЛИКОМ видимые углы: частично обрезанный
        # клипом панели патч сам становится артефактом (полудиск).
        # У кромки угол остаётся в простом two-rect виде.
        next unless eff && eff.width >= sq.width && eff.height >= sq.height
        ui.painter.clip = eff
        ui.painter.rect(eff, 0.0, BG)                   # стереть угол
        ui.painter.circle_filled(c_out, radius, DARKGRAY)
        if r_in > 0.0
          c_in = Egui::Pos2.new(
            sx > 0 ? icx + r_in : icx - r_in,
            sy > 0 ? icy + r_in : icy - r_in)
          ui.painter.circle_filled(c_in, r_in, GRAY)
        else
          # толстая рамка: прямой внутренний угол лежит внутри дуги
          if (irect = intersect(inner, eff))
            ui.painter.rect(irect, 0.0, GRAY)
          end
        end
      end
      ui.painter.clip = prev_clip
    end

    font = ui.style.font_size
    tw = ui.ctx.fonts.measure(label, font).x
    ui.painter.text(Egui::Pos2.new(
      inner.min.x + (inner.width - tw) / 2.0, inner.center.y),
      label, font, TEXT)
  end
end

class BorderRadiusApp < Egui::App
  @themed = false

  def update(ctx : Egui::Context) : Nil
    unless @themed
      Egui::DefaultTheme.build("border_radius", dark: false) do |v|
        v.window_fill = Br::BG
        v.panel_fill = Br::BG
        v.text_color = Br::TEXT
        v.window_stroke = Br::BG # page has no window chrome
      end.tap { |t| ctx.theme = t }
      @themed = true
    end

    ctx.central_panel do |ui|
      ui.heading(".first + .second (border-width: 5px, radius 10)")
      Br.nested(ui, Egui::Vec2.new(500.0, 200.0),
        5.0, 5.0, 5.0, 5.0, 10.0,
        "500×200, inner 490×190 at +5,+5")

      ui.separator
      ui.heading("border-width: 1px")
      Br.nested(ui, Egui::Vec2.new(500.0, 110.0),
        1.0, 1.0, 1.0, 1.0, 10.0, "1px")

      ui.separator
      ui.heading("border-width: 10px")
      Br.nested(ui, Egui::Vec2.new(500.0, 110.0),
        10.0, 10.0, 10.0, 10.0, 10.0, "10px")

      ui.separator
      ui.heading("per-side: left 3px, bottom 6px")
      Br.nested(ui, Egui::Vec2.new(500.0, 110.0),
        3.0, 0.0, 0.0, 6.0, 10.0, "left 3 / bottom 6")
    end
  end
end

Egui.run(BorderRadiusApp.new,
  title: "egui.cr — border radius (nested rects)", inspector: :hidden)
