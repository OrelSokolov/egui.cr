module IosTags
  # ios_tags.cr — кастомные теги iOS-лука для exml-версии «Настроек»
  # (examples/ios_settings_exml.cr, разметка assets/ios_settings.exml,
  # стили assets/ios_settings.ecss). Слой egui.cr §Extensibility:
  # разметка состоит из встроенных тегов и этих.
  #
  # ios-screen   скаффолд экрана: фон, статус-бар, шапка активного
  #              ios-body (large title или sub-nav с back=), тело в
  #              scroll_area (инсет-паддинг 16), таб-бар. Активный
  #              таб — strings["tab"] ("main" | "screen" | "about"),
  #              таб-бар и back-кнопка пишут его прямо в стор.
  # ios-body     пассивная группа контента: show="main" — когда видна.
  # ios-group    инсет-группа строк: карточка + ios-row-дети, фильтр
  #              по strings["query"], хайлайны, first/last-углы.
  # ios-row      строка: title, icon (lucide-имя, runtime Svg.load),
  #              tint (#hex), value ({интерполяция}), switch (слот
  #              bools — живой переключатель), chevron="false".
  # ios-card     карточка с паддингом 16/12: caption? + произвольные
  #              дети (сегменты, слайдеры, одиночные ios-row).
  # ios-search   SearchBar, bind= — слот strings.
  # ios-segmented bind= (слот floats — индекс), options="A|B".
  # ios-slider   bind= (слот floats), 0..100.
  #
  # Геометрия/цвета повторяют examples/ios_settings.cr (ручная версия).

  BG        = Egui::Color32.rgb(242, 242, 247)
  CARD      = Egui::Color32.rgb(255, 255, 255)
  LABEL     = Egui::Color32.rgb(0, 0, 0)
  SECONDARY = Egui::Color32.rgb(138, 138, 142)
  SEPARATOR = Egui::Color32.rgb(227, 227, 232)
  TINT      = Egui::Color32.rgb(0, 122, 255)
  CHEVRON   = Egui::Color32.rgb(199, 199, 204)
  HIGHLIGHT = Egui::Color32.rgb(209, 209, 214)
  TAB_BG    = Egui::Color32.rgb(249, 249, 249)
  TAB_INACT = Egui::Color32.rgb(142, 142, 147)
  WHITE     = Egui::Color32.rgb(255, 255, 255)

  STATUS_H   = 47.0
  TAB_H      = 49.0
  MARGIN     = 16.0
  ROW_H      = 44.0
  ICON_BOX   = 29.0
  CARD_ROUND = 10.0

  # {tab id (strings["tab"]), lucide name, label}.
  TABS = [{"main", "settings", "Настройки"},
          {"screen", "sun", "Экран"},
          {"about", "smartphone", "Об устройстве"}]

  ROOT = File.expand_path("../..", __DIR__)

  @@icons = {} of Tuple(String, Egui::Color32) => Egui::Svg

  # Runtime-иконка: имена приходят из атрибутов разметки, а
  # Icon.from_file — compile-time (литерал). Разбираем файл на месте
  # и кэшируем по (имя, тинт).
  def self.icon(name : String, tint : Egui::Color32) : Egui::Svg
    @@icons[{name, tint}] ||= begin
      path = File.join(ROOT, "icons", "lucide", name.gsub('_', '-') + ".svg")
      Egui::Svg.new(File.read(path), Egui::Vec2.new(24.0, 24.0), tint)
    end
  end

  def self.hex(s : String?) : Egui::Color32?
    return nil unless s && s.starts_with?('#')
    h = s[1..]
    h = h.chars.map { |c| "#{c}#{c}" }.join if h.size == 3
    return nil unless h.size == 6 || h.size == 8
    vals = h.chars.map { |c| c.to_i?(16) || (return nil) }
    pair = ->(i : Int32) { vals[i] * 16 + vals[i + 1] }
    a = h.size == 8 ? pair.call(6).to_u8 : 255u8
    Egui::Color32.new(pair.call(0).to_u8, pair.call(2).to_u8,
      pair.call(4).to_u8, a)
  end

  # интерполированный атрибут ноды
  def self.a(node, rt, key) : String?
    node.attrs[key]?.try { |v| rt.interpolate(v) }
  end

  def self.install(r : Egui::Exml::Renderer) : Nil
    r.on("ios-screen") { |node, ui, ctx, rt, ren| screen(node, ui, ctx, rt, ren) }
    r.on("ios-group") { |node, ui, ctx, rt, ren| group(node, ui, ctx, rt) }
    r.on("ios-card") { |node, ui, ctx, rt, ren| card(node, ui, ctx, rt, ren) }
    r.on("ios-row") { |node, ui, ctx, rt, ren| paint_row(ui, rt, node, first: true, last: true) }
    r.on("ios-search") { |node, ui, ctx, rt, ren| search(node, ui, ctx, rt) }
    r.on("ios-segmented") { |node, ui, ctx, rt, ren| segmented(node, ui, ctx, rt) }
    r.on("ios-slider") { |node, ui, ctx, rt, ren| slider(node, ui, ctx, rt) }
  end

  # ── скаффолд экрана ────────────────────────────────────────────────

  private def self.screen(node, ui : Egui::Ui, ctx, rt, renderer) : Nil
    tab = rt.strings["tab"]? || "main"
    # Корневые табы (tab=) против подстраниц (page=): подстраница
    # накрывает весь экран, включая таб-бар — как в iOS.
    page = rt.strings["page"]? || "root"
    show_tabs = page == "root"
    target = show_tabs ? tab : page
    full = ui.max_rect
    p = ui.painter
    p.rect(full, 0.0, BG)
    status_bar(ui)

    body = node.children.find do |c|
      c.name == "ios-body" && (a(c, rt, "show") || "main") == target
    end
    if body
      title = a(body, rt, "title") || ""
      back = a(body, rt, "back")
      header_h = back ? 48.0 : 62.0
      if back
        sub_nav(ui, full, title, back, rt)
      else
        p.text(Egui::Pos2.new(MARGIN, STATUS_H + 40.0), title, 34.0, LABEL,
          bold: true)
      end
      ui.allocate_space(Egui::Vec2.new(full.width, STATUS_H + header_h))
    end

    ui.scroll_area(max_height: {
      ui.available_height - (show_tabs ? TAB_H : 0.0), 1.0,
    }.max) do |sc|
      inner = sc.child_ui(Egui::Rect.from_min_size(
        Egui::Pos2.new(sc.cursor.x + MARGIN, sc.cursor.y),
        Egui::Vec2.new(sc.available_width - MARGIN * 2.0, 1e6)))
      renderer.render_each(body, inner, ctx, rt) if body
      # child_ui не двигает поток родителя (паттерн Card) — без этого
      # ScrollArea измеряет контент пустым.
      sc.min_rect = sc.min_rect.union(inner.min_rect)
      sc.cursor = Egui::Pos2.new(sc.cursor.x, inner.min_rect.bottom)
    end

    tab_bar(ui, rt) if show_tabs
  end

  # iOS статус-бар: время, антенна, wifi, батарея — painter only.
  private def self.status_bar(ui : Egui::Ui) : Nil
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

  # Шапка внутренней страницы: маленький заголовок по центру, синий back.
  private def self.sub_nav(ui : Egui::Ui, full : Egui::Rect,
                           title : String, back : String, rt) : Nil
    p = ui.painter
    y = STATUS_H + 24.0
    tw = ui.ctx.fonts_for(nil).measure(title, 17.0).x
    p.text(Egui::Pos2.new(full.center.x - tw / 2.0, y), title, 17.0, LABEL,
      bold: true)

    rect = Egui::Rect.from_min_size(Egui::Pos2.new(0.0, STATUS_H),
      Egui::Vec2.new(110.0, 44.0))
    resp = ui.interact(rect, ui.next_widget_id, Egui::Sense.click)
    Egui::Icons.draw(p, :left,
      Egui::Rect.from_min_size(Egui::Pos2.new(10.0, y - 8.0),
        Egui::Vec2.new(16.0, 16.0)), TINT)
    p.text(Egui::Pos2.new(30.0, y), "Настройки", 17.0, TINT)
    if resp.clicked?
      # Возврат на корневой таб: подстраница закрывается, tab не трогаем.
      rt.strings["page"] = "root"
      # Кадр пишется ПОСЛЕ отрисовки тела: без явного перезапроса
      # новый контент появился бы только со следующим событием.
      ui.ctx.request_repaint
    end

    p.rect(Egui::Rect.from_min_size(
      Egui::Pos2.new(full.left, STATUS_H + 47.0),
      Egui::Vec2.new(full.width, 1.0)), 0.0, SEPARATOR)
  end

  private def self.tab_bar(ui : Egui::Ui, rt) : Nil
    full = ui.max_rect
    bar = Egui::Rect.from_min_size(
      Egui::Pos2.new(full.left, full.bottom - TAB_H),
      Egui::Vec2.new(full.width, TAB_H))
    p = ui.painter
    p.rect(bar, 0.0, TAB_BG)
    p.rect(Egui::Rect.from_min_size(Egui::Pos2.new(full.left, bar.top),
      Egui::Vec2.new(full.width, 1.0)), 0.0, SEPARATOR)

    tab = rt.strings["tab"]? || "main"
    slot = full.width / TABS.size
    TABS.each_with_index do |(id, icon_name, label), i|
      x = full.left + slot * i
      cell = Egui::Rect.from_min_size(Egui::Pos2.new(x, bar.top),
        Egui::Vec2.new(slot, 49.0))
      resp = ui.interact(cell, ui.next_widget_id, Egui::Sense.click)
      if resp.clicked?
        rt.strings["tab"] = id
        ui.ctx.request_repaint
      end

      color = tab == id ? TINT : TAB_INACT
      icon(icon_name, color).paint(ui, Egui::Rect.from_min_size(
        Egui::Pos2.new(x + slot / 2.0 - 13.0, bar.top + 5.0),
        Egui::Vec2.new(26.0, 26.0)))
      lw = ui.ctx.fonts_for(nil).measure(label, 10.0).x
      p.text(Egui::Pos2.new(x + slot / 2.0 - lw / 2.0, bar.top + 37.0),
        label, 10.0, color)
    end
  end

  # ── строки ─────────────────────────────────────────────────────────

  private def self.group(node, ui : Egui::Ui, ctx, rt) : Nil
    query = (rt.strings["query"]? || "").downcase
    shown = node.children.select do |c|
      next false unless c.name == "ios-row"
      t = (a(c, rt, "title") || "").downcase
      query.empty? || t.includes?(query)
    end
    return if shown.empty?
    ui.card do |c|
      shown.each_with_index do |ch, i|
        paint_row(c, rt, ch, first: i == 0, last: i == shown.size - 1)
      end
    end
  end

  private def self.paint_row(ui : Egui::Ui, rt, node, first : Bool,
                             last : Bool) : Nil
    w = ui.available_width
    rect = ui.allocate_at_least(Egui::Vec2.new(w, ROW_H))
    resp = ui.interact(rect, ui.next_widget_id, Egui::Sense.click)
    p = ui.painter
    if resp.active?
      p.rect(rect, 0.0, HIGHLIGHT, corners: Egui::CornerRadii.new(
        first ? CARD_ROUND : 0.0, first ? CARD_ROUND : 0.0,
        last ? CARD_ROUND : 0.0, last ? CARD_ROUND : 0.0))
    end

    x = rect.left + 16.0
    sep_inset = x
    if (icon_name = a(node, rt, "icon")) && (tint = hex(a(node, rt, "tint")))
      box = Egui::Rect.from_min_size(
        Egui::Pos2.new(x, rect.center.y - ICON_BOX / 2.0),
        Egui::Vec2.new(ICON_BOX, ICON_BOX))
      p.rect(box, 6.5, tint)
      inset = (ICON_BOX - 17.0) / 2.0
      icon(icon_name, WHITE).paint(ui, Egui::Rect.from_min_size(
        Egui::Pos2.new(box.left + inset, box.top + inset),
        Egui::Vec2.new(17.0, 17.0)))
      x += ICON_BOX + 12.0
      sep_inset = x
    end

    p.text(Egui::Pos2.new(x, rect.center.y),
      a(node, rt, "title") || "", 17.0, LABEL)

    value = a(node, rt, "value")
    right = rect.right - 16.0
    chev = a(node, rt, "chevron") != "false"
    # Right stack, right→left: chevron zone, notification badge, value.
    badge_zone = 0.0
    if (b = a(node, rt, "badge"))
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
    if (nav = a(node, rt, "nav"))
      # Тап по строке-переходу: открыть подстраницу (page=), накрыв
      # весь экран — таб-бар и родительский список уходят под неё.
      rt.strings["page"] = nav if resp.clicked?
      ui.ctx.request_repaint if resp.clicked?
    end
    if (slot = a(node, rt, "switch"))
      strip = ui.child_ui(Egui::Rect.from_min_size(
        Egui::Pos2.new(right - 51.0, rect.center.y - 15.5),
        Egui::Vec2.new(51.0, 31.0)))
      state = rt.bools[slot]? || false
      sw = strip.add(Egui::Switch.new(state, id: "sw.#{slot}"))
      rt.bools[slot] = !state if sw.changed?
    end

    unless last
      p.rect(Egui::Rect.from_min_size(
        Egui::Pos2.new(rect.left + sep_inset, rect.bottom - 1.0),
        Egui::Vec2.new(rect.width - sep_inset, 1.0)), 0.0, SEPARATOR)
      # Rows inside a group sit FLUSH (44pt steps): the flow advance
      # added item_spacing (22 — the GROUP gap) — pull it back.
      sp = ui.style.spacing.item_spacing.y
      ui.cursor = Egui::Pos2.new(ui.cursor.x, ui.cursor.y - sp)
    end
  end

  # ── свободный контент ──────────────────────────────────────────────

  private def self.card(node, ui : Egui::Ui, ctx, rt, renderer) : Nil
    ui.card do |c|
      inner = c.child_ui(Egui::Rect.from_min_size(
        Egui::Pos2.new(c.cursor.x + 16.0, c.cursor.y + 12.0),
        Egui::Vec2.new(c.available_width - 32.0, 1e6)))
      if (cap = a(node, rt, "caption"))
        inner.add(Egui::Label.new(cap).style do |s|
          s.font_size = 13.0
          s.text_color = SECONDARY
        end)
        # Caption sits 8pt above the control, not the group-gap 22.
        sp = inner.style.spacing.item_spacing.y
        inner.cursor = Egui::Pos2.new(inner.cursor.x, inner.cursor.y - (sp - 8.0))
      end
      renderer.render_each(node, inner, ctx, rt)
      c.min_rect = c.min_rect.union(inner.min_rect)
      c.cursor = Egui::Pos2.new(c.cursor.x, inner.min_rect.bottom + 12.0)
    end
  end

  private def self.search(node, ui : Egui::Ui, ctx, rt) : Nil
    key = a(node, rt, "bind") || "query"
    text = rt.strings[key]? || ""
    ui.search_bar(text, a(node, rt, "hint") || "Поиск",
      id: "search.#{key}") { |s| rt.strings[key] = s }
  end

  private def self.segmented(node, ui : Egui::Ui, ctx, rt) : Nil
    key = a(node, rt, "bind") || ""
    labels = (a(node, rt, "options") || "").split('|').reject(&.empty?)
    return if labels.empty?
    ui.segmented((rt.floats[key]? || 0.0).to_i, labels) do |i|
      rt.floats[key] = i.to_f64
    end
  end

  private def self.slider(node, ui : Egui::Ui, ctx, rt) : Nil
    key = a(node, rt, "bind") || ""
    ui.slider(rt.floats[key]? || 0.0, 0.0..100.0, id: "sl.#{key}") do |v|
      rt.floats[key] = v
    end
  end
end
