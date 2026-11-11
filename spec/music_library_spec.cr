# music_library — детерминированная генерация данных порта oracle_live
# (app.js: LCG (s*1664525+1013904223)>>>0 >>>8, сид 20261101+a*7919 /
# 20261101+p*977). Контрольные значения пересчитаны независимо (Python),
# это фиксирует совпадение выдачи с Vue-оракулом.
require "spec"
require "../examples/music_components/music_library"

describe MusicLibrary do
  library = MusicLibrary::Library.new

  it "строит 14 альбомов, 6 плейлистов, 10 жанров" do
    library.albums.size.should eq 14
    library.playlists.size.should eq 6
    library.genres.size.should eq 10
    library.albums[0].title.should eq "Tides"
    library.albums[0].tracks.size.should eq 11 # TIDES
    library.playlists[0].title.should eq "Liked songs"
    library.playlists[0].cover.should eq -1
  end

  it "треки Tides — точно 11 оригинальных" do
    tds = library.albums[0].tracks.map { |i| library.tracks[i].title }
    tds.should eq ["Glass Waves", "Midnight Horizon", "Static Cathedral",
      "Leave Me Tonight", "Burning Weather", "The Arcade",
      "the Desert, Forever", "Daydreams", "The Machines",
      "the Valley, Home", "Seoul, Tonight"]
    library.tracks[2].liked.should be_true # Static Cathedral
    library.tracks[6].liked.should be_true # the Desert, Forever
  end

  it "генерация альбомов совпадает с контрольными точками app.js" do
    # python-пересчёт: album1 — 7 треков, первый «Crimson Paris» 303с;
    # album2 — 12, первый «Hold Me Alone» 244с; album13 — 12, «June, Away» 241с
    library.albums[1].tracks.size.should eq 7
    t = library.tracks[library.albums[1].tracks[0]]
    t.title.should eq "Crimson Paris"
    t.seconds.should eq 303
    t.liked.should be_false

    library.albums[2].tracks.size.should eq 12
    t = library.tracks[library.albums[2].tracks[0]]
    t.title.should eq "Hold Me Alone"
    t.seconds.should eq 244

    library.albums[13].tracks.size.should eq 12
    t = library.tracks[library.albums[13].tracks[0]]
    t.title.should eq "June, Away"
    t.seconds.should eq 241

    library.tracks.size.should eq 133 # 11 Tides + 122 сгенерированных
  end

  it "плейлисты генерируются тем же сидом (контрольные индексы)" do
    # python-пересчёт fillPlaylist(1): первые три индекса 112, 13, 90
    library.playlists[1].track_list.size.should eq 17 # 14 + p*3
    library.playlists[1].track_list[0, 3].should eq [112, 13, 90]
    library.playlists[5].track_list.size.should eq 29
  end

  it "liked songs — живой список лайков" do
    library.playlists[0].track_list.should eq library.liked_tracks
    library.tracks[0].liked = true
    library.fill_playlist(0).should contain 0
    library.tracks[0].liked = false
  end

  it "make_accent зажимает насыщенность и яркость" do
    # контрольные значения — эталонная JS-функция app.js (node)
    MusicLibrary.make_accent("#E92236").should eq "#e92337"
    MusicLibrary.make_accent("#237FEC").should eq "#237fec"
    MusicLibrary.make_accent("#808080").should eq "#c76d6d" # серый → s clamp 0.45
    MusicLibrary.make_accent("#3AC69E").should eq "#3ac79f"
    # детерминизм и hex-формат
    MusicLibrary.make_accent("#E92236").should eq MusicLibrary.make_accent("#E92236")
    # обложка Tides: из насыщенного красного получается светлый читаемый тон
    r = MusicLibrary.make_accent("#E92236")[1..].to_i(16)
    ((r >> 16) & 255).should be > 150 # v >= 0.78*255
  end

  it "scale_hex и fmt_time" do
    MusicLibrary.scale_hex("#ff0000", 0.5).should eq "#800000"
    MusicLibrary.fmt_time(0.0).should eq "0:00"
    MusicLibrary.fmt_time(83.9).should eq "1:23"
    MusicLibrary.fmt_time(302.0).should eq "5:02"
  end

  it "fake_level: бит каждые 0.5 с, всегда в [0.05, 1]" do
    24.times do |i|
      5.times do |bar|
        v = MusicLibrary.fake_level(bar, 5, i * 0.1)
        v.should be >= 0.05
        v.should be <= 1.0
      end
    end
    # бит: в момент t=0 волна баса сильнее, чем на четверти периода
    b0 = MusicLibrary.fake_level(0, 5, 0.0)
    b1 = MusicLibrary.fake_level(0, 5, 0.125)
    b0.should be > b1
  end
end
