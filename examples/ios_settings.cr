# ios_settings.cr — «нативное» мобильное приложение: копия iOS Settings
# (тот же канон, что имитируют React/Vue-киты — Framework7 iOS theme,
# Vant, Ionic). Ничего нового в виджетах нет: строки выкладываются
# вручную (цветная капсула-иконка + заголовок + значение/шеврон/свитч),
# группы — перекрашенный `ui.card`, свитчи — `Egui::Switch` с ECSS-
# правилами под iOS-геометрию и зелёный #34C759, segmented и слайдер —
# классы `segmented`/`slider`. Статус-бар и таб-бар рисуются прямо
# поверх painter'а (двухуровневая структура «статус / контент / табы»).
#
# Запуск: rake build:dev[ios_settings] && ./bin/apps/ios_settings

{% unless env("EGUI_EMBEDDED") %}require "../src/egui/driver_selector"{% end %}

class IosSettingsApp < Egui::App
  # --- iOS light palette --------------------------------------------
  BG        = Egui::Color32.rgb(242, 242, 247)   # grouped background
  CARD      = Egui::Color32.rgb(255, 255, 255)
  LABEL     = Egui::Color32.rgb(0, 0, 0)
  SECONDARY = Egui::Color32.rgb(138, 138, 142)   # #8A8A8E
  SEPARATOR = Egui::Color32.rgb(227, 227, 232)   # hairline
  TINT      = Egui::Color32.rgb(0, 122, 255)     # #007AFF
  CHEVRON   = Egui::Color32.rgb(199, 199, 204)   # #C7C7CC
  HIGHLIGHT = Egui::Color32.rgb(209, 209, 214)   # pressed cell
  TAB_BG    = Egui::Color32.rgb(249, 249, 249)
  TAB_INACT = Egui::Color32.rgb(142, 142, 147)   # #8E8E93
  FIELD     = Egui::Color32.rgb(233, 233, 235)   # search pill fill
  WHITE     = Egui::Color32.rgb(255, 255, 255)

  # --- layout ---------------------------------------------------------
  STATUS_H = 47.0        # status bar slot
  TAB_H    = 49.0        # tab bar slot (no fake safe-area on desktop)
  MARGIN   = 16.0        # inset-group side margin
  ROW_H    = 44.0        # iOS row height
  ICON_BOX = 29.0        # settings icon capsule
  CARD_ROUND = 10.0      # group card corner radius

  # Compile-time lucide glyphs, tinted per use (Icon caches per color).
  macro lucide(name, tint)
    Egui::Icon.from_file(:lucide, {{ name }}, tint: {{ tint }})
  end

  # One row. `svg`/`tint` build the settings-style icon capsule (nil =
  # a plain text row like the detail pages); `sw` is an index into
  # `@sw` (a live switch row), `value` a static right-side text,
  # `dynamic` computes it from state, `chevron` the gray disclosure
  # chevron.
  class Row
    getter title : String
    getter svg : Egui::Svg?
    getter tint : Egui::Color32?
    getter value : String?
    getter dynamic : Symbol?
    getter sw : Int32?
    getter? chevron : Bool
    getter badge : String?

    def initialize(@title, @svg = nil, @tint = nil, @value = nil,
                   @dynamic : Symbol? = nil, @sw : Int32? = nil,
                   @chevron : Bool = true, @badge : String? = nil)
    end
  end

  # Tab bar: {lucide icon, label}.
  TABS = [{:settings, "Настройки"}, {:sun, "Экран"},
          {:smartphone, "Об устройстве"}]

  @tab = 0
  # Switch states by index: 0 авиарежим, 1 wi-fi, 2 bluetooth,
  # 3 true tone, 4 жирный текст.
  @sw : Array(Bool) = [false, true, true, true, false]
  @query = ""
  @appearance = 0
  @text_size = 0
  @brightness = 62.0
  @styled = false

  def update(ctx : Egui::Context) : Nil
    apply_ios_theme(ctx) unless @styled

    ctx.central_panel(scroll: false) do |ui|
      full = ui.max_rect
      ui.painter.rect(full, 0.0, BG)

      draw_status_bar(ui)

      if @tab == 0
        # Large-title navigation (the root page look).
        ui.painter.text(Egui::Pos2.new(MARGIN, STATUS_H + 40.0),
          "Настройки", 34.0, LABEL, bold: true)
        header_h = 62.0
      else
        draw_sub_nav(ui, SUB_TITLES[@tab])
        header_h = 48.0
      end
      ui.allocate_space(Egui::Vec2.new(full.width, STATUS_H + header_h))

      ui.scroll_area(max_height: {ui.available_height - TAB_H, 1.0}.max) do |sc|
        # Inset-group side margins: all cards run in a padded child.
        inner = sc.child_ui(Egui::Rect.from_min_size(
          Egui::Pos2.new(sc.cursor.x + MARGIN, sc.cursor.y),
          Egui::Vec2.new(sc.available_width - MARGIN * 2.0, 1e6)))
        case @tab
        when 0 then draw_settings(inner)
        when 1 then draw_screen(inner)
        else        draw_about(inner)
        end
        # A child_ui does not advance its parent's flow (the Card
        # pattern) — without this the ScrollArea measures the content
        # as empty and there is nothing to scroll.
        sc.min_rect = sc.min_rect.union(inner.min_rect)
        sc.cursor = Egui::Pos2.new(sc.cursor.x, inner.min_rect.bottom)
      end

      draw_tab_bar(ui)
    end
  end

  SUB_TITLES = ["", "Экран и яркость", "Об устройстве"]

  # --- iOS restyling through the global stylesheet --------------------
  private def apply_ios_theme(ctx : Egui::Context) : Nil
    # The default theme is DARK — the search pill's TextEdit (and every
    # other inherited text color) would come out white on light. The
    # iOS look is a light theme; the ECSS rules below restyle on top.
    ctx.theme = Egui::Theme.light
    # The mobile app IS the screen: zero out the central panel's
    # window_padding so nothing insets the content from the edges.
    ctx.style.spacing.window_padding = Egui::Vec2.new(0.0, 0.0)
    sheet = ctx.stylesheet
    # iOS toggle: 51×31 track, green when on, white thumb.
    sheet.rule("switch", Egui::StyleVars{
      "on_color"     => Egui::Color32.rgb(52, 199, 89),
      "off_color"    => Egui::Color32.rgb(233, 233, 235),
      "thumb_color"  => WHITE,
      "track_width"  => 51.0,
      "tumbler_size" => 31.0,
    })
    # Inset group: flat white card, 10pt corners, zero padding — the
    # rows carry their own insets.
    sheet.rule("card", Egui::StyleVars{
      "background" => CARD,
      "rounding"   => CARD_ROUND,
      "padding"    => 0.0,
    })
    sheet.rule("search_bar", Egui::StyleVars{
      "background" => FIELD,
      # Only the right side grows — the clear X's zone (the widget
      # draws the glyph at `right - padding.right + 2`). Left keeps
      # the default 14 (an unset side falls out of the box() cascade
      # as 0), top/bottom keep the default 0.
      "padding.left"  => 14.0,
      "padding.right" => 32.0,
    })
    sheet.rule("slider", Egui::StyleVars{
      # Blue fill AND a visible blue handle (a white handle vanishes
      # on the white card).
      "fill"           => TINT,
      "selection_fill" => TINT,
      # Fixed width: a slider grabs `max(slider_width, available)` —
      # in the brightness row it would starve the right sun and wrap
      # it to the next line.
      "width"          => 220.0,
    })
    # iOS "strong" segmented: borderless gray bezel, raised white
    # selection pill (specs — Framework7 --f7-segmented-strong-*).
    sheet.rule("segmented", Egui::StyleVars{
      "background"      => Egui::Color32.rgb(234, 234, 236),
      "stroke_width"    => 0.0,
      "rounding"        => 9.0,
      "selection_fill"  => WHITE,
      "selection_text"  => LABEL,
      "text_color"      => LABEL,
      "font_size"       => 13.0,
      # A code-side rule() keeps strings as-is (only the .ecss parser
      # converts "100%" to a StyleLength) — build the length explicitly.
      "width"           => Egui::StyleLength.new(100.0, :percent),
      "height"          => 32.0,
      "shadow.color"    => Egui::Color32.rgba(0, 0, 0, 64),
      "shadow.blur"     => 2.0,
      "shadow.y"        => 2.0,
    })
  end

  # --- tab 0: the settings root ----------------------------------------
  private def draw_settings(ui : Egui::Ui) : Nil
    ui.search_bar(@query, "Поиск", id: "search") { |s| @query = s }
    gap(ui, 16.0)
    main_groups.each_with_index do |rows, gi|
      next unless draw_group(ui, "g.#{gi}", rows)
      gap(ui, 22.0)
    end
  end

  private def main_groups : Array(Array(Row))
    [
      [
        Row.new("Авиарежим", lucide(:plane, WHITE),
          Egui::Color32.rgb(255, 149, 0), sw: 0),
        Row.new("Wi-Fi", lucide(:wifi, WHITE), TINT, dynamic: :wifi),
        Row.new("Bluetooth", lucide(:bluetooth, WHITE), TINT, dynamic: :bt),
        Row.new("Мобильная связь", lucide(:antenna, WHITE),
          Egui::Color32.rgb(52, 199, 89), value: "MTS"),
      ],
      [
        Row.new("Уведомления", lucide(:bell, WHITE),
          Egui::Color32.rgb(255, 59, 48), badge: "1"),
        Row.new("Звуки, тактильные сигналы", lucide(:volume_2, WHITE),
          Egui::Color32.rgb(255, 45, 85)),
        Row.new("Не беспокоить", lucide(:moon, WHITE),
          Egui::Color32.rgb(94, 92, 230)),
        Row.new("Экранное время", lucide(:hourglass, WHITE),
          Egui::Color32.rgb(94, 92, 230)),
      ],
      [
        # Заглушки доступных сетей — как на странице Wi-Fi.
        Row.new("home-5G", lucide(:wifi, WHITE), TINT,
          chevron: false),
        Row.new("home-2G", lucide(:wifi, WHITE),
          Egui::Color32.rgb(142, 142, 147), chevron: false),
        Row.new("Neighbours_5G", lucide(:wifi, WHITE),
          Egui::Color32.rgb(142, 142, 147), chevron: false),
        Row.new("TP-LINK_A24F", lucide(:wifi, WHITE),
          Egui::Color32.rgb(142, 142, 147), chevron: false),
        Row.new("MTS_Free", lucide(:wifi, WHITE),
          Egui::Color32.rgb(142, 142, 147), chevron: false),
      ],
      [
        Row.new("Основные", lucide(:settings, WHITE),
          Egui::Color32.rgb(142, 142, 147)),
        Row.new("Пункт управления", lucide(:square_plus, WHITE), TINT),
        Row.new("Экран и яркость", lucide(:sun, WHITE), TINT),
        Row.new("Экран «Домой»", lucide(:grid_2x2, WHITE), TINT),
        Row.new("Универсальный доступ", lucide(:circle_user_round, WHITE),
          TINT),
        Row.new("Обои", lucide(:image, WHITE),
          Egui::Color32.rgb(50, 173, 230)),
      ],
      [
        Row.new("Siri", lucide(:sparkles, WHITE),
          Egui::Color32.rgb(142, 142, 147)),
        Row.new("Face ID и код-пароль", lucide(:scan_face, WHITE),
          Egui::Color32.rgb(52, 199, 89)),
        Row.new("Экстренный вызов — SOS", lucide(:phone, WHITE),
          Egui::Color32.rgb(255, 59, 48)),
        Row.new("Аккумулятор", lucide(:battery_full, WHITE),
          Egui::Color32.rgb(52, 199, 89)),
        Row.new("Конфиденциальность и безопасность",
          lucide(:shield, WHITE), TINT),
      ],
      [
        # Приложения с бейджами непрочитанных уведомлений.
        Row.new("Почта", lucide(:mail, WHITE), TINT, badge: "12"),
        Row.new("Сообщения", lucide(:message_circle, WHITE),
          Egui::Color32.rgb(52, 199, 89), badge: "2"),
        Row.new("Браузер", lucide(:compass, WHITE),
          Egui::Color32.rgb(50, 173, 230), badge: "1"),
      ],
    ]
  end

  # --- tab 1: Экран и яркость ------------------------------------------
  private def draw_screen(ui : Egui::Ui) : Nil
    padded_card(ui, "scr.appearance") do |c|
      c.add(Egui::Label.new("ОФОРМЛЕНИЕ").style do |s|
        s.font_size = 13.0
        s.text_color = SECONDARY
      end)
      c.segmented(@appearance, ["Светлая", "Тёмная"]) { |i| @appearance = i }
    end
    gap(ui, 22.0)

    ui.card(id: "scr.bright") do |c|
      # iOS brightness row: sun — slider — sun, vertically centered,
      # inset from the card edges (the shared `card` rule is padding 0
      # for the settings rows).
      c.flex(justify: :space_between, align: :center,
        margin: Egui::Vec2.new(16.0, 8.0), height: 52.0,
        id: "scr.bright.row") do |f|
        f.child { |k| k.add(lucide(:sun, SECONDARY)) }
        f.child { |k| k.slider(@brightness, 0.0..100.0, id: "scr.brightness") do |v|
          @brightness = v
        end }
        f.child { |k| k.add(lucide(:sun, SECONDARY)) }
      end
    end
    gap(ui, 22.0)

    ui.card(id: "scr.tone") do |c|
      draw_row(c, Row.new("True Tone", sw: 3, chevron: false), first: true)
      draw_row(c, Row.new("Night Shift", value: "22:00 — 07:00"), last: true)
    end
    gap(ui, 22.0)

    padded_card(ui, "scr.text") do |c|
      c.add(Egui::Label.new("ТЕКСТ").style do |s|
        s.font_size = 13.0
        s.text_color = SECONDARY
      end)
      c.segmented(@text_size, ["Мелкий", "Крупный"]) { |i| @text_size = i }
      draw_row(c, Row.new("Жирный текст", sw: 4, chevron: false), last: true)
    end
  end

  # --- tab 2: Об устройстве ---------------------------------------------
  private def draw_about(ui : Egui::Ui) : Nil
    ui.card(id: "ab.main") do |c|
      draw_row(c, Row.new("Имя", value: "iPhone", chevron: false), first: true)
      draw_row(c, Row.new("Версия iOS", value: "18.2", chevron: false),
        false)
      draw_row(c, Row.new("Название модели", value: "iPhone 15 Pro",
        chevron: false), false)
      draw_row(c, Row.new("Номер модели", value: "MU2Q3RU/A",
        chevron: false), false)
      draw_row(c, Row.new("Серийный номер", value: "F2LXC8KQ1P",
        chevron: false), false)
      draw_row(c, Row.new("Емкость", value: "256 ГБ", chevron: false),
        false)
      draw_row(c, Row.new("Доступная емкость", value: "48,4 ГБ",
        chevron: false), last: true)
    end
    gap(ui, 22.0)
    ui.card(id: "ab.warranty") do |c|
      draw_row(c, Row.new("Гарантия", value: "Действует"), first: true, last: true)
    end
  end

  # --- pieces ------------------------------------------------------------

  private def gap(ui : Egui::Ui, h : Float64) : Nil
    ui.allocate_space(Egui::Vec2.new(0.0, h))
  end

  # A group card with real padding: the shared `card` rule is padding 0
  # (the settings rows carry their own insets), but free-form content
  # (captions + segmented) needs the usual 16/12 inset. Same
  # child-flow propagation as the scroll body.
  private def padded_card(ui : Egui::Ui, id : String,
                          &content : Egui::Ui ->) : Nil
    ui.card(id: id) do |c|
      inner = c.child_ui(Egui::Rect.from_min_size(
        Egui::Pos2.new(c.cursor.x + 16.0, c.cursor.y + 12.0),
        Egui::Vec2.new(c.available_width - 32.0, 1e6)))
      content.call(inner)
      c.min_rect = c.min_rect.union(inner.min_rect)
      c.cursor = Egui::Pos2.new(c.cursor.x, inner.min_rect.bottom + 12.0)
    end
  end

  # An inset group: flat white card of rows, hidden when the search
  # query matches nothing in it. Returns false when skipped.
  private def draw_group(ui : Egui::Ui, id : String,
                         rows : Array(Row)) : Bool
    shown = @query.empty? ? rows : rows.select do |r|
      r.title.downcase.includes?(@query.downcase)
    end
    return false if shown.empty?
    ui.card(id: id) do |c|
      shown.each_with_index do |r, i|
        draw_row(c, r, first: i == 0, last: i == shown.size - 1)
      end
    end
    true
  end

  private def draw_row(ui : Egui::Ui, row : Row, first : Bool = false,
                       last : Bool = false) : Nil
    w = ui.available_width
    rect = ui.allocate_at_least(Egui::Vec2.new(w, ROW_H))
    resp = ui.interact(rect, ui.next_widget_id, Egui::Sense.click)
    p = ui.painter
    if resp.active?
      # Pressed highlight: round the corners that sit on the card's
      # rounded corners — the card does not clip children to its
      # rounding, a square fill would poke out.
      p.rect(rect, 0.0, HIGHLIGHT, corners: Egui::CornerRadii.new(
        first ? CARD_ROUND : 0.0, first ? CARD_ROUND : 0.0,
        last ? CARD_ROUND : 0.0, last ? CARD_ROUND : 0.0))
    end

    x = rect.left + 16.0
    sep_inset = x
    if (svg = row.svg) && (tint = row.tint)
      box = Egui::Rect.from_min_size(
        Egui::Pos2.new(x, rect.center.y - ICON_BOX / 2.0),
        Egui::Vec2.new(ICON_BOX, ICON_BOX))
      p.rect(box, 6.5, tint)
      inset = (ICON_BOX - 17.0) / 2.0
      svg.paint(ui, Egui::Rect.from_min_size(
        Egui::Pos2.new(box.left + inset, box.top + inset),
        Egui::Vec2.new(17.0, 17.0)))
      x += ICON_BOX + 12.0
      sep_inset = x
    end

    p.text(Egui::Pos2.new(x, rect.center.y), row.title, 17.0, LABEL)

    value = case row.dynamic
            when :wifi then @sw[1] ? "home-5G" : "Выкл."
            when :bt   then @sw[2] ? "Вкл." : "Выкл."
            else            row.value
            end

    right = rect.right - 16.0
    chev = row.chevron?
    # Right stack, right→left: chevron zone, notification badge, value.
    badge_zone = 0.0
    if (b = row.badge)
      bw = {ui.ctx.fonts_for(nil).measure(b, 13.0).x + 14.0, 20.0}.max
      pill = Egui::Rect.from_min_size(
        Egui::Pos2.new(right - (chev ? 24.0 : 0.0) - bw,
          rect.center.y - 9.5),
        Egui::Vec2.new(bw, 19.0))
      p.rect(pill, 9.5, Egui::Color32.rgb(255, 59, 48))
      p.text(Egui::Pos2.new(pill.center.x -
               ui.ctx.fonts_for(nil).measure(b, 13.0).x / 2.0,
        rect.center.y), b, 13.0, WHITE, bold: true)
      badge_zone = bw + 8.0
    end
    if (v = value)
      vw = ui.ctx.fonts_for(nil).measure(v, 17.0).x
      p.text(Egui::Pos2.new(right - (chev ? 24.0 : 0.0) - badge_zone - vw,
        rect.center.y), v, 17.0, SECONDARY)
    end
    if chev
      Egui::Icons.draw(p, :right,
        Egui::Rect.from_min_size(
          Egui::Pos2.new(right - 16.0, rect.center.y - 7.0),
          Egui::Vec2.new(16.0, 14.0)), CHEVRON)
    end
    if (si = row.sw)
      strip = ui.child_ui(Egui::Rect.from_min_size(
        Egui::Pos2.new(right - 51.0, rect.center.y - 15.5),
        Egui::Vec2.new(51.0, 31.0)))
      sw = strip.add(Egui::Switch.new(@sw[si], id: "sw.#{row.title}"))
      @sw[si] = !@sw[si] if sw.changed?
    end

    # Hairline between rows, inset past the icon like iOS.
    unless last
      p.rect(Egui::Rect.from_min_size(
        Egui::Pos2.new(rect.left + sep_inset, rect.bottom - 1.0),
        Egui::Vec2.new(rect.width - sep_inset, 1.0)), 0.0, SEPARATOR)
    end
  end

  # iOS status bar: time, signal bars, wifi, battery — painter only.
  private def draw_status_bar(ui : Egui::Ui) : Nil
    full = ui.max_rect
    p = ui.painter
    y = 22.0
    p.text(Egui::Pos2.new(27.0, y), "9:41", 15.0, LABEL, bold: true)

    bw = 25.0
    bx = full.right - 16.0 - bw
    p.rect(Egui::Rect.from_min_size(Egui::Pos2.new(bx, y - 6.5),
      Egui::Vec2.new(bw, 13.0)), 4.0, nil,
      Egui::Color32.rgba(0, 0, 0, 90), 1.0)
    p.rect(Egui::Rect.from_min_size(Egui::Pos2.new(bx + 2.5, y - 4.0),
      Egui::Vec2.new(17.0, 8.0)), 2.0, LABEL)
    p.rect(Egui::Rect.from_min_size(
      Egui::Pos2.new(bx + bw + 1.5, y - 2.0), Egui::Vec2.new(1.5, 4.0)),
      1.0, Egui::Color32.rgba(0, 0, 0, 90))

    wx = bx - 28.0
    Egui::Icons.draw(p, :wifi,
      Egui::Rect.from_min_size(Egui::Pos2.new(wx, y - 8.0),
        Egui::Vec2.new(16.0, 16.0)), LABEL)

    sx = wx - 48.0
    [4.0, 6.0, 8.0, 11.0].each_with_index do |h, i|
      p.rect(Egui::Rect.from_min_size(
        Egui::Pos2.new(sx + i * 5.0, y + 5.5 - h),
        Egui::Vec2.new(3.0, h)), 1.0, LABEL)
    end
  end

  # Detail-page navigation bar: small centered title, blue back button.
  private def draw_sub_nav(ui : Egui::Ui, title : String) : Nil
    full = ui.max_rect
    p = ui.painter
    y = STATUS_H + 24.0
    p.text(Egui::Pos2.new(full.center.x -
             ui.ctx.fonts_for(nil).measure(title, 17.0).x / 2.0, y),
      title, 17.0, LABEL, bold: true)

    back = Egui::Rect.from_min_size(Egui::Pos2.new(0.0, STATUS_H),
      Egui::Vec2.new(110.0, 44.0))
    resp = ui.interact(back, ui.next_widget_id, Egui::Sense.click)
    Egui::Icons.draw(p, :left,
      Egui::Rect.from_min_size(Egui::Pos2.new(10.0, y - 8.0),
        Egui::Vec2.new(16.0, 16.0)), TINT)
    p.text(Egui::Pos2.new(30.0, y), "Настройки", 17.0, TINT)
    @tab = 0 if resp.clicked?

    p.rect(Egui::Rect.from_min_size(Egui::Pos2.new(full.left, STATUS_H + 47.0),
      Egui::Vec2.new(full.width, 1.0)), 0.0, SEPARATOR)
  end

  private def draw_tab_bar(ui : Egui::Ui) : Nil
    full = ui.max_rect
    bar = Egui::Rect.from_min_size(
      Egui::Pos2.new(full.left, full.bottom - TAB_H),
      Egui::Vec2.new(full.width, TAB_H))
    p = ui.painter
    p.rect(bar, 0.0, TAB_BG)
    p.rect(Egui::Rect.from_min_size(Egui::Pos2.new(full.left, bar.top),
      Egui::Vec2.new(full.width, 1.0)), 0.0, SEPARATOR)

    slot = full.width / TABS.size
    TABS.each_with_index do |(_, label), i|
      x = full.left + slot * i
      cell = Egui::Rect.from_min_size(Egui::Pos2.new(x, bar.top),
        Egui::Vec2.new(slot, 49.0))
      resp = ui.interact(cell, ui.next_widget_id, Egui::Sense.click)
      @tab = i if resp.clicked?

      color = @tab == i ? TINT : TAB_INACT
      # from_file takes a LITERAL icon name — the per-tab dispatch.
      svg = case i
            when 0 then lucide(:settings, color)
            when 1 then lucide(:sun, color)
            else        lucide(:smartphone, color)
            end
      svg.paint(ui, Egui::Rect.from_min_size(
        Egui::Pos2.new(x + slot / 2.0 - 13.0, bar.top + 5.0),
        Egui::Vec2.new(26.0, 26.0)))
      lw = ui.ctx.fonts_for(nil).measure(label, 10.0).x
      p.text(Egui::Pos2.new(x + slot / 2.0 - lw / 2.0, bar.top + 37.0),
        label, 10.0, color)
    end
  end
end

{% unless env("EGUI_EMBEDDED") %}
Egui.run(IosSettingsApp.new, title: "Настройки — iOS look",
  width: 390, height: 844, inspector: :hidden)
{% end %}
