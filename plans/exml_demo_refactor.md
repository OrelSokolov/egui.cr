# Декомпозиция демок на exml

Обзор `examples/*.cr` после появления полного exml-стека: словарь +
`widget`-сахар (стейтless кастом-элементы в глобальном реестре) +
`Component` (стейтфул, живые пропы) + мемоизированный `repeat`.

Граница декомпозиции проходит не по виджетам, а по **поведению** и
**колонкам**:

- формы/панели/меню/условные секции — раскладываются на стандартный
  словарь целиком;
- painter-код и тяжёлые интерактивные виджеты — НЕ декомпозируются,
  а встраиваются одним `widget`-хендлером (структура в разметке,
  поведение в коде);
- виртуализация и колонки (fraction-ширины, drag-resize) — вне
  досягаемости `repeat` + `<row>`, туда не идём (урок icons_browser:
  ~1850 ячеек без culling; замер bench/exml_bench.cr: ~350 виджетов
  ≈ 0.9 мс CPU/кадр).

## Конвенция

exml-версии — отдельными примерами `*_with_exml` рядом с живым
оригиналом (side-by-side чтение), как `notepad_with_exml`. Оригиналы
не трогаем. Каждый новый ассет `.exml` покрывается lint-спекой
(`Exml.validate`), кастом-элементы — `examples/*_components/` по
файлу на элемент.

## Порядок работ

### 1. `system_monitor_with_exml` — флагман связки

Хром (заголовки, подписи, статусбар) в разметке; каждый график —
`widget :graph` c `SysMon.graph(ui.painter, …)` (код переносится
как есть). Сэмплирование sysinfo остаётся кодом, публикует слоты
(cpu%, ram, rx/tx, подписи) в стор; график получает данные замыканием
или по имени серии из атрибута (`<graph series="ram"/>` — витрина
живых пропов/атрибутов у widget-хендлера).

### 2. Дешёвая тройка — документация входа

- `markdown_with_exml` — минимальный: весь UI это
  `<central><markdown text="{source}"/></central>`, ~70 строк
  загрузки шрифтов остаются кодом;
- `counter_with_exml` — hello-world: `{…}`-интерполяция, `bind` на
  input/slider/checkbox, панелька статистики; side-by-side с
  сигнальной `counter_reactive`;
- `openfiledialog_with_exml` — условия (`if` вокруг picked),
  async-статус SystemPorts, actions; разметка уже набросана (см.
  историю обсуждения — central/heading/label/button + column if=).

### 3. Хром + widget (по потребности)

- `icons_browser` — грид одним `widget :icon_grid` (compile-time
  встраивание + viewport culling остаются кодом), поиск/радио/
  превью-панель разметкой;
- `fontbrowser` — контролы (input, slider, combo размеров/семейств)
  разметкой, спесимен-строки `widget`-ом;
- `tableview` — НЕ декомпозировать (решение зафиксировано):
  виртуализация + sort/resize/multi-select — поведение, не структура.
  Максимум: тулбар/статус разметкой, `<table/>`-виджет вокруг
  сконфигурированного TableView.

## Пробелы словаря (мелкие, по желанию)

- `password` у `<input>` — `text_edit_singleline` умеет, атрибута в
  словаре нет (нужен iOS-демке для 100% декомпозиции);
- `spinner` — нет; async-режим обходится label'ом.

## Блокеры (что разблокирует будущие кандидаты)

- **`<grid>`** — fraction-колонки, выравнивание ключ-значение.
  Разблокирует `win_properties_demo` (property-таблицы) и мелкие
  ключ-значение списки, где декомпозиция на row честно работает;
- **`<tabs>`** — вторая половина `win_properties_demo`.

## Не кандидаты (фикс, чтобы не пересматривать)

paint, crystal3d, box_shadow, logos, logo_variants, splash, video,
camera, lottie, svg_rasterizer, terminal, formulas, voice_echo,
multitouch, remote_image, mdvsfonts (суть — кастомный рендер/нативные
фичи); borderless, rounded_window (caption-хуки); widgets_gallery
(справочник в коде); responsive_demo (суть — CSS media/переходы);
tray, text_input/iOS/Android, capybara, inspector (платформенные/
тестовые); notepad уже сделан.
