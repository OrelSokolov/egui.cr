require "../../src/egui"

# NativeHTML Music — библиотека (порт tmp/Raven/examples/music/library.c,
# Raven Apache-2.0; происхождение указано в отчёте этапа 1 плана
# plans/NATIVE_HTML_DEMO.md). 24 выдуманных альбома, треки и 6 плейлистов
# генерируются тем же LCG (seed 20261101) и теми же списками слов, что и
# в оригинале, — имена совпадают один к одному. У каждого альбома два
# акцентных цвета (color/color2), выведенных из цвета жанра тем же
# HSV-поворотом, каким library.c красит рисуемую обложку, когда .jpg нет;
# в этом порту обложек-файлов нет вообще — все рисует виджет Cover
# (градиент двух цветов + инициалы артиста), шейдерные узоры рисуемой
# обложки оригинала приходят на этапе 3.

module Music
  # ---- сделанные имена (списки слов 1:1 из library.c) ----------------

  ADJECTIVES = {"Velvet", "Neon", "Paper", "Glass", "Midnight", "Golden", "Silent", "Electric", "Hollow", "Crimson",
                "Northern", "Lucid", "Static", "Wild", "Slow", "Distant", "Burning", "Quiet", "Endless", "Broken",
                "Little", "Blue", "Copper", "Stray", "Silver", "Tender", "Restless", "Faded", "Bright", "Lonely"}
  NOUNS      = {"Harbor", "Satellites", "Weather", "Gardens", "Echoes", "Highways", "Motel", "Summer", "Tides", "Signals",
                "Lanterns", "Cathedral", "Rivers", "Daydreams", "Machines", "Orchards", "Avenue", "Fever", "Horizon", "Comets",
                "Heartbeat", "Mirrors", "Wolves", "Arcade", "Paradise", "Skyline", "Strangers", "Waves", "Embers", "Ghosts"}
  PLACES     = {"Tokyo", "the Rain", "Lisbon", "the Dark", "July", "Berlin", "the Valley", "Room 9", "the Desert", "Brooklyn",
                "Marseille", "the Morning", "Seoul", "the Deep End", "Nowhere"}
  VERBS      = {"Call", "Hold", "Wake", "Take", "Find", "Leave", "Save", "Show", "Keep", "Tell"}
  ADVERBS    = {"Slowly", "Again", "Tonight", "Home", "Closer", "Gently", "Back", "Forever"}
  FIRST      = {"Mira", "Jonah", "Elio", "Sasha", "Noor", "Theo", "Lena", "Kai", "Ines", "Felix", "Ava", "Remy", "Yuna", "Otis", "Zadie", "Milo"}
  LAST       = {"Solen", "Hart", "Vale", "Okafor", "Lindqvist", "Moreau", "Kane", "Rivers", "Sato", "Bellamy", "Quinn", "Delacroix", "Ash", "Novak"}

  GENRES       = {"Pop", "Hip-Hop", "Rock", "Indie", "R&B", "Electronic", "Soul", "Folk", "Jazz", "Chill"}
  GENRE_COLORS = {0xE8115B_u32, 0xBA5D07, 0xE91429, 0x608108, 0x8D67AB, 0x0D73EC, 0xDC148C, 0x477D95, 0x1E3264, 0x27856A}

  PLAYLIST_TITLES       = {"Liked songs", "Late night drive", "Focus flow", "Sunday morning", "Heavy rotation", "Fresh finds"}
  PLAYLIST_DESCRIPTIONS = {"The songs you marked with a heart.",
                           "Long roads, city lights and the windows down.",
                           "Quiet songs to keep your head down.",
                           "Slow coffee, open windows, nowhere to be.",
                           "What you have been playing the most lately.",
                           "New songs picked for you, every Friday."}

  # ---- структуры ------------------------------------------------------

  class Album
    property title : String
    property artist : String
    property genre : String
    property year : Int32
    property first_track : Int32 = 0
    property track_count : Int32 = 0
    # цвет, которым альбом «известен»: акцент, пока он играет, и второй —
    # для градиента обложки/фона (в оригинале — две доминанты картинки)
    getter color : Egui::Color32
    getter color2 : Egui::Color32

    def initialize(@title : String, @artist : String, @genre : String,
                   @year : Int32, @color : Egui::Color32, @color2 : Egui::Color32)
    end

    # Инициалы артиста крупным шрифтом на обложке: первые буквы первых
    # двух слов («The Neon Harbor» → «TN»).
    def initials : String
      words = artist.split.reject { |w| w == "The" }
      words.first(2).map(&.[0]).join
    end
  end

  class Track
    property title : String
    getter album : Int32
    property seconds : Int32
    property plays : Int32
    property liked : Bool

    def initialize(@title : String, @album : Int32, @seconds : Int32,
                   @plays : Int32, @liked : Bool)
    end
  end

  class Playlist
    property title : String
    property description : String
    property tracks : Array(Int32)
    # альбом, чью обложку плейлист занимает
    getter cover : Int32

    def initialize(@title : String, @description : String,
                   @tracks : Array(Int32), @cover : Int32)
    end
  end

  # ---- генератор (LCG из library.c, тот же порядок вызовов) ----------

  @@seed : UInt32 = 20261101_u32

  private def self.next_random : UInt32
    @@seed = @@seed &* 1664525_u32 &+ 1013904223_u32
    @@seed >> 8
  end

  private def self.pick(count : Int32) : Int32
    (next_random % count).to_i
  end

  private def self.pick_from(list : Tuple) : String
    list[pick(list.size)]
  end

  # ---- цвета (HSV-алгоритмы library.c) --------------------------------

  def self.rgb_to_hsv(r : Float64, g : Float64, b : Float64) : {Float64, Float64, Float64}
    max = {r, g, b}.max
    min = {r, g, b}.min
    d = max - min
    v = max
    s = max > 0.0 ? d / max : 0.0
    h = if d <= 0.0
          0.0
        elsif max == r
          ((g - b) / d + 6.0) % 6.0 / 6.0
        elsif max == g
          ((b - r) / d + 2.0) / 6.0
        else
          ((r - g) / d + 4.0) / 6.0
        end
    {h, s, v}
  end

  def self.hsv_to_rgb(h : Float64, s : Float64, v : Float64) : {Float64, Float64, Float64}
    k = {5.0, 3.0, 1.0}
    rgb = StaticArray(Float64, 3).new(0.0)
    3.times do |i|
      x = (k[i] + h * 6.0) % 6.0
      clamped = {0.0, {x, 4.0 - x, 1.0}.min}.max
      rgb[i] = v - v * s * clamped
    end
    {rgb[0], rgb[1], rgb[2]}
  end

    # Цвет, который читается как акцент на тёмном окне: достаточно
    # яркий и достаточно светлый (насыщенность/светлота зажаты).
  def self.make_accent(rgb : {Float64, Float64, Float64}) : {Float64, Float64, Float64}
    h, s, v = rgb_to_hsv(*rgb)
    hsv_to_rgb(h, s.clamp(0.45, 0.85), v.clamp(0.78, 0.98))
  end

  def self.to_color32(rgb : {Float64, Float64, Float64}) : Egui::Color32
    r, g, b = rgb
    Egui::Color32.rgb((r.clamp(0.0, 1.0) * 255.0).to_u8,
                (g.clamp(0.0, 1.0) * 255.0).to_u8,
                (b.clamp(0.0, 1.0) * 255.0).to_u8)
  end

  def self.genre_rgb(index : Int32) : {Float64, Float64, Float64}
    c = GENRE_COLORS[index]
    {((c >> 16) & 255).to_f / 255.0, ((c >> 8) & 255).to_f / 255.0, (c & 255).to_f / 255.0}
  end

  # Два цвета обложки без файла (путь load_cover → draw_cover в library.c):
  # база — цвет жанра, второй — её же тон, повёрнутый на 0.08·(i%5)+0.5
  # и притемнённый до v=0.55; оба проходят через make_accent.
  private def self.cover_colors(index : Int32, genre : Int32) : {Egui::Color32, Egui::Color32}
    base = genre_rgb(genre)
    h, s, v = rgb_to_hsv(*base)
    other = hsv_to_rgb((h + 0.08 * (index % 5) + 0.5) % 1.0,
      {s + 0.1, 1.0}.min, 0.55)
    {to_color32(make_accent(base)), to_color32(make_accent(other))}
  end

  # ---- генерация библиотеки -------------------------------------------

  @@albums = [] of Album
  @@tracks = [] of Track
  @@playlists = [] of Playlist
  @@built = false

  def self.build : Nil
    return if @@built
    @@albums.clear
    @@tracks.clear
    MUSIC_ALBUMS.times do |a|
      genre = pick(GENRES.size)
      title = make_album_title
      artist = make_artist
      year = 2026 - pick(40) * (pick(3) == 0 ? 1 : 0) - pick(6)
      color, color2 = cover_colors(a, genre)
      album = Album.new(title, artist, GENRES[genre], year, color, color2)
      album.first_track = @@tracks.size
      track_count = 6 + pick(7)
      track_count.times do
        break if @@tracks.size >= MUSIC_MAX_TRACKS
        @@tracks << Track.new(
          make_track_title,
          a,
          128 + pick(200),
          20000 + pick(4000) * pick(900),
          pick(6) == 0)
      end
      album.track_count = @@tracks.size - album.first_track
      @@albums << album
    end
    MUSIC_PLAYLISTS.times do |p|
      # (плейлист «Liked songs» собирается по требованию — см. .liked_playlist)
      tracks = [] of Int32
      while p > 0 && tracks.size < 14 + p * 3 && tracks.size < 40
        tracks << pick(@@tracks.size)
      end
      @@playlists << Playlist.new(PLAYLIST_TITLES[p],
        PLAYLIST_DESCRIPTIONS[p], tracks, p == 0 ? 15 : (p * 7 + 3) % MUSIC_ALBUMS)
    end
    @@built = true
  end

  def self.make_artist : String
    case pick(4)
    when 0 then "The #{pick_from(ADJECTIVES)} #{pick_from(NOUNS)}"
    when 1 then "#{pick_from(ADJECTIVES)} #{pick_from(NOUNS)}"
    else        "#{pick_from(FIRST)} #{pick_from(LAST)}"
    end
  end

  def self.make_album_title : String
    case pick(5)
    when 0 then pick_from(NOUNS)
    when 1 then "#{pick_from(NOUNS)} in #{pick_from(PLACES)}"
    when 2 then "The #{pick_from(ADJECTIVES)} #{pick_from(NOUNS)}"
    else        "#{pick_from(ADJECTIVES)} #{pick_from(NOUNS)}"
    end
  end

  def self.make_track_title : String
    case pick(7)
    when 0 then "#{pick_from(ADJECTIVES)} #{pick_from(NOUNS)}"
    when 1 then "#{pick_from(NOUNS)} in #{pick_from(PLACES)}"
    when 2 then "#{pick_from(VERBS)} Me #{pick_from(ADVERBS)}"
    when 3 then "The #{pick_from(NOUNS)}"
    when 4 then pick_from(NOUNS)
    when 5 then "#{pick_from(ADJECTIVES)} #{pick_from(NOUNS)} (Interlude)"
    else        "#{pick_from(PLACES)}, #{pick_from(ADVERBS)}"
    end
  end

  MUSIC_ALBUMS     = 24
  MUSIC_MAX_TRACKS = 320
  MUSIC_PLAYLISTS  = 6

  def self.albums : Array(Album)
    build
    @@albums
  end

  def self.tracks : Array(Track)
    build
    @@tracks
  end

  def self.playlists : Array(Playlist)
    build
    @@playlists
  end

  # «Liked songs» — плейлист, собираемый из сердечек по мере надобности
  # (make_liked_playlist в main.c): у трека liked меняется на лету.
  def self.liked_playlist : Playlist
    liked = playlists[0]
    liked.tracks = tracks.each_with_index.compact_map { |t, i| t.liked ? i : nil }.first(40).to_a
    liked
  end

  # Треки альбома по индексам (очередь воспроизведения альбома).
  def self.album_tracks(album : Int32) : Array(Int32)
    a = albums[album]
    (a.first_track...(a.first_track + a.track_count)).to_a
  end

  def self.album_seconds(album : Int32) : Int32
    album_tracks(album).sum { |t| tracks[t].seconds }
  end

  # "3:07" (library_format_time)
  def self.format_time(seconds : Int32) : String
    seconds = 0 if seconds < 0
    "#{seconds // 60}:#{(seconds % 60).to_s.rjust(2, '0')}"
  end

  # ---- процедурная обложка ---------------------------------------------

  # Рисует обложку в `rect` painter'ом: скруглённый квадрат с
  # вертикальным градиентом color → color2 и инициалами артиста
  # крупным полупрозрачно-белым шрифтом по центру. Файла/текстуры нет —
  # это и есть обложка (рисуемые узоры draw_cover из library.c — этап 3).
  def self.paint_cover(painter : Egui::Painter, fonts : Egui::Fonts, rect : Egui::Rect,
                       album : Album, rounding : Float64 = 8.0) : Nil
    return if rect.width < 1.0 || rect.height < 1.0
    painter.rect_gradient(rect, rounding, album.color, album.color2)
    initials = album.initials
    size = {rect.height * 0.34, 12.0}.max
    measured = fonts.measure(initials, size)
    painter.text(Egui::Pos2.new(rect.center.x - measured.x / 2.0, rect.center.y),
      initials, size, Egui::Color32.rgba(255, 255, 255, 0x9A), bold: true)
  end

  # Cover — виджет-обложка фиксированного размера (те же краски, что
  # #paint_cover); кликабелен: карточка альбома — это Cover + подписи,
  # и клик ловится прямо по обложке.
  class Cover
    include Egui::Widget

    def initialize(@album : Album, @size : Float64,
                   @rounding : Float64 = 8.0, id : String? = nil)
      @id_name = id
    end

    def ui(ui : Egui::Ui) : Egui::Response
      id = resolve_id(ui)
      rect = ui.allocate_at_least(Egui::Vec2.new(@size, @size))
      Music.paint_cover(ui.painter, ui.fonts, rect, @album, @rounding)
      ui.interact(rect, id, Egui::Sense::Click)
    end
  end
end
