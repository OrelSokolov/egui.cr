# music_app.cr — приложение Raven Music live (NATIVE_HTML_DEMO):
# порт поведения Vue-оракула oracle/oracle_live (плеер, акцент из
# обложки, поиск, коллекция, остров, клавиши) на exml-разметку.
# Слои как у оригинала: markup (assets/music.exml) — структура, геометрия
# (assets/music.ecss) — паддинги/скругления панелей (цвета классов пишет
# apply_look по текущему луку — как <Theme>-файлы Raven), состояние — MusicPlayer
# (music_player.cr, порт app.js), данные — MusicLibrary
# (music_library.cr, тот же LCG, что в library.c). Каждый кадр
# приложение синхронизирует вычисляемые значения в store exml-рендера
# (аналог computed у Vue); действия разметки зовут методы плеера.
# Точка входа — examples/music_exml.cr (спекам класс нужен без Egui.run).
require "../../src/egui"
require "./music_tags"
require "./music_player"
class MusicExmlApp < Egui::App
  getter rt : Egui::Exml::Runtime
  getter player : MusicPlayer
  @exml : Egui::Exml::Document

  # стартовые затраты exml-слоя для сравнения с ручной версткой
  # (MUSIC_TTFB=1 у точки входа печатает их)
  class_property exml_parse_ms : Float64 = 0.0
  class_property ecss_parse_ms : Float64 = 0.0

  def initialize
    super
    t0 = Time.instant
    @exml = self.class.load_document
    MusicExmlApp.exml_parse_ms = (Time.instant - t0).total_milliseconds
    @renderer = Egui::Exml::Renderer.new
    @rt = Egui::Exml::Runtime.new
    @ecss = nil
    @styled = false
    # живое состояние (порт root component oracle_live/app.js)
    @player = MusicPlayer.new
    @library = @player.library
    @last_tick = 0.0
    apply_start_state
  end

  # стартовое состояние — аналог location.hash оракула (#album,#playlist,
  # #search,#genres,#library,#settings, опционально ,paused): MUSIC_PAGE
  def apply_start_state : Nil
    opts = (ENV["MUSIC_PAGE"]? || "").split(',').map(&.strip)
    case
    when opts.includes?("album")     then @player.open_album(0, 0.0)
    when opts.includes?("playlist")  then @player.open_playlist(1)
    when opts.includes?("search")    then @player.query = "the"; @player.nav_to(:search)
    when opts.includes?("genres")    then @player.nav_to(:search)
    when opts.includes?("library")   then @player.nav_to(:library)
    when opts.includes?("settings")  then @player.nav_to(:settings)
    end
    if (lk = ENV["MUSIC_LOOK"]?) && (i = MusicLibrary::LOOKS.index(lk))
      @player.look = i
    end
    @player.playing = false if opts.includes?("paused")
    @player.animate = false if opts.includes?("still") # для скриншот-сравнений
  end

  def self.exml_path : String
    env = ENV["MUSIC_EXML"]?
    return env if env && File.exists?(env)
    candidates = [
      # из корня проекта (music_app.cr живёт в examples/music_components)
      # и из bin/ (дев-запуск и бинарь)
      File.join(File.dirname(File.dirname(__DIR__)), "assets", "music.exml"),
    ]
    candidates.each do |c|
      return c if File.exists?(c)
    end
    raise "assets/music.exml not found (set MUSIC_EXML)"
  end

  # Источник разметки: живой .exml через парсер (dev, hot-reload).
  # Кодоген-сборка (music_gen) подменяет это на Document.hybrid —
  # живой файл, если он есть, иначе вшитые литералы egui-gen.
  def self.load_document : Egui::Exml::Document
    Egui::Exml::Document.load(exml_path)
  end

  def self.ecss_path : String
    File.join(File.dirname(exml_path), "music.ecss")
  end

  def update(ctx : Egui::Context) : Nil
    unless @styled
      # Вся геометрия — как в оракуле: нулевые item_spacing/window_padding
      # (зазоры в разметке явные <gap/>, отступы — в ECSS-правилах).
      # Цвета лука пишутся ПОВЕРХ сессии ecss (в файле — только геометрия)
      # и переписываются при каждой смене лука (apply_look).
      ctx.style.spacing.item_spacing = Egui::Vec2.new(0.0, 0.0)
      ctx.style.spacing.window_padding = Egui::Vec2.new(0.0, 0.0)
      t0 = Time.instant
      @ecss = Egui::Ecss::Session.new(ctx, self.class.ecss_path)
      MusicExmlApp.ecss_parse_ms = (Time.instant - t0).total_milliseconds
      apply_look(ctx)
      @styled = true
      register_actions(ctx)
      bind_hotkeys(ctx)
    end

    @exml.reload_if_changed
    now = advance_clock(ctx)
    handle_hotkeys(ctx, now)
    sync(ctx, now)
    if ENV["MUSIC_DBG"]? && (dbg_n = ENV["MUSIC_DBG"].to_i?) && (dbg_n > 0)
      STDERR.puts "dbg n=#{dbg_n} accent=#{@rt.string("accent").inspect} " \
                  "np=#{@rt.string("np_title").inspect} elapsed=#{@rt.string("elapsed")} " \
                  "len=#{@rt.string("length")} play=#{@rt.string("play_icon")} " \
                  "page=#{@player.page} focus=#{@rt.string("_focus").inspect} query=#{@rt.string("query").inspect}"
      ENV["MUSIC_DBG"] = (dbg_n - 1).to_s
    end

    @renderer.render_routes(ctx, @exml, @rt)
  end

  # ── лук (аналог use_look/Rtheme_use у Raven) ───────────────────────
  # Применяет лук @player.look: палитру MusicTags (её читают теги каждый
  # кадр), базовые visuals контекста и ЦВЕТНАЯ часть ECSS-классов —
  # music.ecss хранит только геометрию, цвета пишутся сюда поверх сессии
  # (стили файлов темы Raven: Colors + Style Class="surface" …).
  def apply_look(ctx : Egui::Context) : Nil
    name = MusicLibrary::LOOKS[@player.look]? || MusicLibrary::LOOKS[0]
    MusicTags.use_look(name)
    pal = MusicTags.look
    # мутация in-place: ctx.theme= идемпотентен по имени (dark == dark)
    ctx.style.visuals.panel_fill = pal["window"]
    ctx.style.visuals.text_color = pal["text"]
    sheet = ctx.stylesheet
    surfaces = {"center", "nowplaying", "nav-box", "lib-box"}
    surfaces.each do |cls|
      sheet.rule(cls, Egui::StyleVars{
        "background" => pal["surface_bg"], "stroke" => pal["surface_border"]})
    end
    sheet.rule("album-card:hover", Egui::StyleVars{"background" => pal["card_hover"]})
    sheet.rule("top-card", Egui::StyleVars{"background" => pal["card_flat"]})
    sheet.rule("top-card:hover", Egui::StyleVars{"background" => pal["card_hover"]})
    sheet.rule("quick", Egui::StyleVars{"background" => pal["control"]})
    sheet.rule("quick:hover", Egui::StyleVars{"background" => pal["control_hov"]})
    sheet.rule("np-artist-card", Egui::StyleVars{"background" => pal["np_artist"]})
    {"np-queue-card", "about-card"}.each do |cls|
      sheet.rule(cls, Egui::StyleVars{"background" => pal["card2"]})
    end
    {"lib-row", "track-row"}.each do |cls|
      sheet.rule("#{cls}:hover", Egui::StyleVars{"background" => pal["row_hover"]})
    end
  end

  # ── часы плеера (mounted() оракула): позиция идёт, пока играет; конец
  # трека → следующий по режиму repeat ────────────────────────────────

  private def advance_clock(ctx : Egui::Context) : Float64
    now = ctx.input.time
    @last_tick = now if @last_tick == 0.0
    dt = {now - @last_tick, 0.25}.min
    @last_tick = now
    @player.advance(dt, now)
    ctx.request_repaint if @player.playing
    # цвета текущего лука (разметка: color="{c_muted}" и т.п.)
    rt.strings["c_muted"] = MusicTags.hex_str("muted")
    rt.strings["c_eyebrow"] = MusicTags.hex_str("eyebrow")
    rt.strings["c_muted_b3"] = MusicTags.hex_str("muted") + "b3"

    # остров: notice живёт 2.5 с — к моменту истечения нужен кадр
    ctx.request_repaint if @player.notice != "" && @player.notice_until > now
    now
  end

  # ── данные → store (computed у Vue) ────────────────────────────────

  private def accent_hex : String
    if @player.follow_cover
      acc = MusicLibrary.make_accent(@player.album.c1)
      # на светлом окне акцент обложки темнее (main.c: rgb *= 0.62)
      MusicTags.look.dark? ? acc : MusicLibrary.scale_hex(acc, 0.62)
    else
      @player.picked
    end
  end

  private def sync(ctx : Egui::Context, now : Float64) : Nil
    p = @player
    library = @library
    rt = @rt

    # страницы/навигация
    page = p.page.to_s
    %w(home search settings library collection).each do |pg|
      rt.bools["page_#{pg}"] = (pg == page)
      rt.bools["nav_#{pg}"] = (pg == page)
    end
    rt.bools["nav_library"] = {"library", "collection"}.includes?(page)
    rt.bools["chip_s_all"] = p.lib_filter == 0
    rt.bools["chip_s_playlists"] = p.lib_filter == 1
    rt.bools["chip_s_albums"] = p.lib_filter == 2

    # акцент/фон из обложки
    accent = accent_hex
    rt.strings["accent"] = accent
    album = p.album
    dark = MusicTags.look.dark?
    rt.strings["m1"] = MusicLibrary.scale_hex(album.c1, dark ? 0.55 : 1.0)
    rt.strings["m2"] = MusicLibrary.scale_hex(album.c2, dark ? 0.35 : 0.9)
    rt.strings["m3"] = MusicLibrary.scale_hex(album.c1, dark ? 0.35 : 0.9)
    rt.floats["mesh_op"] = dark ? 1.0 : 0.5 # opacity backdrop 0.9/0.45
    rt.bools["mesh_on"] = p.effect != 5 # None
    rt.bools["animate_bg"] = p.animate
    rt.floats["effect"] = p.effect.to_f64
    rt.strings["np_rb"] = MusicLibrary.scale_hex(album.c1, 0.7)

    # плеер
    obj = p.track_obj
    rt.strings["np_c1"] = album.c1
    rt.strings["np_c2"] = album.c2
    rt.strings["np_txt"] = album.ini
    rt.strings["np_title"] = obj ? obj.title : ""
    rt.strings["np_artist"] = album.artist
    rt.strings["context_str"] = p.context
    rt.strings["play_icon"] = p.playing ? "pause" : "play"
    rt.strings["elapsed"] = MusicLibrary.fmt_time(p.position)
    rt.strings["length"] = obj ? MusicLibrary.fmt_time(obj.seconds.to_f64) : "0:00"
    rt.floats["seek_frac"] = p.seek_frac
    rt.bools["paused"] = !p.playing
    rt.bools["liked_current"] = obj ? obj.liked : false
    rt.strings["heart_icon"] = obj.try(&.liked) ? "heart-f" : "heart"
    icon_c = MusicTags.hex_str("icon")
    rt.strings["heart_col"] = obj.try(&.liked) ? accent : icon_c
    rt.strings["shuffle_col"] = p.shuffle ? accent : icon_c
    rt.strings["repeat_icon"] = p.repeat_mode == 2 ? "repeat1" : "repeat"
    rt.strings["repeat_col"] = p.repeat_mode != 0 ? accent : icon_c
    rt.strings["vol_icon"] = (p.muted || p.volume <= 0.001) ? "muted" : "volume"
    rt.floats["volume_frac"] = p.muted ? 0.0 : p.volume
    rt.strings["island_text"] = p.island_text(now)
    rt.bools["np_visible"] = p.panel
    # ширина центра — computed (Vue .center{flex:1} без flex-движка):
    # окно − паддинги mainarea (2×8) − sidebar 300 − зазор 8 − np-панель
    # (320 + зазор 8, когда видна); центр всегда занимает остаток строки
    rt.floats["center_w"] = ctx.input.screen_rect.width - 2 * 8 - 300 - 8 -
                            (p.panel ? 320 + 8 : 0)

    # очередь в now playing (до 4 строк, прыжок по клику)
    queue = p.queue[p.queue_pos + 1..].first(4)
    rt.rows["queue"] = queue.map { |ti|
      a = library.albums[library.tracks[ti].album]
      {"c1" => a.c1, "c2" => a.c2, "txt" => a.ini,
       "t" => library.tracks[ti].title, "s" => a.artist}
    }
    rt.bools["queue_empty"] = queue.empty?

    # сайдбар: фильтры как fill_sidebar()
    rows = [] of Hash(String, String)
    if p.lib_filter != 2
      library.playlists.each_with_index do |pl, pi|
        n = pi == 0 ? library.liked_tracks.size : pl.track_list.size
        if pi == 0
          rows << {"c1" => "#B79CFF", "c2" => "#6D28D9", "txt" => "♥",
                   "round" => "1", "t" => pl.title, "s" => "Playlist · #{n} songs",
                   "kind" => "pl", "idx" => pi.to_s}
        else
          a = library.albums[pl.cover]
          rows << {"c1" => a.c1, "c2" => a.c2, "txt" => a.ini, "round" => "1",
                   "t" => pl.title, "s" => "Playlist · #{n} songs",
                   "kind" => "pl", "idx" => pi.to_s}
        end
      end
    end
    if p.lib_filter != 1
      library.albums.each_with_index do |a, ai|
        rows << {"c1" => a.c1, "c2" => a.c2, "txt" => a.ini, "round" => "",
                 "t" => a.title, "s" => "Album · #{a.artist}",
                 "kind" => "al", "idx" => ai.to_s}
      end
    end
    rt.rows["lib_rows"] = rows

    # home: подборки — индексы альбомов, как quickPicks у оригинала
    cur_album = obj ? obj.album : -1
    quick = ->(ai : Int32) do
      a = library.albums[ai]
      {"c1" => a.c1, "c2" => a.c2, "txt" => a.ini, "t" => a.title,
       "ai" => ai.to_s, "vis" => ai == cur_album ? "1" : ""}
    end
    rt.rows["quick_a"] = [3, 1, 2].map { |ai| quick.call(ai) }
    rt.rows["quick_b"] = [0, 4, 5].map { |ai| quick.call(ai) }
    rt.rows["made_cards"] = (1..5).map { |pi|
      pl = library.playlists[pi]
      a = library.albums[pl.cover]
      {"c1" => a.c1, "c2" => a.c2, "txt" => a.ini, "round" => "1",
       "t" => pl.title, "s" => pl.description, "pi" => pi.to_s}
    }
    album_card = ->(ai : Int32, round : String) do
      a = library.albums[ai]
      {"c1" => a.c1, "c2" => a.c2, "txt" => a.ini, "round" => round,
       "t" => a.title, "s" => "#{a.year} · #{a.artist}", "ai" => ai.to_s}
    end
    rt.rows["recent_cards"] = [6, 7, 8, 9, 10].map { |ai| album_card.call(ai, "") }
    rt.rows["artist_cards"] = [6, 5, 2, 9, 3].map { |ai|
      a = library.albums[ai]
      {"c1" => a.c1, "c2" => a.c2, "txt" => a.ini, "round" => "1",
       "t" => a.artist, "s" => "Artist", "ai" => ai.to_s}
    }
    # newReleases: сортировка по году, как fill_home()
    releases = (0...library.albums.size).to_a.sort_by { |ai| {-library.albums[ai].year, ai} }
    rt.rows["release_cards"] = releases.map { |ai| album_card.call(ai, "") }

    # поиск: run_search() из main.c
    q = p.query.strip.downcase
    rt.strings["query"] = p.query
    rt.bools["searching"] = !q.empty?
    if q.empty?
      rt.bools["no_results"] = false
      rt.rows["search_songs"] = [] of Hash(String, String)
      rt.rows["search_albums"] = [] of Hash(String, String)
    else
      s_albums = (0...library.albums.size).select { |ai|
        a = library.albums[ai]
        a.title.downcase.includes?(q) || a.artist.downcase.includes?(q) ||
          a.genre.downcase.includes?(q)
      }
      songs = [] of Int32
      (0...library.tracks.size).each do |ti|
        break if songs.size >= 5
        t = library.tracks[ti]
        songs << ti if t.title.downcase.includes?(q) ||
                       library.albums[t.album].artist.downcase.includes?(q)
      end
      top = s_albums.first? || (songs.first? ? library.tracks[songs.first].album : nil)
      rt.bools["no_results"] = top.nil?
      if (tai = top)
        a = library.albums[tai]
        rt.strings["top_c1"] = a.c1
        rt.strings["top_c2"] = a.c2
        rt.strings["top_txt"] = a.ini
        rt.strings["top_t"] = a.title
        rt.strings["top_s"] = a.artist
      end
      rt.rows["search_songs"] = songs.map_with_index { |ti, i| song_row(ti, i, accent, always_album: true) }
      rt.rows["search_albums"] = s_albums.map { |ai| album_card.call(ai, "") }
    end

    # library
    saved = p.album_likes.count(&.itself)
    rt.strings["lib_summary"] = "#{library.playlists.size} playlists, " \
      "#{library.albums.size} albums (#{saved} saved), " \
      "#{library.liked_tracks.size} liked songs."
    rt.rows["playlists"] = library.playlists.map_with_index { |pl, pi|
      if pi == 0
        {"c1" => "#B79CFF", "c2" => "#6D28D9", "txt" => "♥", "round" => "1",
         "t" => pl.title, "s" => "#{library.liked_tracks.size} songs",
         "pi" => pi.to_s}
      else
        a = library.albums[pl.cover]
        {"c1" => a.c1, "c2" => a.c2, "txt" => a.ini, "round" => "1",
         "t" => pl.title, "s" => "#{pl.track_list.size} songs",
         "pi" => pi.to_s}
      end
    }
    # альбомы по 3 на ряд (перенос строк CSS → пять crow-рядов разметки)
    5.times do |ri|
      rt.rows["albums_r#{ri}"] = ((ri * 3)...library.albums.size)
        .select { |ai| ai // 3 == ri }.map { |ai| album_card.call(ai, "") }
    end

    # коллекция
    ca = p.col_album
    rt.strings["col_h1"] = MusicLibrary.scale_hex(ca.c1, 0.55)
    rt.strings["col_h2"] = MusicLibrary.scale_hex(ca.c2, 0.22)
    rt.strings["col_c1"] = ca.c1
    rt.strings["col_c2"] = ca.c2
    rt.strings["col_txt"] = ca.ini
    is_pl = p.col_kind == :playlist
    rt.bools["col_is_playlist"] = is_pl
    rt.strings["col_kind_label"] = is_pl ? "PLAYLIST" : "ALBUM"
    rt.strings["col_title"] = is_pl ? library.playlists[p.col_index].title : library.albums[p.col_index].title
    rt.strings["col_desc"] = is_pl ? library.playlists[p.col_index].description : ""
    rt.strings["col_artist"] = is_pl ? "Raven Music" : library.albums[p.col_index].artist
    rt.strings["col_meta"] = p.col_meta
    rt.strings["col_play_icon"] = p.col_playing_same_list? && p.playing ? "pause" : "play"
    rt.strings["col_heart_icon"] = p.col_is_liked ? "heart-f" : "heart"
    rt.strings["col_heart_col"] = p.col_is_liked ? accent : MusicTags.hex_str("icon")
    rt.strings["album_head"] = is_pl ? "Album" : ""
    rt.rows["tracks"] = p.col_tracks.map_with_index { |ti, i|
      song_row(ti, i, accent, always_album: is_pl)
    }

    # настройки
    rt.bools["sw_accent_follow"] = p.follow_cover
    rt.bools["sw_animate"] = p.animate
    rt.bools["sw_np_setting"] = p.panel
    rt.bools["sw_normalize"] = p.normalize
    rt.strings["combo_look"] = MusicLibrary::LOOKS[p.look]? || MusicLibrary::LOOKS[0]
    rt.strings["look_name"] = rt.string("combo_look")
    rt.strings["combo_bg"] = MusicLibrary::EFFECTS[p.effect]? || MusicLibrary::EFFECTS[0]
    rt.strings["combo_quality"] = ["Low", "Normal", "High", "Very high"][p.quality]? || "High"
    # опции комбо — как <option v-for> у оракула (looks/effects/quality)
    rt.rows["combo_look_opts"] = MusicLibrary::LOOKS.map { |l| {"t" => l} }
    rt.rows["combo_bg_opts"] = MusicLibrary::EFFECTS.map { |l| {"t" => l} }
    rt.rows["combo_quality_opts"] = %w[Low Normal High Very high].map { |l| {"t" => l} }
    rt.floats["crossfade_frac"] = p.crossfade / 12.0
    rt.strings["crossfade_text"] = "#{p.crossfade} s"

    # greeting по часам (computed оракула)
    h = Time.local.hour
    rt.strings["greeting"] = h < 5 ? "Good night" : h < 12 ? "Good morning" :
                             h < 18 ? "Good afternoon" : "Good evening"

    # жанры Browse all
    rt.rows["genres"] = library.genres.map { |g|
      {"g" => g.color, "t" => g.name, "c1" => g.c1, "c2" => g.c2, "txt" => g.ini}
    }
  end

  # строка песни (search songs / треки коллекции): колонка Album —
  # только у плейлиста (fill_collection_rows)
  private def song_row(ti : Int32, i : Int32, accent : String, *,
                       always_album : Bool) : Hash(String, String)
    t = @library.tracks[ti]
    a = @library.albums[t.album]
    playing = ti == @player.track
    {"n" => (i + 1).to_s,
     "tc" => playing ? accent : MusicTags.hex_str("text"),
     "c1" => a.c1, "c2" => a.c2, "txt" => a.ini,
     "tt" => t.title, "ta" => a.artist,
     "al" => always_album ? a.title : "",
     "hicon" => t.liked ? "heart-f" : "heart",
     "hcol" => t.liked ? accent : MusicTags.hex_str("icon") + "8c",
     "time" => MusicLibrary.fmt_time(t.seconds.to_f64)}
  end

  # ── действия разметки (methods у Vue) ──────────────────────────────

  private def register_actions(ctx : Egui::Context) : Nil
    a = @rt.actions
    p = @player
    now = -> { ctx.input.time }
    repaint = -> { ctx.request_repaint }

    nav = ->(pg : Symbol) { p.nav_to(pg); ctx.request_repaint }
    a["go_home"] = -> { nav.call(:home) }
    a["go_search"] = -> { nav.call(:search) }
    a["go_settings"] = -> { nav.call(:settings) }
    a["go_library"] = -> { nav.call(:library) }
    a["nav_back"] = -> { p.back; ctx.request_repaint }
    a["not_in_demo"] = -> { p.notify("Not in this demo", now.call); ctx.request_repaint }

    3.times { |i| a["chip_side_#{i}"] = -> { p.lib_filter = i; ctx.request_repaint } }
    a["chip_home"] = -> { p.notify("Only music here", now.call); ctx.request_repaint }

    # строки-карточки несут ai/pi (индекс альбома/плейлиста); repeat кладёт
    # _i — действие знает свой список и берёт строку по индексу
    card_open = ->(list : String) {
      i = @rt.string("_i").to_i? || 0
      if (row = @rt.rows[list][i]?)
        if (ai = row["ai"]?)
          p.open_album(ai.to_i, now.call)
        elsif (pi = row["pi"]?)
          p.open_playlist(pi.to_i)
        end
        ctx.request_repaint
      end
    }
    a["open_quick_a"] = -> { card_open.call("quick_a") }
    a["open_quick_b"] = -> { card_open.call("quick_b") }
    a["open_made"] = -> { card_open.call("made_cards") }
    a["open_recent"] = -> { card_open.call("recent_cards") }
    a["open_artist"] = -> { card_open.call("artist_cards") }
    a["open_release"] = -> { card_open.call("release_cards") }
    a["open_lib_playlist"] = -> { card_open.call("playlists") }
    a["open_search_album"] = -> { card_open.call("search_albums") }
    5.times { |ri| a["open_lib_album_r#{ri}"] = -> { card_open.call("albums_r#{ri}") } }

    # строка сайдбара: kind/idx в строке (repeat кладёт _i)
    a["open_side_row"] = -> {
      i = @rt.string("_i").to_i? || 0
      if (row = @rt.rows["lib_rows"][i]?)
        if row["kind"]? == "pl"
          p.open_playlist(row["idx"].to_i)
        else
          p.open_album(row["idx"].to_i, now.call)
        end
        ctx.request_repaint
      end
    }
    a["top_open"] = -> {
      # top-карта вне repeat (_i не её) — ищем первый совпавший альбом
      q = @player.query.strip.downcase
      top = (0...@library.albums.size).find { |ai|
        al = @library.albums[ai]
        al.title.downcase.includes?(q) || al.artist.downcase.includes?(q) ||
          al.genre.downcase.includes?(q)
      } || (@player.query.strip.empty? ? nil : begin
        songs = track_index_of_search?(0)
        songs ? @library.tracks[songs].album : nil
      end)
      if top
        p.open_album(top, now.call)
        ctx.request_repaint
      end
    }

    # поиск: живой фильтр по каждому нажатию (searchinput → search_changed)
    a["search_changed"] = -> {
      @player.query = @rt.string("query")
      @player.nav_to(:search) if @player.page != :search && !@player.query.strip.empty?
      ctx.request_repaint
    }
    a["search_genre"] = -> {
      @player.query = @rt.string("_gt")
      @player.nav_to(:search)
      ctx.request_repaint
    }
    a["play_song"] = -> {
      i = @rt.string("_i").to_i? || 0
      if (ti = track_index_of_search?(i))
        p.play_track_row(ti)
        ctx.request_repaint
      end
    }
    a["like_song"] = -> {
      i = @rt.string("_i").to_i? || 0
      if (ti = track_index_of_search?(i))
        p.like_track(ti, now.call)
        ctx.request_repaint
      end
    }

    # плеер
    a["toggle_play"] = -> { p.toggle(now.call); ctx.request_repaint }
    a["next_track"] = -> { p.next_track; ctx.request_repaint }
    a["prev_track"] = -> { p.prev_track; ctx.request_repaint }
    a["like_current"] = -> { p.like_current(now.call); ctx.request_repaint }
    a["toggle_np"] = -> { p.panel = !p.panel; ctx.request_repaint }
    a["shuffle"] = -> { p.toggle_shuffle(now.call); ctx.request_repaint }
    a["cycle_repeat"] = -> { p.cycle_repeat(now.call); ctx.request_repaint }
    a["seek"] = -> { p.seek(@rt.float("seek_frac")); ctx.request_repaint }
    a["set_volume"] = -> { p.set_volume(@rt.float("volume_frac"), now.call); ctx.request_repaint }
    a["toggle_mute"] = -> { p.toggle_mute(now.call); ctx.request_repaint }
    a["jump_queue"] = -> {
      i = @rt.string("_i").to_i? || 0
      p.jump_queue(i)
      ctx.request_repaint
    }

    # коллекция
    a["col_play"] = -> { p.col_play(now.call); ctx.request_repaint }
    a["col_shuffle"] = -> { p.col_shuffle(now.call); ctx.request_repaint }
    a["like_collection"] = -> { p.like_collection(now.call); ctx.request_repaint }
    a["play_track"] = -> {
      i = @rt.string("_i").to_i? || 0
      if (ti = p.col_tracks[i]?)
        p.play_track_row(ti)
        ctx.request_repaint
      end
    }
    a["like_track"] = -> {
      i = @rt.string("_i").to_i? || 0
      if (ti = p.col_tracks[i]?)
        p.like_track(ti, now.call)
        ctx.request_repaint
      end
    }

    # настройки
    a["sw_accent"] = -> { p.follow_cover = !p.follow_cover; ctx.request_repaint }
    a["sw_animate"] = -> { p.animate = !p.animate; ctx.request_repaint }
    a["sw_normalize"] = -> { p.normalize = !p.normalize; ctx.request_repaint }
    a["look_change"] = -> {
      p.look = MusicLibrary::LOOKS.index(@rt.string("combo_look")) || 0
      apply_look(ctx)
      ctx.request_repaint
    }
    a["effect_change"] = -> {
      p.effect = MusicLibrary::EFFECTS.index(@rt.string("combo_bg")) || 0
      ctx.request_repaint
    }
    a["quality_change"] = -> {
      p.quality = ["Low", "Normal", "High", "Very high"].index(@rt.string("combo_quality")) || 2
      ctx.request_repaint
    }
    a["crossfade_change"] = -> {
      p.crossfade = (@rt.float("crossfade_frac") * 12).round.to_i
      ctx.request_repaint
    }

    # служебные ключи тегов (ocombo/_focus)
    @rt.strings["_combo"] = ""
    @rt.strings["_focus"] = ""
    @rt.strings["query"] = ""
  end

  # индекс трека в библиотеке по позиции строки поиска (searching → songs)
  private def track_index_of_search?(i : Int32) : Int32?
    q = @player.query.strip.downcase
    songs = [] of Int32
    (0...@library.tracks.size).each do |ti|
      break if songs.size > i
      t = @library.tracks[ti]
      songs << ti if t.title.downcase.includes?(q) ||
                     @library.albums[t.album].artist.downcase.includes?(q)
    end
    songs[i]?
  end

  private def track_index_of_search(i : Int32) : Int32
    track_index_of_search?(i) || 0
  end

  # ── клавиши (onKey оракула): Space, Ctrl+←/→, Ctrl+L/F/P, Alt+← ────

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
    if ENV["MUSIC_KEYDBG"]? && (fired = ctx.fired_actions).size > 0
      fired.each { |f| STDERR.puts "keydbg fired #{f}" }
    end
    # как onKey у Vue: горячие клавиши не срабатывают при печати в поле
    typing = !@rt.string("_focus").empty?
    p = @player
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
      @rt.strings["_focus"] = "query" # фокус в поле поиска (focusSearch)
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
end
