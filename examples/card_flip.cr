# egui-cr card flip — порт демо "3D card flip animation"
# (You-Dont-Need-JavaScript) на нативный движок.
#
# Оригинал крутит карту через CSS `perspective` + `rotateY(180deg)` +
# `backface-visibility: hidden` на checkbox-hack'е. Здесь то же самое
# на полном `transform` движка:
#
#   * флип  — scaleX 1 → 0 → 1 (горизонтальное сжатие, классический
#     "fake 3D" флип) + смена стороны на середине пролёта; слегка
#     scaleY для псевдо-наклона;
#   * стороны — div-структура: Джокер из кругов/капсул/букв (спереди),
#     рубашка с орнаментом + аватар (сзади);
#   * кнопка-«checkbox» — Crystal-стейт вместо :checked-hack'а.
#
# Всё через ui.box(transform:) — paint-only, layout на месте.

require "../src/egui/driver_selector"

class CardFlipApp < Egui::App
  BG      = Egui::Color32.rgb(0x24, 0x24, 0x24)
  GHOST   = Egui::Color32.rgb(0xf8, 0xf8, 0xff) # ghostwhite
  OLDLACE = Egui::Color32.rgb(0xfd, 0xf5, 0xe6)
  RED     = Egui::Color32.rgb(0xdc, 0x26, 0x26)
  BLACK   = Egui::Color32.rgb(0x0a, 0x0a, 0x0a)
  GREY    = Egui::Color32.rgb(0x9c, 0x9c, 0x9c)
  BURLY   = Egui::Color32.rgb(0xde, 0xb8, 0x87)
  TEXT    = Egui::Color32.rgb(0xe8, 0xe8, 0xe8)
  MUTED   = Egui::Color32.rgb(0x9a, 0x9a, 0xa2)

  CARD_W = 250.0
  CARD_H = 350.0

  @themed = false
  @flipped = false
  # Прогресс флипа 0..1 (1 = полностью перевёрнута). Двигается к цели
  # каждый кадр — ease-in-out по синусу половинки.
  @flip = 0.0
  @last_t : Float64? = nil

  def update(ctx : Egui::Context) : Nil
    theme_once(ctx)
    now = ctx.input.time
    # Анимация: шаг к цели со скоростью ~2.2 сек^-1 (независимо от FPS
    # грубо; для демо достаточно — request_repaint держит кадры живыми).
    target = @flipped ? 1.0 : 0.0
    if @flip != target
      dir = target > @flip ? 1.0 : -1.0
      step = (now - (@last_t ||= now)) * 2.2
      @flip = (@flip + dir * step).clamp(target < @flip ? target : 0.0,
        target > @flip ? target : 1.0)
      ctx.request_repaint
    end
    @last_t = now

    ctx.central_panel do |ui|
      ui.box(:column, fill: BG, margin: Egui::Vec2.new(16.0, 16.0),
        rounding: 0.0, stroke: nil) do |col|
        col.rich(Egui::RichText.new("3D card flip — transform demo")
          .size(20.0).color(TEXT))
        col.rich(Egui::RichText
          .new("scaleX 1 → 0 → 1 + face swap at the midpoint (fake perspective)")
          .size(11.0).color(MUTED))
        col.box(:row, margin: Egui::Vec2.new(0.0, 8.0)) { }

        col.box(:row, wrap: false, margin: Egui::Vec2.new(0.0, 0.0)) do |stage|
          the_card(stage)
        end

        # Кнопка-переключатель (бывший label checkbox-hack'а).
        col.box(:row, wrap: false, margin: Egui::Vec2.new(0.0, 24.0)) do |bar|
          label = @flipped ? "Front Side" : "Back Side"
          if bar.button(label, id: "flip").clicked?
            @flipped = !@flipped
          end
          bar.rich(Egui::RichText.new("  flip: #{@flip.round(2)}")
            .size(11.0).color(MUTED))
        end
      end
    end
  end

  # --- the card ----------------------------------------------------------

  private def the_card(stage : Egui::Ui) : Nil
    # Половина флипа: 0 → 1 → 0; лицо видно на первой половине.
    half = 1.0 - (@flip * 2.0 - 1.0).abs
    show_front = @flip < 0.5
    sx = 1.0 - 0.94 * half
    sy = 1.0 - 0.10 * half
    # Небольшой наклон вокруг середины пролёта для живости.
    rot = (@flip - 0.5) * 2.0
    tilt = -6.0 * (show_front ? half : -half)
    xf = "rotate(#{tilt.round(2)}deg) scale(#{sx.round(4)}, #{sy.round(4)})"

    stage.box(:column, transform: xf, transform_origin: "center",
      margin: Egui::Vec2.new(0.0, 0.0)) do |card|
      if show_front
        card_front(card)
      else
        card_back(card)
      end
    end
  end

  # Лицевая сторона: упрощённый Джокер из оригинала — буквы, «шляпа»
  # из кругов и капсул, «улыбка». cb-top/cb-bottom зеркальны.
  private def card_front(card : Egui::Ui) : Nil
    card.box(:column, fill: GHOST, rounding: 16.0, stroke: GREY,
      margin: Egui::Vec2.new(0.0, 0.0), width: CARD_W, height: CARD_H) do |face|
      face.box(:column, fill: nil, stroke: nil, rounding: 0.0,
        margin: Egui::Vec2.new(12.0, 12.0)) do |inner|
        joker_half(inner, RED)
        inner.box(:row, margin: Egui::Vec2.new(0.0, 8.0)) { }
        # Нижняя половина — как верхняя, но чёрная (в оригинале это
        # разворот на 180°; здесь просто вторая половина).
        joker_half(inner, BLACK)
      end
    end
  end

  private def joker_half(ui : Egui::Ui, color : Egui::Color32) : Nil
    # J-O-K-E-R вертикально
    ui.box(:row, wrap: false, margin: Egui::Vec2.new(0.0, 4.0)) do |row|
      "JOKER".each_char do |ch|
        row.rich(Egui::RichText.new(ch.to_s).size(19.0).color(color))
      end
    end
    # «Голова»: капсула-колпак + круг-лицо + глаз
    ui.box(:row, wrap: false, margin: Egui::Vec2.new(0.0, 4.0)) do |row|
      row.box(:column, fill: color, rounding: 3.0,
        margin: Egui::Vec2.new(14.0, 10.0)) do |hat|
        hat.box(:row, margin: Egui::Vec2.new(4.0, 8.0)) { }
      end
    end
    ui.box(:row, wrap: false, margin: Egui::Vec2.new(0.0, 2.0)) do |row|
      row.box(:column, fill: GHOST, stroke: color, rounding: 11.0,
        margin: Egui::Vec2.new(10.0, 10.0)) do |face|
        face.box(:row, margin: Egui::Vec2.new(2.0, 2.0)) do |eye|
          eye.box(:column, fill: color, rounding: 1.5,
            margin: Egui::Vec2.new(3.0, 3.0)) { }
        end
      end
    end
    # «Улыбка»: три капсулы
    ui.box(:row, wrap: false, margin: Egui::Vec2.new(0.0, 3.0)) do |row|
      row.box(:column, fill: color, rounding: 5.0,
        margin: Egui::Vec2.new(4.0, 7.0)) { }
      row.box(:column, fill: color, rounding: 5.0,
        margin: Egui::Vec2.new(4.0, 5.0)) { }
      row.box(:column, fill: color, rounding: 5.0,
        margin: Egui::Vec2.new(4.0, 7.0)) { }
    end
  end

  # Рубашка: oldlace-фон, орнамент из полос и точек, «аватар»-круг и
  # подпись (в оригинале — remote-аватар GitHub; здесь локальный круг).
  private def card_back(card : Egui::Ui) : Nil
    card.box(:column, fill: OLDLACE, rounding: 16.0, stroke: GREY,
      margin: Egui::Vec2.new(0.0, 0.0), width: CARD_W, height: CARD_H) do |face|
      # Орнамент: столбики-«точки» по верхней кромке
      face.box(:row, wrap: false, margin: Egui::Vec2.new(12.0, 12.0)) do |strip|
        16.times do
          strip.box(:column, fill: BURLY, rounding: 1.0,
            margin: Egui::Vec2.new(2.0, 6.0)) { }
        end
      end
      # Круг-«аватар»
      face.box(:row, wrap: false, margin: Egui::Vec2.new(12.0, 12.0)) do |circ|
        circ.box(:column, fill: RED, rounding: 38.0,
          margin: Egui::Vec2.new(38.0, 38.0)) do |c|
          c.rich(Egui::RichText.new("e").size(40.0).color(OLDLACE))
        end
      end
      face.box(:column, margin: Egui::Vec2.new(20.0, 8.0)) do |note|
        note.rich(Egui::RichText.new("egui.cr").size(24.0).color(BLACK))
        note.rich(Egui::RichText
          .new("If you have any suggestions please please let me know")
          .size(11.0).color(GREY))
      end
    end
  end

  private def theme_once(ctx : Egui::Context) : Nil
    return if @themed
    Egui::DefaultTheme.build("card-flip", dark: true) do |v|
      v.window_fill = BG
      v.panel_fill = BG
      v.text_color = TEXT
      v.window_stroke = BG
    end.tap { |t| ctx.theme = t }
    @themed = true
  end
end

Egui.run(CardFlipApp.new,
  title: "egui.cr — 3D card flip", inspector: :hidden)
