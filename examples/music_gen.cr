# music_gen.cr — Raven Music live на вшитой кодогеном разметке:
# rake build автоматически генерирует examples/music_components/
# music_gen.cr (литералы Node-дерева assets/music.exml, тот же парсер)
# и компилятор вшивает его в бинарь. Бинарь НЕ читает .exml в рантайме
# — литералы всегда; живой файл (hot-reload) — только дев-оверрайдом
# MUSIC_EXML=…; дев-версия с живой разметкой — music_exml.cr.
# Запуск: rake build:dev[music_gen] && ./bin/clones/music_gen
# MUSIC_TTFB=1 — печатать время старта (parse.exml — всегда ~0:
# exml-парса в рантайме нет) и выйти (MUSIC_TTFB_EXIT=1).
MUSIC_T0 = Time.instant
require "../src/egui/driver_selector"
require "./music_components/music_gen_app"

# обёртка с таймингом кадров для MUSIC_TTFB=1 (симметрично music_exml.cr)
class MusicGenTimed < MusicGenApp
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
      STDERR.printf("ttfb parse.exml %8.1f ms\n", MusicExmlApp.exml_parse_ms)
      STDERR.printf("ttfb parse.ecss %8.1f ms\n", MusicExmlApp.ecss_parse_ms)
      STDERR.printf("ttfb update#1   %8.1f ms\n",
        (Time.instant - MUSIC_T0).total_milliseconds)
      # без событий/repaint второго update не будет — просим кадр,
      # чтобы поймать момент «первый кадр показан» (начало update#2)
      ctx.request_repaint
    end
  end
end

if ENV["MUSIC_TTFB"]?
  Egui.run(MusicGenTimed.new,
    title: "Raven Music — gen live",
    width: 1360, height: 860, inspector: :hidden)
else
  Egui.run(MusicGenApp.new,
    title: "Raven Music — gen live",
    width: 1360, height: 860, inspector: :hidden)
end
