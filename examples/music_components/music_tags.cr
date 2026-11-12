# music_tags.cr — кастомные теги демо «Raven Music 1:1» (NATIVE_HTML_DEMO,
# этап 2). Приложение Raven объявляет свои теги через Rxml_register_tag
# (Icon/Cover/Visualizer/Heading); здесь тот же слой egui.cr — глобальный
# реестр `widget` (exml.cr §Extensibility): разметка assets/music.exml
# состоит из встроенных тегов (row/column/box/repeat/…) и этих.
#
# Почти всё рисуется painter'ом по прямоугольникам — как Rcustom-виджеты
# Raven. Значения цветов/отступов — из oracle/raven_music/style.css
# (тема Nocturne); номера в комментариях ссылаются на его строки.
require "../../src/egui"
require "./music_library"

module MusicTags
  # слой развёрнутого острова (присваивается тегом <island>)
  class_property island_layer : Egui::LayerId? = nil

  # ── акцент (динамика live-оракула) ──────────────────────────────────
  # Приложение пишет hex акцента в store каждый кадр (follow_cover →
  # make_accent цвета играющей обложки, иначе picked из настроек);
  # до первого кадра — акцент темы Nocturne.
  def self.accent(rt) : Egui::Color32
    hex(rt.string("accent")) || ACCENT
  end

  # ── палитра Nocturne (oracle style.css :root) ──────────────────────
  WINDOW      = Egui::Color32.rgb(0x06, 0x06, 0x09)
  POPUP       = Egui::Color32.rgb(0x1b, 0x1b, 0x24)
  TEXT        = Egui::Color32.rgb(0xf4, 0xf4, 0xf8)
  PLACEHOLDER = Egui::Color32.rgb(0x8a, 0x8a, 0x99)
  MUTED       = Egui::Color32.rgb(0xa3, 0xa3, 0xb4)
  EYEBROW     = Egui::Color32.rgb(0xd6, 0xd6, 0xe2)
  SEPARATOR   = Egui::Color32.rgba(255, 255, 255, 0x14)
  BORDER      = Egui::Color32.rgba(255, 255, 255, 0x12)
  CONTROL     = Egui::Color32.rgba(255, 255, 255, 0x12)
  CONTROL_HOV = Egui::Color32.rgba(255, 255, 255, 0x1f)
  ROW_HOVER   = Egui::Color32.rgba(255, 255, 255, 0x10)
  BAR_BG      = Egui::Color32.rgb(0x05, 0x05, 0x08)
  SEARCH_BG   = Egui::Color32.rgb(0x1e, 0x1e, 0x28)
  ACCENT      = Egui::Color32.rgb(0xb7, 0x9c, 0xff)
  WHITE       = Egui::Color32.rgb(255, 255, 255)
  ICON_FG     = Egui::Color32.rgb(0xc4, 0xc4, 0xd2)

  # Оценка ширины ребёнка строки (для предрасчёта пружин — flex-распре-
  # деления в движке разметки нет, контейнер считает сам по атрибутам).
  def self.estimate_width(node, rt, fonts : Egui::Fonts) : Float64
    case node.name
    when "gap"        then f(node, rt, "w", 0.0)
    when "spring"     then 0.0
    when "t"          then w = f(node, rt, "w", -1.0)
                         w >= 0 ? w : fonts.measure(a(node, rt, "text") || "", f(node, rt, "size", 14.0)).x
    when "ibtn"       then f(node, rt, "btn", 34.0)
    when "cover"      then w = f(node, rt, "w", -1.0)
                         w >= 0 ? w : f(node, rt, "s", 46.0)
    when "icon"       then w = f(node, rt, "w", -1.0)
                         w >= 0 ? w : f(node, rt, "size", 18.0)
    when "vis"        then n = f(node, rt, "n", 4.0)
                         (a(node, rt, "mode") == "np") ? f(node, rt, "w", 288.0)
                           : 2.5 * n + 2.0 * (n - 1.0)
    when "playround"  then f(node, rt, "s", 40.0)
    when "oslider"    then w = f(node, rt, "w", -1.0); w >= 0 ? w : 0.0
    when "ocombo"     then f(node, rt, "w", 160.0)
    when "oswitch"    then 44.0
    when "swatch"     then f(node, rt, "s", 34.0)
    when "avatar"     then f(node, rt, "s", 30.0)
    when "logo"       then f(node, rt, "s", 30.0)
    when "searchpill" then f(node, rt, "w", 280.0)
    when "searchinput" then f(node, rt, "w", 280.0)
    when "chip"       then fonts.measure(a(node, rt, "text") || "", f(node, rt, "fs", 13.0)).x + 28.0
    when "navitem"    then fonts.measure(a(node, rt, "text") || "", f(node, rt, "fs", 15.0)).x + f(node, rt, "size", 24.0) + 16.0 + 2 * f(node, rt, "pad", 6.0)
    when "col", "panel" then w = f(node, rt, "w", -1.0); {w, 0.0}.max
    else 0.0
    end
  end

  # Оценка высоты ребёнка вертикального стека (col центрируется в строке:
  # высоту нужно знать ДО отрисовки — красим уже в центрированном ректе)
  def self.estimate_height(node, rt) : Float64
    case node.name
    when "t"     then h = f(node, rt, "h", -1.0)
                     h >= 0 ? h : f(node, rt, "size", 14.0) * 1.35
    when "gap"   then f(node, rt, "h", 0.0)
    when "vis"   then f(node, rt, "h", 12.0)
    when "cover" then f(node, rt, "h", f(node, rt, "s", 46.0))
    when "icon"  then f(node, rt, "size", 18.0)
    when "col", "column" then node.children.sum { |c| estimate_height(c, rt) }
    when "hbar" then f(node, rt, "h", 56.0)
    else 20.0
    end
  end

  # Ширина одной пружины в строке: (ширина контейнера − сумма оценок детей)
  # делённая на число пружин; 0, если пружин нет.
  def self.spring_width(children, rt, fonts : Egui::Fonts,
                        width : Float64) : Float64
    springs = children.count(&.name.==("spring"))
    return 0.0 if springs == 0
    used = children.sum { |c| estimate_width(c, rt, fonts) }
    {(width - used) / springs, 0.0}.max
  end

  # отладка: MUSIC_GEOM=1 — печатать прямоугольники ключевых тегов (раз)
  @@geom_done = {} of String => Bool

  def self.geom!(key : String, rect : Egui::Rect) : Nil
    return unless ENV["MUSIC_GEOM"]? && !@@geom_done[key]?
    @@geom_done[key] = true
    STDERR.printf("geom %-14s %6.1f %6.1f %6.1f %6.1f\n", key,
      rect.left, rect.top, rect.width, rect.height)
  end

  # пересечение прямоугольников клипа: clip ребёнка не должен расширять
  # клип родителя (Rect ∩ Rect)
  def self.clip_intersect(a : Egui::Rect, b : Egui::Rect) : Egui::Rect
    left = {a.min.x, b.min.x}.max
    top = {a.min.y, b.min.y}.max
    right = {a.max.x, b.max.x}.min
    bottom = {a.max.y, b.max.y}.min
    Egui::Rect.new(Egui::Pos2.new(left, top),
      Egui::Pos2.new({right, left}.max, {bottom, top}.max))
  end

  # ── утилиты ─────────────────────────────────────────────────────────

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

  def self.f(node, rt, key, default : Float64) : Float64
    a(node, rt, key).try(&.to_f?) || default
  end

  def self.b(node, rt, key) : Bool
    v = a(node, rt, key)
    v == "1" || v == "true" || v == "on" || v == "yes"
  end

  # визуализатор — точный порт RaVis из app.js (fake_level из tags.c):
  # бит каждые полсекунды, атака 22 / спад 9 (на паузе 4), уровень паузы
  # 0.08; dt clamp 0.05. Состояние столбиков — по ключу виджета.
  @@vis_state = {} of String => Tuple(Array(Float64), Float64)

  def self.vis_step(key : String, bars : Int32, playing : Bool,
                    now : Float64) : Array(Float64)
    st = @@vis_state[key] ||= {Array.new(bars, 0.08), 0.0}
    levels, last = st
    dt = last > 0 ? {now - last, 0.05}.min : 0.016
    bars.times do |i|
      target = playing ? MusicLibrary.fake_level(i, bars, now) : 0.08
      speed = target > levels[i] ? 22.0 : (playing ? 9.0 : 4.0)
      levels[i] += (target - levels[i]) *
        MusicLibrary.clamp(dt * speed, 0.0, 1.0)
    end
    @@vis_state[key] = {levels, now}
    levels
  end

  # радиальный градиент CSS теперь честный: Gradient с эллиптическими
  # радиусами (400px 200px at 80% 0%) тесселлируется Gouraud-кольцами
  # (sokol #gradient_fill) — вместо концентрических кругов.

  # Мягкое пятно = «div с border-radius:50% + radial-gradient(closest-
  # side, var(--m), transparent 90%) + filter:blur(Npx)» (oracle_live
  # .blob): цвет ЛИНЕЙНО спадает к 90% радиуса ещё внутри элемента, blur
  # лишь размывает этот спад (σ = blur/2) и выпускает хвост за границу.
  # box_shadow здесь не годился — у тени нутро кастера сплошное, и в
  # щелях между панелями mesh читался как плоские полосы. Профиль
  # (свёртка треугольного спада с гауссом) сэмплится в стопы радиального
  # градиента с эллиптическими радиусами (w/2+3σ, h/2+3σ). `opacity` —
  # CSS-opacity блоба (цвет несёт alpha).
  def self.blob(p : Egui::Painter, cx : Float64, cy : Float64,
                w : Float64, h : Float64, color : Egui::Color32,
                opacity : Float64, blur : Float64) : Nil
    a = (color.a.to_f64 * opacity).round.clamp(0.0, 255.0).to_u8
    return if a.zero?
    r = {w, h}.min / 2.0
    return if r < 1.0
    sig = {blur, 0.0}.max / 2.0 # CSS blur: σ = N/2
    stops = [] of Egui::Gradient::Stop
    alpha_at = ->(t : Float64) do # спад 1−|s|/0.9, свёрнутый с гауссом
      v = 0.0
      32.times do |k|
        s = -0.9 + 1.8 * (k + 0.5) / 32.0
        f = 1.0 - s.abs / 0.9
        if f > 0.0
          v += f * Math.exp(-0.5 * ((t - s) / (sig / r)) ** 2)
        end
      end
      (v / 32.0 * 1.8 * r / sig / Math.sqrt(2.0 * Math::PI)).clamp(0.0, 1.0)
    end
    if sig < 1.0 # blur(0): спад без размытия, ступенька на 90%
      stops << Egui::Gradient::Stop.new(0.0, Egui::Color32.new(color.r, color.g, color.b, a))
      stops << Egui::Gradient::Stop.new(0.9,
        Egui::Color32.new(color.r, color.g, color.b, 0u8))
    else
      # хвост 3σ за 90% радиуса; нормирован на радиус пятна (min-ось),
      # эллипс рисуется расширенным на 3σ, стопы пересчитаны в его доли
      tmax = 0.9 + 3.0 * sig / r
      10.times do |i|
        t = tmax * i / 9.0
        v = alpha_at.call(t)
        stops << Egui::Gradient::Stop.new(
          (t * r / (r + 3.0 * sig)).clamp(0.0, 1.0),
          Egui::Color32.new(color.r, color.g, color.b,
            (a.to_f64 * v).round.clamp(0, 255).to_u8))
      end
    end
    rx = w / 2.0 + 3.0 * sig
    ry = h / 2.0 + 3.0 * sig
    rect = Egui::Rect.from_min_size(
      Egui::Pos2.new(cx - rx, cy - ry), Egui::Vec2.new(rx * 2.0, ry * 2.0))
    p.rect(rect, 0.0, gradient: Egui::Gradient.new(:radial, stops,
      cx: 0.5, cy: 0.5, rx: rx, ry: ry))
  end

  # Радиальное пятно-градиент поверх `rect` (radial-gradient у hero и
  # np-artist-card): явные эллиптические радиусы, центр — доли rect,
  # спад к прозрачному на `fade` (0.7 = transparent 70%).
  def self.spot(p : Egui::Painter, rect : Egui::Rect, cx : Float64,
                cy : Float64, rx : Float64, ry : Float64,
                color : Egui::Color32, fade : Float64) : Nil
    return if rect.width < 1.0 || rect.height < 1.0
    grad = Egui::Gradient.new(:radial,
      [Egui::Gradient::Stop.new(0.0, color),
       Egui::Gradient::Stop.new(fade,
         Egui::Color32.new(color.r, color.g, color.b, 0u8))],
      cx: cx, cy: cy, rx: rx, ry: ry)
    p.rect(rect, 0.0, gradient: grad)
  end

  # ── CSS-переходы (style.css: transition … .12–.18s) ────────────────
  # Обёртки над Context#animate_style_*: значение мягко едет к цели
  # (первое появление — snap, как в CSS); пока едет, контекст сам
  # просит перерисовку.

  def self.fade(ctx : Egui::Context, id : Egui::Id, key : String,
                target : Egui::Color32, ms : Float64 = 150.0) : Egui::Color32
    ctx.animate_style_color(id, key, target, ms)
  end

  def self.glide(ctx : Egui::Context, id : Egui::Id, key : String,
                 target : Float64, ms : Float64 = 150.0) : Float64
    ctx.animate_style_scalar(id, key, target, ms)
  end

  def self.lerp(a : Float64, b : Float64, t : Float64) : Float64
    a + (b - a) * t.clamp(0.0, 1.0)
  end

  def self.lerp_color(a : Egui::Color32, b : Egui::Color32,
                      t : Float64) : Egui::Color32
    f = t.clamp(0.0, 1.0)
    Egui::Color32.new(
      MusicTags.lerp(a.r, b.r, f).round.to_u8,
      MusicTags.lerp(a.g, b.g, f).round.to_u8,
      MusicTags.lerp(a.b, b.b, f).round.to_u8,
      MusicTags.lerp(a.a, b.a, f).round.to_u8)
  end

  # appear=/appear-delay=/appear-stagger= панели: входная анимация
  # (Egui::AppearAnims — общий движок с `appear:` в ECSS). Задержка
  # stagger умножается на индекс строки repeat-а — волна входа карточек
  # как CSS animation-delay у nth-child. Transform чисто визуальный:
  # layout панели на месте с первого кадра.
  def self.appear_xf(node, rt, ctx : Egui::Context)
    aname = MusicTags.a(node, rt, "appear")
    return nil unless aname && !ctx.reduced_motion?
    kind = Egui::AppearAnims.kind?(aname)
    return nil unless kind
    delay = MusicTags.f(node, rt, "appear-delay", 0.0) / 1000.0
    stagger = MusicTags.f(node, rt, "appear-stagger", 0.0) / 1000.0
    if rt.is_a?(Egui::Exml::ScopedRuntime) && (idx = rt.repeat_index)
      delay += idx * stagger
    end
    id = Egui::Id.from("#{node.path}/appear")
    xf = ctx.memory.appear_anims.drive(id, kind, delay, ctx.input.time)
    ctx.memory.use_id(id)
    ctx.request_repaint if xf
    xf
  end

  # иконки: имена — из oracle index.html (#i-…), файлы — lucide/bootstrap
  # (Icon.from_file встраивает SVG на компиляции, поэтому case-диспетчер).
  def self.icon(name : String, tint : Egui::Color32) : Egui::Svg
    case name
    when "home"     then Egui::Icon.from_file(:lucide, :house, tint: tint)
    when "search"   then Egui::Icon.from_file(:lucide, :search, tint: tint)
    when "settings" then Egui::Icon.from_file(:lucide, :settings, tint: tint)
    when "library"  then Egui::Icon.from_file(:lucide, :library, tint: tint)
    when "plus"     then Egui::Icon.from_file(:lucide, :plus, tint: tint)
    when "back"     then Egui::Icon.from_file(:lucide, :arrow_left, tint: tint)
    when "note"     then Egui::Icon.from_file(:lucide, :music, tint: tint)
    when "heart"    then Egui::Icon.from_file(:lucide, :heart, tint: tint)
    when "heart-f"  then Egui::Icon.from_file(:bootstrap, :heart_fill, tint: tint)
    when "play"     then Egui::Icon.from_file(:bootstrap, :play_fill, tint: tint)
    when "pause"    then Egui::Icon.from_file(:bootstrap, :pause_fill, tint: tint)
    when "prev"     then Egui::Icon.from_file(:bootstrap, :skip_backward_fill, tint: tint)
    when "next"     then Egui::Icon.from_file(:bootstrap, :skip_forward_fill, tint: tint)
    when "shuffle"  then Egui::Icon.from_file(:lucide, :shuffle, tint: tint)
    when "repeat"   then Egui::Icon.from_file(:lucide, :repeat, tint: tint)
    when "volume"   then Egui::Icon.from_file(:lucide, :volume_2, tint: tint)
    when "mic"      then Egui::Icon.from_file(:lucide, :mic, tint: tint)
    when "queue"    then Egui::Icon.from_file(:lucide, :list, tint: tint)
    when "panel"    then Egui::Icon.from_file(:lucide, :panel_right, tint: tint)
    when "share"    then Egui::Icon.from_file(:lucide, :share_2, tint: tint)
    when "more"     then Egui::Icon.from_file(:lucide, :ellipsis, tint: tint)
    when "close"    then Egui::Icon.from_file(:lucide, :x, tint: tint)
    when "download" then Egui::Icon.from_file(:lucide, :download, tint: tint)
    when "clock"    then Egui::Icon.from_file(:lucide, :clock, tint: tint)
    when "chev"     then Egui::Icon.from_file(:lucide, :chevron_down, tint: tint)
    else                 Egui::Icon.from_file(:lucide, :circle, tint: tint)
    end
  end

  # обложка: вертикальный градиент двух цветов + инициалы (у оригинала
  # 135°, ECSS поддерживает только вертикальный — расхождение зафикси-
  # ровано в README).
  def self.cover(p : Egui::Painter, fonts : Egui::Fonts, rect : Egui::Rect,
                 c1 : Egui::Color32, c2 : Egui::Color32, txt : String,
                 rounding : Float64, fs : Float64) : Nil
    return if rect.width < 1.0 || rect.height < 1.0
    # 135° градиент движка (linear-gradient(135deg)): gouraud-тесселяция
    # по диагонали TL→BR — гладко, без полос
    p.rect_gradient_diag(rect, rounding, c1, c2)
    return if txt.empty?
    m = fonts.measure(txt, fs)
    p.text(Egui::Pos2.new(rect.center.x - m.x / 2.0, rect.center.y),
      txt, fs, Egui::Color32.rgba(255, 255, 255, 0x9A), bold: true)
  end

  # текст с перносом по словам под ширину w (для .desc/.b/.b about-текстов)
  def self.wrap_lines(fonts : Egui::Fonts, text : String, size : Float64,
                      w : Float64) : Array(String)
    lines = [] of String
    text.split('\n').each do |para|
      line = ""
      para.split(' ').each do |word|
        cand = line.empty? ? word : "#{line} #{word}"
        if !line.empty? && fonts.measure(cand, size).x > w
          lines << line
          line = word
        else
          line = cand
        end
      end
      lines << line
    end
    lines
  end
end

# ── теги разметки ──────────────────────────────────────────────────────

# <gap w= h=/> — фиксированный отступ (item_spacing темы = 0, все зазоры
# в разметке явные — как в HTML). В начале строки переноса отступ
# пропускается: хвостовой gap карточного ряда, переехавший на новую
# строку, не должен сдвигать её первый элемент (flex-gap семантика).
widget :gap do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  w = MusicTags.f(node, rt, "w", 0.0)
  h = MusicTags.f(node, rt, "h", 0.0)
  if ui.layout.horizontal? && w > 0 &&
     ui.cursor.x <= ui.max_rect.min.x + 0.5
    next
  end
  # Хвостовой gap, не влезающий в строку, пропускается целиком: сам
  # перенос строки сделает следующий виджет (flex-gap семантика —
  # зазор не сдвигает начало новой строки).
  if ui.layout.horizontal? && w > 0 && ui.wrap_x &&
     ui.cursor.x + w > ui.max_rect.right + 0.5
    next
  end
  ui.allocate_space(Egui::Vec2.new(w, h)) if w > 0 || h > 0
end

# <spring/> — flex:1: строка → вся остаточная ширина, колонка → высота.
widget :spring do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  if ui.layout.horizontal?
    ui.allocate_space(Egui::Vec2.new(ui.available_width, 0.0))
  else
    ui.allocate_space(Egui::Vec2.new(0.0, ui.available_height))
  end
end

# <t text= size= color= bold= w= h= align=l|c|r wrap= lh= ls=/> — painted text.
# ls — letter-spacing в em (CSS .08em): трекинг применяется и к метрике
# (Fonts#with_letter_spacing), и к отрисовке (TextCmd#letter_spacing).
# С явным w= длинный текст усечывается с «…» (text-overflow: ellipsis,
# Fonts#fit) — не жёсткой обрезкой клипа.
widget :t do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  text = MusicTags.a(node, rt, "text") || ""
  size = MusicTags.f(node, rt, "size", 14.0)
  color = MusicTags.hex(MusicTags.a(node, rt, "color")) || MusicTags::TEXT
  bold = MusicTags.b(node, rt, "bold")
  w = MusicTags.f(node, rt, "w", 0.0)
  h = MusicTags.f(node, rt, "h", 0.0)
  align = MusicTags.a(node, rt, "align") || "l"
  ls_px = MusicTags.f(node, rt, "ls", 0.0) * size
  fonts = ui.fonts

  if MusicTags.b(node, rt, "wrap") && w > 0
    lh = size * MusicTags.f(node, rt, "lh", 1.5)
    lines = MusicTags.wrap_lines(fonts, text, size, w)
    rect = ui.allocate_space(Egui::Vec2.new(w, {h, lines.size * lh}.max))
    lines.each_with_index do |line, i|
      lw = fonts.measure(line, size).x
      x = case align
          when "c" then rect.center.x - lw / 2.0
          when "r" then rect.right - lw
          else          rect.left
          end
      ui.painter.text(Egui::Pos2.new(x, rect.top + lh * (i + 0.5)),
        line, size, color, bold: bold)
    end
  else
    # слот w= с усечением: сначала fit («…»), потом метрика усечённого
    if w > 0
      text = fonts.with_letter_spacing(ls_px) { fonts.fit(text, size, w) }
    end
    m = if ls_px != 0.0
          fonts.with_letter_spacing(ls_px) { fonts.measure(text, size) }
        else
          fonts.measure(text, size)
        end
    # явный w= — жёсткий слот: метрика не шире слота после fit
    tw = w > 0 ? w : m.x
    rect = ui.allocate_space(Egui::Vec2.new(
      tw, {h, size * 1.35}.max))
    MusicTags.geom!("t:#{text[0, 14]} #{node.path[-10..]?}", rect)
    lw = m.x
    x = case align
        when "c" then rect.center.x - lw / 2.0
        when "r" then rect.right - lw
        else          rect.left
        end
    ui.painter.text(Egui::Pos2.new(x, rect.center.y), text, size, color,
      bold: bold, letter_spacing: ls_px != 0.0 ? ls_px : nil)
  end
end

# <icon name= size= color= w=/> — векторный глиф; w — ширина слота
# (иконка центрируется, аналог .heart width:32).
widget :icon do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  name = MusicTags.a(node, rt, "name") || "circle"
  size = MusicTags.f(node, rt, "size", 18.0)
  color = MusicTags.hex(MusicTags.a(node, rt, "color")) || MusicTags::ICON_FG
  slot_w = MusicTags.f(node, rt, "w", -1.0)
  rect = ui.allocate_space(Egui::Vec2.new(
    slot_w >= 0 ? slot_w : size, size))
  inner = Egui::Rect.from_min_size(
    Egui::Pos2.new(rect.center.x - size / 2.0, rect.center.y - size / 2.0),
    Egui::Vec2.new(size, size))
  MusicTags.icon(name, color).paint(ui, inner)
end

# <ibtn icon= size= btn= on_click=/> — круглая кнопка-иконка (.icon-btn):
# 34×34, hover → control-подложка, иконка 18. Переходы CSS .15s —
# подложка и цвет глифа мягко едут (animate_style_*).
widget :ibtn do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  name = MusicTags.a(node, rt, "icon") || "circle"
  isz = MusicTags.f(node, rt, "size", 18.0)
  btn = MusicTags.f(node, rt, "btn", 34.0)
  rect = ui.allocate_space(Egui::Vec2.new(btn, btn))
  MusicTags.geom!("ibtn:#{name}", rect)
  id = Egui::Id.from(node.path)
  resp = ui.interact(rect, id, Egui::Sense::Click)
  # .icon-btn:active — pressed #ffffff2b, hover — #ffffff12 (transition)
  hov = MusicTags.glide(ctx, id, "hov",
    resp.active? ? 0x2B : (resp.hovered? ? 0x12 : 0x00), 150.0)
  if hov >= 0.5
    ui.painter.circle_filled(rect.center, btn / 2.0,
      Egui::Color32.new(255, 255, 255, hov.round.to_u8))
  end
  # color= — постоянный тон глифа (активный shuffle/repeat, лайкнутое
  # сердце — цвет акцента); hover мягко ведёт к #fff (.icon-btn:hover)
  tint = MusicTags.hex(MusicTags.a(node, rt, "color"))
  base = tint || MusicTags::ICON_FG
  color = MusicTags.lerp_color(base, MusicTags::WHITE, hov / 0x12)
  inner = Egui::Rect.from_min_size(
    Egui::Pos2.new(rect.center.x - isz / 2.0, rect.center.y - isz / 2.0),
    Egui::Vec2.new(isz, isz))
  MusicTags.icon(name, color).paint(ui, inner)
  if resp.clicked? && (act = MusicTags.a(node, rt, "on_click"))
    rt.fire(act)
  end
end

# <navitem icon= text= active= on_click=/> — пункт сайдбара (.nav-item).
widget :navitem do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  name = MusicTags.a(node, rt, "icon") || "home"
  text = MusicTags.a(node, rt, "text") || ""
  active = MusicTags.b(node, rt, "active")
  w_attr = MusicTags.f(node, rt, "w", -1.0)
  h = MusicTags.f(node, rt, "h", 32.0)
  isz = MusicTags.f(node, rt, "size", 24.0)
  fs = MusicTags.f(node, rt, "fs", 15.0)
  pad = MusicTags.f(node, rt, "pad", 6.0)
  # ширина: в вертикальном потоке — на всю ширину блока (hover-полоса
  # как у block-element HTML), в горизонтальной строке — по контенту
  if w_attr >= 0
    w = w_attr
  elsif ui.layout.horizontal?
    w = pad + isz + 16.0 + ui.fonts.measure(text, fs).x + pad
  else
    w = ui.available_width
  end
  rect = ui.allocate_space(Egui::Vec2.new(w, h))
  id = Egui::Id.from(node.path)
  resp = ui.interact(rect, id, Egui::Sense::Click)
  # hover-полоса и цвет — transition .15s (style.css .nav-item)
  hov = MusicTags.glide(ctx, id, "hov",
    (resp.hovered? && !active) ? 0x10 : 0x00, 150.0)
  if hov >= 0.5
    ui.painter.rect(rect, 6.0,
      fill: Egui::Color32.new(255, 255, 255, hov.round.to_u8))
  end
  fg = active ? MusicTags::WHITE
    : MusicTags.lerp_color(MusicTags::MUTED, MusicTags::WHITE, hov / 0x10)
  cx = rect.left + pad
  MusicTags.icon(name, fg).paint(ui, Egui::Rect.from_min_size(
    Egui::Pos2.new(cx, rect.center.y - isz / 2.0),
    Egui::Vec2.new(isz, isz)))
  ui.painter.text(Egui::Pos2.new(cx + isz + 16.0, rect.center.y),
    text, fs, fg, bold: true)
  if resp.clicked? && (act = MusicTags.a(node, rt, "on_click"))
    rt.fire(act)
  end
end

# <chip text= on=/> — пилюля-фильтр (.chip), 30 высотой.
widget :chip do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  text = MusicTags.a(node, rt, "text") || ""
  on = MusicTags.b(node, rt, "on")
  fs = MusicTags.f(node, rt, "fs", 13.0)
  m = ui.fonts.measure(text, fs)
  w = m.x + 28.0
  rect = ui.allocate_space(Egui::Vec2.new(w, 30.0))
  id = Egui::Id.from(node.path)
  resp = ui.interact(rect, id, Egui::Sense::Click)
  # .chip { transition: background .15s, color .15s } — фон мягко едет
  # между control / control-hover / включённым состоянием
  target = on ? MusicTags::TEXT
    : (resp.hovered? ? MusicTags::CONTROL_HOV : MusicTags::CONTROL)
  bg = MusicTags.fade(ctx, id, "bg", target, 150.0)
  fg = on ? MusicTags::WINDOW : MusicTags::TEXT
  ui.painter.rect(rect, 15.0, fill: bg)
  ui.painter.text(Egui::Pos2.new(rect.center.x - m.x / 2.0, rect.center.y),
    text, fs, fg)
  if resp.clicked? && (act = MusicTags.a(node, rt, "on_click"))
    rt.fire(act)
  end
end

# <cover c1= c2= txt= s= r= fs= shadow=/> — процедурная обложка;
# shadow="1" — мягкая тень как у .np-cover/.hero .cover
# (0 10-14px 30-40px #000000a6).
widget :cover do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  c1 = MusicTags.hex(MusicTags.a(node, rt, "c1")) || MusicTags::ACCENT
  c2 = MusicTags.hex(MusicTags.a(node, rt, "c2")) || c1
  txt = MusicTags.a(node, rt, "txt") || ""
  s = MusicTags.f(node, rt, "s", 46.0)
  w = MusicTags.f(node, rt, "w", s)
  h = MusicTags.f(node, rt, "h", s)
  rounding = MusicTags.b(node, rt, "round") ? {w, h}.min / 2.0
    : MusicTags.f(node, rt, "r", 8.0)
  fs = MusicTags.f(node, rt, "fs", {h * 0.34, 12.0}.max)
  rect = ui.allocate_space(Egui::Vec2.new(w, h))
  if MusicTags.b(node, rt, "shadow")
    ui.painter.box_shadow(rect,
      Egui::Color32.rgba(0, 0, 0, 0xA6), h >= 200 ? 38.0 : 28.0, rounding,
      6.0, Egui::Vec2.new(0.0, h >= 200 ? 13.0 : 10.0))
  end
  MusicTags.geom!("cover:#{txt} #{node.path[-8..]?} #{w}x#{h}", rect)
  MusicTags.cover(ui.painter, ui.fonts, rect, c1, c2, txt, rounding, fs)
end

# <vis n= h= mode=mini|np color=/> — визуализатор («звуковые столбики»).
# CSS-анимаций в ECSS нет — это painter-виджет, как <Visualizer> Raven:
# паттерн высот из статического оракула × уровень level(t, i); пока
# «играет», сам просит следующий кадр.
widget :vis do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  # show= — условное отображение (напр. столбики только на играющей
  # карточке quick): пустое значение → не занимает места
  if (show = node.attrs["show"]?) && !MusicTags.b(node, rt, "show")
    next
  end
  n = MusicTags.f(node, rt, "n", 4.0).to_i
  h = MusicTags.f(node, rt, "h", 12.0)
  minh = MusicTags.f(node, rt, "min", 2.0)
  playing = !MusicTags.b(node, rt, "paused")
  color = MusicTags.hex(MusicTags.a(node, rt, "color")) || MusicTags.accent(rt)
  mode = MusicTags.a(node, rt, "mode") || "mini"

  t = ctx.input.time
  levels = MusicTags.vis_step(node.path, n, playing, t)

  if mode == "np"
    w = MusicTags.f(node, rt, "w", 288.0)
    rect = ui.allocate_space(Egui::Vec2.new(w, h))
    gap = 3.0
    bw = (w - gap * (n - 1)) / n
    n.times do |i|
      # RaVis: height = max(level*h, min), opacity = 0.55+0.45*level
      bh = {levels[i] * h, minh}.max
      a = ((0.55 + 0.45 * levels[i]) * 255.0).round.clamp(0, 255).to_u8
      x = rect.left + i * (bw + gap)
      ui.painter.rect(Egui::Rect.from_min_size(
        Egui::Pos2.new(x, rect.bottom - bh), Egui::Vec2.new(bw, bh)),
        2.0, fill: Egui::Color32.new(color.r, color.g, color.b, a))
    end
  else
    bw = 2.5
    gap = 2.0
    w = bw * n + gap * (n - 1)
    rect = ui.allocate_space(Egui::Vec2.new(w, h))
    n.times do |i|
      bh = {levels[i] * h, minh}.max
      a = ((0.55 + 0.45 * levels[i]) * 255.0).round.clamp(0, 255).to_u8
      x = rect.left + i * (bw + gap)
      ui.painter.rect(Egui::Rect.from_min_size(
        Egui::Pos2.new(x, rect.bottom - bh), Egui::Vec2.new(bw, bh)),
        1.0, fill: Egui::Color32.new(color.r, color.g, color.b, a))
    end
  end
  ctx.request_repaint if playing
end

# <mesh c1= c2= c3= fx= animate=/> — mesh-фон (.mesh + .fx1–.fx4):
# мягкие пятна в цветах играющей обложки (app.js: meshStyle —
# c1×0.55, c2×0.35, c1×0.35). Каждое пятно — #blob: радиальный
# градиент closest-side с размытием (radial-gradient(…, transparent 90%)
# + filter:blur — как .blob в style.css). fx= — вариант фона из настроек (EFFECTS: 0 Mesh,
# 1 Aurora, 2 Plasma, 3 Spotlight, 4 Shimmer; 5 None — панель скрыта
# if=-ом). animate=1 — пятна плывут (CSS keyframes drift1-3: амплитуда
# и период — из style.css), окно перерисовывается.
widget :mesh do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  rect = Egui::Rect.new(ui.cursor,
    Egui::Pos2.new(ui.max_rect.right, ui.max_rect.bottom))
  next if rect.width < 1.0
  p = ui.painter
  c1 = MusicTags.hex(MusicTags.a(node, rt, "c1")) ||
       Egui::Color32.rgba(0x3b, 0x2a, 0x6e, 0xCC)
  c2 = MusicTags.hex(MusicTags.a(node, rt, "c2")) ||
       Egui::Color32.rgba(0x0e, 0x3b, 0x4a, 0xB3)
  c3 = MusicTags.hex(MusicTags.a(node, rt, "c3")) ||
       Egui::Color32.rgba(0x2d, 0x1b, 0x4e, 0x99)
  fx = MusicTags.f(node, rt, "fx", 0.0).to_i.clamp(0, 4)
  t = ctx.input.time
  animate = MusicTags.b(node, rt, "animate")

  # Блоб: базовый прямоугольник (x, y — центр), цвета/прозрачность и
  # параметры дрейфа (амплитуды в px; ω = π/T — полупериод, как CSS
  # alternate). Геометрия — 1:1 из style.css (.blob, .fx1–.fx4).
  bx = ->(cx : Float64, cy : Float64, w : Float64, h : Float64,
          color : Egui::Color32, op : Float64, blur : Float64,
          ax : Float64, ay : Float64, period : Float64, ph : Float64,
          scale_amp : Float64) do
    s = Math.sin(t * Math::PI / period + ph)
    dx = animate ? s * ax : 0.0
    dy = animate ? Math.cos(t * Math::PI / period + ph) * ay : 0.0
    k = 1.0 + (animate ? scale_amp * (1.0 + s) / 2.0 : scale_amp / 2.0)
    MusicTags.blob(p, cx + dx, cy + dy, w * k, h * k, color, op, blur)
  end

  w = rect.width
  hgt = rect.height
  case fx
  when 1 # Aurora (.fx1): широкие плоские полосы, медленнее
    bx.call(rect.left - 240.0 + 700.0, rect.top - 60.0 + 210.0,
      1400.0, 420.0, c1, 0.8, 90.0, 140.0, 70.0, 70.0, 0.0, 0.09)
    bx.call(rect.left + w + 300.0 - 750.0, rect.top + 300.0 + 190.0,
      1500.0, 380.0, c2, 0.75, 90.0, -120.0, 90.0, 80.0, 2.0, 0.09)
    bx.call(rect.left + w * 0.30 + 390.0, rect.top + hgt + 340.0 - 390.0,
      780.0, 780.0, c3, 0.3, 90.0, -160.0, -80.0, 52.0, 4.0, 0.15)
  when 2 # Plasma (.fx2): четвёртое пятно, всё быстрее и резче
    bx.call(rect.left - 160.0 + 430.0, rect.top - 200.0 + 320.0,
      860.0, 640.0, c1, 0.8, 70.0, 140.0, 70.0, 30.0, 0.0, 0.09)
    bx.call(rect.left + w + 220.0 - 500.0, rect.top - 140.0 + 360.0,
      1000.0, 720.0, c2, 0.75, 70.0, -120.0, 90.0, 30.0, 2.0, 0.09)
    bx.call(rect.left + w * 0.30 + 390.0, rect.top + hgt + 340.0 - 390.0,
      780.0, 780.0, c3, 0.5, 70.0, -160.0, -80.0, 30.0, 4.0, 0.15)
    bx.call(rect.left + w * 0.55 + 320.0, rect.top + hgt * 0.30 + 320.0,
      640.0, 640.0, c2, 0.45, 70.0, 140.0, -70.0, 26.0, 1.0, 0.18)
  when 3 # Spotlight (.fx3): одно огромное пятно сверху
    bx.call(rect.left + w * 0.32 + 600.0, rect.top - 320.0 + 450.0,
      1200.0, 900.0, c1, 0.9, 90.0, 140.0, 70.0, 46.0, 0.0, 0.09)
  when 4 # Shimmer (.fx4): всё тусклее, шире и медленнее
    bx.call(rect.left - 160.0 + 430.0, rect.top - 200.0 + 320.0,
      860.0, 640.0, c1, 0.3, 120.0, 140.0, 70.0, 90.0, 0.0, 0.09)
    bx.call(rect.left + w + 220.0 - 500.0, rect.top - 140.0 + 360.0,
      1000.0, 720.0, c2, 0.3, 120.0, -120.0, 90.0, 90.0, 2.0, 0.09)
    bx.call(rect.left + w * 0.30 + 390.0, rect.top + hgt + 340.0 - 390.0,
      780.0, 780.0, c3, 0.3, 120.0, -160.0, -80.0, 90.0, 4.0, 0.15)
  else   # Mesh (по умолчанию): геометрия .blob из style.css
    bx.call(rect.left - 160.0 + 430.0, rect.top - 200.0 + 320.0,
      860.0, 640.0, c1, 0.8, 90.0, 140.0, 70.0, 46.0, 0.0, 0.09)
    bx.call(rect.left + w + 220.0 - 500.0, rect.top - 140.0 + 360.0,
      1000.0, 720.0, c2, 0.75, 90.0, -120.0, 90.0, 58.0, 2.0, 0.09)
    bx.call(rect.left + w * 0.30 + 390.0, rect.top + hgt + 340.0 - 390.0,
      780.0, 780.0, c3, 0.5, 90.0, -160.0, -80.0, 52.0, 4.0, 0.15)
  end
  ctx.request_repaint if animate
end

# <panel class= w= h= dir=row|column pad= appear= appear-delay=
# appear-stagger= rgrad=/> — контейнер, красящий своё «хромовое»
# покрытие из ECSS-правила класса (background/stroke/stroke-width/
# rounding/padding.*, :hover-правило, transition: background <ms>,
# background-gradient) — аналог .surface оракула. appear= — входная
# анимация (appear: rise/fade/…, Egui::AppearAnims); appear-stagger=
# умножается на индекс строки repeat-а (волна карточек CSS
# card-in с задержками nth-child). rgrad= — радиальный градиент
# поверх фона (radial-gradient(...) из store, следует за обложкой).
widget :panel do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  cls = MusicTags.a(node, rt, "class") || ""
  w_attr = MusicTags.f(node, rt, "w", -1.0)
  h_attr = MusicTags.f(node, rt, "h", -1.0)
  w = w_attr >= 0 ? w_attr : ui.available_width
  h = h_attr >= 0 ? h_attr : ui.available_height
  if h_attr.zero? # h="0": высота по содержимому (CSS height:auto)
    bg_index = ui.painter.add_noop
    content = ui.child_ui(
      Egui::Rect.from_min_size(ui.cursor, Egui::Vec2.new(w, 1e6)),
      Egui::Id.from("#{node.path}/content"), layout: Egui::Layout.top_down)
    content.clip = MusicTags.clip_intersect(
      Egui::Rect.from_min_size(ui.cursor, Egui::Vec2.new(w, 1e6)), ui.clip)
    r.render_each(node, content, ctx, rt)
    h = {content.min_rect.height, 1.0}.max
    rect = ui.allocate_space(Egui::Vec2.new(w, h))
    MusicTags.geom!("panel:#{cls} #{rect.left}/#{rect.top}", rect)
    cvars = ctx.stylesheet.resolve(cls)
    if (bg = cvars.color?("background"))
      ui.painter.set(bg_index, Egui::RectCmd.new(ui.painter.clip, rect,
        cvars.f64("rounding", 8.0), bg, cvars.color?("stroke"),
        cvars.f64("stroke_width", 1.0), nil, nil))
    end
    next
  end
  rect = ui.allocate_space(Egui::Vec2.new(w, h))
  MusicTags.geom!("panel:#{cls} #{node.path[-10..]?} #{rect.left}/#{rect.top}", rect) if cls != ""
  # :hover-правило класса (album-card:hover …): interact всегда с
  # Sense::Click — Memory#interact не даёт hover виджетам без sense-флагов
  # (Sense::None ⇒ hovered всегда false); клик без on_click просто ничего
  # не делает, как block-element в HTML
  clickable = node.attrs["on_click"]?
  resp = ui.interact(rect, Egui::Id.from("#{node.path}/hover"),
    Egui::Sense::Click)
  hovered = resp.hovered?
  cvars = ctx.stylesheet.resolve(cls)
  hvars = ctx.stylesheet.resolve(cls, "hover")
  vars = hovered ? hvars : cvars
  p = ui.painter
  prev_clip = p.clip
  p.clip = rect
  # фон: базовый ↔ hover с переходом `transition: background <ms>`
  # (ECSS); без правила — snap, как в CSS
  bg_base = cvars.color?("background")
  bg_hover = hvars.color?("background") || bg_base
  tms = hvars.f64?("transition.background") || hvars.f64?("transition") ||
        cvars.f64?("transition.background") || cvars.f64?("transition") ||
        0.0
  bg = nil
  if bg_hover
    # цели перехода: при отведении фона нет — едем к прозрачному
    rest = bg_base ||
      Egui::Color32.new(bg_hover.r, bg_hover.g, bg_hover.b, 0u8)
    target = hovered ? bg_hover : rest
    bg = if tms > 0.0
          MusicTags.fade(ctx, Egui::Id.from("#{node.path}/hover"), "bg",
            target, tms)
        else
          target
        end
  end
  grad = vars.gradient?("background-gradient") ||
         MusicTags.a(node, rt, "rgrad").try { |s| Egui::Gradient.parse?(s) }
  if bg || grad
    p.rect(rect, vars.f64("rounding", 8.0), fill: bg,
      stroke_color: vars.color?("stroke"),
      stroke_width: vars.f64("stroke_width", 1.0), gradient: grad)
  end
  # appear= — входная анимация (paint-only transform, layout на месте)
  xf = MusicTags.appear_xf(node, rt, ctx)
  if xf
    p.push_transform(rect.center, xf[:sx], xf[:sy], xf[:dx], xf[:dy],
      xf[:opacity])
  end
  pad = vars.box("padding")
  padx = MusicTags.f(node, rt, "padx", -1.0)
  inner = Egui::Rect.new(
    Egui::Pos2.new(rect.left + (padx >= 0 ? padx : pad.left),
      rect.top + pad.top),
    Egui::Pos2.new(rect.right - (padx >= 0 ? padx : pad.right),
      rect.bottom - pad.bottom))
  dir = MusicTags.a(node, rt, "dir") || "column"
  # bounded=1: регион ребёнка ограничен видимой высотой панели (без 1e9) —
  # для родителей скроллируемых детей (center → center-page)
  child_bottom_unbounded = !MusicTags.b(node, rt, "bounded")
  if MusicTags.b(node, rt, "scroll")
    # скроллируемая панель: фон + ScrollArea в holder-регионе панели
    # (прокрутка контента как у live-версии / ScrollBox Raven)
    holder = ui.child_ui(inner, Egui::Id.from("#{node.path}/scroll"))
    holder.clip = MusicTags.clip_intersect(inner, ui.clip)
    holder.scroll_area do |scroll|
      r.render_each(node, scroll, ctx, rt)
    end
    p.pop_transform(rect.center) if xf
    p.clip = prev_clip
    next
  end
  child = ui.child_ui(
    # Нижняя граница полубесконечна: контент оракула переливается через
    # низ панели и обрезается clip'ом (CSS overflow:hidden); allocate_space
    # иначе клампит высоту вложенных виджетов в остаток региона.
    Egui::Rect.new(inner.min,
      Egui::Pos2.new(inner.right,
        dir == "row" || !child_bottom_unbounded ? inner.bottom : 1e9)),
    Egui::Id.from(node.path),
    layout: dir == "row" ? Egui::Layout.left_to_right : Egui::Layout.top_down)
  child.wrap_x = true if dir == "row" # сетки карточек переносятся
  child.clip = MusicTags.clip_intersect(inner, ui.clip)
  if dir == "row"
    sw = MusicTags.spring_width(node.children, rt, ui.fonts, inner.width)
    spacing = MusicTags.f(node, rt, "spacing", -1.0)
    first = true
    node.children.each do |cn|
      if cn.name == "spring"
        child.allocate_space(Egui::Vec2.new(sw, 0.0))
      elsif spacing >= 0 && cn.name == "gap"
        next # зазоры управляются контейнером (spacing=)
      else
        if spacing >= 0 && !first
          child.allocate_space(Egui::Vec2.new(spacing, 0.0))
        end
        r.render(cn, child, ctx, rt)
        first = false
      end
    end
  else
    r.render_each(node, child, ctx, rt)
  end
  p.pop_transform(rect.center) if xf
  p.clip = prev_clip
  if resp.clicked? && (act = clickable)
    rt.fire(rt.interpolate(act))
  end
end

# <crow gap= pad=> — горизонтальный ряд КАРТОЧЕК без переноса: правая и
# нижняя границы полубесконечны (карточки за краем обрезаются clip'ом,
# как overflow:hidden карточного ряда оракула; allocate_space иначе
# сжимает карточку в остаточную ширину строки).
widget :crow do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  gap = MusicTags.f(node, rt, "gap", 4.0)
  pad = MusicTags.f(node, rt, "pad", 0.0)
  h = MusicTags.f(node, rt, "h", 234.0)
  rect = ui.allocate_space(Egui::Vec2.new(ui.available_width, h))
  child = ui.child_ui(
    Egui::Rect.new(
      Egui::Pos2.new(rect.left + pad, rect.top),
      Egui::Pos2.new(1e9, 1e9)),
    Egui::Id.from(node.path), layout: Egui::Layout.left_to_right)
  child.wrap_x = false
  # клип по ВЕРТИКАЛИ тоже: карточный ряд — окно высотой h (overflow:
  # hidden), обложки-слайвы обрезаются снизу
  child.clip = MusicTags.clip_intersect(Egui::Rect.new(rect.min,
    Egui::Pos2.new(ui.max_rect.right, rect.bottom)), ui.clip)
  node.children.each_with_index do |cn, i|
    r.render(cn, child, ctx, rt)
    child.allocate_space(Egui::Vec2.new(gap, 0.0)) if gap > 0
  end
end

# <hline pad=/> — разделитель 1px (.sep / .col-sep); pad — боковые поля.
widget :hline do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  pad = MusicTags.f(node, rt, "pad", 0.0)
  w = MusicTags.f(node, rt, "w", -1.0)
  w = ui.available_width - 2 * pad if w < 0
  rect = ui.allocate_space(Egui::Vec2.new({w, 0.0}.max, 1.0))
  ui.painter.rect(rect, 0.0, fill: MusicTags::SEPARATOR)
end

# <searchpill/> — поле поиска в шапке (статичный placeholder).
widget :searchpill do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  text = MusicTags.a(node, rt, "text") || "What do you want to play?"
  w = MusicTags.f(node, rt, "w", 280.0)
  rect = ui.allocate_space(Egui::Vec2.new(w, 40.0))
  p = ui.painter
  p.rect(rect, 20.0, fill: MusicTags::SEARCH_BG)
  MusicTags.icon("search", Egui::Color32.rgba(0x8a, 0x8a, 0x99, 0xB3))
      .paint(ui, Egui::Rect.from_min_size(
        Egui::Pos2.new(rect.left + 14.0, rect.center.y - 9.0),
        Egui::Vec2.new(18.0, 18.0)))
  ui.painter.text(Egui::Pos2.new(rect.left + 42.0, rect.center.y),
    text, 14.0, MusicTags::PLACEHOLDER)
end

# <searchinput bind= w=> — поле поиска: та же пилюля, но с живым вводом
# (клик — фокус, Input.text добавляет символы, Backspace режет).
widget :searchinput do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  key = node.attrs["bind"]? || "query"
  hint = MusicTags.a(node, rt, "text") || "What do you want to play?"
  w = MusicTags.f(node, rt, "w", 280.0)
  rect = ui.allocate_space(Egui::Vec2.new(w, 40.0))
  focused = rt.string("_focus") == key
  resp = ui.interact(rect, Egui::Id.from(node.path), Egui::Sense::Click)
  if resp.clicked?
    rt.strings["_focus"] = key
    ctx.request_repaint
  end
  if focused && ctx.input.key_pressed?(Egui::KeyCode::Escape)
    if ctx.input.consume_key(Egui::KeyCode::Escape)
      rt.strings["_focus"] = "" # blur, текст сохраняется (как у Vue)
      ctx.request_repaint
    end
  end
  if focused
    txt = rt.string(key)
    add = ctx.input.text
    if !add.empty? && !ctx.input.shortcut_modifiers_down?
      rt.strings[key] = (txt + add)[0, 40]
      MusicTags.search_changed(rt, ctx)
    end
    if ctx.input.key_pressed?(Egui::KeyCode::Backspace)
      if ctx.input.consume_key(Egui::KeyCode::Backspace)
        t = rt.string(key)
        rt.strings[key] = t.size > 1 ? t[0...-1] : ""
        MusicTags.search_changed(rt, ctx)
      end
    end
    ctx.request_repaint
  end
  p = ui.painter
  # focus-within: обводка 1px цветом акцента (как .search-pill:focus-within)
  p.rect(rect, 20.0, fill: MusicTags::SEARCH_BG,
    stroke_color: focused ? MusicTags::ACCENT : nil,
    stroke_width: 1.0)
  MusicTags.icon("search", Egui::Color32.rgba(0x8a, 0x8a, 0x99, 0xB3)).paint(ui,
    Egui::Rect.from_min_size(
      Egui::Pos2.new(rect.left + 14.0, rect.center.y - 9.0),
      Egui::Vec2.new(18.0, 18.0)))
  txt = rt.string(key)
  if txt.empty?
    ui.painter.text(Egui::Pos2.new(rect.left + 42.0, rect.center.y),
      hint, 14.0, MusicTags::PLACEHOLDER)
  else
    m = ui.fonts.measure(txt, 14.0)
    caret_x = rect.left + 42.0 + {m.x, rect.width - 60.0}.min
    ui.painter.text(Egui::Pos2.new(rect.left + 42.0, rect.center.y),
      txt[0, 28], 14.0, MusicTags::TEXT)
    # мигающий курсор
    if (ctx.input.time * 2.0).to_i % 2 == 0
      ui.painter.rect(Egui::Rect.from_min_size(
        Egui::Pos2.new(caret_x + 1.0, rect.center.y - 8.0),
        Egui::Vec2.new(1.0, 16.0)), 0.0, fill: MusicTags::TEXT)
    end
  end
end

# хук поиска: перезаполняется приложением (см. music_exml.cr)
def MusicTags.search_changed(rt, ctx) : Nil
  if (act = rt.actions["search_changed"]?)
    act.call
  end
end

# <avatar/> — круг M в шапке.
widget :avatar do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  s = MusicTags.f(node, rt, "s", 30.0)
  rect = ui.allocate_space(Egui::Vec2.new(s, s))
  p = ui.painter
  p.circle_filled(rect.center, s / 2.0, Egui::Color32.rgb(0xe8, 0xa9, 0x3b))
  m = ui.fonts.measure("M", 14.0)
  p.text(Egui::Pos2.new(rect.center.x - m.x / 2.0, rect.center.y),
    "M", 14.0, MusicTags::WINDOW, bold: true)
end

# <logo/> — белый скруглённый квадрат с нотой.
widget :logo do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  s = MusicTags.f(node, rt, "s", 30.0)
  isz = MusicTags.f(node, rt, "size", 18.0)
  rect = ui.allocate_space(Egui::Vec2.new(s, s))
  ui.painter.rect(rect, 9.0, fill: MusicTags::WHITE)
  MusicTags.icon("note", MusicTags::WINDOW).paint(ui,
    Egui::Rect.from_min_size(
      Egui::Pos2.new(rect.center.x - isz / 2.0, rect.center.y - isz / 2.0),
      Egui::Vec2.new(isz, isz)))
end

# <playround icon= s=/> — круглая кнопка play/pause (.play-round) или
# большая (.play-big, s=56). Hover — scale(1.06)+brightness, :active —
# scale(.95/.97): transition .12s, масштаб мягко едет.
widget :playround do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  name = MusicTags.a(node, rt, "icon") || "pause"
  s = MusicTags.f(node, rt, "s", 40.0)
  isz = MusicTags.f(node, rt, "size", s * 0.45)
  big = MusicTags.b(node, rt, "big")
  rect = ui.allocate_space(Egui::Vec2.new(s, s))
  MusicTags.geom!("playround:#{name}", rect)
  id = Egui::Id.from(node.path)
  resp = ui.interact(rect, id, Egui::Sense::Click)
  bg = big ? MusicTags.accent(rt) : MusicTags::TEXT
  fg = MusicTags::WINDOW
  sc = MusicTags.glide(ctx, id, "scale",
    resp.active? ? (big ? 0.97 : 0.95) : (resp.hovered? ? 1.06 : 1.0), 120.0)
  # filter: brightness — play-big светлеет (+8%), play-round чуть
  # темнеет (−4%); глубина = доля hover-масштаба
  lift = big ? 0.08 : -0.04
  depth = MusicTags.lerp(0.0, 1.0, (sc - 1.0) / 0.06)
  bg = Egui::Color32.new(
    (bg.r.to_f64 * (1.0 + lift * depth)).round.clamp(0, 255).to_u8,
    (bg.g.to_f64 * (1.0 + lift * depth)).round.clamp(0, 255).to_u8,
    (bg.b.to_f64 * (1.0 + lift * depth)).round.clamp(0, 255).to_u8, bg.a)
  rs = s / 2.0 * sc
  # transform:scale не клипается родителем (overflow visible): кругу с
  # hover/active-масштабом нужен запас по clip сверх своего бокса
  grow = (rs - s / 2.0).abs
  saved_clip = ui.painter.clip
  ui.painter.clip = saved_clip.expand(grow)
  ui.painter.circle_filled(rect.center, rs, bg)
  MusicTags.icon(name, fg).paint(ui, Egui::Rect.from_min_size(
    Egui::Pos2.new(rect.center.x - isz * sc / 2.0,
      rect.center.y - isz * sc / 2.0),
    Egui::Vec2.new(isz * sc, isz * sc)))
  ui.painter.clip = saved_clip
  if resp.clicked? && (act = MusicTags.a(node, rt, "on_click"))
    rt.fire(act)
  end
end

# <gtile g= t= c1= c2= txt=/> — плитка жанра (.genre-tile): цвет фона,
# заголовок, обложка в углу (позиционирование в углу — painter'ом).
widget :gtile do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  g = MusicTags.hex(MusicTags.a(node, rt, "g")) || MusicTags.accent(rt)
  title = MusicTags.a(node, rt, "t") || ""
  c1 = MusicTags.hex(MusicTags.a(node, rt, "c1")) || MusicTags.accent(rt)
  c2 = MusicTags.hex(MusicTags.a(node, rt, "c2")) || c1
  txt = MusicTags.a(node, rt, "txt") || ""
  w = MusicTags.f(node, rt, "w", 184.0)
  h = MusicTags.f(node, rt, "h", 112.0)
  padb = MusicTags.f(node, rt, "padb", 16.0) # запас под перенос строк
  rect = ui.allocate_space(Egui::Vec2.new(w, h + padb))
  rect = Egui::Rect.from_min_size(rect.min, Egui::Vec2.new(w, h))
  MusicTags.geom!("gtile:#{title}", rect)
  p = ui.painter
  id = Egui::Id.from(node.path)
  resp = ui.interact(rect, id, Egui::Sense::Click)
  # hover: scale(1.03) + brightness(1.1) — transition .15s; клик-зона
  # остаётся на базовом прямоугольнике (transform — только визуально)
  sc = MusicTags.glide(ctx, id, "scale", resp.hovered? ? 1.03 : 1.0, 150.0)
  prev = p.clip
  clip_base = p.clip
  vis = Egui::Rect.from_min_size(
    Egui::Pos2.new(rect.center.x - rect.width * sc / 2.0,
      rect.center.y - rect.height * sc / 2.0),
    Egui::Vec2.new(rect.width * sc, rect.height * sc))
  p.clip = Egui::Rect.new(
    Egui::Pos2.new({clip_base.min.x, vis.min.x}.min,
      {clip_base.min.y, vis.min.y}.min),
    Egui::Pos2.new({clip_base.max.x, vis.max.x}.max,
      {clip_base.max.y, vis.max.y}.max))
  depth = MusicTags.lerp(0.0, 1.0, (sc - 1.0) / 0.03)
  fill = g
  if depth > 0.0
    k = 1.0 + 0.085 * depth
    fill = Egui::Color32.new(
      (g.r.to_f64 * k).round.clamp(0, 255).to_u8,
      (g.g.to_f64 * k).round.clamp(0, 255).to_u8,
      (g.b.to_f64 * k).round.clamp(0, 255).to_u8, g.a)
  end
  p.rect(vis, 10.0, fill: fill)
  p.text(Egui::Pos2.new(vis.left + 16.0, vis.top + 14.0 + 11.0),
    title, 22.0, MusicTags::WHITE, bold: true)
  MusicTags.cover(p, ui.fonts,
    Egui::Rect.from_min_size(
      Egui::Pos2.new(vis.right - 70.0, vis.bottom - 72.0),
      Egui::Vec2.new(80.0, 80.0)),
    c1, c2, txt, 6.0, 18.0)
  p.clip = prev
  if resp.clicked? && (act = MusicTags.a(node, rt, "on_click"))
    rt.strings["_gt"] = title
    rt.fire(act)
  end
end

# <hero c1= c2=/> — шапка страницы коллекции (.hero): два радиальных
# пятна из цветов обложки (app.js: heroStyle — c1×0.55 у 75%/-10%,
# c2×0.22 у 15%/120%, база #111117) + ряд детей, padding 40/28/26.
widget :hero do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  h = MusicTags.f(node, rt, "h", 298.0)
  rect = ui.allocate_space(Egui::Vec2.new(ui.available_width, h))
  p = ui.painter
  prev = p.clip
  p.clip = rect
  p.rect(rect, 0.0, fill: Egui::Color32.rgb(0x11, 0x11, 0x17))
  c1 = MusicTags.hex(MusicTags.a(node, rt, "c1")) ||
       Egui::Color32.rgba(0xe9, 0x22, 0x36, 0xFF)
  c2 = MusicTags.hex(MusicTags.a(node, rt, "c2")) ||
       Egui::Color32.rgba(0x57, 0x1d, 0xc6, 0xFF)
  # heroStyle: два эллиптических radial-gradient (1200x500 у 75%/-10%,
  # 900x500 у 15%/120%, transparent 70%) — честные градиенты движка
  # (Gradient с явными радиусами, Gouraud-кольца), не пятна-круги
  MusicTags.spot(p, rect, 0.75, -0.10, 1200.0, 500.0, c1, 0.70)
  MusicTags.spot(p, rect, 0.15, 1.20, 900.0, 500.0, c2, 0.70)
  inner = Egui::Rect.new(
    Egui::Pos2.new(rect.left + 28.0, rect.top + 40.0),
    Egui::Pos2.new(rect.right - 28.0, rect.bottom - 26.0))
  child = ui.child_ui(inner, Egui::Id.from(node.path),
    layout: Egui::Layout.left_to_right)
  child.clip = MusicTags.clip_intersect(rect, ui.clip)
  r.render_each(node, child, ctx, rt)
  p.clip = prev
end

# <oswitch on=/> — тумблер настроек (.switch), 44×24. Ползунок и фон
# едут за .18s (CSS transition), а не прыгают.
widget :oswitch do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  on = MusicTags.b(node, rt, "on")
  act = MusicTags.a(node, rt, "on_click")
  rect = ui.allocate_space(Egui::Vec2.new(44.0, 24.0))
  id = Egui::Id.from(node.path)
  resp = ui.interact(rect, id, Egui::Sense::Click)
  p = ui.painter
  # лёгкое свечение при hover (live)
  if resp.hovered?
    p.rect(Egui::Rect.from_min_size(rect.min,
      Egui::Vec2.new(rect.width, rect.height)), 12.0,
      fill: MusicTags::ROW_HOVER)
  end
  pos = MusicTags.glide(ctx, id, "knob", on ? 1.0 : 0.0, 180.0)
  bg = MusicTags.fade(ctx, id, "bg",
    on ? MusicTags.accent(rt) : MusicTags::CONTROL, 180.0)
  p.rect(rect, 12.0, fill: bg)
  kx = MusicTags.lerp(rect.left + 2.0, rect.left + 22.0, pos)
  p.circle_filled(Egui::Pos2.new(kx + 10.0, rect.center.y), 10.0, MusicTags::WHITE)
  if resp.clicked?
    # с on_click состояние меняет приложение (player), без — сам store
    if act
      rt.fire(act)
    elsif (key = node.attrs["bind"]?)
      rt.bools[key] = !rt.bool(key)
    end
    ctx.request_repaint
  end
end

# <swatch/> — квадратик цвета акцента (.swatch).
widget :swatch do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  s = MusicTags.f(node, rt, "s", 34.0)
  rect = ui.allocate_space(Egui::Vec2.new(s, s))
  ui.painter.rect(rect, 8.0, fill: MusicTags.accent(rt))
end

# <ocombo text= w=/> — комбо настроек (.combo), статичный вид.
widget :ocombo do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  key = node.attrs["bind"]?
  # опции — из store (rt.rows["<key>_opts"], как <option v-for> у Vue),
  # фолбэк — статичный атрибут options="a,b,c"
  options = if key && (rows = rt.rows["#{key}_opts"]?)
              rows.map { |row| row["t"]? || "" }
            else
              node.attrs["options"]?.to_s.split(",").map(&.strip)
                .reject(&.empty?)
            end
  text = key ? rt.string(key)
    : (MusicTags.a(node, rt, "text") || "")
  w = MusicTags.f(node, rt, "w", 160.0)
  h = MusicTags.f(node, rt, "h", 34.0)
  rect = ui.allocate_space(Egui::Vec2.new(w, h))
  resp = ui.interact(rect, Egui::Id.from(node.path), Egui::Sense::Click)
  p = ui.painter
  open = key && rt.string("_combo") == key
  p.rect(rect, 8.0,
    fill: resp.hovered? || open ? MusicTags::CONTROL_HOV : MusicTags::CONTROL,
    stroke_color: MusicTags::BORDER, stroke_width: 1.0)
  m = ui.fonts.measure(text, 14.0)
  p.text(Egui::Pos2.new(rect.left + 12.0, rect.center.y), text, 14.0,
    MusicTags::TEXT)
  MusicTags.icon("chev", Egui::Color32.rgba(0xc4, 0xc4, 0xd2, 0xB3)).paint(ui,
    Egui::Rect.from_min_size(
      Egui::Pos2.new(rect.right - 12.0 - 16.0, rect.center.y - 8.0),
      Egui::Vec2.new(16.0, 16.0)))
  if resp.clicked? && key
    rt.strings["_combo"] = open ? "" : key.not_nil!
    ctx.request_repaint
  end
  # список поверх всего (Order::Foreground)
  if open && key
    layer = Egui::LayerId.new(Egui::Order::Foreground,
      Egui::Id.from("combo/#{key}"))
    item_h = 30.0
    list_rect = Egui::Rect.from_min_size(
      Egui::Pos2.new(rect.left, rect.bottom + 4.0),
      Egui::Vec2.new({w, 180.0}.max, item_h * options.size + 8.0))
    lp = ctx.painter
    prev_clip = lp.clip
    lp.clip = Egui::Rect.new(Egui::Pos2.new(-1e8, -1e8),
      Egui::Pos2.new(1e8, 1e8))
    prev_layer = lp.layer
    lp.layer = Egui::Order::Foreground
    lp.rect(list_rect, 8.0, fill: MusicTags::POPUP,
      stroke_color: MusicTags::BORDER, stroke_width: 1.0)
    options.each_with_index do |opt, i|
      orect = Egui::Rect.from_min_size(
        Egui::Pos2.new(list_rect.left + 4.0,
          list_rect.top + 4.0 + i * item_h),
        Egui::Vec2.new(list_rect.width - 8.0, item_h))
      oresp = ctx.interact(Egui::Id.from("#{node.path}/opt#{i}"), orect,
        Egui::Sense::Click, layer, orect)
      if oresp.hovered?
        lp.rect(Egui::Rect.from_min_size(orect.min,
          Egui::Vec2.new(orect.width, orect.height)), 6.0,
          fill: MusicTags::CONTROL)
      end
      lp.text(Egui::Pos2.new(orect.left + 8.0, orect.center.y), opt, 14.0,
        opt == text ? MusicTags::WHITE : MusicTags::MUTED)
      if oresp.clicked?
        rt.strings[key] = opt
        rt.strings["_combo"] = ""
        if (act = MusicTags.a(node, rt, "on_change"))
          rt.fire(act)
        end
        ctx.request_repaint
      end
    end
    lp.layer = prev_layer
    lp.clip = prev_clip
  end
end

# <oslider frac= w=/> — слайдер-вид (seek 28%, volume 70%, crossfade 42%):
# track 4px + fill + knob 12 — статичный оракул, некликабелен.
widget :oslider do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  key = node.attrs["bind"]?
  frac = key ? rt.float(key).clamp(0.0, 1.0)
    : (MusicTags.f(node, rt, "frac", 0.0) / 100.0).clamp(0.0, 1.0)
  w = MusicTags.f(node, rt, "w", -1.0)
  w = ui.available_width if w < 0
  # высота 16: ручка 12–15px с антиалиасингом не должна резаться
  # клипом строки (трек рисуется по центру, как в .slider height:12)
  rect = ui.allocate_space(Egui::Vec2.new(w, 16.0))
  resp = ui.interact(Egui::Rect.from_min_size(rect.min,
      Egui::Vec2.new(w, 12.0)), Egui::Id.from(node.path),
    Egui::Sense::Click | Egui::Sense::Drag)
  if key && (resp.dragged? || resp.clicked?) && (ptr = ctx.input.pointer_pos)
    rt.floats[key] = ((ptr.x - rect.left) / w).clamp(0.0, 1.0)
    frac = rt.float(key)
    if (act = MusicTags.a(node, rt, "on_change"))
      rt.fire(act)
    end
    ctx.request_repaint
  end
  p = ui.painter
  cy = rect.center.y
  # knob:hover scale(1.25) — transition .1s, радиус мягко растёт
  kw = MusicTags.glide(ctx, Egui::Id.from(node.path), "kw",
    resp.hovered? || resp.dragged? ? 7.5 : 6.0, 100.0)
  p.rect(Egui::Rect.from_min_size(Egui::Pos2.new(rect.left, cy - 2.0),
    Egui::Vec2.new(w, 4.0)), 2.0,
    fill: Egui::Color32.rgba(255, 255, 255, 0x33))
  p.rect(Egui::Rect.from_min_size(Egui::Pos2.new(rect.left, cy - 2.0),
    Egui::Vec2.new(w * frac, 4.0)), 2.0, fill: MusicTags.accent(rt))
  kx = rect.left + w * frac
  p.circle_filled(Egui::Pos2.new(kx, cy), kw, MusicTags::WHITE)
end

# <island/> — «остров» сверху по центру (.island): пилюля с обложкой,
# названием и мини-визуализатором; overlay-слой фреймворка.
widget :island do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  # мини-слайдер seek для развёрнутого острова
  draw_seek = ->(area : Egui::Rect, key : String, w : Float64) {
    frac = rt.float(key).clamp(0.0, 1.0)
    cy = area.center.y
    lp = ctx.painter
    lp.rect(Egui::Rect.from_min_size(Egui::Pos2.new(area.left, cy - 2.0),
      Egui::Vec2.new(w, 4.0)), 2.0,
      fill: Egui::Color32.rgba(255, 255, 255, 0x40))
    lp.rect(Egui::Rect.from_min_size(Egui::Pos2.new(area.left, cy - 2.0),
      Egui::Vec2.new(w * frac, 4.0)), 2.0, fill: MusicTags.accent(rt))
    lp.circle_filled(Egui::Pos2.new(area.left + w * frac, cy), 5.0,
      MusicTags::WHITE)
    srect = Egui::Rect.from_min_size(Egui::Pos2.new(area.left, cy - 7.0),
      Egui::Vec2.new(w, 14.0))
    sresp = ctx.interact(Egui::Id.from("#{node.path}/seek"), srect,
      Egui::Sense::Click | Egui::Sense::Drag, MusicTags.island_layer.not_nil!, srect)
    if (sresp.dragged? || sresp.clicked?) && (ptr = ctx.input.pointer_pos)
      rt.floats[key] = ((ptr.x - area.left) / w).clamp(0.0, 1.0)
      rt.fire("seek")
      ctx.request_repaint
    end
  }
  c1 = MusicTags.hex(MusicTags.a(node, rt, "c1")) || MusicTags::ACCENT
  c2 = MusicTags.hex(MusicTags.a(node, rt, "c2")) || c1
  txt = MusicTags.a(node, rt, "txt") || "DH"
  title = MusicTags.a(node, rt, "title") || ""
  ui.overlay(:top_center, margin: Egui::StyleBox.new(top: 6.0)) do |o|
    o.painter.clip = o.clip
    # .island .title: max-width 220 + text-overflow: ellipsis
    title = o.fonts.fit(title, 12.0, 220.0)
    tw = o.fonts.measure(title, 12.0).x
    w = 10.0 + 20.0 + 8.0 + tw + 8.0 + (4 * 2.5 + 3 * 2) + 10.0
    rect = o.allocate_space(Egui::Vec2.new(w, 28.0))
    # hover-зона: только пилюля + 8px (не 300px — перехватывала клики
    # по поисковой пилюле); развёрнутая панель добавляет свою зону ниже
    layer = Egui::LayerId.new(Egui::Order::Foreground,
      Egui::Id.from("island"))
    MusicTags.island_layer = layer
    expanded = rt.bool("island_open") ||
               ctx.input.pointer_pos.try { |pt| rect.contains?(pt) } ||
               false
    rt.bools["island_open"] = false
    hov_rect = Egui::Rect.from_min_size(
      Egui::Pos2.new(rect.left - 8.0, rect.top - 4.0),
      Egui::Vec2.new(w + 16.0, 36.0))
    if expanded
      hov_rect = Egui::Rect.from_min_size(rect.min,
        Egui::Vec2.new({w, 300.0}.max, 190.0))
    end
    hresp = ctx.interact(Egui::Id.from("#{node.path}/hov"), hov_rect,
      Egui::Sense::Click, layer, rect)
    expanded ||= hresp.hovered?
    p = o.painter
    # .island { transition: border-radius .18s ease }: скругление пилюли
    # (100px капсула → 14px панели) мягко едет; высота/контент, как в
    # CSS height:auto, переключаются сразу
    radius = MusicTags.glide(ctx, Egui::Id.from("#{node.path}/rad"),
      "radius", expanded ? 14.0 : 100.0, 180.0)
    p.rect(rect, radius, fill: MusicTags::POPUP,
      stroke_color: Egui::Color32.rgba(255, 255, 255, 0x1a), stroke_width: 1.0)
    x = rect.left + 10.0
    MusicTags.cover(p, o.fonts,
      Egui::Rect.from_min_size(Egui::Pos2.new(x, rect.center.y - 10.0),
        Egui::Vec2.new(20.0, 20.0)), c1, c2, txt, 5.0, 8.0)
    x += 20.0 + 8.0
    p.text(Egui::Pos2.new(x, rect.center.y), title, 12.0, MusicTags::TEXT)
    x += tw + 8.0
    t = ctx.input.time
    heights = {6.0, 11.0, 8.0, 5.0}
    levels = MusicTags.vis_step("#{node.path}/folded", 4, !rt.bool("paused"), t)
    4.times do |i|
      bh = {heights[i] * levels[i], 2.0}.max
      p.rect(Egui::Rect.from_min_size(
        Egui::Pos2.new(x + i * 4.5, rect.bottom - 8.0 - bh),
        Egui::Vec2.new(2.5, bh)), 1.0, fill: MusicTags.accent(rt))
    end

    # ── развёрнутый мини-плеер (island.xml): 300px поверх всего ──
    if expanded
      lp = ctx.painter
      prev_clip = lp.clip
      lp.clip = Egui::Rect.new(Egui::Pos2.new(-1e8, -1e8),
        Egui::Pos2.new(1e8, 1e8))
      prev_layer = lp.layer
      lp.layer = Egui::Order::Foreground
      iw = 300.0
      ipanel = Egui::Rect.from_min_size(rect.min, Egui::Vec2.new(iw, 186.0))
      lp.rect(ipanel, 14.0, fill: MusicTags::POPUP,
        stroke_color: Egui::Color32.rgba(255, 255, 255, 0x1a), stroke_width: 1.0)
      lp.box_shadow(ipanel, Egui::Color32.rgba(0, 0, 0, 0x80), 30.0, 14.0)
      # u-song: cover 40 + тексты + vis 6
      sy = ipanel.top + 12.0
      MusicTags.cover(lp, o.fonts,
        Egui::Rect.from_min_size(Egui::Pos2.new(ipanel.left + 12.0, sy),
          Egui::Vec2.new(40.0, 40.0)), c1, c2, txt, 6.0, 13.0)
      tt = rt.string("np_title")
      ta = rt.string("np_artist")
      lp.text(Egui::Pos2.new(ipanel.left + 64.0, sy + 10.0), tt, 13.0,
        MusicTags::TEXT, bold: true)
      lp.text(Egui::Pos2.new(ipanel.left + 64.0, sy + 26.0), ta, 11.0,
        MusicTags::MUTED)
      6.times do |i|
        ulevels = MusicTags.vis_step("#{node.path}/unfolded", 6,
          !rt.bool("paused"), t)
        bh = {16.0 * ulevels[i], 2.0}.max
        lp.rect(Egui::Rect.from_min_size(
          Egui::Pos2.new(ipanel.right - 16.0 - (6 - i) * 4.5,
            sy + 40.0 - bh),
          Egui::Vec2.new(2.5, bh)), 1.0, fill: MusicTags.accent(rt))
      end
      draw_seek.call(
        Egui::Rect.from_min_size(
          Egui::Pos2.new(ipanel.left + 12.0, sy + 56.0),
          Egui::Vec2.new(iw - 24.0, 14.0)), "seek_frac", iw - 24.0)
      lp.text(Egui::Pos2.new(ipanel.left + 12.0, sy + 76.0),
        rt.string("elapsed"), 10.0, MusicTags::MUTED)
      lw = o.fonts.measure(rt.string("length"), 10.0).x
      lp.text(Egui::Pos2.new(ipanel.right - 12.0 - lw, sy + 76.0),
        rt.string("length"), 10.0, MusicTags::MUTED)
      # u-row: heart prev play next panel (30px, play 34)
      by = sy + 92.0
      cxm = ipanel.center.x
      buttons = {"heart", "prev", "play", "next", "panel"}
      actions = {"like_current", "prev_track", "toggle_play", "next_track", "toggle_np"}
      # цепочка от центра: 30,6,30,6,34,6,30,6,30 = 178 (island .u-row)
      widths = {30.0, 30.0, 34.0, 30.0, 30.0}
      bgap = 6.0
      bx = cxm - (widths.sum + bgap * (buttons.size - 1)) / 2.0
      buttons.each_with_index do |bname, i|
        bw = widths[i]
        brect = Egui::Rect.from_min_size(
          Egui::Pos2.new(bx, by + (34.0 - bw) / 2.0),
          Egui::Vec2.new(bw, bw))
        bx += bw + bgap
        bresp = ctx.interact(Egui::Id.from("#{node.path}/btn#{i}"), brect,
          Egui::Sense::Click, layer, brect)
        # .play-round: белый круг + тёмный глиф; остальные — прозрачные с
        # hover-подложкой (как .u-row .icon-btn)
        is_play = bname == "play"
        if is_play
          lp.circle_filled(brect.center, brect.width / 2.0, MusicTags::TEXT)
        elsif bresp.hovered?
          lp.circle_filled(brect.center, brect.width / 2.0,
            MusicTags::CONTROL_HOV)
        end
        icon_name = is_play ? rt.string("play_icon") : bname
        icon_name = "heart-f" if bname == "heart" && rt.bool("liked_current")
        fg = is_play ? MusicTags::WINDOW
          : (bresp.hovered? ? MusicTags::WHITE : MusicTags::ICON_FG)
        MusicTags.icon(icon_name, fg).paint(ui,
          Egui::Rect.from_min_size(
            Egui::Pos2.new(brect.center.x - 7.0, brect.center.y - 7.0),
            Egui::Vec2.new(14.0, 14.0)))
        if bresp.clicked?
          rt.fire(actions[i])
          ctx.request_repaint
        end
      end
      # u-sep + u-look
      lp.rect(Egui::Rect.from_min_size(
        Egui::Pos2.new(ipanel.left + 12.0, ipanel.bottom - 40.0),
        Egui::Vec2.new(iw - 24.0, 1.0)), 0.0, fill: MusicTags::SEPARATOR)
      lp.text(Egui::Pos2.new(ipanel.left + 12.0, ipanel.bottom - 20.0),
        "Look: " + rt.string("look_name"), 12.0, MusicTags::MUTED)
      lp.layer = prev_layer
      lp.clip = prev_clip
    end
    ctx.request_repaint
  end
end

# <col w=> — вертикальный стек фиксированной ширины (в отличие от
# прозрачного <column> создаёт свой child Ui — тексты «в две строки»
# внутри горизонтального ряда). Высота — по контенту (min_rect детей).
widget :col do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  w = MusicTags.f(node, rt, "w", 160.0)
  # высота заранее (по атрибутам детей): allocate отцентрирует стек
  # в строке (кросс-центрирование движка), красим в готовом ректе
  h = node.children.sum { |c| MusicTags.estimate_height(c, rt) }
  h = {h, 1.0}.max
  rect = ui.allocate_space(Egui::Vec2.new(w, h))
  child = ui.child_ui(
    Egui::Rect.from_min_size(rect.min, Egui::Vec2.new(w, 1e6)),
    Egui::Id.from(node.path), layout: Egui::Layout.top_down)
  child.clip = MusicTags.clip_intersect(
    Egui::Rect.new(rect.min,
      Egui::Pos2.new(rect.min.x + w, ui.max_rect.bottom)), ui.clip)
  r.render_each(node, child, ctx, rt)
end

# <hbar h=> — строка-контейнер фиксированной высоты (шапка 56): дети
# центрируются по вертикали полосы; <spring/> делит остаток ширины
# (предрасчёт — flex-распределения в движке нет).
widget :hbar do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  h = MusicTags.f(node, rt, "h", 56.0)
  rect = ui.allocate_space(Egui::Vec2.new(ui.available_width, h))
  MusicTags.geom!("hbar:#{MusicTags.a(node, rt, "name") || h}", rect)
  pad = MusicTags.f(node, rt, "pad", 0.0)
  inner = Egui::Rect.from_min_size(
    Egui::Pos2.new(rect.left + pad, rect.top),
    Egui::Vec2.new(rect.width - 2 * pad, h))
  child = ui.child_ui(
    Egui::Rect.new(inner.min, Egui::Pos2.new(inner.right, 1e9)),
    Egui::Id.from(node.path), layout: Egui::Layout.left_to_right)
  child.wrap_x = false
  child.clip = MusicTags.clip_intersect(Egui::Rect.new(rect.min,
    Egui::Pos2.new(ui.max_rect.right, rect.bottom)), ui.clip)
  child.seed_row_height(h)
  sw = MusicTags.spring_width(node.children, rt, ui.fonts, inner.width)
  node.children.each do |cn|
    if cn.name == "spring"
      child.allocate_space(Egui::Vec2.new(sw, 0.0))
    else
      r.render(cn, child, ctx, rt)
    end
  end
end

# <mainarea pad= reserve=> — .main: строка во всю остаточную высоту минус
# reserve (playerbar), с внешним padding 8.
widget :mainarea do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  pad = MusicTags.f(node, rt, "pad", 8.0)
  reserve = MusicTags.f(node, rt, "reserve", 88.0)
  rect = ui.allocate_space(Egui::Vec2.new(ui.available_width,
    ui.available_height - reserve))
  MusicTags.geom!("mainarea", rect)
  inner = Egui::Rect.new(
    Egui::Pos2.new(rect.left + pad, rect.top + pad),
    Egui::Pos2.new(rect.right - pad, rect.bottom - pad))
  child = ui.child_ui(inner, Egui::Id.from(node.path),
    layout: Egui::Layout.left_to_right)
  child.clip = MusicTags.clip_intersect(rect, ui.clip)
  r.render_each(node, child, ctx, rt)
end

# <pbar> — нижний бар плеера (.playerbar): фон bar-bg, три колонки
# 1fr/1.3fr/1fr (grid, align-items:center), дети по порядку.
widget :pbar do |node, ui, ctx, rt, r|
  ui.painter.clip = ui.clip
  h = MusicTags.f(node, rt, "h", 88.0)
  rect = ui.allocate_space(Egui::Vec2.new(ui.available_width, h))
  MusicTags.geom!("pbar", rect)
  p = ui.painter
  p.rect(rect, 0.0, fill: MusicTags::BAR_BG)
  total = rect.width - 32.0
  c13 = total / 3.3
  c2w = total - 2 * c13
  xs = {rect.left + 16.0, rect.left + 16.0 + c13, rect.left + 16.0 + c13 + c2w}
  ws = {c13, c2w, c13}
  node.children.each_with_index do |child_node, i|
    next if i > 2
    # вертикальное центрирование контента колонки (align-items:center)
    ch = {MusicTags.estimate_height(child_node, rt), h}.min
    col = Egui::Rect.from_min_size(
      Egui::Pos2.new(xs[i], rect.top + (h - ch) / 2.0),
      Egui::Vec2.new(ws[i], ch))
    cui = ui.child_ui(col, Egui::Id.from("#{node.path}/col#{i}"),
      layout: Egui::Layout.top_down)
    cui.clip = Egui::Rect.from_min_size(
      Egui::Pos2.new(xs[i], rect.top), Egui::Vec2.new(ws[i], h))
    r.render(child_node, cui, ctx, rt)
  end
end


