# Библиотека встроенных стилей (featured themes) — macos и дальше

> **Статус: план** (не реализовано). Отправная точка — `MacOsTheme.light`
> (src/egui/macos_theme.cr), уже дающий пиксельный паритет с AppKit
> (oracle-дифф 1.2–2.7%, уровень AA-шума — oracle/FINDINGS.md).

Цель: egui.cr из коробки несёт набор именованных платформенных пресетов
(«стиль macos», windows11, gnome, winxp) с мгновенным переключением,
параметром акцента, согласованным хромом окна и терминальной палитрой —
и процессом приёмки по oracle-скриншотам для каждого пресета.

## 0. Что уже есть (опора плана)

- `Theme` (src/egui/theme.cr:18) — бандл `Style` (палитра + spacing +
  шрифт) + `StyleSheet` (eCSS-классы); живёт на `ctx.theme`, свап
  мгновенный (immediate-mode перечитывает стиль каждый кадр).
- `DefaultTheme.build(name, dark) { |v| }` (src/egui/default_theme.cr:57)
  — фабрика пресетов: палитра через блок, поверх — элементные правила.
  Это уже конструктор тем; новые пресеты строятся на нём.
- `MacOsTheme.light` (src/egui/macos_theme.cr) — первый платформенный
  пресет, значения измерены с нативного AppKit. Требуется в `egui.cr:45`.
- `WindowFrame::Style` + классы `Macos`/`Windows`/`WindowsXp`/`Ubuntu`
  (src/egui/containers/window_frame.cr:42) — хром окна, СЕЙЧАС не
  связанный с Theme: оси независимы.
- `Terminal::Theme` (src/egui/terminal/theme.cr:74) — своя 16-цветная
  палитра, с UI-темами не связана.
- Oracle-пайплайн (oracle/) — нативные скриншоты + egui-двойник +
  twinshot-дифф; процесс приёмки уже обкатан на macOS.

Чего не хватает, чтобы это стала «библиотека стилей»: реестра,
параметризации палитрой (акцент), связи с window chrome и терминалом,
новых пресетов.

## 1. Каталог пресетов + реестр `Egui::Themes`

Структура:

```
src/egui/themes/
  registry.cr      # module Egui::Themes — реестр: lookup по имени, list
  macos.cr         # MacOsTheme переезживает сюда; добавляется dark
  windows11.cr     # (фаза 3) Fluent: #0078D4 accent, 4pt rounding
  gnome.cr         # (фаза 3) Adwaita/Yaru: #3584E4, 12pt rounding
  winxp.cr         # (фаза 3) Luna blue (oracle-кадры frame-xp.png есть)
```

Реестр — не просто namespace, а `ThemeRegistry` на `Context`:

```crystal
Egui::Themes.macos_light                  # => Theme (пресет по имени метода)
Egui::Themes["macos-light"]               # => Theme? (по строке)
ctx.themes.register(my_theme)             # пользовательский пресет рядом
ctx.theme = ctx.themes["macos-light"]
```

Зачем реестр, а не только константы:

- settings-UI (переключатель тем в notepad-настройках) — просто
  `ctx.themes.names`;
- декларативный выбор в exml/ecss (`theme="macos-light"` на корне);
- точка регистрации пользовательских пресетов тем же API.

API реестра:

```crystal
class ThemeRegistry
  def register(theme : Theme, name : String? = nil) : Nil
  def [](name : String) : Theme?          # lookup: встроенные + свои
  def names : Array(String)               # для UI и валидации exml
end
```

Встроенные пресеты лениво строятся и мемоизируются (тема — изменяемый
объект: пользователь тюнит `sheet` своего экземпляра, реестровый
экземпляр не мутируется повторной выдачей — отдавать клон или строить
заново; выбрать: строить заново, темы дёшевы).

Точка подключения: require из `egui.cr` после `default_theme` (место
текущего `require "./egui/macos_theme"` — egui.cr:45).

## 2. Параметризация палитрой — ключевое архитектурное изменение

Проблема: в `macos_theme.cr` ~15 правил несут захардкоженный
`ACCENT`/`SELECTION` (`checkbox:checked`, `radio:selected`,
`toggle_button`, `slider`, `segmented`, `progressbar`, …). Смена
`v.selection_fill` у собранной темы эти правила НЕ подхватит — акцент
зашит в класс-слой. Поэтому dark-вариант нельзя вывести из light, а
multicolor accents macOS невозможны без копипасты файла.

Решение — палитра-параметр, из которой ПРАВИЛА ГЕНЕРЯТСЯ:

```crystal
module Egui
  module Themes
    # Макет палитры платформенного пресета. Тема-specific: у macos
    # свои поля (bezel, track), у winxp — другие (luna_face, luna_dark).
    struct MacOsPalette
      property accent : Color32 = Color32.rgb(0, 122, 255)   # systemBlue
      property selection : Color32? = nil  # nil => измеренный (0,119,249)
      property bezel : Color32 = Color32.rgb(218, 218, 218)
      property track : Color32 = Color32.rgb(213, 213, 213)
      # ...
    end

    def self.macos(light = true, accent : Color32? = nil) : Theme
      pal = MacOsPalette.new
      pal.accent = accent if accent
      sel = pal.selection || Color32.rgb(0, 119, 249)
      theme = DefaultTheme.build("macos" + (light ? "" : "-dark"),
                                 dark: !light) do |v|
        v.selection_fill = pal.accent
        # ... палитра из pal; dark-значения — веткой light
      end
      macos_rules(theme, pal, sel)   # sheet-правила генерятся ИЗ палитры
      theme
    end
  end
end
```

Правила файла `macos_theme.cr` переводятся на аргументы палитры
механически: каждое вхождение `ACCENT` → `pal.accent`, `SELECTION` →
`sel`, `Color32.rgb(218,218,218)` → `pal.bezel` и т.д. Значения
измеренные — дефолты палитры, так что `Themes.macos` без аргументов
воспроизводит текущий `MacOsTheme.light` бит-в-бит (критерий приёмки:
twinshot-диффы не меняются).

Дополнительно — тёмная ветка значений. Источник измерений: нативный
AppKit dark appearance (oracle-скриншоты в тёмном виде; прогнать
`oracle/macos`-галерею с `defaults write ... AppleInterfaceStyle Dark`,
снять тот же набор кадров).

Обратная совместимость: `MacOsTheme.light` остаётся алиасом
`Themes.macos_light` (deprecated-пометка не нужна — внешний API не
меняется).

## 3. Связь Theme ↔ WindowFrame

Сейчас оси независимы: macos-тема на Windows-фрейме — франкенштейн.

```crystal
class Theme
  getter chrome : WindowFrame::Style?   # nil => авто по платформе
end
```

- `Themes.macos_light.chrome = WindowFrame::Style::Macos` (пресет
  закрепляет хром);
- `nil` — текущее поведение: `WindowFrame`/`RoundedWindow` выбирают по
  `SystemPorts`-платформе (авто);
- явный стиль у `WindowFrame.new(style:)` остаётся высшим приоритетом.

Плюс: пресет красит и хромовые цвета (title bar band), где фрейм
сегодня берёт свои константы — свести к чтению из `theme.style.visuals`
(`title_bar_fill` уже есть в Visuals; фрейм должен читать, а не
дублировать).

## 4. Маппинг в `Terminal::Theme`

Терминал — единственный виджет со своей палитрой, выпадающий из темы:

```crystal
class Theme
  # Пресет задаёт терминальную палитру (macos => Terminal.app 16 цветов,
  # winxp => классическая консоль, ...); nil => дефолт Terminal::Theme.
  getter terminal : Terminal::Theme?
end
```

Терминал-виджет при инициализации берёт `ctx.theme.terminal` если
задан. Светимость фона синхронизировать с `theme.dark` (в darkness
переключается пара bg/fg, ANSI-16 остаётся из пресета).

## 5. Шрифтовое спаривание

В пресете уже есть `style.font_size`; добавить дефолтный
`style.font_family`:

- macos → `SF Pro Text` / `Helvetica Neue` (fallback-цепочка);
- winxp → `Tahoma`;
- gnome → `Cantarell`;
- windows11 → `Segoe UI Variable` / `Segoe UI`.

Шрифты в репо НЕ тащим: fallback-порядок с системным дефолтом на конце —
механизм уже есть в `fonts.cr` (font chain).

## 6. Новые пресеты (фаза 3) и приёмка по oracle

Правило библиотеки: **каждый пресет принимается только с oracle-диффом
против нативных скриншотов** (порог — как у macos: ~2–3% или уровень
AA-шума конкретной платформы; winxp-рендер GDI чётче — порог ниже).

Порядок oracle-работы на пресет (обкатан на macOS):

1. нативная галерея контролов (кнопка/чекбокс/радио/поле/слайдер/
   свитч/прогресс/сегменты/попап) на целевой платформе — скриншоты;
2. egui-двойник той же геометрии (`examples/macos_gallery.cr` —
   шаблон);
3. twinshot-дифф, правка правил до порога;
4. фиксация спекой: `spec/theme_library_spec.cr` рендерит control sheet
   каждой темы и сверяет с эталонным кадром (дешёвый регрессионный
   страж между oracle-раундами).

Кандидаты по убыванию ценности: windows11 (основная аудитория десктопа),
gnome (linux-десктоп), winxp (ностальгический, oracle-кадры уже есть,
хром `WindowsXp` написан).

## 7. Фазы и порядок работ

| Фаза | Содержание | Зависимости |
|---|---|---|
| 1 | перенос `macos_theme.cr` → `themes/macos.cr`; палитра-параметр (§2); dark-вариант через ту же палитру | — |
| 2 | `Themes`-реестр + `ctx.themes` (§1); `Theme#chrome` + автоподбор (§3) | фаза 1 |
| 3 | `Terminal::Theme` маппинг (§4); шрифтовое спаривание (§5) | фаза 1 |
| 4 | windows11 → gnome → winxp, каждый через oracle (§6) | фазы 1–2 |

Фазы 1–2 — уже «библиотека стилей» в минимальном виде; 3–4 наращиваются
независимо друг от друга.

## 8. Критерии приёмки

- `Themes.macos_light` воспроизводит текущий `MacOsTheme.light`
  бит-в-бит: twinshot-диффы галереи не хуже текущих (1.2–2.7%).
- `ctx.theme = Themes.macos_dark` — весь UI, включая хром окна и
  терминал, перекрашивается со следующего кадра.
- `Themes.macos(accent: Color32.rgb(175, 82, 222))` — ВСЕ акцентные
  поверхности (чекбоксы, свитч, слайдер, сегменты, прогресс) меняют
  цвет, включая класс-слой (сегодня — нет).
- `ctx.themes["..."]` находит встроенные и пользовательские пресеты;
  `names` непуст.
- `spec/theme_library_spec.cr` зелёный; существующие theme-спеки
  (`window_frame_spec`, `menu_popup_style_spec`, `style_scope_spec`,
  …) не сломаны.
