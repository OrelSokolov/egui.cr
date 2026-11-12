# music_widgets_manual_app.cr — Raven Music на РУЧНОЙ верстке: тот же
# UI, что у music_exml.cr (assets/music.exml + assets/music.ecss), но
# деревом прямых вызовов — без парсинга EXML/ECSS на старте и без
# store/interpolation. Поддерживается руками, поэтому расходится с
# music_exml (верстка/стили/контекст) — это наглядное доказательство
# против второго рендерера (plans/NativeHTML.md §6: «B — не делаем»).
# Автоматическая альтернатива — music_gen (egui-gen, литералы того же
# парсера). Слои: состояние — MusicPlayer (music_player.cr), данные —
# MusicLibrary, рисование — переиспользуемые хелперы MusicTags
# (music_tags.cr); стиль панелей — правила music.ecss, запечённые в
# MwStyle-константы.
#
# Эквивалентность тегам music.exml: panel→#panel, hbar→#hbar, col→#col,
# crow→#crow, t→#t, gap→#gap, spring→#rspring, ibtn→#ibtn, navitem→
# #navitem, chip→#chip, cover→#cover, vis→#vis, mesh→#mesh, gtile→
# #gtile, hero→#hero, oswitch→#oswitch, ocombo→#ocombo, oslider→
# #oslider, playround→#playround, searchinput→#search_input, island→
# #island. Идентификаторы виджетов — стабильные строки (аналог node.path).
require "../../src/egui"
require "./music_tags"
require "./music_player"

# ── запечённые ECSS-правила (assets/music.ecss) ──────────────────────
# Пара (правило, :hover-правило) из music.ecss в одну структуру; переход
# transition.background — его длительность.
struct MwStyle
  getter bg : Egui::Color32?
  getter bg_hover : Egui::Color32?
  getter stroke : Egui::Color32?
  getter stroke_width : Float64
  getter rounding : Float64
  getter pad : Egui::StyleBox
  getter trans_ms : Float64

  def initialize(@bg = nil, @bg_hover = nil, @stroke = nil,
                 @stroke_width = 1.0, @rounding = 8.0,
                 @pad = Egui::StyleBox.new, @trans_ms = 0.0)
  end

  # center { background:#0d0d12; stroke:#ffffff0d; rounding:12 }
  CENTER = new(bg: Egui::Color32.rgb(0x0d, 0x0d, 0x12),
               stroke: Egui::Color32.rgba(255, 255, 255, 0x0d), rounding: 12.0)
  # nowplaying { …padding:16 }
  NOWPLAYING = new(bg: Egui::Color32.rgb(0x0d, 0x0d, 0x12),
                   stroke: Egui::Color32.rgba(255, 255, 255, 0x0d),
                   rounding: 12.0, pad: Egui::StyleBox.new(16.0, 16.0, 16.0, 16.0))
  # nav-box { …padding: 10 8 }
  NAVBOX = new(bg: Egui::Color32.rgb(0x0d, 0x0d, 0x12),
               stroke: Egui::Color32.rgba(255, 255, 255, 0x0d),
               rounding: 12.0,
               pad: Egui::StyleBox.new(10.0, 8.0, 10.0, 8.0))
  # lib-box { …padding:10 }
  LIBBOX = new(bg: Egui::Color32.rgb(0x0d, 0x0d, 0x12),
               stroke: Egui::Color32.rgba(255, 255, 255, 0x0d),
               rounding: 12.0, pad: Egui::StyleBox.new(10.0, 10.0, 10.0, 10.0))
  # center-page { padding: 20 24 32 24 } — без фона
  CENTER_PAGE = new(pad: Egui::StyleBox.new(20.0, 24.0, 32.0, 24.0))
  # album-card { rounding:10; padding:10 } / :hover { background:#ffffff12 }
  ALBUM_CARD = new(bg_hover: Egui::Color32.rgba(255, 255, 255, 0x12),
                   rounding: 10.0, pad: Egui::StyleBox.new(10.0, 10.0, 10.0, 10.0))
  # quick { background:#ffffff12; rounding:6; transition.background:150 }
  # quick:hover { background:#ffffff1f }
  QUICK = new(bg: Egui::Color32.rgba(255, 255, 255, 0x12),
              bg_hover: Egui::Color32.rgba(255, 255, 255, 0x1f),
              rounding: 6.0, trans_ms: 150.0)
  # np-artist-card { background:#241a3f; rounding:10; padding:16 }
  NP_ARTIST = new(bg: Egui::Color32.rgb(0x24, 0x1a, 0x3f),
                  rounding: 10.0, pad: Egui::StyleBox.new(16.0, 16.0, 16.0, 16.0))
  # np-queue-card { background:#16161c; rounding:10; padding:14 }
  NP_QUEUE = new(bg: Egui::Color32.rgb(0x16, 0x16, 0x1c),
                 rounding: 10.0, pad: Egui::StyleBox.new(14.0, 14.0, 14.0, 14.0))
  # about-card { background:#16161c; rounding:10; padding:18 }
  ABOUT = new(bg: Egui::Color32.rgb(0x16, 0x16, 0x1c),
              rounding: 10.0, pad: Egui::StyleBox.new(18.0, 18.0, 18.0, 18.0))
  # lib-row { padding:4; transition.background:120 } / :hover #ffffff10
  LIB_ROW = new(bg_hover: Egui::Color32.rgba(255, 255, 255, 0x10),
                pad: Egui::StyleBox.new(4.0, 4.0, 4.0, 4.0), trans_ms: 120.0)
  # track-row { transition.background:120 } / :hover #ffffff10
  TRACK_ROW = new(bg_hover: Egui::Color32.rgba(255, 255, 255, 0x10),
                  trans_ms: 120.0)
  # без класса (panel без class= в разметке)
  PLAIN = new
end

class MusicWidgetsManualApp < Egui::App
  getter player : MusicPlayer
  getter library : MusicLibrary::Library

  def initialize
    super
    @player = MusicPlayer.new
    @library = @player.library
    @last_tick = 0.0
    @styled = false
    @focus = false        # фокус поля поиска (аналог rt.strings["_focus"])
    @combo_open = ""      # открытый комбо настроек: "" | "look" | "bg" | "quality"
    apply_start_state
  end

  # стартовое состояние — аналог location.hash оракула (MUSIC_PAGE)
  def apply_start_state : Nil
    opts = (ENV["MUSIC_PAGE"]? || "").split(',').map(&.strip)
    p = @player
    case
    when opts.includes?("album")    then p.open_album(0, 0.0)
    when opts.includes?("playlist") then p.open_playlist(1)
    when opts.includes?("search")   then p.query = "the"; p.nav_to(:search)
    when opts.includes?("genres")   then p.nav_to(:search)
    when opts.includes?("library")  then p.nav_to(:library)
    when opts.includes?("settings") then p.nav_to(:settings)
    end
    p.playing = false if opts.includes?("paused")
    p.animate = false if opts.includes?("still") # для скриншот-сравнений
  end

  def update(ctx : Egui::Context) : Nil
    unless @styled
      # как у exml-версии: нулевые item_spacing/window_padding (зазоры в
      # верстке явные), фон окна #060609
      ctx.style.spacing.item_spacing = Egui::Vec2.new(0.0, 0.0)
      ctx.style.spacing.window_padding = Egui::Vec2.new(0.0, 0.0)
      MusicTags.use_look(MusicLibrary::LOOKS[@player.look]? || MusicLibrary::LOOKS[0])
      ctx.style.visuals.panel_fill = MusicTags.window
      ctx.style.visuals.text_color = MusicTags.text
      bind_hotkeys(ctx)
      @styled = true
    end
    now = advance_clock(ctx)
    handle_hotkeys(ctx, now)
    accent = accent_col
    ctx.routes do |r|
      r.page("root") { |ui| render_root(ui, ctx, accent) }
    end
  end

  # ── часы плеера (mounted() оракула) ─────────────────────────────────

  private def advance_clock(ctx : Egui::Context) : Float64
    now = ctx.input.time
    @last_tick = now if @last_tick == 0.0
    dt = {now - @last_tick, 0.25}.min
    @last_tick = now
    @player.advance(dt, now)
    ctx.request_repaint if @player.playing
    ctx.request_repaint if @player.notice != "" && @player.notice_until > now
    now
  end

  private def accent_hex : String
    p = @player
    p.follow_cover ? MusicLibrary.make_accent(p.album.c1) : p.picked
  end

  private def accent_col : Egui::Color32
    MusicTags.hex(accent_hex) || MusicTags.accent
  end

  private def greeting : String
    h = Time.local.hour
    h < 5 ? "Good night" : h < 12 ? "Good morning" :
      h < 18 ? "Good afternoon" : "Good evening"
  end

  # ── клавиши (onKey оракула) ─────────────────────────────────────────

  private def bind_hotkeys(ctx : Egui::Context) : Nil
    ctx.hotkeys.bind("Space", Egui::HotkeyAction.new("music_toggle"))
    ctx.hotkeys.bind("Ctrl+Right", Egui::HotkeyAction.new("music_next"))
    ctx.hotkeys.bind("Ctrl+Left", Egui::HotkeyAction.new("music_prev"))
    ctx.hotkeys.bind("Ctrl+L", Egui::HotkeyAction.new("music_like"))
    ctx.hotkeys.bind("Ctrl+F", Egui::HotkeyAction.new("music_find"))
    ctx.hotkeys.bind("Ctrl+P", Egui::HotkeyAction.new("music_settings"))
    ctx.hotkeys.bind("Alt+Left", Egui::HotkeyAction.new("music_back"))
  end

  private def handle_hotkeys(ctx : Egui::Context, now : Float64) : Nil
    p = @player
    typing = @focus # печать в поле — горячие клавиши не срабатывают
    if ctx.consume_action(Egui::HotkeyAction.new("music_toggle"))
      unless typing
        p.toggle(now)
        ctx.request_repaint
      end
    end
    if ctx.consume_action(Egui::HotkeyAction.new("music_next"))
      p.next_track
      ctx.request_repaint
    end
    if ctx.consume_action(Egui::HotkeyAction.new("music_prev"))
      p.prev_track
      ctx.request_repaint
    end
    if ctx.consume_action(Egui::HotkeyAction.new("music_like"))
      p.like_current(now)
      ctx.request_repaint
    end
    if ctx.consume_action(Egui::HotkeyAction.new("music_find"))
      @focus = true # фокус в поле поиска (focusSearch)
      p.nav_to(:search)
      ctx.request_repaint
    end
    if ctx.consume_action(Egui::HotkeyAction.new("music_settings"))
      p.nav_to(:settings)
      ctx.request_repaint
    end
    if ctx.consume_action(Egui::HotkeyAction.new("music_back"))
      p.back
      ctx.request_repaint
    end
  end

  # ═════════════════════════════════════════════════════════════════════
  # ПРИМИТИВЫ (порты кастомных тегов music_tags.cr; вместо чтения
  # атрибутов ноды — явные параметры, вместо store — замыкания)
  # ═════════════════════════════════════════════════════════════════════

  # <gap w= h=/>
  private def gap(ui : Egui::Ui, w : Float64 = 0.0, h : Float64 = 0.0) : Nil
    ui.painter.clip = ui.clip
    if ui.layout.horizontal? && w > 0 &&
       ui.cursor.x <= ui.max_rect.min.x + 0.5
      return
    end
    if ui.layout.horizontal? && w > 0 && ui.wrap_x &&
       ui.cursor.x + w > ui.max_rect.right + 0.5
      return
    end
    ui.allocate_space(Egui::Vec2.new(w, h)) if w > 0 || h > 0
  end

  # <spring/> в строке: весь остаток минус ширина хвостовых детей
  # (reserve — их суммарная ширина; предрасчёт как spring_width exml)
  private def rspring(ui : Egui::Ui, reserve : Float64 = 0.0) : Nil
    ui.painter.clip = ui.clip
    if ui.layout.horizontal?
      w = {ui.available_width - reserve, 0.0}.max
      ui.allocate_space(Egui::Vec2.new(w, 0.0))
    else
      ui.allocate_space(Egui::Vec2.new(0.0, ui.available_height))
    end
  end

  # <t text= size= color= bold= w= h= align= wrap= lh= ls=/>
  private def t(ui : Egui::Ui, text : String, *, size : Float64 = 14.0,
                color : Egui::Color32? = nil, bold : Bool = false,
                w : Float64 = 0.0, h : Float64 = 0.0, align : String = "l",
                wrap : Bool = false, lh : Float64 = 1.5,
                ls : Float64 = 0.0) : Nil
    ui.painter.clip = ui.clip
    color = MusicTags.text unless color
    fonts = ui.fonts
    if wrap && w > 0
      lines = MusicTags.wrap_lines(fonts, text, size, w)
      rect = ui.allocate_space(Egui::Vec2.new(w, {h, lines.size * size * lh}.max))
      lines.each_with_index do |line, i|
        lw = fonts.measure(line, size).x
        x = case align
            when "c" then rect.center.x - lw / 2.0
            when "r" then rect.right - lw
            else          rect.left
            end
        ui.painter.text(Egui::Pos2.new(x, rect.top + size * lh * (i + 0.5)),
          line, size, color, bold: bold)
      end
      return
    end
    ls_px = ls * size
    fit = text
    if w > 0
      fit = fonts.with_letter_spacing(ls_px) { fonts.fit(fit, size, w) }
    end
    m = if ls_px != 0.0
      fonts.with_letter_spacing(ls_px) { fonts.measure(fit, size) }
    else
      fonts.measure(fit, size)
    end
    tw = w > 0 ? w : m.x
    rect = ui.allocate_space(Egui::Vec2.new(tw, {h, size * 1.35}.max))
    x = case align
        when "c" then rect.center.x - m.x / 2.0
        when "r" then rect.right - m.x
        else          rect.left
        end
    ui.painter.text(Egui::Pos2.new(x, rect.center.y), fit, size, color,
      bold: bold, letter_spacing: ls_px != 0.0 ? ls_px : nil)
  end

  # <icon name= size= color= w=/>
  private def icon(ui : Egui::Ui, name : String, size : Float64 = 18.0,
                   color : Egui::Color32? = nil, w : Float64 = -1.0) : Nil
    ui.painter.clip = ui.clip
    color = MusicTags.icon unless color
    rect = ui.allocate_space(Egui::Vec2.new(w >= 0 ? w : size, size))
    MusicTags.icon(name, color).paint(ui, Egui::Rect.from_min_size(
      Egui::Pos2.new(rect.center.x - size / 2.0, rect.center.y - size / 2.0),
      Egui::Vec2.new(size, size)))
  end

  # <ibtn icon= size= btn= color= on_click=/>
  private def ibtn(ui : Egui::Ui, ctx : Egui::Context, id : String,
                   name : String, *, size : Float64 = 18.0,
                   btn : Float64 = 34.0, tint : Egui::Color32? = nil,
                   &on_click) : Nil
    ui.painter.clip = ui.clip
    rect = ui.allocate_space(Egui::Vec2.new(btn, btn))
    wid = Egui::Id.from(id)
    resp = ui.interact(rect, wid, Egui::Sense::Click)
    hov = MusicTags.glide(ctx, wid, "hov",
      resp.active? ? 0x2B : (resp.hovered? ? 0x12 : 0x00), 150.0)
    if hov >= 0.5
      ui.painter.circle_filled(rect.center, btn / 2.0,
        Egui::Color32.new(255, 255, 255, hov.round.to_u8))
    end
    base = tint || MusicTags.icon
    color = MusicTags.lerp_color(base, MusicTags.strong, hov / 0x12)
    MusicTags.icon(name, color).paint(ui, Egui::Rect.from_min_size(
      Egui::Pos2.new(rect.center.x - size / 2.0, rect.center.y - size / 2.0),
      Egui::Vec2.new(size, size)))
    if resp.clicked?
      on_click.call
      ctx.request_repaint
    end
  end

  # <navitem icon= text= active= w= on_click=/>
  private def navitem(ui : Egui::Ui, ctx : Egui::Context, id : String,
                      name : String, text : String, active : Bool, *,
                      w : Float64 = -1.0, h : Float64 = 32.0,
                      isz : Float64 = 24.0, fs : Float64 = 15.0,
                      pad : Float64 = 6.0, &on_click) : Nil
    ui.painter.clip = ui.clip
    w_real = if w >= 0
      w
    elsif ui.layout.horizontal?
      pad + isz + 16.0 + ui.fonts.measure(text, fs).x + pad
    else
      ui.available_width
    end
    rect = ui.allocate_space(Egui::Vec2.new(w_real, h))
    wid = Egui::Id.from(id)
    resp = ui.interact(rect, wid, Egui::Sense::Click)
    hov = MusicTags.glide(ctx, wid, "hov",
      (resp.hovered? && !active) ? 0x10 : 0x00, 150.0)
    if hov >= 0.5
      ui.painter.rect(rect, 6.0,
        fill: Egui::Color32.new(255, 255, 255, hov.round.to_u8))
    end
    fg = active ? MusicTags.strong
      : MusicTags.lerp_color(MusicTags.muted, MusicTags.strong, hov / 0x10)
    cx = rect.left + pad
    MusicTags.icon(name, fg).paint(ui, Egui::Rect.from_min_size(
      Egui::Pos2.new(cx, rect.center.y - isz / 2.0), Egui::Vec2.new(isz, isz)))
    ui.painter.text(Egui::Pos2.new(cx + isz + 16.0, rect.center.y),
      text, fs, fg, bold: true)
    if resp.clicked?
      on_click.call
      ctx.request_repaint
    end
  end

  # <chip text= on= on_click=/>
  private def chip(ui : Egui::Ui, ctx : Egui::Context, id : String,
                   text : String, on : Bool, *, fs : Float64 = 13.0,
                   &on_click) : Nil
    ui.painter.clip = ui.clip
    m = ui.fonts.measure(text, fs)
    rect = ui.allocate_space(Egui::Vec2.new(m.x + 28.0, 30.0))
    wid = Egui::Id.from(id)
    resp = ui.interact(rect, wid, Egui::Sense::Click)
    target = on ? MusicTags.text
      : (resp.hovered? ? MusicTags.control_hov : MusicTags.control)
    bg = MusicTags.fade(ctx, wid, "bg", target, 150.0)
    fg = on ? MusicTags.window : MusicTags.text
    ui.painter.rect(rect, 15.0, fill: bg)
    ui.painter.text(Egui::Pos2.new(rect.center.x - m.x / 2.0, rect.center.y),
      text, fs, fg)
    if resp.clicked?
      on_click.call
      ctx.request_repaint
    end
  end

  # <cover c1= c2= txt= s= w= h= round= r= fs= shadow=/> — цвета hex-строками
  # из данных библиотеки, парсятся каждый кадр (как интерполяция exml)
  private def cover(ui : Egui::Ui, c1 : String, c2 : String, txt : String,
                    s : Float64, *, w : Float64? = nil, h : Float64? = nil,
                    round : Bool = false, r : Float64 = 8.0,
                    fs : Float64? = nil, shadow : Bool = false) : Nil
    ui.painter.clip = ui.clip
    col1 = MusicTags.hex(c1) || MusicTags.accent
    col2 = MusicTags.hex(c2) || col1
    w_real = w || s
    h_real = h || s
    rounding = round ? {w_real, h_real}.min / 2.0 : r
    fs_real = fs || {h_real * 0.34, 12.0}.max
    rect = ui.allocate_space(Egui::Vec2.new(w_real, h_real))
    if shadow
      ui.painter.box_shadow(rect, Egui::Color32.rgba(0, 0, 0, 0xA6),
        h_real >= 200 ? 38.0 : 28.0, rounding, 6.0,
        Egui::Vec2.new(0.0, h_real >= 200 ? 13.0 : 10.0))
    end
    MusicTags.cover(ui.painter, ui.fonts, rect, col1, col2, txt, rounding, fs_real)
  end

  # <vis n= h= min= mode= show=/>
  private def vis(ui : Egui::Ui, ctx : Egui::Context, key : String,
                  n : Int32, h : Float64, *, min : Float64 = 2.0,
                  playing : Bool, color : Egui::Color32,
                  mode : Symbol = :mini, w : Float64 = 288.0,
                  show : Bool = true) : Nil
    ui.painter.clip = ui.clip
    return unless show
    t_now = ctx.input.time
    levels = MusicTags.vis_step(key, n, playing, t_now)
    if mode == :np
      rect = ui.allocate_space(Egui::Vec2.new(w, h))
      gap_w = 3.0
      bw = (w - gap_w * (n - 1)) / n
      n.times do |i|
        bh = {levels[i] * h, min}.max
        a = ((0.55 + 0.45 * levels[i]) * 255.0).round.clamp(0, 255).to_u8
        x = rect.left + i * (bw + gap_w)
        ui.painter.rect(Egui::Rect.from_min_size(
          Egui::Pos2.new(x, rect.bottom - bh), Egui::Vec2.new(bw, bh)),
          2.0, fill: Egui::Color32.new(color.r, color.g, color.b, a))
      end
    else
      bw = 2.5
      gap_w = 2.0
      w_real = bw * n + gap_w * (n - 1)
      rect = ui.allocate_space(Egui::Vec2.new(w_real, h))
      n.times do |i|
        bh = {levels[i] * h, min}.max
        a = ((0.55 + 0.45 * levels[i]) * 255.0).round.clamp(0, 255).to_u8
        x = rect.left + i * (bw + gap_w)
        ui.painter.rect(Egui::Rect.from_min_size(
          Egui::Pos2.new(x, rect.bottom - bh), Egui::Vec2.new(bw, bh)),
          1.0, fill: Egui::Color32.new(color.r, color.g, color.b, a))
      end
    end
    ctx.request_repaint if playing
  end

  # <mesh c1= c2= c3= fx= animate=/>
  private def mesh(ui : Egui::Ui, ctx : Egui::Context, c1 : String,
                   c2 : String, c3 : String, fx : Int32,
                   animate : Bool) : Nil
    ui.painter.clip = ui.clip
    rect = Egui::Rect.new(ui.cursor,
      Egui::Pos2.new(ui.max_rect.right, ui.max_rect.bottom))
    return if rect.width < 1.0
    p = ui.painter
    col1 = MusicTags.hex(c1) || Egui::Color32.rgba(0x3b, 0x2a, 0x6e, 0xCC)
    col2 = MusicTags.hex(c2) || Egui::Color32.rgba(0x0e, 0x3b, 0x4a, 0xB3)
    col3 = MusicTags.hex(c3) || Egui::Color32.rgba(0x2d, 0x1b, 0x4e, 0x99)
    t_now = ctx.input.time
    bx = ->(cx : Float64, cy : Float64, w : Float64, h : Float64,
            color : Egui::Color32, op : Float64, blur : Float64,
            ax : Float64, ay : Float64, period : Float64, ph : Float64,
            scale_amp : Float64) do
      s = Math.sin(t_now * Math::PI / period + ph)
      dx = animate ? s * ax : 0.0
      dy = animate ? Math.cos(t_now * Math::PI / period + ph) * ay : 0.0
      k = 1.0 + (animate ? scale_amp * (1.0 + s) / 2.0 : scale_amp / 2.0)
      MusicTags.blob(p, cx + dx, cy + dy, w * k, h * k, color, op, blur)
    end
    w = rect.width
    hgt = rect.height
    case fx
    when 1 # Aurora (.fx1)
      bx.call(rect.left - 240.0 + 700.0, rect.top - 60.0 + 210.0, 1400.0, 420.0, col1, 0.8, 90.0, 140.0, 70.0, 70.0, 0.0, 0.09)
      bx.call(rect.left + w + 300.0 - 750.0, rect.top + 300.0 + 190.0, 1500.0, 380.0, col2, 0.75, 90.0, -120.0, 90.0, 80.0, 2.0, 0.09)
      bx.call(rect.left + w * 0.30 + 390.0, rect.top + hgt + 340.0 - 390.0, 780.0, 780.0, col3, 0.3, 90.0, -160.0, -80.0, 52.0, 4.0, 0.15)
    when 2 # Plasma (.fx2)
      bx.call(rect.left - 160.0 + 430.0, rect.top - 200.0 + 320.0, 860.0, 640.0, col1, 0.8, 70.0, 140.0, 70.0, 30.0, 0.0, 0.09)
      bx.call(rect.left + w + 220.0 - 500.0, rect.top - 140.0 + 360.0, 1000.0, 720.0, col2, 0.75, 70.0, -120.0, 90.0, 30.0, 2.0, 0.09)
      bx.call(rect.left + w * 0.30 + 390.0, rect.top + hgt + 340.0 - 390.0, 780.0, 780.0, col3, 0.5, 70.0, -160.0, -80.0, 30.0, 4.0, 0.15)
      bx.call(rect.left + w * 0.55 + 320.0, rect.top + hgt * 0.30 + 320.0, 640.0, 640.0, col2, 0.45, 70.0, 140.0, -70.0, 26.0, 1.0, 0.18)
    when 3 # Spotlight (.fx3)
      bx.call(rect.left + w * 0.32 + 600.0, rect.top - 320.0 + 450.0, 1200.0, 900.0, col1, 0.9, 90.0, 140.0, 70.0, 46.0, 0.0, 0.09)
    when 4 # Shimmer (.fx4)
      bx.call(rect.left - 160.0 + 430.0, rect.top - 200.0 + 320.0, 860.0, 640.0, col1, 0.3, 120.0, 140.0, 70.0, 90.0, 0.0, 0.09)
      bx.call(rect.left + w + 220.0 - 500.0, rect.top - 140.0 + 360.0, 1000.0, 720.0, col2, 0.3, 120.0, -120.0, 90.0, 90.0, 2.0, 0.09)
      bx.call(rect.left + w * 0.30 + 390.0, rect.top + hgt + 340.0 - 390.0, 780.0, 780.0, col3, 0.3, 120.0, -160.0, -80.0, 90.0, 4.0, 0.15)
    else   # Mesh (по умолчанию)
      bx.call(rect.left - 160.0 + 430.0, rect.top - 200.0 + 320.0, 860.0, 640.0, col1, 0.8, 90.0, 140.0, 70.0, 46.0, 0.0, 0.09)
      bx.call(rect.left + w + 220.0 - 500.0, rect.top - 140.0 + 360.0, 1000.0, 720.0, col2, 0.75, 90.0, -120.0, 90.0, 58.0, 2.0, 0.09)
      bx.call(rect.left + w * 0.30 + 390.0, rect.top + hgt + 340.0 - 390.0, 780.0, 780.0, col3, 0.5, 90.0, -160.0, -80.0, 52.0, 4.0, 0.15)
    end
    ctx.request_repaint if animate
  end

  # appear= у панели: входная анимация (Egui::AppearAnims)
  private def appear_xf(ctx : Egui::Context, id : Egui::Id, name : String,
                        delay : Float64)
    return nil if ctx.reduced_motion?
    kind = Egui::AppearAnims.kind?(name)
    return nil unless kind
    xf = ctx.memory.appear_anims.drive(id, kind, delay, ctx.input.time)
    ctx.memory.use_id(id)
    ctx.request_repaint if xf
    xf
  end

  # <panel class= w= h= dir= padx= scroll= bounded= appear= rgrad=/> —
  # возвращает clicked? (клик без on_click ничего не делает, как block в HTML)
  private def panel(ui : Egui::Ui, ctx : Egui::Context, id : String,
                    st : MwStyle = MwStyle::PLAIN, *, w : Float64 = -1.0,
                    h : Float64 = -1.0, dir : Symbol = :column,
                    padx : Float64 = -1.0, bounded : Bool = false,
                    scroll : Bool = false, appear : String? = nil,
                    appear_delay : Float64 = 0.0, rgrad : String? = nil,
                    &children : Egui::Ui ->) : Bool
    ui.painter.clip = ui.clip
    w_real = w >= 0 ? w : ui.available_width
    if h.zero? # h=0: высота по содержимому (CSS height:auto)
      bg_index = ui.painter.add_noop
      content = ui.child_ui(
        Egui::Rect.from_min_size(ui.cursor, Egui::Vec2.new(w_real, 1e6)),
        Egui::Id.from("#{id}/content"), layout: Egui::Layout.top_down)
      content.clip = MusicTags.clip_intersect(
        Egui::Rect.from_min_size(ui.cursor, Egui::Vec2.new(w_real, 1e6)), ui.clip)
      yield content
      h_real = {content.min_rect.height, 1.0}.max
      rect = ui.allocate_space(Egui::Vec2.new(w_real, h_real))
      if (bg = st.bg)
        ui.painter.set(bg_index, Egui::RectCmd.new(ui.painter.clip, rect,
          st.rounding, bg, st.stroke, st.stroke_width, nil, nil))
      end
      return false
    end
    h_real = h >= 0 ? h : ui.available_height
    rect = ui.allocate_space(Egui::Vec2.new(w_real, h_real))
    resp = ui.interact(rect, Egui::Id.from("#{id}/hover"), Egui::Sense::Click)
    hovered = resp.hovered?
    p = ui.painter
    prev_clip = p.clip
    p.clip = rect
    # фон: базовый ↔ hover с transition.background
    bg_base = st.bg
    bg_hover = st.bg_hover || bg_base
    bg = nil
    if bg_hover
      rest = bg_base ||
        Egui::Color32.new(bg_hover.r, bg_hover.g, bg_hover.b, 0u8)
      target = hovered ? bg_hover : rest
      bg = if st.trans_ms > 0.0
        MusicTags.fade(ctx, Egui::Id.from("#{id}/hover"), "bg", target, st.trans_ms)
      else
        target
      end
    end
    grad = rgrad.try { |s| Egui::Gradient.parse?(s) }
    if bg || grad
      p.rect(rect, st.rounding, fill: bg, stroke_color: st.stroke,
        stroke_width: st.stroke_width, gradient: grad)
    end
    xf = appear ? appear_xf(ctx, Egui::Id.from("#{id}/appear"), appear, appear_delay) : nil
    if xf
      p.push_transform(rect.center, xf[:sx], xf[:sy], xf[:dx], xf[:dy], xf[:opacity])
    end
    pad = st.pad
    pl = padx >= 0 ? padx : pad.left
    pr = padx >= 0 ? padx : pad.right
    inner = Egui::Rect.new(
      Egui::Pos2.new(rect.left + pl, rect.top + pad.top),
      Egui::Pos2.new(rect.right - pr, rect.bottom - pad.bottom))
    if scroll
      holder = ui.child_ui(inner, Egui::Id.from("#{id}/scroll"))
      holder.clip = MusicTags.clip_intersect(inner, ui.clip)
      holder.scroll_area do |scroll_ui|
        children.call(scroll_ui)
      end
      p.pop_transform(rect.center) if xf
      p.clip = prev_clip
      return resp.clicked?
    end
    bottom = dir == :row || bounded ? inner.bottom : 1e9
    child = ui.child_ui(
      Egui::Rect.new(inner.min, Egui::Pos2.new(inner.right, bottom)),
      Egui::Id.from(id),
      layout: dir == :row ? Egui::Layout.left_to_right : Egui::Layout.top_down)
    child.wrap_x = true if dir == :row
    child.clip = MusicTags.clip_intersect(inner, ui.clip)
    yield child
    p.pop_transform(rect.center) if xf
    p.clip = prev_clip
    resp.clicked?
  end

  # <crow gap= pad= h=> — ряд карточек без переноса (overflow:hidden)
  private def crow(ui : Egui::Ui, id : String, *, gap : Float64 = 4.0,
                   pad : Float64 = 0.0, h : Float64 = 234.0, &children : Egui::Ui ->) : Nil
    ui.painter.clip = ui.clip
    rect = ui.allocate_space(Egui::Vec2.new(ui.available_width, h))
    child = ui.child_ui(
      Egui::Rect.new(Egui::Pos2.new(rect.left + pad, rect.top),
        Egui::Pos2.new(1e9, 1e9)),
      Egui::Id.from(id), layout: Egui::Layout.left_to_right)
    child.wrap_x = false
    child.clip = MusicTags.clip_intersect(Egui::Rect.new(rect.min,
      Egui::Pos2.new(ui.max_rect.right, rect.bottom)), ui.clip)
    yield child
  end

  # <hline pad=/>
  private def hline(ui : Egui::Ui, pad : Float64 = 0.0) : Nil
    ui.painter.clip = ui.clip
    w = ui.available_width - 2 * pad
    rect = ui.allocate_space(Egui::Vec2.new({w, 0.0}.max, 1.0))
    ui.painter.rect(rect, 0.0, fill: MusicTags.separator)
  end

  # <hbar h= pad=> — строка-контейнер, дети центрированы по вертикали
  private def hbar(ui : Egui::Ui, id : String, h : Float64 = 56.0,
                   pad : Float64 = 0.0, &children : Egui::Ui ->) : Nil
    ui.painter.clip = ui.clip
    rect = ui.allocate_space(Egui::Vec2.new(ui.available_width, h))
    inner = Egui::Rect.from_min_size(
      Egui::Pos2.new(rect.left + pad, rect.top),
      Egui::Vec2.new(rect.width - 2 * pad, h))
    child = ui.child_ui(
      Egui::Rect.new(inner.min, Egui::Pos2.new(inner.right, 1e9)),
      Egui::Id.from(id), layout: Egui::Layout.left_to_right)
    child.wrap_x = false
    child.clip = MusicTags.clip_intersect(Egui::Rect.new(rect.min,
      Egui::Pos2.new(ui.max_rect.right, rect.bottom)), ui.clip)
    child.seed_row_height(h)
    yield child
  end

  # <col w=> — вертикальный стек фиксированной ширины (h — оценка высоты
  # для центрирования в строке, как estimate_height exml)
  private def col(ui : Egui::Ui, id : String, w : Float64, h : Float64,
                  &children : Egui::Ui ->) : Nil
    ui.painter.clip = ui.clip
    rect = ui.allocate_space(Egui::Vec2.new(w, {h, 1.0}.max))
    child = ui.child_ui(
      Egui::Rect.from_min_size(rect.min, Egui::Vec2.new(w, 1e6)),
      Egui::Id.from(id), layout: Egui::Layout.top_down)
    child.clip = MusicTags.clip_intersect(
      Egui::Rect.new(rect.min,
        Egui::Pos2.new(rect.min.x + w, ui.max_rect.bottom)), ui.clip)
    yield child
  end

  # <logo/>
  private def logo(ui : Egui::Ui, s : Float64 = 30.0, isz : Float64 = 18.0) : Nil
    ui.painter.clip = ui.clip
    rect = ui.allocate_space(Egui::Vec2.new(s, s))
    ui.painter.rect(rect, 9.0, fill: MusicTags::WHITE)
    MusicTags.icon("note", MusicTags.window).paint(ui,
      Egui::Rect.from_min_size(
        Egui::Pos2.new(rect.center.x - isz / 2.0, rect.center.y - isz / 2.0),
        Egui::Vec2.new(isz, isz)))
  end

  # <avatar/>
  private def avatar(ui : Egui::Ui, s : Float64 = 30.0) : Nil
    ui.painter.clip = ui.clip
    rect = ui.allocate_space(Egui::Vec2.new(s, s))
    p = ui.painter
    p.circle_filled(rect.center, s / 2.0, Egui::Color32.rgb(0xe8, 0xa9, 0x3b))
    m = ui.fonts.measure("M", 14.0)
    p.text(Egui::Pos2.new(rect.center.x - m.x / 2.0, rect.center.y),
      "M", 14.0, MusicTags.window, bold: true)
  end

  # <playround icon= s= size= big=/>
  private def playround(ui : Egui::Ui, ctx : Egui::Context, id : String,
                        name : String, accent : Egui::Color32, *,
                        s : Float64 = 40.0, size : Float64? = nil,
                        big : Bool = false, &on_click) : Nil
    ui.painter.clip = ui.clip
    isz = size || s * 0.45
    rect = ui.allocate_space(Egui::Vec2.new(s, s))
    wid = Egui::Id.from(id)
    resp = ui.interact(rect, wid, Egui::Sense::Click)
    bg = big ? accent : MusicTags.text
    fg = MusicTags.window
    sc = MusicTags.glide(ctx, wid, "scale",
      resp.active? ? (big ? 0.97 : 0.95) : (resp.hovered? ? 1.06 : 1.0), 120.0)
    lift = big ? 0.08 : -0.04
    depth = MusicTags.lerp(0.0, 1.0, (sc - 1.0) / 0.06)
    bg = Egui::Color32.new(
      (bg.r.to_f64 * (1.0 + lift * depth)).round.clamp(0, 255).to_u8,
      (bg.g.to_f64 * (1.0 + lift * depth)).round.clamp(0, 255).to_u8,
      (bg.b.to_f64 * (1.0 + lift * depth)).round.clamp(0, 255).to_u8, bg.a)
    rs = s / 2.0 * sc
    grow = (rs - s / 2.0).abs
    saved_clip = ui.painter.clip
    ui.painter.clip = saved_clip.expand(grow)
    ui.painter.circle_filled(rect.center, rs, bg)
    MusicTags.icon(name, fg).paint(ui, Egui::Rect.from_min_size(
      Egui::Pos2.new(rect.center.x - isz * sc / 2.0,
        rect.center.y - isz * sc / 2.0),
      Egui::Vec2.new(isz * sc, isz * sc)))
    ui.painter.clip = saved_clip
    if resp.clicked?
      on_click.call
      ctx.request_repaint
    end
  end

  # <gtile g= t= c1= c2= txt=/> — плитка жанра
  private def gtile(ui : Egui::Ui, ctx : Egui::Context, id : String,
                    g : String, title : String, c1 : String, c2 : String,
                    txt : String, w : Float64 = 184.0, h : Float64 = 112.0,
                    &on_click) : Nil
    ui.painter.clip = ui.clip
    gcol = MusicTags.hex(g) || MusicTags.accent
    col1 = MusicTags.hex(c1) || MusicTags.accent
    col2 = MusicTags.hex(c2) || col1
    padb = 16.0 # запас под перенос строк
    rect = ui.allocate_space(Egui::Vec2.new(w, h + padb))
    rect = Egui::Rect.from_min_size(rect.min, Egui::Vec2.new(w, h))
    p = ui.painter
    wid = Egui::Id.from(id)
    resp = ui.interact(rect, wid, Egui::Sense::Click)
    sc = MusicTags.glide(ctx, wid, "scale", resp.hovered? ? 1.03 : 1.0, 150.0)
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
    fill = gcol
    if depth > 0.0
      k = 1.0 + 0.085 * depth
      fill = Egui::Color32.new(
        (gcol.r.to_f64 * k).round.clamp(0, 255).to_u8,
        (gcol.g.to_f64 * k).round.clamp(0, 255).to_u8,
        (gcol.b.to_f64 * k).round.clamp(0, 255).to_u8, gcol.a)
    end
    p.rect(vis, 10.0, fill: fill)
    p.text(Egui::Pos2.new(vis.left + 16.0, vis.top + 14.0 + 11.0),
      title, 22.0, MusicTags::WHITE, bold: true)
    MusicTags.cover(p, ui.fonts,
      Egui::Rect.from_min_size(
        Egui::Pos2.new(vis.right - 70.0, vis.bottom - 72.0),
        Egui::Vec2.new(80.0, 80.0)), col1, col2, txt, 6.0, 18.0)
    p.clip = prev
    if resp.clicked?
      on_click.call
      ctx.request_repaint
    end
  end

  # <hero c1= c2=/> — шапка коллекции (два радиальных пятна)
  private def hero(ui : Egui::Ui, id : String, c1 : String, c2 : String,
                   h : Float64 = 298.0, &children : Egui::Ui ->) : Nil
    ui.painter.clip = ui.clip
    rect = ui.allocate_space(Egui::Vec2.new(ui.available_width, h))
    p = ui.painter
    prev = p.clip
    p.clip = rect
    p.rect(rect, 0.0, fill: Egui::Color32.rgb(0x11, 0x11, 0x17))
    col1 = MusicTags.hex(c1) || Egui::Color32.rgba(0xe9, 0x22, 0x36, 0xFF)
    col2 = MusicTags.hex(c2) || Egui::Color32.rgba(0x57, 0x1d, 0xc6, 0xFF)
    MusicTags.spot(p, rect, 0.75, -0.10, 1200.0, 500.0, col1, 0.70)
    MusicTags.spot(p, rect, 0.15, 1.20, 900.0, 500.0, col2, 0.70)
    inner = Egui::Rect.new(
      Egui::Pos2.new(rect.left + 28.0, rect.top + 40.0),
      Egui::Pos2.new(rect.right - 28.0, rect.bottom - 26.0))
    child = ui.child_ui(inner, Egui::Id.from(id),
      layout: Egui::Layout.left_to_right)
    child.clip = MusicTags.clip_intersect(rect, ui.clip)
    yield child
    p.clip = prev
  end

  # <oswitch on= on_click=/>
  private def oswitch(ui : Egui::Ui, ctx : Egui::Context, id : String,
                      on : Bool, accent : Egui::Color32, &on_click) : Nil
    ui.painter.clip = ui.clip
    rect = ui.allocate_space(Egui::Vec2.new(44.0, 24.0))
    wid = Egui::Id.from(id)
    resp = ui.interact(rect, wid, Egui::Sense::Click)
    p = ui.painter
    if resp.hovered?
      p.rect(rect, 12.0, fill: MusicTags.row_hover)
    end
    pos = MusicTags.glide(ctx, wid, "knob", on ? 1.0 : 0.0, 180.0)
    bg = MusicTags.fade(ctx, wid, "bg", on ? accent : MusicTags.control, 180.0)
    p.rect(rect, 12.0, fill: bg)
    kx = MusicTags.lerp(rect.left + 2.0, rect.left + 22.0, pos)
    p.circle_filled(Egui::Pos2.new(kx + 10.0, rect.center.y), 10.0, MusicTags.strong)
    if resp.clicked?
      on_click.call
      ctx.request_repaint
    end
  end

  # <swatch/>
  private def swatch(ui : Egui::Ui, accent : Egui::Color32, s : Float64 = 34.0) : Nil
    ui.painter.clip = ui.clip
    rect = ui.allocate_space(Egui::Vec2.new(s, s))
    ui.painter.rect(rect, 8.0, fill: accent)
  end

  # <ocombo bind= w=/> — опции списком, открытое состояние в @combo_open
  private def ocombo(ui : Egui::Ui, ctx : Egui::Context, id : String,
                     key : String, text : String, options : Array(String),
                     w : Float64 = 160.0, h : Float64 = 34.0,
                     &on_change : String ->) : Nil
    ui.painter.clip = ui.clip
    rect = ui.allocate_space(Egui::Vec2.new(w, h))
    resp = ui.interact(rect, Egui::Id.from(id), Egui::Sense::Click)
    p = ui.painter
    open = @combo_open == key
    p.rect(rect, 8.0,
      fill: resp.hovered? || open ? MusicTags.control_hov : MusicTags.control,
      stroke_color: MusicTags.border, stroke_width: 1.0)
    p.text(Egui::Pos2.new(rect.left + 12.0, rect.center.y), text, 14.0,
      MusicTags.text)
    MusicTags.icon("chev", Egui::Color32.rgba(0xc4, 0xc4, 0xd2, 0xB3)).paint(ui,
      Egui::Rect.from_min_size(
        Egui::Pos2.new(rect.right - 12.0 - 16.0, rect.center.y - 8.0),
        Egui::Vec2.new(16.0, 16.0)))
    if resp.clicked?
      @combo_open = open ? "" : key
      ctx.request_repaint
    end
    return unless open
    layer = Egui::LayerId.new(Egui::Order::Foreground, Egui::Id.from("combo/#{key}"))
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
    lp.rect(list_rect, 8.0, fill: MusicTags.popup,
      stroke_color: MusicTags.border, stroke_width: 1.0)
    options.each_with_index do |opt, i|
      orect = Egui::Rect.from_min_size(
        Egui::Pos2.new(list_rect.left + 4.0, list_rect.top + 4.0 + i * item_h),
        Egui::Vec2.new(list_rect.width - 8.0, item_h))
      oresp = ctx.interact(Egui::Id.from("#{id}/opt#{i}"), orect,
        Egui::Sense::Click, layer, orect)
      if oresp.hovered?
        lp.rect(orect, 6.0, fill: MusicTags.control)
      end
      lp.text(Egui::Pos2.new(orect.left + 8.0, orect.center.y), opt, 14.0,
        opt == text ? MusicTags.strong : MusicTags.muted)
      if oresp.clicked?
        @combo_open = ""
        on_change.call(opt)
        ctx.request_repaint
      end
    end
    lp.layer = prev_layer
    lp.clip = prev_clip
  end

  # <oslider bind= w=/> — track 4px + fill + knob; drag → on_change(frac)
  private def oslider(ui : Egui::Ui, ctx : Egui::Context, id : String,
                      frac : Float64, accent : Egui::Color32,
                      w : Float64 = -1.0, &on_change : Float64 ->) : Nil
    ui.painter.clip = ui.clip
    frac = frac.clamp(0.0, 1.0)
    w = ui.available_width if w < 0
    rect = ui.allocate_space(Egui::Vec2.new(w, 16.0))
    wid = Egui::Id.from(id)
    resp = ui.interact(Egui::Rect.from_min_size(rect.min,
      Egui::Vec2.new(w, 12.0)), wid, Egui::Sense::Click | Egui::Sense::Drag)
    if (resp.dragged? || resp.clicked?) && (ptr = ctx.input.pointer_pos)
      frac = ((ptr.x - rect.left) / w).clamp(0.0, 1.0)
      on_change.call(frac)
      ctx.request_repaint
    end
    p = ui.painter
    cy = rect.center.y
    kw = MusicTags.glide(ctx, wid, "kw",
      resp.hovered? || resp.dragged? ? 7.5 : 6.0, 100.0)
    p.rect(Egui::Rect.from_min_size(Egui::Pos2.new(rect.left, cy - 2.0),
      Egui::Vec2.new(w, 4.0)), 2.0,
      fill: Egui::Color32.rgba(255, 255, 255, 0x33))
    p.rect(Egui::Rect.from_min_size(Egui::Pos2.new(rect.left, cy - 2.0),
      Egui::Vec2.new(w * frac, 4.0)), 2.0, fill: accent)
    p.circle_filled(Egui::Pos2.new(rect.left + w * frac, cy), kw, MusicTags.strong)
  end

  # <searchinput bind= w=/> — поле поиска: клик — фокус, ввод — query
  private def search_input(ui : Egui::Ui, ctx : Egui::Context,
                           w : Float64 = 280.0) : Nil
    ui.painter.clip = ui.clip
    hint = "What do you want to play?"
    rect = ui.allocate_space(Egui::Vec2.new(w, 40.0))
    wid = Egui::Id.from("header/search")
    resp = ui.interact(rect, wid, Egui::Sense::Click)
    if resp.clicked?
      @focus = true
      ctx.request_repaint
    end
    if @focus && ctx.input.key_pressed?(Egui::KeyCode::Escape)
      if ctx.input.consume_key(Egui::KeyCode::Escape)
        @focus = false # blur, текст сохраняется
        ctx.request_repaint
      end
    end
    if @focus
      txt = @player.query
      add = ctx.input.text
      if !add.empty? && !ctx.input.shortcut_modifiers_down?
        @player.query = (txt + add)[0, 40]
        search_changed(ctx)
      end
      if ctx.input.key_pressed?(Egui::KeyCode::Backspace)
        if ctx.input.consume_key(Egui::KeyCode::Backspace)
          t = @player.query
          @player.query = t.size > 1 ? t[0...-1] : ""
          search_changed(ctx)
        end
      end
      ctx.request_repaint
    end
    p = ui.painter
    p.rect(rect, 20.0, fill: MusicTags.search_bg,
      stroke_color: @focus ? MusicTags.accent : nil, stroke_width: 1.0)
    MusicTags.icon("search", Egui::Color32.rgba(0x8a, 0x8a, 0x99, 0xB3)).paint(ui,
      Egui::Rect.from_min_size(
        Egui::Pos2.new(rect.left + 14.0, rect.center.y - 9.0),
        Egui::Vec2.new(18.0, 18.0)))
    txt = @player.query
    if txt.empty?
      p.text(Egui::Pos2.new(rect.left + 42.0, rect.center.y),
        hint, 14.0, MusicTags.placeholder)
    else
      m = ui.fonts.measure(txt, 14.0)
      caret_x = rect.left + 42.0 + {m.x, rect.width - 60.0}.min
      p.text(Egui::Pos2.new(rect.left + 42.0, rect.center.y),
        txt[0, 28], 14.0, MusicTags.text)
      if (ctx.input.time * 2.0).to_i % 2 == 0
        p.rect(Egui::Rect.from_min_size(
          Egui::Pos2.new(caret_x + 1.0, rect.center.y - 8.0),
          Egui::Vec2.new(1.0, 16.0)), 0.0, fill: MusicTags.text)
      end
    end
  end

  # живой фильтр по каждому нажатию (searchinput → search_changed)
  private def search_changed(ctx : Egui::Context) : Nil
    p = @player
    p.nav_to(:search) if p.page != :search && !p.query.strip.empty?
    ctx.request_repaint
  end
end

# ═════════════════════════════════════════════════════════════════════
# ВЕРСТКА (структура assets/music.exml прямыми вызовами)
# ═════════════════════════════════════════════════════════════════════
class MusicWidgetsManualApp
  # <page id="root/root">: mesh, header, mainarea, playerbar, island
  private def render_root(ui : Egui::Ui, ctx : Egui::Context,
                          accent : Egui::Color32) : Nil
    p = @player
    album = p.album
    mesh(ui, ctx, MusicLibrary.scale_hex(album.c1, 0.55),
      MusicLibrary.scale_hex(album.c2, 0.35),
      MusicLibrary.scale_hex(album.c1, 0.35), p.effect, p.animate) if p.effect != 5
    header(ui, ctx)
    mainarea(ui, ctx, accent)
    player_bar(ui, ctx, accent)
    island(ui, ctx, accent)
  end

  # <partial id="header"> — шапка
  private def header(ui : Egui::Ui, ctx : Egui::Context) : Nil
    p = @player
    hbar(ui, "header", 56.0, pad: 12.0) do |c|
      logo(c)
      gap(c, 8.0)
      t(c, "Raven Music", size: 16.0, bold: true)
      gap(c, 36.0)
      ibtn(c, ctx, "header/back", "back") { p.back }
      gap(c, 8.0)
      ibtn(c, ctx, "header/home", "home", size: 20.0) { p.nav_to(:home) }
      gap(c, 8.0)
      search_input(c, ctx, 280.0)
      # хвост: settings(btn34) + gap4 + avatar(30) = 68
      rspring(c, 68.0)
      ibtn(c, ctx, "header/settings", "settings", size: 20.0) { p.nav_to(:settings) }
      gap(c, 4.0)
      avatar(c)
    end
  end

  # <partial id="sidebar"> — навигация + библиотека
  private def sidebar(ui : Egui::Ui, ctx : Egui::Context) : Nil
    p = @player
    panel(ui, ctx, "side", MwStyle::PLAIN, w: 300.0) do |c|
      panel(c, ctx, "side/navbox", MwStyle::NAVBOX, h: 120.0) do |n|
        navitem(n, ctx, "side/nav_home", "home", "Home", p.page == :home) { p.nav_to(:home) }
        gap(n, 2.0)
        navitem(n, ctx, "side/nav_search", "search", "Search", p.page == :search) { p.nav_to(:search) }
        gap(n, 2.0)
        navitem(n, ctx, "side/nav_settings", "settings", "Settings", p.page == :settings) { p.nav_to(:settings) }
      end
      gap(c, 11.0)
      panel(c, ctx, "side/libbox", MwStyle::LIBBOX) do |lb|
        hbar(lb, "side/libhead", 32.0) do |h|
          navitem(h, ctx, "side/nav_library", "library", "Your library",
            {"library", "collection"}.includes?(p.page.to_s), pad: 4.0) { p.nav_to(:library) }
          rspring(h, 28.0) # хвост: plus(btn28)
          ibtn(h, ctx, "side/plus", "plus", btn: 28.0) { p.notify("Not in this demo", ctx.input.time) }
        end
        gap(lb, 10.0)
        hbar(lb, "side/chips", 30.0, pad: 6.0) do |h|
          chip(h, ctx, "side/ch_all", "All", p.lib_filter == 0) { p.lib_filter = 0 }
          gap(h, 8.0)
          chip(h, ctx, "side/ch_playlists", "Playlists", p.lib_filter == 1) { p.lib_filter = 1 }
          gap(h, 8.0)
          chip(h, ctx, "side/ch_albums", "Albums", p.lib_filter == 2) { p.lib_filter = 2 }
        end
        gap(lb, 10.0)
        # repeat lib_rows: строки-плейлисты/альбомы по lib_filter
        rows = sidebar_rows
        rows.each_with_index do |row, i|
          clicked = panel(lb, ctx, "side/row/#{i}", MwStyle::LIB_ROW,
            dir: :row, h: 54.0) do |r|
            cover(r, row[:c1], row[:c2], row[:txt], 46.0,
              round: row[:round], r: 8.0, fs: 15.0)
            gap(r, 12.0)
            col(r, "side/row/#{i}/t", 190.0, 14.0 * 1.35 + 3.0 + 12.0 * 1.35) do |cc|
              t(cc, row[:t], size: 14.0)
              gap(cc, 3.0)
              t(cc, row[:s], size: 12.0, color: MusicTags.muted)
            end
          end
          if clicked
            if row[:kind] == :pl
              p.open_playlist(row[:idx])
            else
              p.open_album(row[:idx], ctx.input.time)
            end
            ctx.request_repaint
          end
          gap(lb, 2.0)
        end
      end
    end
  end

  # фильтры сайдбара — как fill_sidebar()
  private def sidebar_rows : Array(NamedTuple(kind: Symbol, idx: Int32,
                                              c1: String, c2: String,
                                              txt: String, round: Bool,
                                              t: String, s: String))
    p = @player
    library = @library
    rows = [] of NamedTuple(kind: Symbol, idx: Int32, c1: String, c2: String,
      txt: String, round: Bool, t: String, s: String)
    if p.lib_filter != 2
      library.playlists.each_with_index do |pl, pi|
        n = pi == 0 ? library.liked_tracks.size : pl.track_list.size
        if pi == 0
          rows << {kind: :pl, idx: pi, c1: "#B79CFF", c2: "#6D28D9", txt: "♥",
                   round: true, t: pl.title, s: "Playlist · #{n} songs"}
        else
          a = library.albums[pl.cover]
          rows << {kind: :pl, idx: pi, c1: a.c1, c2: a.c2, txt: a.ini,
                   round: true, t: pl.title, s: "Playlist · #{n} songs"}
        end
      end
    end
    if p.lib_filter != 1
      library.albums.each_with_index do |a, ai|
        rows << {kind: :al, idx: ai, c1: a.c1, c2: a.c2, txt: a.ini,
                 round: false, t: a.title, s: "Album · #{a.artist}"}
      end
    end
    rows
  end

  # <mainarea pad=8 reserve=88> — центральная строка: сайдбар/центр/np
  private def mainarea(ui : Egui::Ui, ctx : Egui::Context,
                       accent : Egui::Color32) : Nil
    p = @player
    pad = 8.0
    rect = ui.allocate_space(Egui::Vec2.new(ui.available_width,
      ui.available_height - 88.0))
    inner = Egui::Rect.new(
      Egui::Pos2.new(rect.left + pad, rect.top + pad),
      Egui::Pos2.new(rect.right - pad, rect.bottom - pad))
    child = ui.child_ui(inner, Egui::Id.from("mainarea"),
      layout: Egui::Layout.left_to_right)
    child.clip = MusicTags.clip_intersect(rect, ui.clip)
    sidebar(child, ctx)
    gap(child, 8.0)
    # центр всегда занимает остаток строки (computed .center{flex:1})
    center_w = ctx.input.screen_rect.width - 2 * 8 - 300 - 8 -
               (p.panel ? 320 + 8 : 0)
    panel(child, ctx, "center", MwStyle::CENTER, w: center_w,
      bounded: true) do |c|
      case p.page
      when :home       then page_home(c, ctx, accent)
      when :search     then page_search(c, ctx, accent)
      when :settings   then page_settings(c, ctx, accent)
      when :library    then page_library(c, ctx, accent)
      when :collection then page_collection(c, ctx, accent)
      end
    end
    gap(child, 8.0)
    now_playing(child, ctx, accent) if p.panel
  end

  # <partial id="nowplaying"> — правая панель
  private def now_playing(ui : Egui::Ui, ctx : Egui::Context,
                          accent : Egui::Color32) : Nil
    p = @player
    album = p.album
    obj = p.track_obj
    library = @library
    heart_col = obj.try(&.liked) ? accent : MusicTags.icon
    panel(ui, ctx, "np", MwStyle::NOWPLAYING, w: 320.0, scroll: true) do |c|
      hbar(c, "np/head", 28.0) do |h|
        t(h, "From #{p.context}", size: 15.0, bold: true)
        rspring(h, 56.0) # хвост: more(28) + close(28)
        ibtn(h, ctx, "np/more", "more", btn: 28.0) { p.notify("Not in this demo", ctx.input.time) }
        ibtn(h, ctx, "np/close", "close", btn: 28.0) { p.panel = false }
      end
      gap(c, 14.0)
      cover(c, album.c1, album.c2, album.ini, 288.0, r: 10.0, fs: 60.0, shadow: true)
      gap(c, 14.0)
      hbar(c, "np/title", 48.0) do |h|
        col(h, "np/title/t", 200.0, 22.0 * 1.35 + 3.0 + 15.0 * 1.35) do |cc|
          t(cc, obj ? obj.title : "", size: 22.0, bold: true)
          gap(cc, 3.0)
          t(cc, album.artist, size: 15.0, color: MusicTags.muted)
        end
        rspring(h, 56.0) # хвост: share(28) + heart(28)
        ibtn(h, ctx, "np/share", "share", btn: 28.0, size: 20.0) { p.notify("Not in this demo", ctx.input.time) }
        ibtn(h, ctx, "np/heart", obj.try(&.liked) ? "heart-f" : "heart",
          tint: heart_col, btn: 28.0, size: 20.0) { p.like_current(ctx.input.time) }
      end
      gap(c, 14.0)
      vis(c, ctx, "np/vis", 36, 56.0, min: 4.0, playing: p.playing,
        color: accent, mode: :np, w: 288.0)
      gap(c, 14.0)
      rgrad = "radial-gradient(400px 200px at 80% 0%, " \
              "#{MusicLibrary.scale_hex(album.c1, 0.7)}, #111117 85%)"
      panel(c, ctx, "np/artist", MwStyle::NP_ARTIST, h: 182.0, rgrad: rgrad) do |a|
        t(a, "ABOUT THE ARTIST", size: 12.0, bold: true, color: MusicTags::WHITE, ls: 0.08)
        gap(a, 6.0)
        t(a, album.artist, size: 20.0, bold: true, color: MusicTags::WHITE)
        gap(a, 6.0)
        t(a, "2,341,992 monthly listeners", size: 14.0,
          color: Egui::Color32.rgba(255, 255, 255, 0xCC))
        gap(a, 6.0)
        t(a, "An indie rock band known for wide, slow songs and long instrumental passages. Their eleventh album, Tides, came out in 2026.",
          size: 13.0, color: Egui::Color32.rgba(255, 255, 255, 0xD9),
          w: 256.0, wrap: true, lh: 1.5)
      end
      gap(c, 14.0)
      panel(c, ctx, "np/queue", MwStyle::NP_QUEUE, h: 0.0) do |q|
        hbar(q, "np/queue/head", 22.0) do |h|
          t(h, "Next in queue", size: 15.0, bold: true)
          rspring(h, 0.0)
          t(h, "Open queue", size: 14.0, color: MusicTags.muted)
        end
        gap(q, 8.0)
        queue = p.queue[p.queue_pos + 1..].first(4)
        if queue.empty?
          t(q, "Nothing after this song.", size: 14.0, color: MusicTags.muted)
        else
          queue.each_with_index do |ti, i|
            tr = library.tracks[ti]
            a = library.albums[tr.album]
            clicked = panel(q, ctx, "np/queue/row/#{i}", MwStyle::PLAIN,
              dir: :row, h: 42.0) do |r|
              cover(r, a.c1, a.c2, a.ini, 36.0, r: 4.0, fs: 12.0)
              gap(r, 10.0)
              col(r, "np/queue/row/#{i}/t", 190.0, 14.0 * 1.35 + 2.0 + 12.0 * 1.35) do |cc|
                t(cc, tr.title, size: 14.0)
                gap(cc, 2.0)
                t(cc, a.artist, size: 12.0, color: MusicTags.muted)
              end
            end
            if clicked
              p.jump_queue(i)
              ctx.request_repaint
            end
            gap(q, 6.0)
          end
        end
      end
    end
  end

  # <partial id="playerbar"> — нижний бар: 3 колонки 1fr/1.3fr/1fr
  private def player_bar(ui : Egui::Ui, ctx : Egui::Context,
                         accent : Egui::Color32) : Nil
    p = @player
    album = p.album
    obj = p.track_obj
    library = @library
    h = 88.0
    rect = ui.allocate_space(Egui::Vec2.new(ui.available_width, h))
    pa = ui.painter
    pa.rect(rect, 0.0, fill: MusicTags.bar_bg)
    total = rect.width - 32.0
    c13 = total / 3.3
    c2w = total - 2 * c13
    xs = {rect.left + 16.0, rect.left + 16.0 + c13, rect.left + 16.0 + c13 + c2w}
    ws = {c13, c2w, c13}
    heights = {88.0, 60.0, 88.0} # как estimate_height exml
    # колонка 0: обложка + названия + лайк
    col0 = Egui::Rect.from_min_size(
      Egui::Pos2.new(xs[0], rect.top + (h - heights[0]) / 2.0),
      Egui::Vec2.new(ws[0], heights[0]))
    c0 = ui.child_ui(col0, Egui::Id.from("pb/col0"), layout: Egui::Layout.top_down)
    c0.clip = Egui::Rect.from_min_size(Egui::Pos2.new(xs[0], rect.top),
      Egui::Vec2.new(ws[0], h))
    hbar(c0, "pb/c0", 88.0) do |r|
      cover(r, album.c1, album.c2, album.ini, 58.0, r: 6.0, fs: 20.0)
      gap(r, 14.0)
      col(r, "pb/c0/t", 200.0, 15.0 * 1.35 + 3.0 + 13.0 * 1.35) do |cc|
        t(cc, obj ? obj.title : "", size: 15.0)
        gap(cc, 3.0)
        t(cc, album.artist, size: 13.0, color: MusicTags.muted)
      end
      gap(r, 14.0)
      ibtn(r, ctx, "pb/heart", obj.try(&.liked) ? "heart-f" : "heart",
        tint: obj.try(&.liked) ? accent : MusicTags.icon) { p.like_current(ctx.input.time) }
    end
    # колонка 1: транспорт + seek
    col1 = Egui::Rect.from_min_size(
      Egui::Pos2.new(xs[1], rect.top + (h - heights[1]) / 2.0),
      Egui::Vec2.new(ws[1], heights[1]))
    c1 = ui.child_ui(col1, Egui::Id.from("pb/col1"), layout: Egui::Layout.top_down)
    c1.clip = Egui::Rect.from_min_size(Egui::Pos2.new(xs[1], rect.top),
      Egui::Vec2.new(ws[1], h))
    hbar(c1, "pb/c1/transport", 40.0) do |r|
      # кластер 224px (34+12+34+12+40+12+34+12+34) между двумя пружинами
      sw = (r.available_width - 224.0) / 2.0
      r.allocate_space(Egui::Vec2.new({sw, 0.0}.max, 0.0))
      ibtn(r, ctx, "pb/shuffle", "shuffle", size: 18.0,
        tint: p.shuffle ? accent : MusicTags.icon) { p.toggle_shuffle(ctx.input.time) }
      gap(r, 12.0)
      ibtn(r, ctx, "pb/prev", "prev") { p.prev_track }
      gap(r, 12.0)
      playround(r, ctx, "pb/play", p.playing ? "pause" : "play", accent, s: 40.0, size: 18.0) { p.toggle(ctx.input.time) }
      gap(r, 12.0)
      ibtn(r, ctx, "pb/next", "next") { p.next_track }
      gap(r, 12.0)
      ibtn(r, ctx, "pb/repeat", p.repeat_mode == 2 ? "repeat1" : "repeat",
        size: 18.0, tint: p.repeat_mode != 0 ? accent : MusicTags.icon) { p.cycle_repeat(ctx.input.time) }
      r.allocate_space(Egui::Vec2.new({sw, 0.0}.max, 0.0))
    end
    gap(c1, 4.0)
    hbar(c1, "pb/c1/seek", 16.0) do |r|
      t(r, MusicLibrary.fmt_time(p.position), size: 12.0, color: MusicTags.muted, w: 40.0, align: "r")
      gap(r, 10.0)
      oslider(r, ctx, "pb/seek", p.seek_frac, accent) { |f| p.seek(f) }
      gap(r, 10.0)
      t(r, obj ? MusicLibrary.fmt_time(obj.seconds.to_f64) : "0:00",
        size: 12.0, color: MusicTags.muted, w: 40.0)
    end
    # колонка 2: vis + кнопки + громкость
    col2 = Egui::Rect.from_min_size(
      Egui::Pos2.new(xs[2], rect.top + (h - heights[2]) / 2.0),
      Egui::Vec2.new(ws[2], heights[2]))
    c2 = ui.child_ui(col2, Egui::Id.from("pb/col2"), layout: Egui::Layout.top_down)
    c2.clip = Egui::Rect.from_min_size(Egui::Pos2.new(xs[2], rect.top),
      Egui::Vec2.new(ws[2], h))
    hbar(c2, "pb/c2", 88.0) do |r|
      # хвост: vis(20.5)+8+30+6+30+6+30+6+30+4+120 = 290.5
      rspring(r, 290.5)
      vis(r, ctx, "pb/vis", 5, 16.0, min: 2.0, playing: p.playing, color: accent)
      gap(r, 8.0)
      ibtn(r, ctx, "pb/mic", "mic", btn: 30.0) { p.notify("Not in this demo", ctx.input.time) }
      gap(r, 6.0)
      ibtn(r, ctx, "pb/panel", "panel", btn: 30.0) { p.panel = !p.panel }
      gap(r, 6.0)
      ibtn(r, ctx, "pb/queue", "queue", btn: 30.0) { p.notify("Not in this demo", ctx.input.time) }
      gap(r, 6.0)
      ibtn(r, ctx, "pb/vol", (p.muted || p.volume <= 0.001) ? "muted" : "volume",
        btn: 30.0) { p.toggle_mute(ctx.input.time) }
      gap(r, 4.0)
      oslider(r, ctx, "pb/vol", p.muted ? 0.0 : p.volume, accent, w: 120.0) do |f|
        p.set_volume(f, ctx.input.time)
      end
    end
  end
end

# ═════════════════════════════════════════════════════════════════════
# СТРАНИЦЫ ЦЕНТРА (partials p_home/p_search/p_settings/p_library/
# p_collection — panel class="center-page" scroll=1 appear=fade общий)
# ═════════════════════════════════════════════════════════════════════
class MusicWidgetsManualApp
  # обёртка страницы: скроллируемая центральная панель с fade-входом
  private def center_page(ui : Egui::Ui, ctx : Egui::Context, page : String,
                          &children : Egui::Ui ->) : Nil
    panel(ui, ctx, "page/#{page}", MwStyle::CENTER_PAGE, scroll: true,
      appear: "fade", &children)
  end

  # ── Home ────────────────────────────────────────────────────────────
  private def page_home(ui : Egui::Ui, ctx : Egui::Context,
                        accent : Egui::Color32) : Nil
    p = @player
    library = @library
    cur_album = p.track_obj.try(&.album) || -1
    center_page(ui, ctx, "home") do |c|
      hbar(c, "home/chips", 30.0, pad: 0.0) do |h|
        chip(h, ctx, "home/ch_all", "All", true) { }
        gap(h, 8.0)
        chip(h, ctx, "home/ch_music", "Music", false) { p.notify("Only music here", ctx.input.time) }
        gap(h, 8.0)
        chip(h, ctx, "home/ch_pod", "Podcasts", false) { p.notify("Only music here", ctx.input.time) }
        gap(h, 8.0)
        chip(h, ctx, "home/ch_books", "Audiobooks", false) { p.notify("Only music here", ctx.input.time) }
      end
      gap(c, 14.0)
      t(c, greeting, size: 30.0, bold: true, h: 46.0)
      gap(c, 6.0)
      quick_row(c, ctx, "qa", [3, 1, 2], cur_album, accent)
      gap(c, 10.0)
      quick_row(c, ctx, "qb", [0, 4, 5], cur_album, accent)
      gap(c, 14.0)
      section_header(c, ctx, "home/h_made", "Made for you", true)
      crow(c, "home/made") do |row|
        (1..5).each_with_index do |pi, i|
          pl = library.playlists[pi]
          a = library.albums[pl.cover]
          album_card(row, ctx, "home/made/#{i}", a.c1, a.c2, a.ini, true,
            pl.title, pl.description, i) { p.open_playlist(pi) }
          gap(row, 4.0)
        end
      end
      section_header(c, ctx, "home/h_recent", "Recently played", true)
      crow(c, "home/recent") do |row|
        [6, 7, 8, 9, 10].each_with_index do |ai, i|
          a = library.albums[ai]
          album_card(row, ctx, "home/recent/#{i}", a.c1, a.c2, a.ini, false,
            a.title, "#{a.year} · #{a.artist}", i) { p.open_album(ai, ctx.input.time) }
          gap(row, 4.0)
        end
      end
      section_header(c, ctx, "home/h_artists", "Your favorite artists", false)
      crow(c, "home/artists") do |row|
        [6, 5, 2, 9, 3].each_with_index do |ai, i|
          a = library.albums[ai]
          album_card(row, ctx, "home/artists/#{i}", a.c1, a.c2, a.ini, true,
            a.artist, "Artist", i) { p.open_album(ai, ctx.input.time) }
          gap(row, 4.0)
        end
      end
      section_header(c, ctx, "home/h_new", "New releases", true)
      crow(c, "home/releases") do |row|
        releases = (0...library.albums.size).to_a
          .sort_by { |ai| {-library.albums[ai].year, ai} }
        releases.each_with_index do |ai, i|
          a = library.albums[ai]
          album_card(row, ctx, "home/releases/#{i}", a.c1, a.c2, a.ini, false,
            a.title, "#{a.year} · #{a.artist}", i) { p.open_album(ai, ctx.input.time) }
          gap(row, 4.0)
        end
      end
    end
  end

  # ряд quick-подборок (две строки карточек .quick)
  private def quick_row(ui : Egui::Ui, ctx : Egui::Context, key : String,
                        album_ids : Array(Int32), cur_album : Int32,
                        accent : Egui::Color32) : Nil
    p = @player
    panel(ui, ctx, "home/#{key}", MwStyle::PLAIN, dir: :row, h: 60.0) do |row|
      album_ids.each do |ai|
        a = @library.albums[ai]
        clicked = panel(row, ctx, "home/#{key}/#{ai}", MwStyle::QUICK,
          dir: :row, w: 210.0, h: 60.0) do |q|
          cover(q, a.c1, a.c2, a.ini, 60.0, r: 6.0, fs: 18.0)
          gap(q, 12.0)
          t(q, a.title, size: 14.0, bold: true, w: 98.0)
          rspring(q, 28.0) # хвост: vis(16) + gap12
          vis(q, ctx, "home/#{key}/#{ai}/vis", 4, 14.0, min: 2.0,
            playing: p.playing, color: accent, show: ai == cur_album)
          gap(q, 12.0)
        end
        if clicked
          p.open_album(ai, ctx.input.time)
          ctx.request_repaint
        end
        gap(row, 10.0)
      end
    end
  end

  # заголовок секции: т 22 bold + spring + «Show all»
  private def section_header(ui : Egui::Ui, ctx : Egui::Context, id : String,
                             title : String, show_all : Bool) : Nil
    hbar(ui, id, 36.0) do |h|
      t(h, title, size: 22.0, bold: true)
      reserve = show_all ? h.fonts.measure("Show all", 14.0).x : 0.0
      rspring(h, reserve)
      t(h, "Show all", size: 14.0, color: MusicTags.muted) if show_all
    end
  end

  # карточка альбома/плейлиста (.album-card, appear rise со stagger)
  private def album_card(ui : Egui::Ui, ctx : Egui::Context, id : String,
                         c1 : String, c2 : String, txt : String,
                         round : Bool, title : String, sub : String,
                         idx : Int32, &on_open) : Nil
    clicked = panel(ui, ctx, id, MwStyle::ALBUM_CARD, w: 188.0, h: 234.0,
      appear: "rise", appear_delay: idx * 0.04) do |c|
      cover(c, c1, c2, txt, 168.0, round: round, fs: 34.0)
      gap(c, 6.0)
      t(c, title, size: 14.0, bold: true, w: 164.0)
      gap(c, 2.0)
      t(c, sub, size: 13.0, color: MusicTags.muted, w: 164.0)
    end
    on_open.call if clicked
  end

  # ── Search ──────────────────────────────────────────────────────────
  private def page_search(ui : Egui::Ui, ctx : Egui::Context,
                          accent : Egui::Color32) : Nil
    p = @player
    library = @library
    q = p.query.strip.downcase
    center_page(ui, ctx, "search") do |c|
      if q.empty?
        # Browse all
        t(c, "Browse all", size: 26.0, bold: true)
        gap(c, 14.0)
        c.box(:row) do |row|
          library.genres.each do |g|
            gtile(row, ctx, "search/g/#{g.name}", g.color, g.name,
              g.c1, g.c2, g.ini) do
              p.query = g.name
              p.nav_to(:search)
            end
            gap(row, 16.0)
          end
        end
        next
      end
      # живые результаты (run_search из main.c)
      s_albums = (0...library.albums.size).select { |ai|
        a = library.albums[ai]
        a.title.downcase.includes?(q) || a.artist.downcase.includes?(q) ||
          a.genre.downcase.includes?(q)
      }
      songs = [] of Int32
      (0...library.tracks.size).each do |ti|
        break if songs.size >= 5
        trk = library.tracks[ti]
        songs << ti if trk.title.downcase.includes?(q) ||
                       library.albums[trk.album].artist.downcase.includes?(q)
      end
      top = s_albums.first? || (songs.first? ? library.tracks[songs.first].album : nil)
      t(c, "Results", size: 26.0, bold: true)
      gap(c, 10.0)
      if top.nil?
        t(c, "Nothing matches «#{p.query}». Try another word: a genre, a city, a color…",
          size: 15.0, color: MusicTags.muted, w: 600.0, wrap: true, lh: 1.5)
        next
      end
      t(c, "Top result", size: 22.0, bold: true)
      gap(c, 10.0)
      ta = library.albums[top]
      clicked = panel(c, ctx, "search/top", MwStyle::PLAIN, dir: :row,
        h: 116.0, w: 480.0) do |r|
        cover(r, ta.c1, ta.c2, ta.ini, 92.0, r: 8.0, fs: 30.0)
        gap(r, 16.0)
        col(r, "search/top/t", 340.0, 22.0 * 1.35 + 4.0 + 14.0 * 1.35) do |cc|
          t(cc, ta.title, size: 22.0, bold: true)
          gap(cc, 4.0)
          t(cc, "Album · #{ta.artist}", size: 14.0, color: MusicTags.muted)
        end
      end
      if clicked
        p.open_album(top, ctx.input.time)
        ctx.request_repaint
      end
      gap(c, 10.0)
      t(c, "Songs", size: 22.0, bold: true)
      gap(c, 10.0)
      songs.each_with_index do |ti, i|
        track_row(c, ctx, "search/song/#{i}", ti, i, accent,
          always_album: true,
          on_like: ->{ p.like_track(ti, ctx.input.time) }) do
          p.play_track_row(ti)
        end
      end
      gap(c, 10.0)
      t(c, "Albums", size: 22.0, bold: true)
      crow(c, "search/albums") do |row|
        s_albums.each_with_index do |ai, i|
          a = library.albums[ai]
          album_card(row, ctx, "search/albums/#{i}", a.c1, a.c2, a.ini, false,
            a.title, "#{a.year} · #{a.artist}", i) { p.open_album(ai, ctx.input.time) }
          gap(row, 4.0)
        end
      end
    end
  end

  # строка песни (search songs / треки коллекции)
  private def track_row(ui : Egui::Ui, ctx : Egui::Context, id : String,
                        ti : Int32, i : Int32, accent : Egui::Color32,
                        *, always_album : Bool, on_like : Proc(Nil),
                        &on_play) : Nil
    p = @player
    trk = @library.tracks[ti]
    a = @library.albums[trk.album]
    playing = ti == p.track
    tc = playing ? accent : MusicTags.text
    hcol = trk.liked ? accent : MusicTags.hex("#c4c4d28c").not_nil!
    clicked = panel(ui, ctx, id, MwStyle::TRACK_ROW, dir: :row, h: 56.0,
      padx: 12.0) do |r|
      t(r, (i + 1).to_s, size: 14.0, color: tc, w: 26.0, align: "r")
      gap(r, 14.0)
      cover(r, a.c1, a.c2, a.ini, 40.0, r: 4.0, fs: 13.0)
      gap(r, 12.0)
      col(r, "#{id}/t", 260.0, 15.0 * 1.35 + 2.0 + 13.0 * 1.35) do |cc|
        t(cc, trk.title, size: 15.0, color: tc)
        gap(cc, 2.0)
        t(cc, a.artist, size: 13.0, color: MusicTags.muted)
      end
      rspring(r, 197.0 + 32.0 + 44.0) # хвост: album(197) + ibtn(32) + time(44)
      t(r, always_album ? a.title : "", size: 13.0, color: MusicTags.muted, w: 197.0)
      ibtn(r, ctx, "#{id}/heart", trk.liked ? "heart-f" : "heart",
        tint: hcol, btn: 32.0, size: 16.0) { on_like.call }
      t(r, MusicLibrary.fmt_time(trk.seconds.to_f64), size: 13.0,
        color: MusicTags.muted, w: 44.0, align: "r")
    end
    if clicked
      on_play.call
      ctx.request_repaint
    end
  end
end

# ═════════════════════════════════════════════════════════════════════
# СТРАНИЦЫ (продолжение): настройки, библиотека, коллекция, остров
# ═════════════════════════════════════════════════════════════════════
class MusicWidgetsManualApp
  # ── Settings ────────────────────────────────────────────────────────
  private def page_settings(ui : Egui::Ui, ctx : Egui::Context,
                            accent : Egui::Color32) : Nil
    p = @player
    center_page(ui, ctx, "settings") do |root|
      panel(root, ctx, "settings/col", MwStyle::PLAIN, w: -1.0) do |c|
        t(c, "Settings", size: 30.0, bold: true)
        gap(c, 20.0)
        eyebrow(c, "APPEARANCE")
        setting_row(c, ctx, "look", "Look",
          "A theme of the player, or a look of Raven: Windows, macOS, GNOME, glass, high contrast.",
          wrap: true, h: 60.0) do |h|
          ocombo(h, ctx, "settings/look", "look",
            MusicLibrary::LOOKS[p.look]? || MusicLibrary::LOOKS[0],
            MusicLibrary::LOOKS, w: 260.0) do |opt|
            p.look = MusicLibrary::LOOKS.index(opt) || 0
            MusicTags.use_look(MusicLibrary::LOOKS[p.look])
            ctx.request_repaint
          end
        end
        setting_row(c, ctx, "accent_follow", "Accent from the cover",
          "The color of the controls follows the cover of what plays.") do |h|
          oswitch(h, ctx, "settings/sw_follow", p.follow_cover, accent) { p.follow_cover = !p.follow_cover }
        end
        setting_row(c, ctx, "accent", "Accent",
          "The color of the controls, when it does not follow the cover.") do |h|
          swatch(h, accent)
        end
        setting_row(c, ctx, "bg", "Background",
          "What moves behind the panels, in the colors of the cover.") do |h|
          ocombo(h, ctx, "settings/bg", "bg",
            MusicLibrary::EFFECTS[p.effect]? || MusicLibrary::EFFECTS[0],
            MusicLibrary::EFFECTS, w: 160.0) do |opt|
            p.effect = MusicLibrary::EFFECTS.index(opt) || 0
          end
        end
        setting_row(c, ctx, "animate", "Animate the background",
          "Off, the background stays still and the window draws only when something changes.",
          wrap: true, h: 60.0) do |h|
          oswitch(h, ctx, "settings/sw_animate", p.animate, accent) { p.animate = !p.animate }
        end
        setting_row(c, ctx, "np", "Now playing panel",
          "The panel on the right, with the cover and what comes next.") do |h|
          oswitch(h, ctx, "settings/sw_np", p.panel, accent) { p.panel = !p.panel }
        end
        gap(c, 20.0)
        hline(c)
        gap(c, 20.0)
        eyebrow(c, "PLAYBACK")
        setting_row(c, ctx, "crossfade", "Crossfade",
          "Songs fade into each other.", tail: :crossfade) do |h|
          # oslider + «N s» рисуются в хвосте (ниже)
        end
        setting_row(c, ctx, "normalize", "Normalize the volume",
          "The same loudness for every song.") do |h|
          oswitch(h, ctx, "settings/sw_norm", p.normalize, accent) { p.normalize = !p.normalize }
        end
        setting_row(c, ctx, "quality", "Streaming quality",
          "Nothing is streamed: the songs of this player are made up.") do |h|
          ocombo(h, ctx, "settings/quality", "quality",
            ["Low", "Normal", "High", "Very high"][p.quality]? || "High",
            ["Low", "Normal", "High", "Very high"], w: 160.0) do |opt|
            p.quality = ["Low", "Normal", "High", "Very high"].index(opt) || 2
          end
        end
        gap(c, 20.0)
        hline(c)
        gap(c, 20.0)
        eyebrow(c, "ABOUT")
        panel(c, ctx, "settings/about", MwStyle::ABOUT, h: 190.0) do |a|
          t(a, "Raven Music is a showcase of Raven: no server, no sound, only the interface.",
            size: 14.0, w: 748.0, wrap: true, lh: 1.55)
          gap(a, 8.0)
          ["• every part is an XML file of ui/, brought in with Include",
           "• the cards, the rows and the tiles are tags declared in widgets.xml",
           "• Icon, Cover, Visualizer and Heading are made by the application",
           "• the themes are files of themes/; the accent follows the cover playing",
           "• the island at the top lives in the notch of a MacBook"].each do |line|
            t(a, line, size: 14.0, color: MusicTags.eyebrow)
            gap(a, 4.0)
          end
        end
      end
    end
  end

  # APPEARANCE/PLAYBACK/ABOUT — 12px bold с трекингом
  private def eyebrow(ui : Egui::Ui, text : String) : Nil
    t(ui, text, size: 12.0, bold: true, color: MusicTags.eyebrow, ls: 0.08)
    gap(ui, 20.0)
  end

  # строка настроек: col w=500 (заголовок+описание) + spring + хвост
  private def setting_row(ui : Egui::Ui, ctx : Egui::Context, id : String,
                          title : String, desc : String, *,
                          wrap : Bool = false, h : Float64 = 46.0,
                          tail : Symbol? = nil, &tail_widgets : Egui::Ui ->) : Nil
    p = @player
    hbar(ui, "settings/row/#{id}", h) do |r|
      col(r, "settings/row/#{id}/t", 500.0,
        15.0 * 1.35 + 3.0 + (wrap ? 13.0 * 1.4 * 2 : 13.0 * 1.35)) do |cc|
        t(cc, title, size: 15.0)
        gap(cc, 3.0)
        t(cc, desc, size: 13.0, color: MusicTags.muted,
          w: wrap ? 500.0 : 0.0, wrap: wrap, lh: 1.4)
      end
      # хвост известной ширины: oslider 180 + gap10 + «N s» 36
      rspring(r, tail == :crossfade ? 226.0 : 0.0)
      if tail == :crossfade
        oslider(r, ctx, "settings/crossfade", p.crossfade / 12.0, accent_col,
          w: 180.0) { |f| p.crossfade = (f * 12).round.to_i }
        gap(r, 10.0)
        t(r, "#{p.crossfade} s", size: 14.0, w: 36.0)
      else
        tail_widgets.call(r)
      end
    end
    gap(ui, 20.0)
  end

  # ── Library ─────────────────────────────────────────────────────────
  private def page_library(ui : Egui::Ui, ctx : Egui::Context,
                           accent : Egui::Color32) : Nil
    p = @player
    library = @library
    center_page(ui, ctx, "library") do |c|
      t(c, "Your library", size: 30.0, bold: true, h: 46.0)
      t(c, lib_summary, size: 14.0, color: MusicTags.muted)
      section_header(c, ctx, "lib/h_pl", "Playlists", true)
      crow(c, "lib/playlists", h: 225.0) do |row|
        library.playlists.each_with_index do |pl, pi|
          if pi == 0
            album_card(row, ctx, "lib/pl/#{pi}", "#B79CFF", "#6D28D9", "♥",
              true, pl.title, "#{library.liked_tracks.size} songs", pi) { p.open_playlist(pi) }
          else
            a = library.albums[pl.cover]
            album_card(row, ctx, "lib/pl/#{pi}", a.c1, a.c2, a.ini, true,
              pl.title, "#{pl.track_list.size} songs", pi) { p.open_playlist(pi) }
          end
          gap(row, 4.0)
        end
      end
      section_header(c, ctx, "lib/h_al", "Albums", true)
      # альбомы по 3 на ряд (перенос строк CSS → пять crow-рядов)
      5.times do |ri|
        crow(c, "lib/albums/#{ri}") do |row|
          ((ri * 3)...library.albums.size).select { |ai| ai // 3 == ri }
            .each_with_index do |ai, i|
            a = library.albums[ai]
            album_card(row, ctx, "lib/al/#{ai}", a.c1, a.c2, a.ini, false,
              a.title, "#{a.year} · #{a.artist}", i) { p.open_album(ai, ctx.input.time) }
            gap(row, 4.0)
          end
        end
      end
    end
  end

  private def lib_summary : String
    library = @library
    saved = @player.album_likes.count(&.itself)
    "#{library.playlists.size} playlists, #{library.albums.size} albums " \
      "(#{saved} saved), #{library.liked_tracks.size} liked songs."
  end

  # ── Collection ──────────────────────────────────────────────────────
  private def page_collection(ui : Egui::Ui, ctx : Egui::Context,
                              accent : Egui::Color32) : Nil
    p = @player
    library = @library
    ca = p.col_album
    is_pl = p.col_kind == :playlist
    panel(ui, ctx, "page/collection", MwStyle::PLAIN, scroll: true,
      appear: "fade") do |c|
      hero(c, "col/hero", MusicLibrary.scale_hex(ca.c1, 0.55),
        MusicLibrary.scale_hex(ca.c2, 0.22)) do |h|
        cover(h, ca.c1, ca.c2, ca.ini, 232.0, r: 8.0, fs: 48.0, shadow: true)
        gap(h, 26.0)
        # высота col — по контенту (альбом/плейлист)
        est = 12.0 * 1.35 + 8.0 + 56.0 * 1.35 + 8.0 + 24.0
        est += 8.0 + 14.0 * 1.35 if is_pl
        col(h, "col/hero/t", 380.0, est) do |cc|
          t(cc, is_pl ? "PLAYLIST" : "ALBUM", size: 12.0, bold: true,
            color: MusicTags::WHITE, ls: 0.08)
          gap(cc, 8.0)
          t(cc, is_pl ? library.playlists[p.col_index].title : library.albums[p.col_index].title,
            size: 56.0, bold: true, color: MusicTags::WHITE)
          if is_pl
            gap(cc, 8.0)
            t(cc, library.playlists[p.col_index].description, size: 14.0,
              color: Egui::Color32.rgba(255, 255, 255, 0xCC),
              w: 360.0, wrap: true, lh: 1.5)
          end
          gap(cc, 8.0)
          hbar(cc, "col/hero/meta", 24.0) do |m|
            cover(m, ca.c1, ca.c2, ca.ini, 24.0, r: 12.0, fs: 9.0)
            gap(m, 8.0)
            t(m, is_pl ? "Raven Music" : library.albums[p.col_index].artist,
              size: 14.0, bold: true, color: MusicTags::WHITE)
            gap(m, 8.0)
            t(m, p.col_meta, size: 14.0,
              color: Egui::Color32.rgba(255, 255, 255, 0xBF))
          end
        end
      end
      gap(c, 6.0)
      # панель действий
      hbar(c, "col/actions", 76.0, pad: 24.0) do |h|
        playround(h, ctx, "col/play",
          p.col_playing_same_list? && p.playing ? "pause" : "play",
          accent, s: 56.0, size: 24.0, big: true) { p.col_play(ctx.input.time) }
        gap(h, 14.0)
        ibtn(h, ctx, "col/shuffle", "shuffle", btn: 40.0, size: 24.0,
          tint: p.shuffle ? accent : MusicTags.icon) { p.col_shuffle(ctx.input.time) }
        gap(h, 14.0)
        ibtn(h, ctx, "col/heart", p.col_is_liked ? "heart-f" : "heart",
          btn: 40.0, size: 24.0,
          tint: p.col_is_liked ? accent : MusicTags.icon) { p.like_collection(ctx.input.time) }
        gap(h, 14.0)
        ibtn(h, ctx, "col/download", "download", btn: 40.0, size: 24.0) { p.notify("Not in this demo", ctx.input.time) }
        gap(h, 14.0)
        ibtn(h, ctx, "col/more", "more", btn: 40.0, size: 24.0) { p.notify("Not in this demo", ctx.input.time) }
        rspring(h, 0.0)
        t(h, "List", size: 14.0, color: MusicTags.muted)
        gap(h, 8.0)
        icon(h, "queue", 18.0, color: Egui::Color32.rgba(0xa3, 0xa3, 0xb4, 0xB3))
      end
      gap(c, 6.0)
      # шапка списка
      hbar(c, "col/head", 29.0, pad: 12.0) do |h|
        t(h, "#", size: 13.0, color: MusicTags.muted, w: 26.0, align: "r")
        gap(h, 14.0)
        t(h, "Title", size: 13.0, color: MusicTags.muted)
        # хвост: album(197) + gap32 + clock(16)
        rspring(h, 245.0)
        t(h, is_pl ? "Album" : "", size: 13.0, color: MusicTags.muted, w: 197.0)
        gap(h, 32.0)
        icon(h, "clock", 16.0, color: Egui::Color32.rgba(0xa3, 0xa3, 0xb4, 0xB3))
      end
      gap(c, 4.0)
      hline(c, pad: 12.0)
      gap(c, 6.0)
      p.col_tracks.each_with_index do |ti, i|
        track_row(c, ctx, "col/track/#{i}", ti, i, accent,
          always_album: is_pl,
          on_like: ->{ p.like_track(ti, ctx.input.time) }) do
          p.play_track_row(ti)
        end
      end
    end
  end

  # ── <island/> — «остров» сверху по центру + развёрнутый мини-плеер ──
  private def island(ui : Egui::Ui, ctx : Egui::Context,
                     accent : Egui::Color32) : Nil
    p = @player
    album = p.album
    obj = p.track_obj
    now = ctx.input.time
    c1 = MusicTags.hex(album.c1) || MusicTags.accent
    c2 = MusicTags.hex(album.c2) || c1
    txt = album.ini
    ui.overlay(:top_center, margin: Egui::StyleBox.new(top: 6.0)) do |o|
      o.painter.clip = o.clip
      title = o.fonts.fit(p.island_text(now), 12.0, 220.0)
      tw = o.fonts.measure(title, 12.0).x
      w = 10.0 + 20.0 + 8.0 + tw + 8.0 + (4 * 2.5 + 3 * 2) + 10.0
      rect = o.allocate_space(Egui::Vec2.new(w, 28.0))
      layer = Egui::LayerId.new(Egui::Order::Foreground, Egui::Id.from("island"))
      MusicTags.island_layer = layer
      expanded = ctx.input.pointer_pos.try { |pt| rect.contains?(pt) } || false
      hov_rect = Egui::Rect.from_min_size(
        Egui::Pos2.new(rect.left - 8.0, rect.top - 4.0),
        Egui::Vec2.new(w + 16.0, 36.0))
      if expanded
        hov_rect = Egui::Rect.from_min_size(rect.min,
          Egui::Vec2.new({w, 300.0}.max, 190.0))
      end
      hresp = ctx.interact(Egui::Id.from("island/hov"), hov_rect,
        Egui::Sense::Click, layer, rect)
      expanded ||= hresp.hovered?
      pnt = o.painter
      radius = MusicTags.glide(ctx, Egui::Id.from("island/rad"), "radius",
        expanded ? 14.0 : 100.0, 180.0)
      pnt.rect(rect, radius, fill: MusicTags.popup,
        stroke_color: Egui::Color32.rgba(255, 255, 255, 0x1a), stroke_width: 1.0)
      x = rect.left + 10.0
      MusicTags.cover(pnt, o.fonts,
        Egui::Rect.from_min_size(Egui::Pos2.new(x, rect.center.y - 10.0),
          Egui::Vec2.new(20.0, 20.0)), c1, c2, txt, 5.0, 8.0)
      x += 20.0 + 8.0
      pnt.text(Egui::Pos2.new(x, rect.center.y), title, 12.0, MusicTags.text)
      x += tw + 8.0
      heights = {6.0, 11.0, 8.0, 5.0}
      levels = MusicTags.vis_step("island/folded", 4, p.playing, now)
      4.times do |i|
        bh = {heights[i] * levels[i], 2.0}.max
        pnt.rect(Egui::Rect.from_min_size(
          Egui::Pos2.new(x + i * 4.5, rect.bottom - 8.0 - bh),
          Egui::Vec2.new(2.5, bh)), 1.0, fill: accent)
      end
      if expanded
        lp = ctx.painter
        prev_clip = lp.clip
        lp.clip = Egui::Rect.new(Egui::Pos2.new(-1e8, -1e8),
          Egui::Pos2.new(1e8, 1e8))
        prev_layer = lp.layer
        lp.layer = Egui::Order::Foreground
        iw = 300.0
        ipanel = Egui::Rect.from_min_size(rect.min, Egui::Vec2.new(iw, 186.0))
        lp.rect(ipanel, 14.0, fill: MusicTags.popup,
          stroke_color: Egui::Color32.rgba(255, 255, 255, 0x1a), stroke_width: 1.0)
        lp.box_shadow(ipanel, Egui::Color32.rgba(0, 0, 0, 0x80), 30.0, 14.0)
        sy = ipanel.top + 12.0
        MusicTags.cover(lp, o.fonts,
          Egui::Rect.from_min_size(Egui::Pos2.new(ipanel.left + 12.0, sy),
            Egui::Vec2.new(40.0, 40.0)), c1, c2, txt, 6.0, 13.0)
        lp.text(Egui::Pos2.new(ipanel.left + 64.0, sy + 10.0),
          obj ? obj.title : "", 13.0, MusicTags.text, bold: true)
        lp.text(Egui::Pos2.new(ipanel.left + 64.0, sy + 26.0),
          album.artist, 11.0, MusicTags.muted)
        ulevels = MusicTags.vis_step("island/unfolded", 6, p.playing, now)
        6.times do |i|
          bh = {16.0 * ulevels[i], 2.0}.max
          lp.rect(Egui::Rect.from_min_size(
            Egui::Pos2.new(ipanel.right - 16.0 - (6 - i) * 4.5, sy + 40.0 - bh),
            Egui::Vec2.new(2.5, bh)), 1.0, fill: accent)
        end
        # мини-seek
        seek_w = iw - 24.0
        frac = p.seek_frac.clamp(0.0, 1.0)
        cy = sy + 56.0 + 7.0
        lp.rect(Egui::Rect.from_min_size(
          Egui::Pos2.new(ipanel.left + 12.0, cy - 2.0),
          Egui::Vec2.new(seek_w, 4.0)), 2.0,
          fill: Egui::Color32.rgba(255, 255, 255, 0x40))
        lp.rect(Egui::Rect.from_min_size(
          Egui::Pos2.new(ipanel.left + 12.0, cy - 2.0),
          Egui::Vec2.new(seek_w * frac, 4.0)), 2.0, fill: accent)
        lp.circle_filled(Egui::Pos2.new(ipanel.left + 12.0 + seek_w * frac, cy),
          5.0, MusicTags.strong)
        srect = Egui::Rect.from_min_size(
          Egui::Pos2.new(ipanel.left + 12.0, cy - 7.0),
          Egui::Vec2.new(seek_w, 14.0))
        sresp = ctx.interact(Egui::Id.from("island/seek"), srect,
          Egui::Sense::Click | Egui::Sense::Drag,
          MusicTags.island_layer.not_nil!, srect)
        if (sresp.dragged? || sresp.clicked?) && (ptr = ctx.input.pointer_pos)
          p.seek(((ptr.x - ipanel.left - 12.0) / seek_w).clamp(0.0, 1.0))
          ctx.request_repaint
        end
        lp.text(Egui::Pos2.new(ipanel.left + 12.0, sy + 76.0),
          MusicLibrary.fmt_time(p.position), 10.0, MusicTags.muted)
        len_w = o.fonts.measure(
          obj ? MusicLibrary.fmt_time(obj.seconds.to_f64) : "0:00", 10.0).x
        lp.text(Egui::Pos2.new(ipanel.right - 12.0 - len_w, sy + 76.0),
          obj ? MusicLibrary.fmt_time(obj.seconds.to_f64) : "0:00",
          10.0, MusicTags.muted)
        # u-row: heart prev play next panel
        by = sy + 92.0
        cxm = ipanel.center.x
        buttons = {"heart", "prev", "play", "next", "panel"}
        actions = {"like", "prev", "toggle", "next", "panel"}
        widths = {30.0, 30.0, 34.0, 30.0, 30.0}
        bgap = 6.0
        bx = cxm - (widths.sum + bgap * (buttons.size - 1)) / 2.0
        buttons.each_with_index do |bname, i|
          bw = widths[i]
          brect = Egui::Rect.from_min_size(
            Egui::Pos2.new(bx, by + (34.0 - bw) / 2.0),
            Egui::Vec2.new(bw, bw))
          bx += bw + bgap
          bresp = ctx.interact(Egui::Id.from("island/btn#{i}"), brect,
            Egui::Sense::Click, layer, brect)
          is_play = bname == "play"
          if is_play
            lp.circle_filled(brect.center, brect.width / 2.0, MusicTags.text)
          elsif bresp.hovered?
            lp.circle_filled(brect.center, brect.width / 2.0, MusicTags.control_hov)
          end
          icon_name = is_play ? (p.playing ? "pause" : "play") : bname
          icon_name = "heart-f" if bname == "heart" && obj.try(&.liked)
          fg = is_play ? MusicTags.window
            : (bresp.hovered? ? MusicTags.strong : MusicTags.icon)
          MusicTags.icon(icon_name, fg).paint(o,
            Egui::Rect.from_min_size(
              Egui::Pos2.new(brect.center.x - 7.0, brect.center.y - 7.0),
              Egui::Vec2.new(14.0, 14.0)))
          if bresp.clicked?
            case actions[i]
            when "like"    then p.like_current(now)
            when "prev"    then p.prev_track
            when "toggle"  then p.toggle(now)
            when "next"    then p.next_track
            when "panel"   then p.panel = !p.panel
            end
            ctx.request_repaint
          end
        end
        lp.rect(Egui::Rect.from_min_size(
          Egui::Pos2.new(ipanel.left + 12.0, ipanel.bottom - 40.0),
          Egui::Vec2.new(iw - 24.0, 1.0)), 0.0, fill: MusicTags.separator)
        lp.text(Egui::Pos2.new(ipanel.left + 12.0, ipanel.bottom - 20.0),
          "Look: #{MusicLibrary::LOOKS[p.look]}", 12.0, MusicTags.muted)
        lp.layer = prev_layer
        lp.clip = prev_clip
      end
      ctx.request_repaint
    end
  end
end
