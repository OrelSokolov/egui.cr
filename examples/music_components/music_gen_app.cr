# music_gen_app.cr — Raven Music на ВШИТОЙ разметке (кодоген,
# plans/NativeHTML.md §6 Route A): rake build перед crystal build
# прогоняет egui-gen (scripts/egui_gen.cr) — парсер один раз читает
# assets/music.exml и эмитит литералы Node-дерева во временный
# music_gen.cr, который компилятор вшивает в бинарь. Рендерер тот же,
# что у music_exml (один на оба фронта), расхождение невозможно по
# построению. Бинарь НЕ читает .exml в рантайме — литералы всегда;
# живой файл грузится только явным дев-оверрайдом (MUSIC_EXML=…,
# hot-reload как у music_exml). Дев-версия с живой разметкой —
# music_exml.cr.
require "./music_app"
require "./music_gen"

class MusicGenApp < MusicExmlApp
  # путь для ecss_path (тема): env или репозиторный assets/, как у родителя
  def self.exml_path : String
    ENV["MUSIC_EXML"]? ||
      File.join(File.dirname(File.dirname(__DIR__)), "assets", "music.exml")
  end

  # Разметка: всегда вшитые литералы — exml-парса в рантайме нет.
  # MUSIC_EXML (существующий файл) — единственный обходной путь для
  # дев-экспериментов: живой файл с hot-reload, как у music_exml.
  def self.load_document : Egui::Exml::Document
    if (env = ENV["MUSIC_EXML"]?) && File.exists?(env)
      Egui::Exml::Document.load(env)
    else
      MusicUi.document
    end
  end
end
