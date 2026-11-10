# egui-cr music — NativeHTML Music, этап 1 (каркас) плана
# plans/NATIVE_HTML_DEMO.md: порт демо `examples/music` библиотеки Raven
# (tmp/Raven, Apache-2.0) — ходячее приложение без красоты. Окно
# 1360×860: слева sidebar (Home / Collection / Search / Library /
# Settings), в центре пять страниц с реальными данными из
# examples/music_components/library.cr (24 альбома, ~200 треков, 6
# плейлистов — генерация и цвета 1:1 с library.c), снизу бар плеера.
# Проигрывание имитируется часами (позиция наращивается по input.time,
# пока играет — request_repaint, как в animated-plot трюке галереи);
# звука нет — как и в оригинале. Горячие клавиши: Space, Ctrl+←/→,
# Ctrl+L/F/P, Alt+← (назад по истории страниц).
#
# Этап 2 (exml-разметка страниц), этап 3 (темы/акцент/эффекты) и далее
# — по плану; здесь UI собран кристал-кодом на существующих виджетах.

require "../src/egui/driver_selector"
require "./icon"
require "./music_components/library"

class MusicApp < Egui::App
  # Страницы — те же пять, что в `<Switcher>` оригинала.
  enum Page
    Home
    Collection
    Search
    Library
    Settings
  end

  # Действия приложения (hotkey-слой экшен-ориентированный: комбинации
  # упомянуты только в DEFAULT_BINDINGS ниже).
  ACTION_TOGGLE   = Egui::HotkeyAction.new("music.toggle")
  ACTION_NEXT     = Egui::HotkeyAction.new("music.next")
  ACTION_PREV     = Egui::HotkeyAction.new("music.previous")
  ACTION_LIKE     = Egui::HotkeyAction.new("music.like")
  ACTION_SEARCH   = Egui::HotkeyAction.new("music.search")
  ACTION_SETTINGS = Egui::HotkeyAction.new("music.settings")
  ACTION_BACK     = Egui::HotkeyAction.new("music.back")

  DEFAULT_BINDINGS = {
    ACTION_TOGGLE   => "Space",
    ACTION_NEXT     => "Ctrl+Right",
    ACTION_PREV     => "Ctrl+Left",
    ACTION_LIKE     => "Ctrl+L",
    ACTION_SEARCH   => "Ctrl+F",
    ACTION_SETTINGS => "Ctrl+P",
    ACTION_BACK     => "Alt+Left",
  }

  # Навигация: страница + глиф lucide для sidebar-кнопки.
  NAV_ITEMS = {
    {Page::Home,       "Home",       :home},
    {Page::Collection, "Collection", :disc_3},
    {Page::Search,     "Search",     :search},
    {Page::Library,    "Library",    :library},
    {Page::Settings,   "Settings",   :settings},
  }

  @page = Page::Home
  @history = [] of Page
  @hotkeys_ready = false

  # Плеер (main.c): очередь треков, позиция по часам, shuffle/repeat.
  @queue = [] of Int32
  @queue_position = -1
  @track : Int32? = nil
  @position = 0.0
  @playing = false
  @shuffle = false
  @repeat_mode = 0 # 0 off / 1 all / 2 one
  @volume = 0.7
  @muted = false
  @context = ""
  @last_tick = 0.0

  # Коллекция: вкладка Albums/Playlists.
  @collection_kind = 0
  # Settings-заглушки (эффекты фона — этап 5, акцент — этап 3).
  @follow_cover = true
  @animate = true
  @now_playing_panel = true
  # Поиск: живой фильтр по названию/артисту/альбому.
  @search_query = ""

  def update(ctx : Egui::Context) : Nil
    unless @hotkeys_ready
      DEFAULT_BINDINGS.each { |action, combo| ctx.hotkeys.bind(combo, action) }
      @hotkeys_ready = true
    end

    advance_clock(ctx)

    ctx.side_panel(:left, "nav", width: 190.0, resizable: false) do |ui|
      draw_sidebar(ui)
    end

    ctx.central_panel do |ui|
      ui.scroll_area do |page|
        case @page
        when .home?       then page_home(page)
        when .collection? then page_collection(page)
        when .search?     then page_search(page)
        when .library?    then page_library(page)
        when .settings?   then page_settings(page)
        end
      end
    end

    ctx.bottom_panel("player", height: 76.0, resizable: false) do |ui|
      draw_player_bar(ui)
    end

    handle_actions(ctx)
  end

  # ---- часы плеера -----------------------------------------------------
  #
  # Позиция наращивается по input.time (Rtimer 0.25 с оригинала здесь —
  # каждый кадр: request_repaint ниже держит кадры идущими, пока играет;
  # конец трека двигает очередь по repeat-режиму).

  private def advance_clock(ctx : Egui::Context) : Nil
    now = ctx.input.time
    if @playing && (index = @track)
      ctx.request_repaint
      @position += now - @last_tick
      track = Music.tracks[index]
      if @position >= track.seconds
        if @repeat_mode == 2
          @position = 0.0
        elsif @queue_position + 1 < @queue.size
          play_position(@queue_position + 1)
        elsif @repeat_mode == 1
          play_position(0)
        else
          @playing = false
          @position = 0.0
        end
      end
    end
    @last_tick = now
  end

  # Ставит список треков с одного из них; при shuffle остальные идут
  # после него в случайном порядке (play_list из main.c).
  private def play_list(tracks : Array(Int32), start : Int32, context : String) : Nil
    return if tracks.empty?
    @queue = tracks.dup
    @context = context
    if @shuffle
      @queue[start], @queue[0] = @queue[0], @queue[start]
      (tracks.size - 1).downto(2) do |i|
        j = 1 + rand(i)
        @queue[i], @queue[j] = @queue[j], @queue[i]
      end
      start = 0
    end
    play_position(start)
  end

  private def play_position(pos : Int32) : Nil
    return if @queue.empty?
    pos = 0 if pos < 0 || pos >= @queue.size
    @queue_position = pos
    @track = @queue[pos]
    @position = 0.0
    @playing = true
    Music.tracks[@track.not_nil!].plays += 1
  end

  def play_album(index : Int32) : Nil
    album = Music.albums[index]
    play_list(Music.album_tracks(index), 0, album.title)
  end

  def play_playlist(index : Int32) : Nil
    list = index == 0 ? Music.liked_playlist : Music.playlists[index]
    play_list(list.tracks.dup, 0, list.title)
  end

  # Клик по треку: играет список, в котором он живёт, начиная с него —
  # его альбом (track.play.NN из main.c, вне страницы коллекции).
  def play_track(index : Int32) : Nil
    track = Music.tracks[index]
    album = Music.albums[track.album]
    play_list(Music.album_tracks(track.album),
      index - album.first_track, album.title)
  end

  def toggle_play : Nil
    if @track.nil?
      play_album(0)
    else
      @playing = !@playing
    end
  end

  def next_track : Nil
    play_position(@queue_position + 1 < @queue.size ? @queue_position + 1 : 0) unless @queue.empty?
  end

  def previous_track : Nil
    # несколько секунд в песне — к её началу, иначе предыдущая
    if @position > 3.0 || @queue_position <= 0
      @position = 0.0
    else
      play_position(@queue_position - 1)
    end
  end

  def toggle_like : Nil
    if (index = @track)
      track = Music.tracks[index]
      track.liked = !track.liked
    end
  end

  def seek(fraction : Float64) : Nil
    return unless (index = @track)
    @position = fraction.clamp(0.0, 1.0) * Music.tracks[index].seconds
  end

  # ---- история страниц --------------------------------------------------

  def show_page(page : Page, remember : Bool = true) : Nil
    if remember && page != @page
      @history << @page
      @history.shift if @history.size > 32
    end
    @page = page
  end

  def go_back : Nil
    if (page = @history.pop?)
      @page = page
    end
  end

  # ---- sidebar -----------------------------------------------------------

  private def draw_sidebar(ui : Egui::Ui) : Nil
    fg = ui.style.visuals.text_color
    ui.heading("Music")
    ui.separator
    NAV_ITEMS.each do |page, title, glyph|
      button = Egui::Button.new(title).icon(nav_icon(page, glyph, fg))
      button = button.style { |s|
        s.background = ui.style.visuals.selection_fill
      } if @page == page
      if ui.add(button).clicked?
        show_page(page)
      end
    end
    ui.separator
    ui.label("Space play/pause")
    ui.label("Ctrl+←/→ prev/next")
    ui.label("Ctrl+L like · Ctrl+F find")
    ui.label("Ctrl+P settings · Alt+← back")
  end

  # ---- карточки ----------------------------------------------------------

  # Карточка альбома: обложка (процедурная, painter'ом) + подписи,
  # клик по всей карточке играет альбом. `round` — круглая (артисты).
  private def album_card(ui : Egui::Ui, index : Int32,
                         cover_size : Float64 = 132.0,
                         round : Bool = false) : Bool
    album = Music.albums[index]
    radius = round ? cover_size / 2.0 : 8.0
    rect = ui.allocate_space(Egui::Vec2.new(cover_size, cover_size + 44.0))
    resp = ui.interact(rect, ui.named_id("album-card/#{index}/#{round}"),
      Egui::Sense::Click)
    cover_rect = Egui::Rect.from_min_size(
      rect.min, Egui::Vec2.new(cover_size, cover_size))
    Music.paint_cover(ui.painter, ui.fonts, cover_rect, album, radius)
    if resp.hovered?
      ui.painter.rect(cover_rect, radius,
        fill: Egui::Color32.rgba(255, 255, 255, 26))
    end
    fg = ui.style.visuals.text_color
    weak = Egui::Color32.new(fg.r, fg.g, fg.b, 0xA0)
    ui.painter.text(
      Egui::Pos2.new(rect.min.x, rect.min.y + cover_size + 10.0),
      album.title, 13.0, fg)
    ui.painter.text(
      Egui::Pos2.new(rect.min.x, rect.min.y + cover_size + 30.0),
      "#{album.year} · #{album.artist}", 12.0, weak)
    resp.clicked?
  end

  private def playlist_card(ui : Egui::Ui, index : Int32,
                            cover_size : Float64 = 132.0) : Bool
    list = index == 0 ? Music.liked_playlist : Music.playlists[index]
    album = Music.albums[list.cover]
    rect = ui.allocate_space(Egui::Vec2.new(cover_size, cover_size + 44.0))
    resp = ui.interact(rect, ui.named_id("playlist-card/#{index}"),
      Egui::Sense::Click)
    cover_rect = Egui::Rect.from_min_size(
      rect.min, Egui::Vec2.new(cover_size, cover_size))
    Music.paint_cover(ui.painter, ui.fonts, cover_rect, album, 8.0)
    if resp.hovered?
      ui.painter.rect(cover_rect, 8.0,
        fill: Egui::Color32.rgba(255, 255, 255, 26))
    end
    fg = ui.style.visuals.text_color
    weak = Egui::Color32.new(fg.r, fg.g, fg.b, 0xA0)
    ui.painter.text(
      Egui::Pos2.new(rect.min.x, rect.min.y + cover_size + 10.0),
      list.title, 13.0, fg)
    note = list.description.size > 28 ? "#{list.description[0, 27]}…" : list.description
    ui.painter.text(
      Egui::Pos2.new(rect.min.x, rect.min.y + cover_size + 30.0),
      note, 12.0, weak)
    resp.clicked?
  end

  # ---- страницы ----------------------------------------------------------

  private def page_home(ui : Egui::Ui) : Nil
    hour = Time.local.hour
    greeting = hour < 5 ? "Good night" : hour < 12 ? "Good morning" :
               hour < 18 ? "Good afternoon" : "Good evening"
    ui.heading(greeting)
    ui.separator

    ui.heading("Recently played")
    ui.horizontal(wrap: true) do |row|
      10.times { |i| play_album((i * 7 + 2) % Music::MUSIC_ALBUMS) if album_card(row, (i * 7 + 2) % Music::MUSIC_ALBUMS) }
    end

    ui.heading("Made for you")
    ui.horizontal(wrap: true) do |row|
      (1...Music::MUSIC_PLAYLISTS).each do |p|
        play_playlist(p) if playlist_card(row, p)
      end
    end

    # новинки: альбомы по году, как home.new оригинала
    ui.heading("New releases")
    order = (0...Music::MUSIC_ALBUMS).to_a.sort { |a, b|
      Music.albums[b].year <=> Music.albums[a].year
    }
    ui.horizontal(wrap: true) do |row|
      order.first(10).each { |a| play_album(a) if album_card(row, a) }
    end
  end

  private def page_collection(ui : Egui::Ui) : Nil
    ui.heading("Collection")
    ui.segmented(@collection_kind, ["Albums", "Playlists"]) { |i| @collection_kind = i }
    ui.separator
    ui.horizontal(wrap: true) do |row|
      if @collection_kind == 0
        Music::MUSIC_ALBUMS.times do |a|
          play_album(a) if album_card(row, a)
        end
      else
        Music::MUSIC_PLAYLISTS.times do |p|
          play_playlist(p) if playlist_card(row, p)
        end
      end
    end
  end

  private def page_search(ui : Egui::Ui) : Nil
    ui.heading("Search")
    ui.text_edit_singleline(@search_query,
      hint: "Songs, artists, albums…", focus_id: "search") { |t| @search_query = t }
    ui.separator

    query = @search_query.downcase.strip
    if query.empty?
      ui.label("Type to filter the library by song, artist or album.")
      return
    end

    found = Music.tracks.each_with_index.select { |track, _|
      album = Music.albums[track.album]
      track.title.downcase.includes?(query) ||
        album.artist.downcase.includes?(query) ||
        album.title.downcase.includes?(query)
    }.map { |_, i| i }.to_a

    ui.label("Songs · #{found.size}")
    if found.empty?
      ui.label("Nothing matches \"#{@search_query}\". Try another word: a genre, a city, a color…")
      return
    end

    track_table(ui, "search", found.first(50), show_number: false)
  end

  private def page_library(ui : Egui::Ui) : Nil
    ui.heading("Library")
    ui.label("#{Music::MUSIC_PLAYLISTS} playlists, #{Music::MUSIC_ALBUMS} albums, " \
             "#{Music.tracks.size} songs (#{Music.tracks.count(&.liked)} liked).")
    ui.separator
    track_table(ui, "library", (0...Music.tracks.size).to_a, show_number: true)
  end

  # Таблица треков: клик по названию играет трек (очередь — его альбом,
  # с него). Текущая строка подсвечена selectable-состоянием.
  private def track_table(ui : Egui::Ui, id : String, rows : Array(Int32),
                          show_number : Bool) : Nil
    headers = show_number ? ["#", "Title", "Artist", "Album", "Time", "Plays"] :
                            ["Title", "Artist", "Album", "Time"]
    fractions = show_number ? [0.05, 0.30, 0.21, 0.25, 0.09, 0.10] :
                              [0.34, 0.22, 0.26, 0.10]
    ui.table("#{id}-tracks", headers, fractions) do |grid|
      rows.each_with_index do |index, n|
        track = Music.tracks[index]
        album = Music.albums[track.album]
        grid.label((n + 1).to_s) if show_number
        if grid.add(Egui::SelectableLabel.new(@track == index, track.title)).clicked?
          play_track(index)
        end
        grid.label(album.artist)
        grid.label(album.title)
        grid.label(Music.format_time(track.seconds))
        grid.label(track.plays.to_s) if show_number
        grid.end_row
      end
    end
  end

  private def page_settings(ui : Egui::Ui) : Nil
    ui.heading("Settings")
    ui.separator
    ui.checkbox(@follow_cover, "Follow the cover (accent takes the album colors)") { |v| @follow_cover = v }
    ui.checkbox(@animate, "Animate background") { |v| @animate = v }
    ui.checkbox(@now_playing_panel, "Now playing panel") { |v| @now_playing_panel = v }
    ui.separator
    ui.label("Background effects (mesh/aurora/plasma/spotlight/shimmer),")
    ui.label("themes and the island arrive at stages 3–7 of the port plan")
    ui.label("(plans/NATIVE_HTML_DEMO.md); the toggles above already drive")
    ui.label("the player state they will plug into.")
  end

  # ---- нижний бар плеера --------------------------------------------------

  # Обложка + название/артист рисуются painter'ом одним блоком (слева),
  # дальше транспорт, громкость и seek-слайдер до правого края.
  private def draw_player_bar(ui : Egui::Ui) : Nil
    fg = ui.style.visuals.text_color
    weak = Egui::Color32.new(fg.r, fg.g, fg.b, 0xA0)
    track = (index = @track) ? Music.tracks[index] : nil
    album = track ? Music.albums[track.album] : nil
    accent = album ? album.color : fg

    ui.horizontal(wrap: false) do |bar|
      block = bar.allocate_space(Egui::Vec2.new(292.0, 60.0))
      if track && album
        Music.paint_cover(bar.painter, bar.fonts,
          Egui::Rect.from_min_size(block.min, Egui::Vec2.new(60.0, 60.0)),
          album, 6.0)
        title = track.title
        title = "#{title[0, 28]}…" if title.size > 29
        bar.painter.text(
          Egui::Pos2.new(block.min.x + 72.0, block.min.y + 16.0),
          title, 14.0, fg, bold: true)
        bar.painter.text(
          Egui::Pos2.new(block.min.x + 72.0, block.min.y + 42.0),
          album.artist, 12.0, weak)
      else
        bar.painter.text(
          Egui::Pos2.new(block.min.x + 4.0, block.center.y),
          "Nothing playing — pick a song", 13.0, weak)
      end

      icon_button(bar, Egui::Icon.from_file(:lucide, :skip_back, tint: fg), "prev") { previous_track }
      playing_svg = @playing ? Egui::Icon.from_file(:lucide, :pause, tint: fg) :
                               Egui::Icon.from_file(:lucide, :play, tint: fg)
      icon_button(bar, playing_svg, "toggle") { toggle_play }
      icon_button(bar, Egui::Icon.from_file(:lucide, :skip_forward, tint: fg), "next") { next_track }
      shuffle_svg = Egui::Icon.from_file(:lucide, :shuffle, tint: @shuffle ? accent : fg)
      icon_button(bar, shuffle_svg, "shuffle") { @shuffle = !@shuffle }
      repeat_svg = @repeat_mode == 2 ? Egui::Icon.from_file(:lucide, :repeat_1, tint: @repeat_mode != 0 ? accent : fg) :
                                      Egui::Icon.from_file(:lucide, :repeat, tint: @repeat_mode != 0 ? accent : fg)
      icon_button(bar, repeat_svg, "repeat") { @repeat_mode = (@repeat_mode + 1) % 3 }

      liked = track.try(&.liked) || false
      heart = liked ? Egui::Icon.from_file(:bootstrap, :heart_fill, tint: accent) :
                      Egui::Icon.from_file(:lucide, :heart, tint: fg)
      if ui.add(Egui::Button.new("", id: "like").icon(heart)).clicked?
        toggle_like
      end

      mute_svg = @muted ? Egui::Icon.from_file(:lucide, :volume_x, tint: fg) :
                          Egui::Icon.from_file(:lucide, :volume_2, tint: fg)
      icon_button(bar, mute_svg, "mute") do
        @muted = !@muted
        @volume = 0.5 if !@muted && @volume <= 0.001
      end
      volume = Egui::Slider.new(@muted ? 0.0 : @volume, 0.0..1.0, id: "volume")
      volume_resp = bar.add_sized(Egui::Vec2.new(110.0, 20.0), volume)
      if volume_resp.changed? && (v = volume_resp.widget_value)
        @volume = v
        @muted = v <= 0.001
      end

      elapsed = Music.format_time(@position.to_i)
      total = Music.format_time(track.try(&.seconds) || 0)
      bar.label("#{elapsed} / #{total}")
      fraction = track && track.seconds > 0 ? @position / track.seconds : 0.0
      bar.slider(fraction.clamp(0.0, 1.0), 0.0..1.0, id: "seek") { |v| seek(v) }
    end
  end

  # Иконка навигации: имена глифов должны быть литералами в местах
  # вызова Icon.from_file (compile-time встраивание SVG), поэтому case,
  # а не запись из NAV_ITEMS.
  private def nav_icon(page : Page, glyph : Symbol, tint : Egui::Color32) : Egui::Svg
    case page
    when .home?       then Egui::Icon.from_file(:lucide, :house, tint: tint)
    when .collection? then Egui::Icon.from_file(:lucide, :disc_3, tint: tint)
    when .search?     then Egui::Icon.from_file(:lucide, :search, tint: tint)
    when .library?    then Egui::Icon.from_file(:lucide, :library, tint: tint)
    else                   Egui::Icon.from_file(:lucide, :settings, tint: tint)
    end
  end

  # Кнопка-иконка (lucide): глиф тонирован цветом — акцент для
  # включённых состояний (shuffle/repeat/сердечко), обычный текстовый —
  # для остальных. Глиф передаётся готовым Svg: имя иконки должно быть
  # литералом у места вызова Icon.from_file.
  private def icon_button(ui : Egui::Ui, svg : Egui::Svg,
                          id : String, &block) : Nil
    if ui.add(Egui::Button.new("", id: id).icon(svg)).clicked?
      yield
    end
  end

  # ---- действия ------------------------------------------------------------

  private def handle_actions(ctx : Egui::Context) : Nil
    # Space в поле ввода — это пробел, не пауза (фокус-проверка).
    if ctx.consume_action(ACTION_TOGGLE) && ctx.memory.focused_text_input.nil?
      toggle_play
    end
    next_track if ctx.consume_action(ACTION_NEXT)
    previous_track if ctx.consume_action(ACTION_PREV)
    toggle_like if ctx.consume_action(ACTION_LIKE)
    show_page(Page::Search) if ctx.consume_action(ACTION_SEARCH)
    show_page(Page::Settings) if ctx.consume_action(ACTION_SETTINGS)
    go_back if ctx.consume_action(ACTION_BACK)
  end
end

Egui.run(MusicApp.new, title: "egui-cr — NativeHTML Music",
  width: 1360, height: 860,
  icon: {rgba: ICON_64_RGBA, width: 64, height: 64}, inspector: :hidden)
