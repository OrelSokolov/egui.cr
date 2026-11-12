# music_exml.cr — Raven Music live: точка входа (класс приложения —
# examples/music_components/music_app.cr, как у html_gallery).
# Запуск: rake build:dev[music_exml] && ./bin/clones/music_exml
require "../src/egui/driver_selector"
require "./music_components/music_app"

Egui.run(MusicExmlApp.new,
  title: "Raven Music — exml live",
  width: 1360, height: 860, inspector: :hidden)
