# MVC-анализ примеров egui.cr и kodkod (доказательная база разреза)

Статус: аналитика к plans/frontend-backend-split.md (фаза 4 — миграция
примеров). Проверяемое утверждение: в примерах нет шаблона управления
ресурсами, весь код слит в `App#update`, и значительную его часть
можно вынести в контроллеры/модели. Проверено чтением кода.

## Общий вердикт

Утверждение подтверждается полностью. Ни одно приложение не имеет
разделения на ресурсы/действия: состояние, файловый IO, бизнес-правила
и UI живут в одном классе App. При этом во ВСЕХ примерах повторяется
один и тот же скелет (документы+вкладки, настройки, статус, квит-флоу,
диалоги, хоткеи) — готовый кандидат на фреймворк-уровень.

## Разбор по примерам

### notepad.cr (575 строк)

Состояние: `@docs` (Doc: text/path/dirty/name + кэш статистики),
сигнал `selected`, `@settings` (AppConfig), `@status`, `@pending_close`,
`@quitting`, роут (root/root, root/settings, root/confirm-close).

Логика вне UI: чтение/запись файлов (`write_doc`, `open_doc`,
`open_at_startup`), сниффинг MIME через subprocess `file -b`
(`mime_type`/`text_mime?`), машина состояний квит-флоу (подтверждение
каждого dirty-дока по очереди), нумерация untitled, персист настроек,
подсчёт chars/lines с кэшем по идентичности строки.

Разрез:
- Модель: `Document` (text, path, dirty) — буквально CRUD-ресурс;
  `Setting` (theme)
- `DocumentsController`: create (new tab) / open / update (PATCH
  текст, дебаунс) / save / save_as / destroy (close + confirm-флоу
  как `confirm`-параметр); `SettingsController`: show/update
- Вид: вкладки из `state["docs"]`, textarea, dirty-точка, модалка
  рисует `state["pending_close"]`
- Ресурсы: `documents`, `settings` — каноничный Rails-случай

### terminal.cr (355)

Состояние: `tabs` (Tab: PTY-сессия + title), `picked`/computed
`selected`, профили `Config` (opacity/bg/blink, персист в JSON),
`@dirty`.

Логика: жизненный цикл PTY-сессий (open/close/kill), pump скрытых
вкладок (скроллбэк не ждёт рендера), синк OSC-тайтлов, репа мёртвых
детей (+ выход приложения с последней вкладкой), CRUD профилей +
персист, буфер-обмен с обёрткой bracketed-paste (`paste_bytes`).

Разрез:
- Модели: `Session` (PTY), `Profile` (AR-подобный: имя, opacity, bg,
  blink — персист в JSON-файл = адаптер хранилища)
- `SessionsController`: create/destroy/`POST /sessions/:id/stdin`;
  `ProfilesController`: CRUD; copy/paste = экшены SessionsController
- Скроллбэк и grid эмулятора — State-срезы (по решению §4.1
  frontend-backend-split: терминал — НЕ стрим)
- Джобы: reader-файберы уже есть (станут деталью адаптера сессии)
- Вид: табы, TermView (виджет фреймворка), панель настроек

### tableview.cr (182) — ЕДИНСТВЕННЫЙ ресурс-пример

Состояние: `ListStore` пакетов (status/name/installed/available/
size/section), `@search`, `@message`, selection.

Логика: сидинг фейковых данных, поиск-фильтр, toggle install/remove с
бизнес-правилами (install принимает available-версию, remove чистит
installed), массовые операции над selection.

Разрез:
- Модель: `Package` (поля выше) — готовая таблица; ListStore =
  view-модель над коллекцией моделей
- `PackagesController`: `resources "packages"` 1:1 — index (параметр
  search → фильтр), update (install/remove/upgrade)
- Вид: таблица + тулбар, ноль логики
- Вывод: CRUD-пример УЖЕ написан, но ресурсный слой вшит в App

### system_monitor.cr (301)

Состояние: Series-кольца (cpu/ram/rx/tx с таймстампами), `@cores`,
`@merged`, `@last_sample`.

Логика: цикл сэмплирования sysinfo (каденс 1с), кольца истории,
форматирование human_rate, автоскейл по пику окна.

Разрез:
- Джоба: `MetricsSamplerJob < AsyncJob` (checkpoint! в цикле, раз в
  секунду dispatch `metrics/*` в State) — учебный пример джобы
- Контроллер: не нужен (нет пользовательских записей) — только
  `SettingsController` для merged-вида; приложение без единого
  пользовательского POST — нормальная форма
- Вид: рисованные графики (чистый painter), подписи из State

### paint.cr (2086)

Состояние: канвас-пиксели, undo/redo (Snap-снапшоты всего канваса),
инструменты (fg/bg/brush/tool/zoom/размеры), палитра, `@doc_dirty`,
диалоги, жестовые состояния (SelState/TextState/CurveState/lasso/poly).

Логика: кодеки (сохранение/загрузка PNG), управление историей
undo/redo, растеризация текста, алгоритмы заливки, диалог Edit Colors.

Разрез:
- Модель: `Artwork` (пиксели, размер, path, dirty) + история
  (undo/redo — метод модели: `POST /artwork/undo`)
- `ArtworksController`: new/save/load/save_as/undo/redo;
  `PATCH /tools` — состояние инструментов (State-слайс)
- Джобы: энкод/декод PNG (тяжёлый IO)
- Вид: канвас-виджет; жесты (штрих) — эфемерное виджетное состояние,
  коммит в модель на pointer-up (ответ на вопрос о дебаунсе из
  App API-обсуждения: высокочастотные штрихи НЕ ходят запросом)
- Самый большой пример — и его бэкенд-слой (документ+история+кодеки)
  отделяется так же cleanly, как в notepad

### markdown.cr (109) / formulas.cr (128)

markdown: чтение файла + рендер-пайплайн (парсинг → подсветка →
galley — это ФОРМАТИРОВАНИЕ для показа, вид). Разрез:
`DocsController#show` (отдаёт исходник), виджет рендерит.
formulas: `Formula` — модель с кэшированным `to_svg` (MathJax),
контроллер почти не нужен. Мелочь, но и здесь разделение очевидно.

### remote_image.cr (59) / camera.cr (188) / voice_echo.cr (197)

remote_image: fetch + кэш по URL + машина состояний слота →
`ImagesController#index(url)` + http_client-щупальце; байты в модели,
декод и заливка текстуры — в кадре (решение http.cr).
camera: сессии/разрешение/поворот → ровно `CameraController` из §4.1
(stream-контракт проектировался по этому примеру).
voice_echo: захват/воспроизведение → `VoiceController` + аудио-щупальце.

## kodkod (11 716 строк) — редактор

Уже ПОЛОВИНА разделён — не в терминах MVC, но по модулям:

Чистый не-UI слой (~5.5k строк): `rope.cr` (389 — каноничная модель
данных), `editor_buffer.cr` (205 — документ: версии, undo/redo,
`changed_on_disk?`), `symbol_index/extractor` (279+), `index_worker`
(396 — индексация В ОТДЕЛЬНОМ ПРОЦЕССЕ, line-JSON по stdin/stdout!),
`index_queue.cr` (389 — очередь джоб), `quick_open.cr` (635 — fuzzy
поиск по файлам), `file_tree.cr` (682 — ленивое дерево), `fuzzy.cr`,
`gitignore.cr`, `fold_map.cr`, `syntax.cr`, `vim_mode/command`
(1154 — модальное редактирование = команды над документом),
`voice/` (service+sqlite+gigastt ~970 — STT с базой!), `i18n.cr`,
`reload_queue.cr`, `watch_filter.cr`.

Точка слипания — `app.cr` (1912): вкладки, настройки, эксплорер,
поиск, quick open UI, деф-попап, символ-браузер, о программе.

Разрез:
- Модели: `Doc`(=EditorBuffer+rope, undo/redo/folds), `FileNode`
  (дерево), `SymbolIndex`, `Setting`
- Контроллеры: `DocumentsController` (вкладки/open/save/close/
  undo/redo — как notepad), `ProjectController` (дерево, watch,
  reload), `SearchController` (quick open = запрос по индексу),
  `SymbolsController` (браузер, goto-def = запрос к индексу),
  `SettingsController`, `VoiceController` (transcribe)
- Джобы: `IndexJob` (прогресс, checkpoint — контракт §6.1);
  fswatch-события → системные события (пункт 2 инвентаризации)
- Честная оговорка: IndexWorker в отдельном процессе — не только
  архитектура, но и обход Boehm-GC STW-пауз (тяжёлая индексация не
  делит heap с UI). Контракт джоб покрывает оба варианта (in-process
  / subprocess-адаптер) — GC-изоляция остаётся законной причиной
  для subprocess-адаптера
- Вид: `code_editor.cr` (1561) — сложный виджет (гаттер, курсоры,
  подсветка) — фреймворк-фронт; vim-слой — обработка ввода, живёт
  у вида, командует моделью через те же экшены

## Скелет, повторяющийся во ВСЕХ примерах (кандидат в фреймворк)

| Повтор | notepad | terminal | kodkod | paint |
|---|---|---|---|---|
| документы/вкладки + selected-сигнал + focus-follows-tab | ✔ | ✔ | ✔ | — |
| настройки + AppConfig-персист + страница/панель настроек | ✔ | ✔ | ✔ | — |
| статус-строка `@status` | ✔ | ✔ | ✔ | ✔ |
| confirm-close/квит-флоу (dirty → модалка → цепочка) | ✔ | — | ✔ | ✔ |
| нативные диалоги через SystemPorts | ✔ | — | ✔ | ✔ |
| хоткей-экшены + «dispatch в конце update» | ✔ | ✔ | ✔ | ✔ |

Это «фабрика фич» наоборот: не фичи собираются из CRUD, а CRUD
уже собран в каждом примере руками. Фреймворк должен дать:
`DocumentsController`-базу (вкладки/selection/confirm-close/квит),
`SettingsController`-базу (AppConfig-персист), статус-слайс,
дефолтные хоткей-биндинги. Оценочно −30–40% кода в notepad/kodkod.

## Итог

1. Шаблона управления ресурсами нет НИГДЕ — даже в tableview
   (единственном CRUD-кейсе) ресурс вшит в App.
2. Каждый пример разрезается по MVC без насилия: бэкенд-слой —
   документы/сессии/настройки/история + IO; фронт — виджеты и
   разметка. Доля выносимого: notepad ~40%, terminal ~45%,
   tableview ~50%, system_monitor ~30% (но это джоба), paint ~35%,
   kodkod ~50% (и уже наполовину вынесен автором интуитивно).
3. kodkod доказывает потребность эскалации: автор сам завёл EventBus,
   очереди, воркер-процесс и DB для голоса — то есть джобы, события
   и модели УЖЕ спроектированы заново, только без общих контрактов.
4. Порядок миграции фазы 4 подтверждается: tableview (канон CRUD) →
   notepad (документы+настройки+квит) → terminal (сессии+State-поток)
   → system_monitor (джобы) → paint (документ+история) — каждый
   добавляет один слой каркаса.
