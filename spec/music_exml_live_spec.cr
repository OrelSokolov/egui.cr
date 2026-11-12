# music_exml live — приложение целиком (порт oracle/oracle_live):
# кадры гоняются capybara-сессией (шрифты — фиктивные, без X), действия
# разметки дёргаются напрямую из store, состояние сверяется с MusicPlayer
# и синком store — так покрывается связка actions ↔ player ↔ computed.
require "spec"
require "../src/egui"
require "../src/egui/capybara"
require "../src/egui/capybara/fonts"
require "../examples/music_components/music_app"

def live_session
  app = MusicExmlApp.new
  Egui::Capybara::Fonts.install!(app.ctx)
  Egui::Capybara::Session.new(app, width: 1360, height: 860)
end

def act(t, name)
  app = t.app.as(MusicExmlApp)
  app.rt.actions[name].not_nil!.call
  t.idle(1) # sync store из player происходит на следующем кадре
  app
end

describe MusicExmlApp do
  it "первый кадр: синк store из плеера (Tides играет, акцент из обложки)" do
    t = live_session
    t.idle(2)
    app = t.app.as(MusicExmlApp)
    app.rt.string("np_title").should eq "Glass Waves"
    app.rt.string("np_artist").should eq "The Distant Horizon"
    app.rt.string("context_str").should eq "Tides"
    app.rt.string("play_icon").should eq "pause"
    app.rt.string("accent").should eq "#e92337" # make_accent(#E92236)
    app.rt.string("m1").should eq "#80131e"     # scale_hex ×0.55
    app.rt.rows["lib_rows"].size.should eq 20   # 6 плейлистов + 14 альбомов
    app.rt.rows["genres"].size.should eq 10
    app.player.page.should eq :home
  end

  it "плеер: toggle/next/seek/лайк через действия разметки" do
    t = live_session
    t.idle(2)
    app = t.app.as(MusicExmlApp)
    act(t, "toggle_play")
    app.player.playing.should be_false
    app.rt.string("play_icon").should eq "play"
    act(t, "next_track")
    app.player.track_obj.not_nil!.title.should eq "Midnight Horizon"
    act(t, "prev_track") # позиция 0 (<3 c) → предыдущий
    app.player.track_obj.not_nil!.title.should eq "Glass Waves"
    app.player.position = 5.0
    act(t, "prev_track") # >3 c → в начало того же трека
    app.player.track_obj.not_nil!.title.should eq "Glass Waves"
    app.player.position.should be < 0.1 # кадр успел отыграть один тик
    app.rt.floats["seek_frac"] = 0.5
    act(t, "seek")
    app.player.position.should be_close(150.0, 0.1) # 0.5 × 300 c (+тик кадра)
    act(t, "like_current")
    app.player.library.tracks[app.player.track].liked.should be_true
    app.rt.string("heart_icon").should eq "heart-f"
  end

  it "repeat/shuffle/mute циклятся с notices" do
    t = live_session
    t.idle(2)
    app = t.app.as(MusicExmlApp)
    act(t, "cycle_repeat")
    app.player.repeat_mode.should eq 1
    app.rt.string("repeat_col").should eq "#e92337" # активный — акцент
    act(t, "cycle_repeat")
    app.rt.string("repeat_icon").should eq "repeat1"
    act(t, "shuffle")
    app.player.shuffle.should be_true
    app.rt.string("shuffle_col").should eq "#e92337"
    act(t, "toggle_mute")
    app.player.muted.should be_true
    app.rt.string("vol_icon").should eq "muted"
    app.rt.float("volume_frac").should eq 0.0
  end

  it "поиск: живой фильтр по вводу (top/songs/albums, авто-страница)" do
    t = live_session
    t.idle(2)
    app = t.app.as(MusicExmlApp)
    app.rt.strings["query"] = "mir"
    act(t, "search_changed")
    app.player.page.should eq :search
    app.rt.bool("searching").should be_true
    app.rt.string("top_t").should eq "Mirrors"
    app.rt.rows["search_albums"].size.should eq 1
    # Songs: до 5 треков с «mir» (генератор: Velvet/Crimson/Golden Mirrors)
    app.rt.rows["search_songs"].each { |row| row["tt"].downcase.should contain "mir" }
    app.rt.rows["search_songs"].size.should be <= 5
    # жанр-плитка: query = название жанра
    app.rt.strings["_gt"] = "Jazz"
    act(t, "search_genre")
    app.rt.string("top_t").should eq "The Blue Comets"
    # очистка → Browse all
    app.rt.strings["query"] = ""
    act(t, "search_changed")
    app.rt.bool("searching").should be_false
  end

  it "навигация: сайдбар открывает плейлист, карточки — альбом" do
    t = live_session
    t.idle(2)
    app = t.app.as(MusicExmlApp)
    app.rt.strings["_i"] = "1" # Late night drive
    act(t, "open_side_row")
    app.player.page.should eq :collection
    app.player.col_kind.should eq :playlist
    app.rt.string("col_title").should eq "Late night drive"
    app.rt.string("col_kind_label").should eq "PLAYLIST"
    app.rt.string("col_meta").should start_with("· 17 songs")
    app.rt.string("album_head").should eq "Album"
    # колонка Album у каждой строки — альбом этого трека (плейлист смешивает)
    first_track = app.player.library.tracks[app.player.col_tracks.first]
    app.rt.rows["tracks"].first["al"].should eq \
      app.player.library.albums[first_track.album].title
    # альбомная коллекция: колонки Album нет
    app.rt.strings["_i"] = "0"
    act(t, "open_lib_album_r0")
    app.player.col_kind.should eq :album
    app.rt.string("album_head").should eq ""
    app.rt.rows["tracks"].first["al"].should eq ""
    # фильтры сайдбара
    act(t, "chip_side_2") # Albums
    app.rt.rows["lib_rows"].size.should eq 14
    act(t, "chip_side_1") # Playlists
    app.rt.rows["lib_rows"].size.should eq 6
  end

  it "настройки: переключатели и комбо меняют плеер" do
    t = live_session
    t.idle(2)
    app = t.app.as(MusicExmlApp)
    act(t, "sw_accent")
    app.player.follow_cover.should be_false
    app.rt.string("accent").should eq "#B79CFF" # picked (как задан) вместо обложки
    act(t, "sw_animate")
    app.player.animate.should be_false
    app.rt.bool("animate_bg").should be_false
    app.rt.strings["combo_bg"] = "None"
    act(t, "effect_change")
    app.player.effect.should eq 5
    app.rt.bool("mesh_on").should be_false
    app.rt.strings["combo_look"] = "Daylight"
    act(t, "look_change")
    app.player.look.should eq 2 # Daylight — применяется, а не «Not in this demo»
    MusicTags.look.name.should eq "Daylight"
    app.rt.string("c_muted").should eq "#5e5e6c" # цвета лука ушли в store
    MusicTags.look.dark?.should be_false
    app.rt.strings["combo_look"] = "Nocturne" # вернуть тёмный для остальных спек
    act(t, "look_change")
    app.player.look.should eq 0
    MusicTags.look.name.should eq "Nocturne"
    app.rt.floats["crossfade_frac"] = 0.5
    act(t, "crossfade_change")
    app.player.crossfade.should eq 6
  end

  it "клавиши: Space/стрелки через hotkey-действия" do
    t = live_session
    t.idle(2)
    app = t.app.as(MusicExmlApp)
    t.press_key(:space)
    t.idle(1)
    app.player.playing.should be_false
    t.press_key(:right, ctrl: true)
    t.idle(1)
    app.player.track_obj.not_nil!.title.should eq "Midnight Horizon"
  end
end
