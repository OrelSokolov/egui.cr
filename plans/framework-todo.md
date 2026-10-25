# Framework TODO — «полный фарш»

Дорожмап фич до уровня Qt/Flutter по категориям. Статусы: ✅ есть /
в планах / не начато. Приоритет в конце.

## Текст / Rich content

- **Markdown** — ✅ есть (`examples/markdown.cr`)
- **Syntax highlighting** — ✅ есть: порт ядра highlight.js
  (`lib/highlight_cr`), подключён в markdown-фенсы
- **Math (KaTeX/MathJax)** — ✅ есть: LaTeX → SVG (nanosvg) с
  попиксельным MathJax-оракулом (`examples/formulas.cr`)
- **HTML-рендер** — minihtml/litehtml, если нужен rich text в лейблах
- **i18n** — ICU (сортировка, плюрализм, bidi), gettext-подобный слой.
  Bidi/RTL критичен для арабского/иврита

## Изображения / графика

- **SVG** — ✅ есть (nanosvg), но он ограничен; для полного фарша —
  resvg
- **Кодеки изображений** — JPEG, WebP, AVIF, GIF (включая анимацию),
  TIFF — «открыть файл любого вида». Слой абстракции — ✅ сделан
  (`Egui::ImageCodec`: bytes-in decode/probe + magic-sniffer,
  устанавливаемый провайдер; текущий — stb_image из шима, PNG/JPEG/
  GIF/BMP; см. TODO.md «Непротекающие абстракции»). Новые кодеки —
  просто вторые провайдеры на том же шове
- **Lottie (rlottie)** — анимированные векторные ассеты — ✅ фаза 1
  (C-shim twin): `Egui::Lottie::Player` + `ui.lottie` (widgets/lottie.cr,
  stream-текстуры), рендер через vendored rlottie за флагом `LOTTIE=1`
  (backend/rlottie.cr, `require "egui/backend/rlottie"`); фаза 2 —
  чисто-Crystal интерпретатор поверх растеризатора nanosvg.cr (A/B
  побайтово против шима)
- **Графики/charts** — built-in виджет (линии, свечи, heatmap) —
  обязательный атрибут фреймворков уровня Excel-like приложений

## Мультимедиа

- **Video** — ✅ есть демо (VP8/VP9/AV1, `examples/video.cr`), но нужен
  полноценный пайплайн: декод в текстуру, синхронизация аудио
- **Аудио-слой** — miniaudio / SDL_audio: клики, стриминг, микрофон
- **Камера / capture** — редко, но для «полного фарша»

## Система / platform

- **Clipboard с rich formats** — текст, изображения, файлы
- **Drag&Drop** — файлов извне и внутри
- **Файловые диалоги** — ✅ есть (`examples/openfiledialog.cr`), вопрос
  native vs собственный
- **IME** — ввод китайского/японского/корейского, если цель — не только
  латиница
- **Accessibility (screen readers)** — AT-SPI/UIA/AXAPI; у egui-upstream
  это больная тема (immediate mode → синтез accessibility-дерева), у нас
  скорее всего тоже
- **Global hotkeys, tray icon, notifications** — libnotify
- **Printing** — CUPS / PDF export

## Данные / сеть

- **HTTP-клиент с async** — для виджетов типа «картинка по URL»
- **Виртуальная FS** — zip/tar, assets packaging
- **Serialization** — JSON ✅ (Crystal stdlib), но нужен layer для
  тем/конфигов

## Адаптивность / мобильные экраны

- **Единицы в стилях** (`%`, `vw/vh`, `vmin/vmax`, `rem`), `width/
  min_width/max_width` как общие пропсы виджетов, медиа-условия
  (`orientation`, height, `pointer`/`hover`), safe area, системный
  fontScale, touch-эргономика, стили управляют лейаутом — полный
  план с фазами и зависимостями: `plans/responsive-mobile.md`
  (мобильные экраны уже используются — приоритет выше среднего,
  Этапы 1–3 срочные)

- **Анимации UI как встроенная фича** — `transition` в ECSS
  (интерполяция в слое каскада, все виджетов разом), easing-библиотека,
  reduced-motion, enter/exit — план: `plans/animations.md`
  (опирается на единицы длин из `plans/responsive-mobile.md`)

## Виджеты-level

- **DataGrid / таблицы на миллионы строк** — virtualized table
- **Tree view** — с lazy loading
- **Property inspector** — ✅ есть (`examples/inspector_demo.cr`)
- **Richtext editor** — сложнее notepad: таблицы, встроенные картинки

## Приоритет (по пользе)

1. Responsive/мобильное (`plans/responsive-mobile.md`, Этапы 1–3)
2. Image codecs (WebP/JPEG) — слой абстракции готов (TODO.md,
   «Непротекающие абстракции»), остались сами кодеки как провайдеры
3. Bidi/IME
4. Charts
5. DnD / clipboard rich
6. Accessibility

Остальное — по мере запросов пользователей.
