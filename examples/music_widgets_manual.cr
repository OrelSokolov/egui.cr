# music_widgets_manual.cr — Raven Music live на РУЧНОЙ верстке: тот же
# UI, что music_exml, прямым кодом без парсинга EXML/ECSS. Пишется и
# поддерживается руками — расхождения с music_exml неизбежны; канон
# разметки — assets/music.exml, автоматическая версия — music_gen.cr
# (кодоген egui-gen, вшивает литералы того же парсера).
# Запуск: rake build:dev[music_widgets_manual] && ./bin/clones/music_widgets_manual
# MUSIC_TTFB=1 — печатать время старта (конец первого update, момент
# после показа первого кадра) и выйти (MUSIC_TTFB_EXIT=1).
MUSIC_T0 = Time.instant
require "../src/egui/driver_selector"
require "./music_components/music_widgets_manual_app"

# обёртка с таймингом кадров для MUSIC_TTFB=1 (симметрично music_exml.cr)
class MusicWidgetsManualTimed < MusicWidgetsManualApp
  @frames = 0

  def update(ctx : Egui::Context) : Nil
    @frames += 1
    if @frames == 2
      # второй update начинается после present первого кадра
      STDERR.printf("ttfb presented  %8.1f ms\n",
        (Time.instant - MUSIC_T0).total_milliseconds)
      exit 0 if ENV["MUSIC_TTFB_EXIT"]?
    end
    super
    if @frames == 1
      STDERR.printf("ttfb update#1   %8.1f ms\n",
        (Time.instant - MUSIC_T0).total_milliseconds)
      # без событий/repaint второго update не будет — просим кадр,
      # чтобы поймать момент «первый кадр показан» (начало update#2)
      ctx.request_repaint
    end
  end
end

if ENV["MUSIC_TTFB"]?
  Egui.run(MusicWidgetsManualTimed.new,
    title: "Raven Music — widgets manual live",
    width: 1360, height: 860, inspector: :hidden)
else
  Egui.run(MusicWidgetsManualApp.new,
    title: "Raven Music — widgets manual live",
    width: 1360, height: 860, inspector: :hidden)
end
