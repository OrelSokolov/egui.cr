# Framework TODO — «полный фарш»

Дорожмап фич до уровня Qt/Flutter по категориям. Статусы: ✅ есть /
в планах / не начато. Приоритет в конце.

## Текст / Rich content

- **Markdown** — ✅ есть (`examples/markdown.cr`)
- **Syntax highlighting** — в планах (`plans/syntax-highlighting-plan.md`):
  tree-sitter или port грамматико-ориентированного движка (highlight.js)
- **Math (KaTeX/MathJax)** — MathJax тяжёлый (JS); для нативного рендера
  port KaTeX или хотя бы subset LaTeX → свои глифы. В текущем плане
  формулы через SVG (nanosvg) с оракулом MathJax
- **HTML-рендер** — minihtml/litehtml, если нужен rich text в лейблах
- **i18n** — ICU (сортировка, плюрализм, bidi), gettext-подобный слой.
  Bidi/RTL критичен для арабского/иврита

## Изображения / графика

- **SVG** — ✅ есть (nanosvg), но он ограничен; для полного фарша —
  resvg
- **Кодеки изображений** — JPEG, WebP, AVIF, GIF (включая анимацию),
  TIFF — «открыть файл любого вида». Слой абстракции — см. TODO.md
  «Непротекающие абстракции» (провайдер пока — stb через sokol-бекенд)
- **Lottie (rlottie)** — анимированные векторные ассеты
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

## Виджеты-level

- **DataGrid / таблицы на миллионы строк** — virtualized table
- **Tree view** — с lazy loading
- **Property inspector** — ✅ есть (`examples/inspector_demo.cr`)
- **Richtext editor** — сложнее notepad: таблицы, встроенные картинки

## Приоритет (по пользе)

1. Image codecs (WebP/JPEG) — но сначала слой абстракции (TODO.md,
   «Непротекающие абстракции»)
2. Bidi/IME
3. Charts
4. DnD / clipboard rich
5. Accessibility

Остальное — по мере запросов пользователей.
