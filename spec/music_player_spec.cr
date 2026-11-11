# music_player — порт поведения плеера из oracle/oracle_live/app.js:
# очередь по всей библиотеке, on_ended по трём режимам repeat, prev >3 с,
# shuffle (start в голову), лайки с живым «Liked songs», notices, навигация.
require "spec"
require "../examples/music_components/music_player"

describe MusicPlayer do
  it "стартует с первого трека Tides в очереди альбома" do
    p = MusicPlayer.new
    p.track_obj.not_nil!.title.should eq "Glass Waves"
    p.queue.should eq p.library.albums[0].tracks
    p.context.should eq "Tides"
  end

  it "on_ended: очередь идёт дальше; repeat one — тот же трек" do
    p = MusicPlayer.new
    p.on_ended(0.0)
    p.track_obj.not_nil!.title.should eq "Midnight Horizon"
    p.repeat_mode = 2
    p.on_ended(100.0)
    p.track_obj.not_nil!.title.should eq "Midnight Horizon"
    p.position.should eq 0.0
  end

  it "on_ended: конец очереди — repeat off стоп, repeat all с начала" do
    p = MusicPlayer.new
    p.play_position(p.queue.size - 1)
    p.repeat_mode = 0
    p.on_ended(0.0)
    p.playing.should be_false
    p.position.should eq 0.0

    p.playing = true
    p.repeat_mode = 1
    p.play_position(p.queue.size - 1)
    p.on_ended(0.0)
    p.queue_pos.should eq 0
    p.playing.should be_true
  end

  it "prev: >3 с — в начало трека, иначе предыдущий" do
    p = MusicPlayer.new
    p.play_position(2)
    p.position = 5.0
    p.prev_track
    p.position.should eq 0.0
    p.queue_pos.should eq 2
    p.prev_track # 0 с на треке 2 → трек 1
    p.queue_pos.should eq 1
  end

  it "play_list со shuffle ставит start в голову" do
    p = MusicPlayer.new
    p.shuffle = true
    start = p.library.albums[2].tracks[3]
    p.play_list(p.library.albums[2].tracks, start, "Mirrors")
    p.queue[0].should eq start
    p.queue_pos.should eq 0
    p.track.should eq start
    p.context.should eq "Mirrors"
    # очередь — перестановка исходного списка
    sorted = p.queue.sort
    sorted.should eq p.library.albums[2].tracks.sort
  end

  it "play_position увеличивает plays" do
    p = MusicPlayer.new
    plays0 = p.library.tracks[p.queue[1]].plays
    p.play_position(1)
    p.library.tracks[p.queue[1]].plays.should eq plays0 + 1
  end

  it "лайки: like_track живит «Liked songs», notice только для текущего" do
    p = MusicPlayer.new
    p.library.tracks[0].liked.should be_false
    p.like_track(0, now = 10.0) # 0 — текущий трек
    p.library.tracks[0].liked.should be_true
    p.island_text(10.5).should eq "Added to Liked songs"
    p.island_text(13.0).should eq "Glass Waves" # notice истёк

    p.col_kind = :playlist
    p.col_index = 0
    p.like_track(0, 20.0) # дизлайк — список обновился
    p.library.playlists[0].track_list.should_not contain 0
    p.library.tracks[0].liked.should be_false
  end

  it "like_collection: плейлист — notice, альбом — флаг + notice" do
    p = MusicPlayer.new
    p.open_playlist(1)
    p.like_collection(0.0)
    p.island_text(0.5).should eq "It is your playlist already"

    p.open_album(2, 5.0) # album_likes[2] = true → «It is your playlist already»
    p.album_likes[2].should be_true
    p.like_collection(6.0) # снять
    p.album_likes[2].should be_false
    p.island_text(6.5).should eq "Removed from your library"
  end

  it "коллекция: мета, колонка Album, play/shuffle по контексту" do
    p = MusicPlayer.new
    p.open_album(0, 0.0)
    p.col_meta.should eq "· 2026 · 11 songs, 43 min 29 s"
    p.open_playlist(1)
    p.col_meta.starts_with?("· 17 songs, about ").should be_true
    # плейлист играет своим списком
    p.col_play(0.0)
    p.context.should eq "Late night drive"
    p.queue.should eq p.library.playlists[1].track_list
    # тот же список повторно — toggle (пауза)
    p.playing.should be_true
    p.col_play(1.0)
    p.playing.should be_false
    p.playing = true
    # shuffle коллекции: случайный трек, очередь перемешана, флаг не залип
    p.col_shuffle(2.0)
    p.playing.should be_true
    p.shuffle.should be_false
    p.island_text(2.5).should eq "Shuffle on"
  end

  it "play_track_row: из коллекции — её списком, чужой — своим альбомом" do
    p = MusicPlayer.new
    p.open_playlist(1)
    ti = p.library.playlists[1].track_list[0]
    p.play_track_row(ti)
    p.context.should eq "Late night drive"
    # трек вне открытого списка (альбом 13)
    other = p.library.albums[13].tracks.first
    p.play_track_row(other)
    p.context.should eq "Crimson Ghosts"
  end

  it "навигация: history с cap 64, back по Alt+←" do
    p = MusicPlayer.new
    p.nav_to(:search)
    p.nav_to(:settings)
    p.page.should eq :settings
    p.back
    p.page.should eq :search
    p.back
    p.page.should eq :home
    100.times { |i| p.show_page(:home, true); p.show_page(:library, true) }
    p.history.size.should eq 64
  end

  it "mute/unmute c notice" do
    p = MusicPlayer.new
    p.toggle_mute(0.0)
    p.muted.should be_true
    p.island_text(0.5).should eq "Muted"
    p.toggle_mute(1.0)
    p.muted.should be_false
    p.island_text(1.5).should eq "Unmuted"
  end

  it "cycle_repeat проходит off → all → one" do
    p = MusicPlayer.new
    p.cycle_repeat(0.0)
    p.repeat_mode.should eq 1
    p.island_text(0.5).should eq "Repeat all"
    p.cycle_repeat(1.0)
    p.repeat_mode.should eq 2
    p.island_text(1.5).should eq "Repeat this song"
    p.cycle_repeat(2.0)
    p.repeat_mode.should eq 0
  end
end
