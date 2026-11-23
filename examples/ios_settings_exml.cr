# ios_settings_exml.cr — «Настройки» iOS-лука: та же оболочка, что
# examples/ios_settings.cr, но UI целиком в разметке
# assets/ios_settings.exml + стили assets/ios_settings.ecss; код —
# только тема/пэддинг при старте, сессия ecss, кастомные теги
# (examples/ios_components/ios_tags.cr) и пуш живых значений в стор.
# Запуск: rake build:dev[ios_settings_exml] && ./bin/apps/ios_settings_exml

{% unless env("EGUI_EMBEDDED") %}require "../src/egui/driver_selector"{% end %}
require "./ios_components/ios_tags"

class IosSettingsExmlApp < Egui::App
  @exml : Egui::Exml::Document
  @renderer = Egui::Exml::Renderer.new
  getter rt : Egui::Exml::Runtime
  @styled = false
  @ecss : Egui::Ecss::Session? = nil

  def self.asset_path(name : String) : String
    env = ENV["IOS_EXML_ASSETS"]?
    return File.join(env, name) if env && File.directory?(env)
    root = File.dirname(__DIR__) # examples/ → корень проекта
    path = File.join(root, "assets", name)
    raise "assets/#{name} not found (set IOS_EXML_ASSETS)" unless File.exists?(path)
    path
  end

  def initialize
    super
    @exml = Egui::Exml::Document.load(self.class.asset_path("ios_settings.exml"))
    @rt = Egui::Exml::Runtime.new
    IosTags.install(@renderer)

    # Стор — источник истины: разметка и теги читают/пишут напрямую.
    rt.strings["tab"] = "main"
    rt.floats["brightness"] = 62.0
    rt.floats["appearance"] = 0.0
    rt.floats["text_size"] = 0.0
    rt.bools["airplane"] = false
    rt.bools["wifi"] = true
    rt.bools["bt"] = true
    rt.bools["true_tone"] = true
    rt.bools["bold"] = false
    # Все switch= слоты разметки инициализированы — «мёртвых тоглов»
    # нет, линт (этап 0) чист.
    rt.bools["wifi_notif"] = true
    rt.bools["notif_mail"] = true
    rt.bools["notif_msg"] = true
    rt.bools["imsg"] = true
    rt.bools["adblock"] = false

    # Производные значения (этап 4): движок считает, зависимость —
    # read-set первого вычисления. Ручные пуши
    # `strings["wifi_value"] = …` в каждом кадре больше не нужны.
    rt.computed "wifi_value" do |s|
      s["wifi"] == "true" ? "home-5G" : "Выкл."
    end
    rt.computed "bt_value" do |s|
      s["bt"] == "true" ? "Вкл." : "Выкл."
    end
  end

  def update(ctx : Egui::Context) : Nil
    unless @styled
      # Тема по умолчанию тёмная — iOS-лук светлый; central-панель не
      # должен инсетить контент (мобильное приложение = весь экран).
      ctx.theme = Egui::Theme.light
      ctx.style.spacing.window_padding = Egui::Vec2.new(0.0, 0.0)
      # Разметка не вставляет явных промежутков между группами — поток
      # живёт на item_spacing (22pt как в ручной версии).
      ctx.style.spacing.item_spacing = Egui::Vec2.new(8.0, 22.0)
      @ecss = Egui::Ecss::Session.new(ctx,
        self.class.asset_path("ios_settings.ecss"))
      @styled = true
    end

    # Живые значения ({wifi_value}/{bt_value}) — computed-слоты
    # (этап 4): пересчитываются при записи в зависимый слот, ручные
    # пуши каждый кадр не нужны.

    @exml.reload_if_changed
    @renderer.render_routes(ctx, @exml, rt)
  end
end

{% unless env("EGUI_EMBEDDED") %}
Egui.run(IosSettingsExmlApp.new, title: "Настройки — iOS look (exml)",
  width: 390, height: 844, inspector: :hidden)
{% end %}
