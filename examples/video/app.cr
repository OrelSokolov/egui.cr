# The video player egui app — TWO interface rendering modes:
#
#   EMBEDDED (windowed): the video is squeezed into the layout —
#   glass info strip floating OVER the video along the top edge,
#   control bar docked at the bottom, video in between.
#
#   OVERLAPPED (fullscreen, the SystemPorts::Window mode): the video
#   owns the whole window; BOTH strips float ON TOP of the stream
#   (position: fixed) and hide after OVERLAY_HIDE_AFTER seconds
#   without ANY user activity — InputState#seconds_since_activity, the
#   framework's idle counter; the next mouse move brings them back.
#
# The top info strip is ALWAYS an overlap in both modes; the strip
# backgrounds are translucent glass (BAR_GLASS) — the video shows
# through.
#
# The seek strip is a thin line along the top edge of the bar that
# doubles its height and knob on hover; drag previews the position and
# commits on release (continuous seeking would decode-forward on every
# mouse move). Space toggles playback; F / F11 and the corner button
# toggle fullscreen; double-click on the video does the same. Files can
# be dropped onto the window.

class VideoApp < Egui::App
  # ── theme (Raven Music tags: examples/music_components/music_tags.cr) ──
  BAR_BG   = Egui::Color32.rgb(0x05, 0x05, 0x08)
  # стекло хрома: полосы-оверлеи поверх видео просвечивают
  BAR_GLASS = Egui::Color32.rgba(0x05, 0x05, 0x08, 0xAA)
  # трек слайдеров — НЕ прозрачный: сквозь стекло видео иначе
  # просвечивает сквозь линию и рвёт её
  TRACK     = Egui::Color32.rgb(0x3c, 0x3c, 0x46)
  VIDEO_BG = Egui::Color32.rgb(0x0a, 0x0a, 0x0f)
  TEXT     = Egui::Color32.rgb(0xec, 0xec, 0xf2)
  MUTED    = Egui::Color32.rgb(0xa3, 0xa3, 0xb4)
  ICON_FG  = Egui::Color32.rgb(0xc4, 0xc4, 0xd2)
  ACCENT   = Egui::Color32.rgb(0xb7, 0x9c, 0xff) # Raven violet
  # playback below native resolution (adaptive downscale): a muted
  # amber, not a loud yellow — an unobtrusive "degraded" marker
  WARN     = Egui::Color32.rgb(0xd9, 0xa0, 0x3c)
  WHITE    = Egui::Color32.rgb(0xff, 0xff, 0xff)

  @seek_drag = false
  @seek_scratch = 0.0
  @volume = 0.8
  @muted = false
  # Manual content rotation: quarter-turns clockwise (the rotate button
  # cycles it). Device rotation is NOT this — it relayouts through the
  # window size; this one turns the video inside the layout.
  @rot = 0

  # YouTube-style center overlay: a click (or Space) toggles playback
  # and flashes the NEW state's big icon in the middle of the video —
  # pause icon when just paused, play icon when just started — which
  # scales up and fades out; while paused, a big play badge stays.
  FLASH_DUR = 0.55
  @flash_at : Time::Instant? = nil
  @flash_icon : Symbol = :play

  # CLI arg: opened on the FIRST update, not before run() — GPU
  # textures can only exist after the sokol gfx setup (the sg view
  # would be dead otherwise).
  def initialize(@pending_open : String? = nil)
    super()
    @player = VideoPlayer.new(@ctx)
    @player.volume = @volume.to_f32!
    @status = "Open a video file — or drop one onto the window."
    # панели по умолчанию обводятся 1px window_stroke — серая рамка по
    # контуру кино-экрана не нужна
    @ctx.style.visuals.window_stroke = Egui::Color32.transparent
  end

  def open_video(path : String) : Nil
    if @player.open(path)
      @status = File.basename(path)
      @seek_drag = false
      STDERR.puts("video: opened #{path} #{@player.width}x#{@player.height} " \
                  "dur=#{@player.duration}") if ENV["EGUI_VIDEO_DEBUG"]?
    else
      @status = "#{File.basename(path)}: #{@player.error || "cannot open"}"
      STDERR.puts("video: open FAILED: #{@player.error}") if ENV["EGUI_VIDEO_DEBUG"]?
    end
  end

  def update(ctx : Egui::Context) : Nil
    t0 = Time.instant
    # CLI arg / queued open — must run inside a frame (GPU is up)
    if (p = @pending_open)
      @pending_open = nil
      open_video(p)
    end

    # Space = play/pause (only when nothing else claimed the key)
    if @player.open? && ctx.input.key_pressed?(Egui::KeyCode::Space)
      ctx.input.consume_key(Egui::KeyCode::Space)
      @player.toggle
      start_flash(@player.playing? ? :play : :pause)
    end

    # F / F11 = fullscreen ↔ windowed — the SystemPorts::Window state
    # port; the button and the video double-click land in the same
    # #toggle_fullscreen.
    if ctx.input.key_pressed?(Egui::KeyCode::F) ||
       ctx.input.key_pressed?(Egui::KeyCode::F11)
      ctx.input.consume_key(Egui::KeyCode::F)
      ctx.input.consume_key(Egui::KeyCode::F11)
      toggle_fullscreen
    end

    # center flash lifetime: keep frames coming while it fades, then
    # one final flash-free frame (the clear happens before this
    # frame's paint, so nothing stale stays on screen)
    if (f = @flash_at)
      if (Time.instant - f).total_seconds < FLASH_DUR
        ctx.request_repaint
      else
        @flash_at = nil
        ctx.request_repaint
      end
    end

    # Drag & drop: first path wins
    if (drop = ctx.input.dropped_files.first?)
      open_video(drop)
    end

    # System events (Events port): the device-rotation report just
    # relayouts (this update runs on the resized window) — drain so the
    # idle gate can go back to sleep. Manual rotation is the button.
    Egui::SystemPorts::Events.take

    # Media flag: bypasses the unfocused idle gate (IDLE_NOT_FOCUSED.md)
    # — decode pump and audio feed live in #advance, a 1 fps gate would
    # stall playback itself. Re-asserted every frame; clears on pause.
    ctx.media_active = @player.playing?
    if @player.playing?
      @player.advance
      ctx.request_repaint # keep the vsync loop from idle-skipping
    elsif @player.open? && ENV["EGUI_VIDEO_DEBUG"]?
      @player.debug_tick # paused state keeps reporting (frozen clock)
      ctx.request_repaint # debug only: keep the loop from idle-skipping
    end

    # ── два режима рендеринга интерфейса ──────────────────────────────
    # OVERLAPPED (fullscreen): видео — на весь экран, обе полосы плавают
    # поверх (position: fixed) и прячутся после OVERLAY_HIDE_AFTER
    # секунд без всякой активности (счётчик простоя InputState —
    # состояние фреймворка; следующее движение мыши возвращает полосы).
    # EMBEDDED (windowed): видео вжато в вёрстку, бар контролов снизу —
    # но верхняя инфо-полоса ВСЕГДА overlap поверх видео, в обоих
    # режимах.
    fullscreen = Egui::SystemPorts::Window.fullscreen?
    # хром (обе полосы) в fullscreen прячется по счётчику простоя; в
    # окне верхняя полоса видна всегда
    chrome_visible = !fullscreen ||
                     ctx.input.seconds_since_activity < OVERLAY_HIDE_AFTER
    ctx.central_panel(fill: VIDEO_BG, scroll: false) do |ui|
      video_area(ui)
      if chrome_visible
        paint_top_overlay(ui)
        if fullscreen
          paint_bar_overlay(ui, ctx)
          # момент скрытия должен наступить даже на паузе (idle-гейт
          # иначе заморозит кадр до следующего движения мыши)
          ctx.request_repaint
        end
      end
    end
    unless fullscreen
      portrait = Egui::SystemPorts::Screen.orientation ==
                 Egui::Orientation::Portrait
      ctx.bottom_panel(height: portrait ? MOBILE_BAR_H : DESKTOP_BAR_H,
        resizable: false, fill: BAR_BG) do |ui|
        player_bar(ui, ctx, portrait)
      end
    end
    VideoApp.add_update_ms((Time.instant - t0).total_milliseconds)
  end

  # ── центр: видео с сохранением пропорций / заглушка ───────────────────

  # Область — весь КЛИП панели, без инсетов window_padding: панель
  # инсетит available-зону на padding со всех сторон, и вжатое туда
  # видео не дотягивается до 100% ширины окна (те самые «рамки»).
  # Клип — точная область окна, оставшаяся под остальными панелями.
  private def video_area(ui : Egui::Ui) : Nil
    screen = ui.clip
    avail = Egui::Vec2.new(screen.width, screen.height)
    rect = screen
    # YouTube-style click-to-toggle on the video surface (when a file
    # is open): play/pause + the center flash.
    if @player.open?
      resp = ui.interact(rect, Egui::Id.from("video/area"),
        Egui::Sense::Click)
      if resp.clicked?
        @player.toggle
        start_flash(@player.playing? ? :play : :pause)
      end
      if resp.double_clicked?
        # the pair's second click already flipped playback above — undo
        # that and flip the window mode instead (YouTube behavior)
        @player.toggle
        start_flash(@player.playing? ? :play : :pause)
        toggle_fullscreen
      end
    end
    p = ui.painter
    if @player.open? &&
       (@player.texture_id != 0 || @player.video_texture_id != 0)
      # Always FIT the area (aspect kept): the decode pipeline adapts
      # the texture size down (adaptive scale_vaapi), and a 1.0 cap on
      # the fit factor would show the shrunken texture at native pixels
      # instead of filling the window — sampling cost is nil. A manual
      # rotation (odd quarter-turns) swaps the fitted dims.
      rotated = @rot.odd?
      vw = rotated ? @player.height : @player.width
      vh = rotated ? @player.width : @player.height
      scale = {vw > 0 ? avail.x / vw : 0.0,
               vh > 0 ? avail.y / vh : 0.0}.min
      size = Egui::Vec2.new(vw * scale, vh * scale)
      vrect = Egui::Rect.from_min_size(
        Egui::Pos2.new(rect.center.x - size.x / 2.0, rect.center.y - size.y / 2.0),
        size)
      ui.painter.clip = ui.clip
      if (vid = @player.video_texture_id) != 0
        ui.painter.video(vrect, vid, rot: @rot) # zero-copy: dmabuf + YUV shader
      else
        ui.painter.image(vrect, @player.texture_id)
      end
    else
      # placeholder: centered film glyph + title + hint
      cy = rect.center.y
      paint_icon(ui, :lucide, :film, MUTED,
        Egui::Rect.from_min_size(Egui::Pos2.new(rect.center.x - 24.0, cy - 78.0),
          Egui::Vec2.new(48.0, 48.0)))
      paint_text_c(ui, "egui-cr video player", rect.center.x, cy - 6.0, 21.0,
        TEXT, bold: true)
      paint_text_c(ui, "FFmpeg decode → RGBA → stream texture · minaudio sync",
        rect.center.x, cy + 20.0, 14.0, MUTED)
      paint_text_c(ui, @status, rect.center.x, cy + 44.0, 13.0, MUTED)
      if (err = @player.error)
        paint_text_c(ui, "last error: #{err}", rect.center.x, cy + 66.0, 13.0,
          Egui::Color32.rgb(0xe2, 0x8a, 0x8a))
      end
    end
    paint_center_overlay(ui, rect)
  end

  # ── центральный оверлей play/pause (YouTube-style) ─────────────────────

  private def start_flash(icon : Symbol) : Nil
    @flash_icon = icon
    @flash_at = Time.instant
  end

  # Flash поверх видео: полупрозрачный круг + большая иконка НОВОГО
  # состояния, растёт и гаснет за FLASH_DUR. На паузе ничего
  # постоянного не рисуем — только флэш по клику.
  private def paint_center_overlay(ui : Egui::Ui, rect : Egui::Rect) : Nil
    return unless @player.open? && !@player.texture_id.zero?
    if (f = @flash_at)
      t = ((Time.instant - f).total_seconds / FLASH_DUR).clamp(0.0, 1.0)
      paint_badge(ui, rect, @flash_icon, 0.85 * (1.0 - t),
        0.8 + 0.35 * t)
    end
  end

  private def paint_badge(ui : Egui::Ui, rect : Egui::Rect, icon : Symbol,
                          alpha : Float64, scale : Float64) : Nil
    return if alpha <= 0.02
    p = ui.painter
    p.clip = ui.clip
    a = alpha.clamp(0.0, 1.0)
    r = 46.0 * scale
    p.circle_filled(rect.center, r,
      Egui::Color32.rgba(0, 0, 0, (140 * a).round.to_u8))
    size = 40.0 * scale
    # иконку гасим tint-альфой самого квада (tint растра не умеет
    # альфу — только RGB), поэтому рисуем текстуру напрямую
    svg = case icon
          when :play  then Egui::Icon.from_file(:bootstrap, :play_fill,
            tint: Egui::Color32.rgb(255, 255, 255))
          when :pause then Egui::Icon.from_file(:bootstrap, :pause_fill,
            tint: Egui::Color32.rgb(255, 255, 255))
          else return
          end
    px = {(size * ui.ctx.pixels_per_point).round.to_i, 1}.max
    tex = svg.raster_texture_id(ui.ctx.textures, px, px)
    return if tex.zero?
    x = rect.center.x - size / 2.0 + (icon == :play ? 2.0 : 0.0)
    y = rect.center.y - size / 2.0
    p.image(Egui::Rect.from_min_size(Egui::Pos2.new(x, y),
      Egui::Vec2.new(size, size)), tex,
      tint: Egui::Color32.rgba(255, 255, 255, (255 * a).round.to_u8))
  end

  # ── нижняя панель: полноростовий seek сверху + одна строка контролов ──

  # высота интерактивной зоны seek-полосы (визуально тоньше)
  SEEK_STRIP_H = 18.0
  DESK_ROW_H   = 56.0

  # ── мобильная раскладка (portrait): seek сверху, имя+время, транспорт ──

  MOBILE_BAR_H = 140.0
  MOBILE_TOP_H = 34.0

  private def mobile_bar(ui : Egui::Ui, ctx : Egui::Context) : Nil
    p = @player
    pad = ui.style.spacing.window_padding
    allocated = ui.allocate_space(
      Egui::Vec2.new(ui.available_width, MOBILE_BAR_H))
    rect = Egui::Rect.from_min_size(
      Egui::Pos2.new(allocated.left - pad.x, allocated.top - pad.y),
      Egui::Vec2.new(allocated.width + 2 * pad.x, MOBILE_BAR_H))
    ui.painter.rect(rect, 0.0, fill: BAR_BG)
    seek_strip(ui, ctx, rect)

    spacing = ui.style.spacing
    saved_spacing = spacing.item_spacing
    spacing.item_spacing = Egui::Vec2.new(0.0, saved_spacing.y)
    begin
      # строка 1: имя файла (elide) слева, время справа
      name = p.open? ? File.basename(p.path.to_s) : "No file"
      time_txt = "#{fmt_time(p.position)} / #{fmt_time(p.duration)}"
      time_w = ui.fonts.measure(time_txt, 13.0).x
      r1 = Egui::Rect.from_min_size(
        Egui::Pos2.new(rect.left + 16.0, rect.top + SEEK_STRIP_H),
        Egui::Vec2.new(rect.width - 32.0, MOBILE_TOP_H))
      row1 = ui.child_ui(r1, Egui::Id.from("vbar/m1"),
        layout: Egui::Layout.left_to_right)
      row1.clip = r1.intersect(ui.clip)
      row1.seed_row_height(r1.height)
      t(row1, name, size: 15.0,
        w: {row1.available_width - time_w - 12.0, 40.0}.max)
      row1.allocate_space(Egui::Vec2.new(
        {row1.available_width - time_w, 0.0}.max, 0.0))
      t(row1, time_txt, size: 13.0, color: MUTED)

      # строка 2: транспорт строго по центру
      transport_w = 34.0 * 4 + 40.0 + 12.0 * 4
      r2 = Egui::Rect.from_min_size(
        Egui::Pos2.new(rect.left + 16.0,
          rect.top + SEEK_STRIP_H + MOBILE_TOP_H),
        Egui::Vec2.new(rect.width - 32.0,
          MOBILE_BAR_H - SEEK_STRIP_H - MOBILE_TOP_H))
      row2 = ui.child_ui(r2, Egui::Id.from("vbar/m2"),
        layout: Egui::Layout.left_to_right)
      row2.clip = r2.intersect(ui.clip)
      row2.seed_row_height(r2.height)
      row2.allocate_space(Egui::Vec2.new(
        {(r2.width - transport_w) / 2.0, 0.0}.max, 0.0))
      transport(row2, ctx)
    ensure
      spacing.item_spacing = saved_spacing
    end
  end

  # десктопный бар: seek-полоса + строка контролов (инфа о видео
  # переехала наверх, в рамку #info_panel)
  DESKTOP_BAR_H = SEEK_STRIP_H + DESK_ROW_H
  # высота верхней рамки с инфо о видео (embedded) и overlapped-полосы
  INFO_BAR_H = 30.0
  # overlapped mode: chrome прячется после стольких секунд простоя
  OVERLAY_HIDE_AFTER = 3.0

  private def player_bar(ui : Egui::Ui, ctx : Egui::Context,
                         portrait : Bool) : Nil
    portrait ? mobile_bar(ui, ctx) : desktop_bar(ui, ctx)
  end

  private def desktop_bar(ui : Egui::Ui, ctx : Egui::Context) : Nil
    # панель инсетит контент на window_padding — компенсируем, чтобы бар
    # жил на полном прямоугольнике панели (пиксель в пиксель с краем окна)
    pad = ui.style.spacing.window_padding
    allocated = ui.allocate_space(Egui::Vec2.new(ui.available_width,
      DESKTOP_BAR_H))
    rect = Egui::Rect.from_min_size(
      Egui::Pos2.new(allocated.left - pad.x, allocated.top - pad.y),
      Egui::Vec2.new(allocated.width + 2 * pad.x, DESKTOP_BAR_H))
    ui.painter.rect(rect, 0.0, fill: BAR_BG)
    bar_body(ui, ctx, rect)
  end

  # Верхняя инфо-полоса — ВСЕГДА overlap (position: fixed) поверх видео,
  # в обоих режимах рендеринга; стекло BAR_GLASS, видео просвечивает.
  private def paint_top_overlay(ui : Egui::Ui) : Nil
    screen = ui.clip
    pa = ui.painter
    pa.clip = ui.clip
    top = Egui::Rect.from_min_size(screen.min,
      Egui::Vec2.new(screen.width, INFO_BAR_H))
    pa.rect(top, 0.0, fill: BAR_GLASS)
    info_strip(ui, top)
    # info_strip работала на child_ui — пейнтер общий, её клип остался
    # в глобальном состоянии; вернули клип панели, иначе всё, что
    # рисуется после, обрежется верхней полосой
    pa.clip = ui.clip
  end

  # OVERLAPPED бар у нижней кромки: рисуется ПОСЛЕ видео, поэтому его
  # hit-test'ы выигрывают у click-to-toggle поверхности под ним.
  private def paint_bar_overlay(ui : Egui::Ui, ctx : Egui::Context) : Nil
    screen = ui.clip
    pa = ui.painter
    pa.clip = ui.clip
    bar = Egui::Rect.from_min_size(
      Egui::Pos2.new(screen.left, screen.bottom - DESKTOP_BAR_H),
      Egui::Vec2.new(screen.width, DESKTOP_BAR_H))
    pa.rect(bar, 0.0, fill: BAR_GLASS)
    bar_body(ui, ctx, bar)
  end

  # seek-полоса вдоль верхней кромки + строка контролов на явном
  # прямоугольнике — общий рендер embedded-бара и overlapped-полосы;
  # все позиции считаются в явных px (gap()/пружины) — неявный
  # item_spacing глушится, иначе он сдвигает каждый элемент строки
  private def bar_body(ui : Egui::Ui, ctx : Egui::Context,
                       rect : Egui::Rect) : Nil
    # пейнтер общий: клип мог остаться от чужой child_ui (см. оверлеи)
    ui.painter.clip = ui.clip
    seek_strip(ui, ctx, rect)
    spacing = ui.style.spacing
    saved_spacing = spacing.item_spacing
    spacing.item_spacing = Egui::Vec2.new(0.0, saved_spacing.y)
    begin
      row_rect = Egui::Rect.from_min_size(
        Egui::Pos2.new(rect.left + 16.0, rect.top + SEEK_STRIP_H),
        Egui::Vec2.new({rect.width - 32.0, 0.0}.max, DESK_ROW_H))
      row = ui.child_ui(row_rect, Egui::Id.from("vbar/row"),
        layout: Egui::Layout.left_to_right)
      row.wrap_x = false
      row.clip = row_rect.intersect(ui.clip)
      row.seed_row_height(row_rect.height)
      controls_row(row, ctx)
    ensure
      spacing.item_spacing = saved_spacing
    end
  end

  # Инфо-полоса: имя файла слева, инфо о носителе справа. Каждой
  # половине — своя ширина с элайдом; имени гарантированы 40% строки.
  private def info_strip(ui : Egui::Ui, rect : Egui::Rect) : Nil
    p = @player
    ui.painter.clip = ui.clip
    name = p.open? ? File.basename(p.path.to_s) : "No file"
    info_txt = media_info
    line_w = rect.width - 32.0
    line = ui.child_ui(Egui::Rect.from_min_size(
      Egui::Pos2.new(rect.left + 16.0, rect.top),
      Egui::Vec2.new({line_w, 0.0}.max, rect.height)),
      Egui::Id.from("vinfo/line"), layout: Egui::Layout.left_to_right)
    line.wrap_x = false
    line.clip = rect.intersect(ui.clip)
    line.seed_row_height(rect.height)
    info_w = line.fonts.measure(info_txt, 12.0).x
    name_w = {line_w - info_w - 16.0, line_w * 0.4}.max
    info_w = {info_w, line_w - name_w - 16.0}.min.clamp(0.0, info_w)
    t(line, name, size: 15.0, w: name_w)
    line.allocate_space(Egui::Vec2.new({line_w - name_w - info_w, 0.0}.max, 0.0))
    if info_w >= 1.0
      t(line, info_txt, size: 12.0, color: MUTED, w: info_w, align: "r")
    end
  end

  # Транспорт (общий для desktop и mobile): слева от play — replay
  # (поворот) и rewind, справа — forward и stop.
  private def transport(ui : Egui::Ui, ctx : Egui::Context) : Nil
    p = @player
    # ручной поворот содержимого: цикл 0° → 90° → 180° → 270°
    rot_name = {"rotate_cw", "rotate_ccw", "rotate_cw", "rotate_ccw"}[@rot % 2]
    ibtn(ui, ctx, "vbar/rot", rot_name,
      tint: @rot.zero? ? ICON_FG : ACCENT) do
      @rot = (@rot + 1) % 4
    end
    gap(ui, 12.0)
    ibtn(ui, ctx, "vbar/back", "rewind") do
      p.seek({p.position - 10.0, 0.0}.max) if p.open?
    end
    gap(ui, 12.0)
    playround(ui, ctx, "vbar/play", p.playing? ? "pause" : "play") { p.toggle }
    gap(ui, 12.0)
    ibtn(ui, ctx, "vbar/fwd", "forward") do
      p.seek({p.position + 10.0, p.duration}.min) if p.open? && p.duration > 0
    end
    gap(ui, 12.0)
    ibtn(ui, ctx, "vbar/stop", "stop") do
      p.stop
      @status = "Stopped."
    end
  end

  # Средняя строка: слева миниатюра + Open…, транспорт СТРОГО по центру
  # окна, справа время + громкость. Имя файла и инфо о кодеке живут в
  # ОТДЕЛЬНОЙ нижней строке (#info_line) — под всеми элементами бара.
  # При сужении окна уступают только гибкие части (громкость → время) —
  # кнопки и центровка транспорта не меняются.
  private def controls_row(ui : Egui::Ui, ctx : Egui::Context) : Nil
    p = @player
    ui.painter.clip = ui.clip

    time_txt = "#{fmt_time(p.position)} / #{fmt_time(p.duration)}"
    time_w = ui.fonts.measure(time_txt, 12.0).x
    transport_w = 34.0 + 12.0 + 40.0 + 12.0 + 34.0 + 12.0 + 34.0 + 12.0 + 34.0
    avail = ui.available_width
    # центр playround-кнопки = центр окна: слева от play 112px
    # (replay 34 + gap + rewind 34 + gap), поэтому смещение 112 + 20
    t_start = avail / 2.0 - 112.0

    # левая группа — две кнопки (миниатюра убрана: дублировала кадр) —
    # не заходит за транспорт

    # правый кластер: если не влезает — сжимаем громкость, потом прячем время
    vol_w = 120.0
    show_time = true
    max_right = avail - (t_start + transport_w + 8.0)
    # хвост кластера: mute 34 + 4 + громкость + 8 + fullscreen 34
    tail_fixed = 34.0 + 4.0 + 8.0 + 34.0
    if 10.0 + time_w + 8.0 + tail_fixed + vol_w > max_right
      vol_w = {max_right - 10.0 - time_w - 8.0 - tail_fixed, 40.0}.max
      vol_w = {vol_w, 120.0}.min
      if 10.0 + time_w + 8.0 + tail_fixed + vol_w > max_right
        show_time = false
        vol_w = {max_right - 8.0 - tail_fixed, 40.0}.max
        vol_w = {vol_w, 120.0}.min
      end
    end
    right_w = (show_time ? 10.0 + time_w + 8.0 : 8.0) + tail_fixed + vol_w

    ibtn(ui, ctx, "vbar/open", "folder", tint: ICON_FG) { open_dialog }
    gap(ui, 12.0)
    ibtn(ui, ctx, "vbar/open_multi", "list_video", tint: ICON_FG) { open_dialog_multiple }

    # пружина до строго центрального транспорта (кластер несимметричен:
    # слева от play 112px, справа 80px — play остаётся в центре окна)
    ui.allocate_space(Egui::Vec2.new(
      {t_start - (34.0 + 12.0 + 34.0), 0.0}.max, 0.0))
    transport(ui, ctx)

    # правый кластер прижат к правому краю
    ui.allocate_space(Egui::Vec2.new(
      {avail - right_w - (t_start + transport_w), 0.0}.max, 0.0))
    if show_time
      t(ui, time_txt, size: 12.0, color: MUTED, w: time_w + 1.0, align: "r")
    end
    gap(ui, 8.0)
    vol_icon = if !p.audio?
                 {"volume_off", MUTED}
               elsif @muted || @volume < 0.02
                 {"volume_x", ACCENT}
               else
                 {"volume_2", ICON_FG}
               end
    # id must differ from the slider's "vbar/vol": a shared id lets the
    # later-registered slider rect win the hit-test, and the button never
    # receives its click
    ibtn(ui, ctx, "vbar/mute", vol_icon[0], btn: 34.0, tint: vol_icon[1]) do
      if p.audio?
        @muted = !@muted
        apply_volume
      end
    end
    gap(ui, 4.0)
    volume_slider(ui, ctx, vol_w)
    gap(ui, 8.0)
    fs = Egui::SystemPorts::Window.fullscreen?
    ibtn(ui, ctx, "vbar/fullscreen", fs ? "minimize" : "maximize",
      btn: 34.0, tint: fs ? ACCENT : ICON_FG) { toggle_fullscreen }
  end

  # fullscreen ↔ windowed через порт состояния Window; один путь входа —
  # для кнопки, хоткея и double-click по видео.
  private def toggle_fullscreen : Nil
    Egui::SystemPorts::Window.set_fullscreen(
      !Egui::SystemPorts::Window.fullscreen?)
  end

  # одна строка инфо о носителе (верхняя рамка)
  private def media_info : String
    p = @player
    return @status unless p.open?
    parts = ["#{p.width}×#{p.height}"]
    parts << (p.video_codec || "?")
    if p.audio_rate > 0
      parts << "#{p.audio_codec} #{(p.audio_rate / 1000.0).round(1)} kHz · #{p.audio_channels}ch"
    elsif (note = p.audio_note)
      parts << "no audio (#{note})"
    end
    parts.join(" · ")
  end

  private def open_dialog : Nil
    Egui::SystemPorts::OpenFileDialog.show(
      title: "Open video",
      filters: [
        "*.mp4", "*.mkv", "*.webm", "*.avi", "*.mov", "*.wmv", "*.flv",
        "*.ts", "*.m4v", "*.mpg", "*.mpeg", "*.vob", "*.3gp", "*.ogv",
        "*.mts", "*.m2ts", "*.gif", "*",
      ]
    ) do |path|
      open_video(path) if path
    end
  end

  # Multi-pick (the layers button): the player has no playlist, so the
  # FIRST picked file plays and the status bar reports the rest.
  private def open_dialog_multiple : Nil
    Egui::SystemPorts::OpenFileDialog.show_multiple(
      title: "Open videos",
      filters: [
        "*.mp4", "*.mkv", "*.webm", "*.avi", "*.mov", "*.wmv", "*.flv",
        "*.ts", "*.m4v", "*.mpg", "*.mpeg", "*.vob", "*.3gp", "*.ogv",
        "*.mts", "*.m2ts", "*.gif", "*",
      ]
    ) do |paths|
      next unless paths && !paths.empty?
      open_video(paths.first)
      @status = "#{File.basename(paths.first)} — 1 of #{paths.size} picked"
    end
  end

  private def apply_volume : Nil
    @player.volume = (@muted ? 0.0 : @volume).to_f32!
  end

  # ── слайдеры панели ────────────────────────────────────────────────────

  # Seek (YouTube-style): полоса на всю ширину окна вдоль верхней кромки
  # бара. Тонкая линия + синяя заливка + белая ручка; на hover высота
  # линии и ручка плавно растут в 2 раза. Превью во время перетаскивания,
  # коммит на отпускании (или клике без перетаскивания).
  private def seek_strip(ui : Egui::Ui, ctx : Egui::Context,
                         bar : Egui::Rect) : Nil
    p = @player
    strip = Egui::Rect.from_min_size(bar.min,
      Egui::Vec2.new(bar.width, SEEK_STRIP_H))
    wid = Egui::Id.from("vbar/seek")
    resp = ui.interact(strip, wid, Egui::Sense::Click | Egui::Sense::Drag)
    hot = resp.hovered? || resp.dragged?
    knob_r = ctx.animate_style_scalar(wid, "kr", hot ? 10.0 : 5.0, 100.0)
    if resp.drag_started? || (resp.clicked? && !resp.dragged?)
      ctx.input.pointer_pos.try do |ptr|
        @seek_scratch = frac_at(strip, ptr.x, knob_r)
        @seek_drag = resp.drag_started?
        unless @seek_drag # одиночный клик — сразу коммит
          commit_seek
        end
        ctx.request_repaint
      end
    elsif resp.dragged?
      ctx.input.pointer_pos.try do |ptr|
        @seek_scratch = frac_at(strip, ptr.x, knob_r)
        ctx.request_repaint
      end
    elsif resp.drag_stopped?
      commit_seek
    end
    frac = if @seek_drag && p.duration > 0
             @seek_scratch
           elsif p.duration > 0
             (p.position / p.duration).clamp(0.0, 1.0)
           else
             0.0
           end
    paint_seek(ui, ctx, wid, strip, frac, hot, knob_r)
  end

  private def commit_seek : Nil
    if @player.open? && @player.duration > 0
      @player.seek(@seek_scratch * @player.duration)
    end
    @seek_drag = false
  end

  private def volume_slider(ui : Egui::Ui, ctx : Egui::Context,
                            w : Float64 = 120.0) : Nil
    ui.painter.clip = ui.clip
    rect = ui.allocate_space(Egui::Vec2.new(w, 16.0))
    wid = Egui::Id.from("vbar/vol")
    resp = ui.interact(Egui::Rect.from_min_size(rect.min,
      Egui::Vec2.new(w, 14.0)), wid, Egui::Sense::Click | Egui::Sense::Drag)
    kw = ctx.animate_style_scalar(wid, "kw",
      resp.hovered? || resp.dragged? ? 7.5 : 6.0, 100.0)
    if (resp.dragged? || resp.clicked?) && (ptr = ctx.input.pointer_pos)
      @volume = frac_at(rect, ptr.x, kw)
      @muted = false if @volume > 0.02
      apply_volume
      ctx.request_repaint
    end
    paint_slider(ui, rect, @muted ? 0.0 : @volume, kw)
  end

  # Доля по x с половинкой ручки: центр ручки ходит от rect.left + r
  # до rect.right - r, чтобы кружок не выходил за границы слайдера
  # (клип строки/окна иначе режет его половинку по краю).
  private def frac_at(rect : Egui::Rect, x : Float64, r : Float64) : Float64
    span = rect.width - 2 * r
    span > 0 ? ((x - rect.left - r) / span).clamp(0.0, 1.0) : 0.0
  end

  # Отрисовка seek-полосы: линия и ручка КОНЦЕНТРИЧНЫ — центр фиксирован
  # (strip.top + 10), при hover высота линии и радиус ручки плавно
  # удваиваются (3→6px, 5→10px), ничего не смещается. Заливка синяя.
  private def paint_seek(ui : Egui::Ui, ctx : Egui::Context,
                         wid : Egui::Id, strip : Egui::Rect,
                         frac : Float64, hot : Bool,
                         knob_r : Float64) : Nil
    p = ui.painter
    frac = frac.clamp(0.0, 1.0)
    track_h = ctx.animate_style_scalar(wid, "th", hot ? 6.0 : 3.0, 100.0)
    cy = strip.top + 10.0
    p.rect(Egui::Rect.from_min_size(
      Egui::Pos2.new(strip.left, cy - track_h / 2.0),
      Egui::Vec2.new(strip.width, track_h)), track_h / 2.0, fill: TRACK)
    p.rect(Egui::Rect.from_min_size(
      Egui::Pos2.new(strip.left, cy - track_h / 2.0),
      Egui::Vec2.new(strip.width * frac, track_h)), track_h / 2.0,
      fill: @player.downscaled? ? WARN : ACCENT)
    p.circle_filled(Egui::Pos2.new(
      strip.left + knob_r + frac * (strip.width - 2 * knob_r), cy),
      knob_r, WHITE)
  end

  # Общая отрисовка слайдера: трек, заливка до frac, круглая ручка
  # (радиус kw приходит извне — маппинг указателя и отрисовка должны
  # ходить по одному диапазону). Центр ручки — с отступом на половинку
  # круга, чтобы кружок не выходил за пределы слайдера.
  private def paint_slider(ui : Egui::Ui, rect : Egui::Rect,
                           frac : Float64, kw : Float64) : Nil
    p = ui.painter
    frac = frac.clamp(0.0, 1.0)
    cy = rect.center.y
    p.rect(Egui::Rect.from_min_size(Egui::Pos2.new(rect.left, cy - 2.0),
      Egui::Vec2.new(rect.width, 4.0)), 2.0, fill: TRACK)
    p.rect(Egui::Rect.from_min_size(Egui::Pos2.new(rect.left, cy - 2.0),
      Egui::Vec2.new(rect.width * frac, 4.0)), 2.0, fill: ACCENT)
    p.circle_filled(Egui::Pos2.new(
      rect.left + kw + frac * (rect.width - 2 * kw), cy), kw, WHITE)
  end

  # ── примитивы (порты music_widgets_manual_app.cr, без зависимостей от Music) ──

  # <gap w= h=/>
  private def gap(ui : Egui::Ui, w : Float64 = 0.0, h : Float64 = 0.0) : Nil
    ui.painter.clip = ui.clip
    ui.allocate_space(Egui::Vec2.new(w, h)) if w > 0 || h > 0
  end

  # <t text= size= color= bold= w= align=/>
  private def t(ui : Egui::Ui, text : String, *, size : Float64 = 14.0,
                color : Egui::Color32? = nil, bold : Bool = false,
                w : Float64 = 0.0, align : String = "l") : Nil
    ui.painter.clip = ui.clip
    color = TEXT unless color
    fonts = ui.fonts
    fit = w > 0 ? fonts.fit(text, size, w) : text
    m = fonts.measure(fit, size)
    tw = w > 0 ? w : m.x
    rect = ui.allocate_space(Egui::Vec2.new(tw, size * 1.35))
    x = case align
        when "c" then rect.center.x - m.x / 2.0
        when "r" then rect.right - m.x
        else          rect.left
        end
    ui.painter.text(Egui::Pos2.new(x, rect.center.y), fit, size, color, bold: bold)
  end

  # иконка по имени провайдер/имя (Film/Volume-2/Rewind…)
  private def paint_icon(ui : Egui::Ui, provider : Symbol, name : Symbol,
                         tint : Egui::Color32, rect : Egui::Rect) : Nil
    svg = case {provider, name}
          when {:lucide, :film}       then Egui::Icon.from_file(:lucide, :film, tint: tint)
          when {:lucide, :folder}     then Egui::Icon.from_file(:lucide, :folder_open, tint: tint)
          when {:lucide, :volume_2}   then Egui::Icon.from_file(:lucide, :volume_2, tint: tint)
          when {:lucide, :volume_x}   then Egui::Icon.from_file(:lucide, :volume_x, tint: tint)
          when {:lucide, :volume_off} then Egui::Icon.from_file(:lucide, :volume_off, tint: tint)
          when {:lucide, :rotate_cw}  then Egui::Icon.from_file(:lucide, :rotate_cw, tint: tint)
          when {:lucide, :rotate_ccw} then Egui::Icon.from_file(:lucide, :rotate_ccw, tint: tint)
          when {:lucide, :maximize}   then Egui::Icon.from_file(:lucide, :maximize, tint: tint)
          when {:lucide, :minimize}   then Egui::Icon.from_file(:lucide, :minimize, tint: tint)
          when {:lucide, :list_video} then Egui::Icon.from_file(:lucide, :list_video, tint: tint)
          when {:bootstrap, :rewind}  then Egui::Icon.from_file(:bootstrap, :rewind_fill, tint: tint)
          when {:bootstrap, :forward} then Egui::Icon.from_file(:bootstrap, :fast_forward_fill, tint: tint)
          when {:bootstrap, :stop}    then Egui::Icon.from_file(:bootstrap, :stop_fill, tint: tint)
          when {:bootstrap, :play}    then Egui::Icon.from_file(:bootstrap, :play_fill, tint: tint)
          when {:bootstrap, :pause}   then Egui::Icon.from_file(:bootstrap, :pause_fill, tint: tint)
          else Egui::Icon.from_file(:lucide, :circle, tint: tint)
          end
    ui.painter.clip = ui.clip
    svg.paint(ui, rect)
  end

  # <ibtn icon= size= btn= color= on_click=/> — круглая подсветка на
  # hover (плавная, через animate_style_scalar) + иконка
  private def ibtn(ui : Egui::Ui, ctx : Egui::Context, id : String,
                   name : String, *, size : Float64 = 18.0,
                   btn : Float64 = 34.0, tint : Egui::Color32? = nil,
                   &on_click) : Nil
    ui.painter.clip = ui.clip
    rect = ui.allocate_space(Egui::Vec2.new(btn, btn))
    wid = Egui::Id.from(id)
    resp = ui.interact(rect, wid, Egui::Sense::Click)
    hov = ctx.animate_style_scalar(wid, "hov",
      resp.active? ? 0x2B : (resp.hovered? ? 0x12 : 0x00), 150.0)
    if hov >= 0.5
      ui.painter.circle_filled(rect.center, btn / 2.0,
        Egui::Color32.new(255, 255, 255, hov.round.to_u8))
    end
    base = tint || ICON_FG
    color = lerp_color(base, WHITE, hov / 0x12)
    provider, iname = icon_key(name)
    paint_icon(ui, provider, iname, color,
      Egui::Rect.from_min_size(Egui::Pos2.new(rect.center.x - size / 2.0,
        rect.center.y - size / 2.0), Egui::Vec2.new(size, size)))
    if resp.clicked?
      on_click.call
      ctx.request_repaint
    end
  end

  # <playround/> — круглая кнопка play/pause с пружинной шкалой на hover
  private def playround(ui : Egui::Ui, ctx : Egui::Context, id : String,
                        name : String, *, s : Float64 = 40.0,
                        size : Float64 = 18.0, &on_click) : Nil
    ui.painter.clip = ui.clip
    rect = ui.allocate_space(Egui::Vec2.new(s, s))
    wid = Egui::Id.from(id)
    resp = ui.interact(rect, wid, Egui::Sense::Click)
    sc = ctx.animate_style_scalar(wid, "scale",
      resp.active? ? 0.95 : (resp.hovered? ? 1.06 : 1.0), 120.0)
    rs = s / 2.0 * sc
    saved_clip = ui.painter.clip
    ui.painter.clip = saved_clip.expand((rs - s / 2.0).abs)
    ui.painter.circle_filled(rect.center, rs, TEXT)
    paint_icon(ui, :bootstrap, name == "pause" ? :pause : :play, BAR_BG,
      Egui::Rect.from_min_size(Egui::Pos2.new(
        rect.center.x - size * sc / 2.0, rect.center.y - size * sc / 2.0),
        Egui::Vec2.new(size * sc, size * sc)))
    ui.painter.clip = saved_clip
    if resp.clicked?
      on_click.call
      ctx.request_repaint
    end
  end

  # <col w=> — вертикальный стек фиксированной ширины
  private def col(ui : Egui::Ui, id : String, w : Float64, h : Float64,
                  &children : Egui::Ui ->) : Nil
    ui.painter.clip = ui.clip
    rect = ui.allocate_space(Egui::Vec2.new(w, {h, 1.0}.max))
    child = ui.child_ui(rect, Egui::Id.from(id), layout: Egui::Layout.top_down)
    child.clip = Egui::Rect.from_min_size(rect.min,
      Egui::Vec2.new(w, 1e6)).intersect(ui.clip)
    yield child
  end

  # текст с центрированием по x (заглушка центральной панели)
  private def paint_text_c(ui : Egui::Ui, text : String, cx : Float64,
                           y : Float64, size : Float64, color : Egui::Color32,
                           bold : Bool = false) : Nil
    ui.painter.clip = ui.clip
    m = ui.fonts.measure(text, size)
    ui.painter.text(Egui::Pos2.new(cx - m.x / 2.0, y), text, size, color,
      bold: bold)
  end

  private def icon_key(name : String) : {Symbol, Symbol}
    case name
    when "rewind"     then {:bootstrap, :rewind}
    when "forward"    then {:bootstrap, :forward}
    when "stop"       then {:bootstrap, :stop}
    when "folder"     then {:lucide, :folder}
    when "volume_2"   then {:lucide, :volume_2}
    when "volume_x"   then {:lucide, :volume_x}
    when "volume_off" then {:lucide, :volume_off}
    when "rotate_cw"  then {:lucide, :rotate_cw}
    when "rotate_ccw" then {:lucide, :rotate_ccw}
    when "maximize"   then {:lucide, :maximize}
    when "minimize"   then {:lucide, :minimize}
    when "list_video" then {:lucide, :list_video}
    else                   {:lucide, :circle}
    end
  end

  private def lerp_color(a : Egui::Color32, b : Egui::Color32,
                         t : Float64) : Egui::Color32
    f = t.clamp(0.0, 1.0)
    Egui::Color32.new(
      (a.r.to_f64 + (b.r - a.r) * f).round.to_u8,
      (a.g.to_f64 + (b.g - a.g) * f).round.to_u8,
      (a.b.to_f64 + (b.b - a.b) * f).round.to_u8,
      (a.a.to_f64 + (b.a - a.a) * f).round.to_u8)
  end

  # debug: cumulative update() duration, printed by the player's tick
  @@update_ms : Float64 = 0.0
  @@frames : Int32 = 0

  def self.add_update_ms(ms : Float64) : Nil
    @@update_ms += ms
    @@frames += 1
  end

  def self.take_update_stats : {Float64, Int32}
    s = {@@update_ms, @@frames}
    @@update_ms = 0.0
    @@frames = 0
    s
  end

  private def fmt_time(sec : Float64) : String
    total = sec.clamp(0.0, Float64::MAX).to_i
    if total >= 3600
      "%d:%02d:%02d" % {total // 3600, (total % 3600) // 60, total % 60}
    else
      "%02d:%02d" % {total // 60, total % 60}
    end
  end
end
