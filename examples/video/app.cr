# The video player egui app: a dark cinema area on top and a Raven
# Music-style player bar at the bottom — a direct-code port of
# examples/music_components/music_widgets_manual_app.cr's player_bar (three
# zones over one painted 88px bar):
#
#   left    thumbnail · file name · media info · Open…
#   center  ⏪10 · play/pause round · ⏩10 · stop   +   elapsed —— seek —— total
#   right   mute · volume
#
# Space toggles playback; files can be dropped onto the window. The seek
# line previews the drag position and commits on release (continuous
# seeking would decode-forward on every mouse move).

class VideoApp < Egui::App
  # ── theme (Raven Music tags: examples/music_components/music_tags.cr) ──
  BAR_BG   = Egui::Color32.rgb(0x05, 0x05, 0x08)
  VIDEO_BG = Egui::Color32.rgb(0x0a, 0x0a, 0x0f)
  THUMB_BG = Egui::Color32.rgb(0x17, 0x17, 0x21)
  SEPARATOR = Egui::Color32.rgb(0x1c, 0x1c, 0x26)
  TEXT     = Egui::Color32.rgb(0xec, 0xec, 0xf2)
  MUTED    = Egui::Color32.rgb(0xa3, 0xa3, 0xb4)
  ICON_FG  = Egui::Color32.rgb(0xc4, 0xc4, 0xd2)
  ACCENT   = Egui::Color32.rgb(0xb7, 0x9c, 0xff) # Raven violet
  WHITE    = Egui::Color32.rgb(0xff, 0xff, 0xff)

  @seek_drag = false
  @seek_scratch = 0.0
  @volume = 0.8
  @muted = false

  # CLI arg: opened on the FIRST update, not before run() — GPU
  # textures can only exist after the sokol gfx setup (the sg view
  # would be dead otherwise).
  def initialize(@pending_open : String? = nil)
    super()
    @player = VideoPlayer.new(@ctx)
    @player.volume = @volume.to_f32!
    @status = "Open a video file — or drop one onto the window."
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
    end

    # Drag & drop: first path wins
    if (drop = ctx.input.dropped_files.first?)
      open_video(drop)
    end

    if @player.playing?
      @player.advance
      ctx.request_repaint # keep the vsync loop from idle-skipping
    elsif @player.open? && ENV["EGUI_VIDEO_DEBUG"]?
      @player.debug_tick # paused state keeps reporting (frozen clock)
      ctx.request_repaint # debug only: keep the loop from idle-skipping
    end

    ctx.central_panel(fill: VIDEO_BG) do |ui|
      video_area(ui)
    end

    ctx.bottom_panel(height: 88.0, resizable: false,
      fill: BAR_BG) do |ui|
      player_bar(ui, ctx)
    end

    VideoApp.add_update_ms((Time.instant - t0).total_milliseconds)
  end

  # ── центр: видео с сохранением пропорций / заглушка ───────────────────

  private def video_area(ui : Egui::Ui) : Nil
    avail = Egui::Vec2.new(ui.available_width, ui.available_height)
    rect = ui.allocate_space(avail)
    p = ui.painter
    if @player.open? && !@player.texture_id.zero?
      scale = {@player.width > 0 ? avail.x / @player.width : 0.0,
               @player.height > 0 ? avail.y / @player.height : 0.0,
               1.0}.min
      size = Egui::Vec2.new(@player.width * scale, @player.height * scale)
      ui.painter.clip = ui.clip
      ui.painter.image(Egui::Rect.from_min_size(
        Egui::Pos2.new(rect.center.x - size.x / 2.0, rect.center.y - size.y / 2.0),
        size), @player.texture_id)
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
  end

  # ── нижняя панель: 3 колонки 1fr/1.3fr/1fr на одном прямоугольнике ────

  private def player_bar(ui : Egui::Ui, ctx : Egui::Context) : Nil
    p = @player
    # панели инсетят контент на window_padding — компенсируем, чтобы бар
    # жил на полном прямоугольнике панели (пиксель в пиксель с краем окна)
    pad = ui.style.spacing.window_padding
    allocated = ui.allocate_space(Egui::Vec2.new(ui.available_width, 88.0))
    rect = Egui::Rect.from_min_size(
      Egui::Pos2.new(allocated.left - pad.x, allocated.top - pad.y),
      Egui::Vec2.new(allocated.width + 2 * pad.x, 88.0))
    pa = ui.painter
    pa.rect(rect, 0.0, fill: BAR_BG)
    pa.line(Egui::Pos2.new(rect.left, rect.top + 0.5),
      Egui::Pos2.new(rect.right, rect.top + 0.5), 1.0, SEPARATOR)

    total = rect.width - 32.0
    c13 = total / 3.3
    c2w = total - 2 * c13
    xs = {rect.left + 16.0, rect.left + 16.0 + c13, rect.left + 16.0 + c13 + c2w}

    # колонка 0: миниатюра · имя файла · медиа-инфо · Open…
    zone(ui, ctx, "vbar/c0", xs[0], rect.top, c13, 88.0) do |c|
      hbar(c, "vbar/c0/row", 88.0) do |r|
        thumb(r)
        gap(r, 14.0)
        col(r, "vbar/c0/t", 220.0, 15.0 * 1.35 + 3.0 + 13.0 * 1.35) do |cc|
          t(cc, p.open? ? File.basename(p.path.to_s) : "No file", size: 15.0)
          gap(cc, 3.0)
          t(cc, media_info, size: 13.0, color: MUTED, w: 220.0)
        end
        gap(r, 14.0)
        ibtn(r, ctx, "vbar/open", "folder", tint: ICON_FG) { open_dialog }
      end
    end

    # колонка 1: транспорт + строка seek
    zone(ui, ctx, "vbar/c1", xs[1], rect.top, c2w, 60.0) do |c|
      hbar(c, "vbar/c1/transport", 40.0) do |r|
        # кластер 202px (34+12+40+12+34+12+34+12+12… см. ниже) между пружинами
        cluster = 34.0 + 12.0 + 40.0 + 12.0 + 34.0 + 12.0 + 34.0
        sw = (r.available_width - cluster) / 2.0
        r.allocate_space(Egui::Vec2.new({sw, 0.0}.max, 0.0))
        ibtn(r, ctx, "vbar/back", "rewind") do
          p.seek({p.position - 10.0, 0.0}.max) if p.open?
        end
        gap(r, 12.0)
        playround(r, ctx, "vbar/play", p.playing? ? "pause" : "play") { p.toggle }
        gap(r, 12.0)
        ibtn(r, ctx, "vbar/fwd", "forward") do
          p.seek({p.position + 10.0, p.duration}.min) if p.open? && p.duration > 0
        end
        gap(r, 12.0)
        ibtn(r, ctx, "vbar/stop", "stop") do
          p.stop
          @status = "Stopped."
        end
        r.allocate_space(Egui::Vec2.new({sw, 0.0}.max, 0.0))
      end
      gap(c, 4.0)
      hbar(c, "vbar/c1/seek", 16.0) do |r|
        t(r, fmt_time(p.position), size: 12.0, color: MUTED, w: 44.0, align: "r")
        gap(r, 10.0)
        seek_slider(r, ctx)
        gap(r, 10.0)
        t(r, fmt_time(p.duration), size: 12.0, color: MUTED, w: 44.0)
      end
    end

    # колонка 2: громкость
    zone(ui, ctx, "vbar/c2", xs[2], rect.top, c13, 88.0) do |c|
      hbar(c, "vbar/c2/row", 88.0) do |r|
        # хвост: 34 + 4 + 120 = 158
        rspring(r, 158.0)
        vol_icon = if !p.audio?
                     {"volume_off", MUTED}
                   elsif @muted || @volume < 0.02
                     {"volume_x", ACCENT}
                   else
                     {"volume_2", ICON_FG}
                   end
        ibtn(r, ctx, "vbar/vol", vol_icon[0], btn: 34.0, tint: vol_icon[1]) do
          if p.audio?
            @muted = !@muted
            apply_volume
          end
        end
        gap(r, 4.0)
        volume_slider(r, ctx)
      end
    end
  end

  # Миниатюра слева: живой кадр видео (с сохранением пропорций) или
  # плейсхолдер с иконкой плёнки.
  private def thumb(ui : Egui::Ui) : Nil
    p = @player
    if p.open? && !p.texture_id.zero? && p.height > 0
      w = {58.0 * p.width / p.height, 160.0}.min
      rect = ui.allocate_space(Egui::Vec2.new(w, 58.0))
      ui.painter.clip = ui.clip
      ui.painter.image(rect, p.texture_id)
    else
      rect = ui.allocate_space(Egui::Vec2.new(58.0, 58.0))
      ui.painter.clip = ui.clip
      ui.painter.rect(rect, 6.0, fill: THUMB_BG)
      paint_icon(ui, :lucide, :film, MUTED, Egui::Rect.from_min_size(
        Egui::Pos2.new(rect.center.x - 14.0, rect.center.y - 14.0),
        Egui::Vec2.new(28.0, 28.0)))
    end
  end

  # одна строка инфо о носителе под именем файла
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

  private def apply_volume : Nil
    @player.volume = (@muted ? 0.0 : @volume).to_f32!
  end

  # ── слайдеры панели ────────────────────────────────────────────────────

  # Seek: превью во время перетаскивания, коммит на отпускании (или на
  # клике без перетаскивания). Тонкая линия + акцентная заливка + ручка,
  # как oslider Raven.
  private def seek_slider(ui : Egui::Ui, ctx : Egui::Context) : Nil
    p = @player
    ui.painter.clip = ui.clip
    w = ui.available_width
    rect = ui.allocate_space(Egui::Vec2.new(w, 16.0))
    wid = Egui::Id.from("vbar/seek")
    resp = ui.interact(Egui::Rect.from_min_size(rect.min,
      Egui::Vec2.new(w, 14.0)), wid, Egui::Sense::Click | Egui::Sense::Drag)
    if resp.drag_started? || (resp.clicked? && !resp.dragged?)
      ctx.input.pointer_pos.try do |ptr|
        @seek_scratch = ((ptr.x - rect.left) / w).clamp(0.0, 1.0)
        @seek_drag = resp.drag_started?
        unless @seek_drag # одиночный клик — сразу коммит
          commit_seek
        end
        ctx.request_repaint
      end
    elsif resp.dragged?
      ctx.input.pointer_pos.try do |ptr|
        @seek_scratch = ((ptr.x - rect.left) / w).clamp(0.0, 1.0)
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
    paint_slider(ui, ctx, wid, rect, frac, resp)
  end

  private def commit_seek : Nil
    if @player.open? && @player.duration > 0
      @player.seek(@seek_scratch * @player.duration)
    end
    @seek_drag = false
  end

  private def volume_slider(ui : Egui::Ui, ctx : Egui::Context) : Nil
    ui.painter.clip = ui.clip
    w = 120.0
    rect = ui.allocate_space(Egui::Vec2.new(w, 16.0))
    wid = Egui::Id.from("vbar/vol")
    resp = ui.interact(Egui::Rect.from_min_size(rect.min,
      Egui::Vec2.new(w, 14.0)), wid, Egui::Sense::Click | Egui::Sense::Drag)
    if (resp.dragged? || resp.clicked?) && (ptr = ctx.input.pointer_pos)
      @volume = ((ptr.x - rect.left) / w).clamp(0.0, 1.0)
      @muted = false if @volume > 0.02
      apply_volume
      ctx.request_repaint
    end
    paint_slider(ui, ctx, wid, rect, @muted ? 0.0 : @volume, resp)
  end

  # Общая отрисовка слайдера: трек, заливка до frac, круглая ручка (с
  # плавным ростом на hover/drag через animate_style_scalar).
  private def paint_slider(ui : Egui::Ui, ctx : Egui::Context,
                           wid : Egui::Id, rect : Egui::Rect, frac : Float64,
                           resp : Egui::Response) : Nil
    p = ui.painter
    frac = frac.clamp(0.0, 1.0)
    cy = rect.center.y
    kw = ctx.animate_style_scalar(wid, "kw",
      resp.hovered? || resp.dragged? ? 7.5 : 6.0, 100.0)
    p.rect(Egui::Rect.from_min_size(Egui::Pos2.new(rect.left, cy - 2.0),
      Egui::Vec2.new(rect.width, 4.0)), 2.0,
      fill: Egui::Color32.rgba(255, 255, 255, 0x33))
    p.rect(Egui::Rect.from_min_size(Egui::Pos2.new(rect.left, cy - 2.0),
      Egui::Vec2.new(rect.width * frac, 4.0)), 2.0, fill: ACCENT)
    p.circle_filled(Egui::Pos2.new(rect.left + rect.width * frac, cy), kw, WHITE)
  end

  # ── примитивы (порты music_widgets_manual_app.cr, без зависимостей от Music) ──

  # Зона панели: child-ui на своём прямоугольнике (клип — вся зона).
  private def zone(ui : Egui::Ui, ctx : Egui::Context, id : String,
                   x : Float64, y : Float64, w : Float64, h : Float64,
                   &children : Egui::Ui ->) : Nil
    inner = Egui::Rect.from_min_size(
      Egui::Pos2.new(x, y + (88.0 - h) / 2.0), Egui::Vec2.new(w, h))
    child = ui.child_ui(inner, Egui::Id.from(id), layout: Egui::Layout.top_down)
    child.clip = clip_zone(ui, x, y, w)
    yield child
  end

  private def clip_zone(ui : Egui::Ui, x : Float64, y : Float64,
                        w : Float64) : Egui::Rect
    Egui::Rect.from_min_size(Egui::Pos2.new(x, y), Egui::Vec2.new(w, 88.0))
      .intersect(ui.clip)
  end

  # <gap w= h=/>
  private def gap(ui : Egui::Ui, w : Float64 = 0.0, h : Float64 = 0.0) : Nil
    ui.painter.clip = ui.clip
    ui.allocate_space(Egui::Vec2.new(w, h)) if w > 0 || h > 0
  end

  # <spring/>: весь остаток минус ширина хвостовых детей (reserve)
  private def rspring(ui : Egui::Ui, reserve : Float64 = 0.0) : Nil
    ui.painter.clip = ui.clip
    if ui.layout.horizontal?
      ui.allocate_space(Egui::Vec2.new({ui.available_width - reserve, 0.0}.max, 0.0))
    else
      ui.allocate_space(Egui::Vec2.new(0.0, ui.available_height))
    end
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

  # <hbar h=> — строка-контейнер, дети центрированы по вертикали
  private def hbar(ui : Egui::Ui, id : String, h : Float64,
                   &children : Egui::Ui ->) : Nil
    ui.painter.clip = ui.clip
    rect = ui.allocate_space(Egui::Vec2.new(ui.available_width, h))
    child = ui.child_ui(rect, Egui::Id.from(id),
      layout: Egui::Layout.left_to_right)
    child.wrap_x = false
    child.clip = rect.intersect(ui.clip)
    child.seed_row_height(h)
    yield child
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
