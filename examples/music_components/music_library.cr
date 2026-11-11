# music_library.cr — данные и утилиты демо «Raven Music», порт 1:1
# oracle/oracle_live/app.js (Vue-оракул, поведение из C-приложения Raven:
# tmp/Raven/examples/music/library.c). Детерминированная генерация треков
# тем же LCG, что в оригинале: одинаковые сиды → одинаковые имена/длины/
# лайки, спека фиксирует контрольные точки.
#
# Цвета — hex-строки (как в app.js): store экзмл-рендера интерполирует
# строки, теги красят через MusicTags.hex.
require "../../src/egui"

module MusicLibrary
  # ── утилиты (app.js: utils) ─────────────────────────────────────────

  def self.clamp(v : Float64, a : Float64, b : Float64) : Float64
    v < a ? a : v > b ? b : v
  end

  # library.c: тот же LCG (rand не нужен — детерминированно на альбом).
  # JS: s = (Math.imul(s, 1664525) + 1013904223) >>> 0; return s >>> 8.
  def self.lcg(seed : UInt32) : Proc(UInt32)
    s = seed
    -> : UInt32 do
      s = (s &* 1664525u32) &+ 1013904223u32
      s >> 8
    end
  end

  # тёмная тема: цвет * k (background_effect / hero в main.c)
  def self.scale_hex(hex : String, k : Float64) : String
    n = hex[1..].to_u32(16)
    r = (((n >> 16) & 255).to_f64 * k).round.to_u32
    g = (((n >> 8) & 255).to_f64 * k).round.to_u32
    b = ((n & 255).to_f64 * k).round.to_u32
    sprintf("#%02x%02x%02x", r, g, b)
  end

  def self.fmt_time(sec : Float64) : String
    sec = {0.0, sec.floor}.max
    m = (sec / 60).to_i
    s = sec.to_i % 60
    "#{m}:#{s < 10 ? "0" : ""}#{s}"
  end

  # library.c: make_accent — цвет, который читается как акцент на тёмном
  # окне (насыщенность 0.45..0.85, яркость 0.78..0.98).
  def self.make_accent(hex : String) : String
    n = hex[1..].to_u32(16)
    r = ((n >> 16) & 255).to_f64 / 255.0
    g = ((n >> 8) & 255).to_f64 / 255.0
    b = (n & 255).to_f64 / 255.0
    max = {r, g, b}.max
    min = {r, g, b}.min
    d = max - min
    h = 0.0
    s = max > 0 ? d / max : 0.0
    v = max
    if d > 0
      if max == r
        h = ((g - b) / d + 6) % 6 / 6
      elsif max == g
        h = ((b - r) / d + 2) / 6
      else
        h = ((r - g) / d + 4) / 6
      end
    end
    s = clamp(s, 0.45, 0.85)
    v = clamp(v, 0.78, 0.98)
    out = {5, 3, 1}.map do |k|
      x = (k.to_f64 + h * 6) % 6
      # JS: v - v*s*max(0, min(min(x, 4-x), 1))
      v - v * s * {0.0, { {x, 4 - x}.min, 1.0 }.min}.max
    end
    sprintf("#%02x%02x%02x",
      (out[0] * 255).round.to_u32, (out[1] * 255).round.to_u32,
      (out[2] * 255).round.to_u32)
  end

  # tags.c: fake_level визуализатора — бит каждые полсекунды
  def self.fake_level(bar : Int32, bars : Int32, time : Float64) : Float64
    x = bar.to_f64 / (bars > 1 ? (bars - 1).to_f64 : 1.0)
    beat = (0.5 + 0.5 * Math.cos((time % 0.5) * 12.566)) ** 6
    bass = (1 - x) * (0.55 + 0.45 * beat)
    body = 0.5 + 0.25 * Math.sin(time * (3.1 + bar * 0.37) + bar * 1.7) +
           0.2 * Math.sin(time * (7.3 + bar * 0.11) + bar)
    clamp(0.15 + bass * 0.6 + body * (0.35 + x * 0.25) * (1 - x * 0.35),
      0.05, 1.0)
  end

  # ── данные (app.js: data) ───────────────────────────────────────────

  class Album
    getter ini : String
    getter c1 : String
    getter c2 : String
    getter title : String
    getter artist : String
    getter year : Int32
    getter genre : String
    # индексы в Library#tracks
    property tracks : Array(Int32) = [] of Int32

    def initialize(@ini, @c1, @c2, @title, @artist, @year, @genre)
    end
  end

  class Track
    getter album : Int32
    getter title : String
    getter seconds : Int32
    property liked : Bool
    property plays : Int32 = 0

    def initialize(@album, @title, @seconds, @liked)
    end
  end

  class Playlist
    getter title : String
    getter cover : Int32 # индекс альбома; -1 — живой «Liked songs»
    getter description : String
    property track_list : Array(Int32) = [] of Int32

    def initialize(@title, @cover, @description)
    end
  end

  struct Genre
    getter name : String
    getter color : String
    getter ini : String
    getter c1 : String
    getter c2 : String

    def initialize(@name, @color, @ini, @c1, @c2)
    end
  end

  # библиотека.c: пулы имён треков (взгляды оригинала)
  POOL_ADJ   = %w[Endless Burning Quiet Electric Velvet Silver Restless
                  Golden Paper Wild Static Crimson Glass Distant Midnight
                  Faded Lonely Northern]
  POOL_NOUN  = %w[Gardens Waves Streets Summers Machines Lights Ghosts
                  Rivers Cathedrals Embers Highways Horizons Lanterns
                  Mirrors Comets Tides Valleys Arcades]
  POOL_PLACE = ["Berlin", "Seoul", "July", "Winter", "the Desert",
                "the Coast", "Paris", "Dawn", "Midnight", "the Valley",
                "Nowhere", "June"]
  POOL_VERB  = %w[Leave Hold Carry Follow Break Keep Lose Find]
  POOL_ADV   = %w[Tonight Alone Forever Slowly Again Together Home Away]

  ALBUMS = [
    {"DH", "#E92236", "#571DC6", "Tides", "The Distant Horizon", 2026, "Rock"},
    {"CM", "#237FEC", "#C3C61D", "Restless Satellites", "The Copper Motel", 2024, "Electronic"},
    {"NK", "#98C61D", "#C61D9F", "Mirrors", "Noor Kane", 1998, "Pop"},
    {"RQ", "#5EA6C6", "#C6714A", "The Paper Lanterns", "Remy Quinn", 2024, "Folk"},
    {"ES", "#3AC69E", "#61C626", "Faded Summer", "The Endless Strangers", 1989, "Chill"},
    {"SK", "#DC2091", "#1DC661", "Electric Highways", "Sasha Kane", 2022, "Soul"},
    {"OL", "#C66F1D", "#1D24C6", "The Blue Comets", "Otis Lindqvist", 2010, "Jazz"},
    {"SC", "#DC2091", "#1D8AC6", "Cathedral in Berlin", "The Static Comets", 2013, "Rock"},
    {"EW", "#E82266", "#2E1DC6", "Endless Gardens", "The Electric Wolves", 2012, "Indie"},
    {"KD", "#5EA6C6", "#4AC667", "The Stray Embers", "Kai Delacroix", 2026, "Chill"},
    {"HH", "#E82266", "#1DC68C", "Heartbeat in July", "The Hollow Harbor", 2022, "R&B"},
    {"AK", "#3B63C6", "#27C68C", "Glass Gardens", "Ava Kane", 2026, "Indie"},
    {"GH", "#237FEC", "#71C61D", "Heartbeat in Seoul", "The Golden Horizon", 2024, "Pop"},
    {"KA", "#E82266", "#1D5EC6", "Crimson Ghosts", "Kai Ash", 2025, "Hip-Hop"},
  ]

  # Tides: 11 треков оригинала (коллекция статического оракула)
  TIDES = [
    {"Glass Waves", 300, false}, {"Midnight Horizon", 302, false},
    {"Static Cathedral", 254, true}, {"Leave Me Tonight", 192, false},
    {"Burning Weather", 191, false}, {"The Arcade", 172, false},
    {"the Desert, Forever", 193, true}, {"Daydreams", 258, false},
    {"The Machines", 323, false}, {"the Valley, Home", 221, false},
    {"Seoul, Tonight", 203, false},
  ]

  PLAYLISTS = [
    {"Liked songs", -1, "Every song you keep close."},
    {"Late night drive", 8, "Long roads, city lights and the windows down."},
    {"Focus flow", 2, "Soft, steady, out of the way."},
    {"Sunday morning", 5, "Slow starts and a second coffee."},
    {"Heavy rotation", 5, "What the week played the most."},
    {"Fresh finds", 1, "New songs, straight from the wire."},
  ]

  # жанровые плитки Search: цвет — g_genre_colors из library.c
  GENRES = [
    {"Pop", "#E8115B", "DH", "#E92236", "#571DC6"},
    {"Hip-Hop", "#BA5D07", "CM", "#237FEC", "#C3C61D"},
    {"Rock", "#E91429", "CW", "#3AC69E", "#C64526"},
    {"Indie", "#608108", "ES", "#3AC69E", "#61C626"},
    {"R&B", "#8D67AB", "RQ", "#98C61D", "#9D1DC6"},
    {"Electronic", "#0D73EC", "CM", "#237FEC", "#C3C61D"},
    {"Soul", "#DC148C", "SK", "#DC2091", "#1DC661"},
    {"Folk", "#477D95", "OL", "#C66F1D", "#1D24C6"},
    {"Jazz", "#1E3264", "BH", "#5EA6C6", "#4AC667"},
    {"Chill", "#27856A", "KD", "#5EA6C6", "#4AC667"},
  ]

  LOOKS   = %w[Nocturne Aurora Daylight Windows\ Light Windows\ Dark
               macOS\ Light macOS\ Dark GNOME\ Light GNOME\ Dark KDE\ Light
               KDE\ Dark Glass High\ Contrast Print Sepia Midnight]
  EFFECTS = %w[Mesh Aurora Plasma Spotlight Shimmer None]

  class Library
    getter albums : Array(Album) = [] of Album
    getter tracks : Array(Track) = [] of Track
    getter playlists : Array(Playlist) = [] of Playlist
    getter genres : Array(Genre) = [] of Genre

    def initialize
      ALBUMS.each_with_index do |(ini, c1, c2, title, artist, year, genre), a|
        album = Album.new(ini, c1, c2, title, artist, year, genre)
        if a == 0
          TIDES.each do |t_title, sec, liked|
            album.tracks << @tracks.size
            @tracks << Track.new(a, t_title, sec, liked)
          end
        else
          rnd = MusicLibrary.lcg((20261101u32 + a.to_u32 * 7919u32))
          pick = ->(n : Int32) { rnd.call % n }
          count = 6 + pick.call(7)
          count.times do
            mode = pick.call(6)
            title = case mode
                    when 0 then "#{POOL_ADJ[pick.call(18)]} #{POOL_NOUN[pick.call(18)]}"
                    when 1 then "#{POOL_NOUN[pick.call(18)]} of #{POOL_PLACE[pick.call(12)]}"
                    when 2 then "#{POOL_VERB[pick.call(8)]} Me #{POOL_PLACE[pick.call(12)]}"
                    when 3 then "#{POOL_VERB[pick.call(8)]} Me #{POOL_ADV[pick.call(8)]}"
                    when 4 then "#{POOL_PLACE[pick.call(12)]}, #{POOL_ADV[pick.call(8)]}"
                    else        "#{POOL_ADJ[pick.call(18)]} #{POOL_PLACE[pick.call(12)]}"
                    end
            album.tracks << @tracks.size
            @tracks << Track.new(a, title, 128 + pick.call(200),
              pick.call(6) == 0)
          end
        end
        @albums << album
      end

      PLAYLISTS.each do |title, cover, desc|
        @playlists << Playlist.new(title, cover, desc)
      end
      GENRES.each do |name, color, ini, c1, c2|
        @genres << Genre.new(name, color, ini, c1, c2)
      end
      (0...@playlists.size).each { |p| @playlists[p].track_list = fill_playlist(p) }
    end

    def liked_tracks : Array(Int32)
      (0...@tracks.size).select { |i| @tracks[i].liked }
    end

    # треки плейлистов (детерминированно; 0-й — Liked songs, живой)
    def fill_playlist(p : Int32) : Array(Int32)
      return liked_tracks if p == 0
      rnd = MusicLibrary.lcg(20261101u32 + p.to_u32 * 977u32)
      count = 14 + p * 3
      Array(Int32).new(count) { (rnd.call % @tracks.size).to_i32 }
    end
  end
end
