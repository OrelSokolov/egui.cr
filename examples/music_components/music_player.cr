# music_player.cr — живое состояние демо «Raven Music», порт 1:1
# oracle/oracle_live/app.js (root component: data + methods). Плеер с
# очередью по всей библиотеке, лайки, notices, навигация и настройки —
# без UI, тестируется спекой (spec/music_player_spec.cr). Приложение
# (music_exml.cr) синхронизирует это состояние в store экзмл-рендера.
require "./music_library"

class MusicPlayer
  getter library : MusicLibrary::Library

  # ── плеер (data: track/position/playing/…) ──────────────────────────
  property track : Int32                 # индекс в library.tracks; -1 — пусто
  property position : Float64 = 84.0
  property playing : Bool = true
  property shuffle : Bool = false
  property repeat_mode : Int32 = 0 # off/all/one
  property volume : Float64 = 0.7
  property muted : Bool = false
  property queue : Array(Int32)
  property queue_pos : Int32 = 0
  property context : String = "Tides"

  # ── настройки (значения по умолчанию — из main() оригинала) ─────────
  property follow_cover : Bool = true
  property picked : String = "#B79CFF"
  property effect : Int32 = 0 # Mesh
  property animate : Bool = true
  property panel : Bool = true
  property crossfade : Int32 = 5
  property look : Int32 = 0
  property normalize : Bool = true
  property quality : Int32 = 2
  property album_likes : Array(Bool)

  # ── навигация ────────────────────────────────────────────────────────
  property page : Symbol = :home
  property history : Array(Symbol) = [] of Symbol
  property col_kind : Symbol = :album # :album | :playlist
  property col_index : Int32 = 0
  property lib_filter : Int32 = 0 # 0 all / 1 playlists / 2 albums
  property query : String = ""

  # ── notices (island): подмена заголовка на 2.5 с ────────────────────
  property notice : String = ""
  property notice_until : Float64 = 0.0

  def initialize(@library = MusicLibrary::Library.new)
    @track = @library.albums[0].tracks[0]
    @queue = @library.albums[0].tracks.dup
    @album_likes = Array(Bool).new(@library.albums.size) { |i| i == 2 || i == 5 }
  end

  def track_obj : MusicLibrary::Track?
    @library.tracks[@track]? unless @track < 0
  end

  def album : MusicLibrary::Album
    obj = track_obj
    obj ? @library.albums[obj.album] : @library.albums[0]
  end

  def notify(text : String, now : Float64) : Nil
    @notice = text
    @notice_until = now + 2.5
  end

  # notice ещё жив (island показывает notice || track title)
  def island_text(now : Float64) : String
    return @notice if now < @notice_until
    @notice = ""
    obj = track_obj
    obj ? obj.title : ""
  end

  # ── часы: позиция идёт, пока играет; конец трека → on_ended ─────────
  def advance(dt : Float64, now : Float64) : Nil
    return unless @playing && @track >= 0
    @position += dt
    if @position >= @library.tracks[@track].seconds.to_f64
      on_ended(now)
    end
  end

  # ── плеер (methods) ─────────────────────────────────────────────────

  # play_list из main.c: start в голову, остальное перемешано (shuffle)
  def play_list(list : Array(Int32), start : Int32, context : String) : Nil
    queue = list.dup
    pos = queue.index(start) || (queue << start; queue.size - 1)
    if @shuffle
      first = queue[pos]
      queue[pos] = queue[0]
      queue[0] = first
      (queue.size - 1).downto(2) do |i|
        j = 1 + Random.new.rand(i)
        queue[i], queue[j] = queue[j], queue[i]
      end
      pos = 0
    end
    @queue = queue
    @context = context
    play_position(pos)
  end

  def play_position(pos : Int32) : Nil
    pos = ((pos % @queue.size) + @queue.size) % @queue.size
    @queue_pos = pos
    @track = @queue[pos]
    @library.tracks[@track].plays += 1
    @position = 0.0
    @playing = true
  end

  def toggle(now : Float64) : Nil
    if @track < 0
      # player.toggle при пустом плеере: играет первый альбом
      open_album(0, now)
      first = @library.albums[0].tracks[0]
      play_list(@library.albums[0].tracks, first, @library.albums[0].title)
      return
    end
    @playing = !@playing
  end

  def next_track : Nil
    play_position(@queue_pos + 1 < @queue.size ? @queue_pos + 1 : 0) unless @queue.empty?
  end

  def prev_track : Nil
    if @position > 3.0 || @queue_pos == 0
      @position = 0.0
      return
    end
    play_position(@queue_pos - 1)
  end

  def on_ended(now : Float64) : Nil
    if @repeat_mode == 2 # repeat one
      @position = 0.0
      return
    end
    if @queue_pos + 1 < @queue.size
      play_position(@queue_pos + 1)
      return
    end
    if @repeat_mode == 1 # repeat all
      play_position(0)
      return
    end
    @playing = false # стоп
    @position = 0.0
  end

  def seek(frac : Float64) : Nil
    obj = track_obj || return
    @position = frac * obj.seconds.to_f64
  end

  def seek_frac : Float64
    obj = track_obj
    obj ? MusicLibrary.clamp(@position / obj.seconds.to_f64, 0.0, 1.0) : 0.0
  end

  def set_volume(frac : Float64, now : Float64) : Nil
    @volume = frac
    @muted = false if frac > 0.001
  end

  def toggle_mute(now : Float64) : Nil
    if @muted || @volume <= 0.001
      @muted = false
      if @volume <= 0.001
        @volume = 0.5
      end
      notify("Unmuted", now)
    else
      @muted = true
      notify("Muted", now)
    end
  end

  def toggle_shuffle(now : Float64) : Nil
    @shuffle = !@shuffle
    notify(@shuffle ? "Shuffle on" : "Shuffle off", now)
  end

  def cycle_repeat(now : Float64) : Nil
    @repeat_mode = (@repeat_mode + 1) % 3
    notify({"Repeat off", "Repeat all", "Repeat this song"}[@repeat_mode], now)
  end

  # ── лайки ────────────────────────────────────────────────────────────

  def like_track(i : Int32, now : Float64) : Nil
    t = @library.tracks[i]
    t.liked = !t.liked
    # открытая коллекция «Liked songs» — живой список
    if @col_kind == :playlist && @col_index == 0
      @library.playlists[0].track_list = @library.liked_tracks
    end
    if i == @track
      notify(t.liked ? "Added to Liked songs" : "Removed from Liked songs", now)
    end
  end

  def like_current(now : Float64) : Nil
    like_track(@track, now) if @track >= 0
  end

  def like_collection(now : Float64) : Nil
    if @col_kind == :playlist
      notify("It is your playlist already", now)
      return
    end
    v = !@album_likes[@col_index]
    @album_likes[@col_index] = v
    notify(v ? "Saved to your library" : "Removed from your library", now)
  end

  # ── коллекция ────────────────────────────────────────────────────────

  def col_album : MusicLibrary::Album
    return @library.albums[@col_index] if @col_kind == :album
    pl = @library.playlists[@col_index]
    @library.albums[pl.cover < 0 ? 0 : pl.cover]
  end

  def col_tracks : Array(Int32)
    return @library.albums[@col_index].tracks if @col_kind == :album
    @library.playlists[@col_index].track_list.dup
  end

  def col_is_liked : Bool
    return false if @col_kind == :playlist
    @album_likes[@col_index]
  end

  # «N songs, M min s» / «N songs, about H h M min» (fill_collection_rows)
  def col_meta : String
    list = col_tracks
    total = list.sum { |i| @library.tracks[i].seconds }
    if @col_kind == :album
      "· #{@library.albums[@col_index].year} · #{list.size} songs, " \
        "#{total // 60} min #{total % 60} s"
    else
      h = total // 3600
      m = ((total % 3600) / 60.0).round.to_i
      "· #{list.size} songs, about " \
        "#{h > 0 ? "#{h} h #{m} min" : "#{m} min"}"
    end
  end

  def col_playing_same_list? : Bool
    ct = col_tracks
    @queue.size == ct.size && @queue.each_with_index.all? { |t, i| t == ct[i] } && !@shuffle
  end

  def col_play(now : Float64) : Nil
    return toggle(now) if col_playing_same_list?
    ctx = col_kind == :album ? @library.albums[@col_index].title : @library.playlists[@col_index].title
    play_list(col_tracks, col_tracks[0], ctx)
  end

  def col_shuffle(now : Float64) : Nil
    list = col_tracks
    i = list.empty? ? 0 : list[Random.new.rand(list.size)]
    ctx = col_kind == :album ? @library.albums[@col_index].title : @library.playlists[@col_index].title
    keep = @shuffle # collection.shuffle: shuffle на этот запуск
    @shuffle = true
    play_list(list, i, ctx)
    @shuffle = keep
    notify("Shuffle on", now)
  end

  # трек из открытой коллекции играет её списком, иначе — своим альбомом
  def play_track_row(i : Int32) : Nil
    if col_tracks.includes?(i)
      ctx = col_kind == :album ? @library.albums[@col_index].title : @library.playlists[@col_index].title
      play_list(col_tracks, i, ctx)
    else
      ai = @library.tracks[i].album
      play_list(@library.albums[ai].tracks, i, @library.albums[ai].title)
    end
  end

  def jump_queue(n : Int32) : Nil
    play_position(@queue_pos + 1 + n)
  end

  # ── навигация (methods: showPage/navTo/back/openAlbum/openPlaylist) ──

  def show_page(p : Symbol, remember : Bool = false) : Nil
    if @page != p
      if remember
        @history << @page
        @history.shift if @history.size > 64
      end
      @page = p
    end
  end

  def nav_to(p : Symbol) : Nil
    show_page(p, true)
  end

  def back : Nil
    @page = @history.pop unless @history.empty?
  end

  def open_album(i : Int32, now : Float64) : Nil
    @col_kind = :album
    @col_index = i
    show_page(:collection, true)
    notify("It is your playlist already", now) if @album_likes[i]
  end

  def open_playlist(p : Int32) : Nil
    @library.playlists[0].track_list = @library.liked_tracks if p == 0
    @col_kind = :playlist
    @col_index = p
    show_page(:collection, true)
  end
end
