# NativeHTML — генеральный план

Единый канонический план (объединяет `explicit-contracts.md`,
`restricted-browser.md`, `exml-codegen.md`, корневой
`HTML_ALIASES.md` — они оставлены как указатели сюда). Записано
2026-11-09, после аудита состояния фреймворка (162 файла, ~45k строк
в `src/egui`) и его использования в kodkod (~156k строк).

## 1. Позиционирование

**Имя: NativeHTML.** Формула: **браузер с ограниченной поддержкой
HTML+CSS, где вместо JS — Crystal.** HTML+CSS — первичный
фронтенд-язык, Crystal — бэкенд (логика). Теглайн: «весь кайф
HTML+CSS, запечённый в бинарь. Вместо JS — Crystal».

Оговорка по имени (проверено 2026-11-09): коллизии — GitHub-org
`native-html` (форк react-native-render-html, живой) и старая
Android-библиотека `nativehtml`. Ниша другая (мы — standalone
движок); брендируем с уточнением, теги `nativehtml` + `crystal`.
Механика переименования (решение 2026-11-09): имя продукта —
NativeHTML; **шард и репозиторий ПОКА сохраняют имя egui.cr —
переименование успеем всегда, отдельным решением при публичном
запуске**; namespace `Egui` в коде — до контракта элемента.

Prior art (ниша доказана): **Sciter** — ближайший аналог
(коммерческий embeddable движок, HTML+CSS-подмножество, бэкенд C++);
Tauri/Lorca (настоящий браузер как UI — платят весом); Slint/QML
(свой markup — учить заново); Servo (браузерный движок целиком).
Конкурент в Crystal: CrymbleUI (январь 2026, «Crystal + nimble») —
у них «ещё один GUI-тулкит», у нас категория с готовой ментальной
моделью у миллиона фронтендеров.

Дифференциаторы: бэкенд — компилируемый Crystal, БЕЗ
JS-интерпретатора в цикле; мгновенный первый кадр (кодоген, §6);
leaf-виджеты = canvas-скорость с DOM-правами (§2); чистый Crystal
без C в релизе (свои порты freetype.cr / nanosvg.cr); пять платформ
с одного `update(ctx)`.

## 2. Модель динамичности (трёхуровневая)

Браузер платит за полную динамичность интерпретатором в цикле и не
может ничего скомпилировать — это его архитектура. Мы этой цены не
платим: фиксированный словарь и паттерны отрисовки → быстрый
нативный интерфейс «через тот же HTML». Веб пришёл к тому же
эшафоту снизу (Figma/WebGL, Google Docs canvas, xterm.js) — но у
браузера canvas это дыра, куда выпадаешь с потерей прав (стили,
выделение, хит-тест — руками). У нас выпадения нет.

| Уровень | Что | Пример |
|---|---|---|
| Экземпляры | сколько/какие данные/показать ли — каждый кадр, бесплатно | `if`/loops, `<repeat>` |
| Структура | дерево/layout — код (if/loops) или exml-файл в рантайме | hot-reload |
| Семантика | новые типы виджетов и поведение — ТОЛЬКО перекомпиляцией | — |

Динамические компоненты (редактор кода, markdown) не идут через
дерево разметки — они нативные leaf-виджеты и остаются ПЕРВЫМ
классом: `Widget`-контракт, `effective_style`, фокус, Memory,
инспектор. **Canvas-скорость с DOM-правами.** Два эшафота:

1. **Композиция** — leaf из готовых виджетов внутри (`Markdown` =
   RichLabel + Separator + пара painter-rects); дёшево, когда
   хватает существующего.
2. **Painter** — полный контроль, измеренная геометрия, виртуализация
   (`CodeEditor` из kodkod: rope-буфер, DisplayDoc-проекция,
   measured-геометрия, свои скроллбары, 14 Memory-сольей).

Снаружи, из разметки, оба — один узел. Полностью динамический
интерфейс из данных есть (exml + store + repeat); «сервер прислал UI
с поведением» — нет и не будет; при необходимости — композиция
известных кубиков через `Custom` + зарегистрированные хендлеры.

## 3. Два закона (важнее виджетов)

1. **Подмножество — опубликованный контракт.** SPEC.md, свой caniuse:
   элемент за элементом, свойство за свойством — что работает и как
   отклоняется. Человек за 10 секунд узнаёт, чего НЕТ, а не
   обнаруживает методом тыка.
2. **Никаких наполовину работающих свойств.** Свойство либо работает
   как в браузере, либо отсутствует явно. `display:flex`, который
   иногда раскладывает не так, хуже отсутствующего.

Модель layout объявляется СВОЕЙ — linear block flow (уже default) +
wrap + grid + columns, — а не «сломанным flexbox».

## 4. Четыре контракта

### 4.1 Элемент (один протокол виджета)

- Один протокол: `Widget#ui`. `show(ui)`-контейнеры (`ScrollArea`,
  `Grid`, `ComboBox`, `TreeView`, `Table`) мигрируют в `Widget`;
  `show(ctx)`-формы (`Wizard`, `WindowFrame`, `TitleBarTabs`) —
  уходят или становятся `Widget`. В `containers/` один протокол
  (сегодня три; `Plot` реализует сразу оба).
- Один протокол значений: `Signal(T)`. `on_change`-блоки — сахар;
  signal-оверлоады (`ui.cr:558-641`, 9 из ~20 виджетов, каждый —
  рукописный дубль скелета) генерируются/схлопываются.
- Один тип возврата (`Response` у виджетов; у контейнеров —
  фиксированный, задокументированный). Сегодня: `Response`/`Rect`/
  `Bool`/`Nil`/сам виджет — вперемешку.
- Коллапс дубликатов поверхностного API: один текстовый виджет
  (`text_edit_singleline`/`textarea`/`text_field`/`TextEdit`/
  `TextArea`), `ComboBox` vs `SelectBox`, `Table` vs `TableView`,
  `label`/`rich`/`scrolledlabel`, `big_button` → параметр.

### 4.2 Cascade (CSS-семантика, один resolver)

- Порядок слоёв **не зависит от ключа**: inline > id > class >
  theme, как в CSS (inline бьёт `:hover`). Сегодня `background` и
  `stroke` разрешаются противоположно (`widget.cr:275-286` vs
  `button.cr:226`), gnome/macos-темы закрепляют акцент дважды
  (`gnome_theme.cr:190-200`, `macos_theme.cr:208-218`).
- Один merge вместо трёх: `WidgetStyle#merge_over` (theme.cr:87),
  `StyleVars#apply_over` (stylesheet.cr:446), `StyledPart`
  (styled_part.cr:116).
- ECSS `Doc` (ecss.cr:96-255) — сериализация diff'а `StyleSheet`,
  не параллельный store: один `split_selector` (ecss.cr:128 ≡
  stylesheet.cr:967), один владелец lifecycle при `ctx.theme=`.
- Fallback-цепочки `Visuals` (`text_selection→selection_fill`,
  `focus_ring→...`, scrollbar→button) — user-agent правила или
  документированный внутренний слой темы.
- Media-правила можно отменять (сегодня gnome переприсовывает
  mobile-правило целиком, gnome_theme.cr:79-92).
- Один спек на полный порядок слоёв (сегодня только по слоям).

### 4.3 Canvas2D (браузерный canvas, Crystal-код)

- **Route A — сделано** (`src/egui/canvas2d.cr`, SPEC.md §5): записанный
  список опов → CPU-бейк через NanoSVG-растеризатор (AA-филы, градиенты,
  dash, evenodd) по боксам регионов → source-over в retained-буфер →
  stream texture. CTM — в момент добавления сегмента; градиенты — в
  user space вызова fill/stroke. fillText — через `Fonts#coverage_quads`
  (CPU-ридбек атласа). Спеки: `spec/canvas2d_spec.cr` +
  `spec/canvas2d_font_smoke.cr` (под реальным шрифтом). Отклонения —
  SPEC.md §5.
- Поверхность: `moveTo/lineTo/quad/bezier/arc/ellipse/rect/close`,
  `fill/stroke` (join/cap/dash, nonzero/evenodd), `fillRect/strokeRect/
  clearRect`, `save/restore`, CTM (translate/rotate/scale/transform/
  setTransform), линейные/радиальные градиенты, `globalAlpha`,
  `fillText/measureText` (`textAlign/textBaseline`), rect-clip.
- **Route B** (потом): `PathCmd` + тесселяция + sgl-pipeline;
  `Mesh3DCmd` — доказанный прецедент расширения paint list. Тот же
  кусок (2D CTM) закрывает `transform`-анимации (§7).
- Сегодня в paint list нет: path-объекта, join/cap/dash, fill rules,
  CTM, произвольных градиентов, blend modes, clip-path (только
  rect-scissor); `ImageCmd` — axis-aligned, без поворота.

### 4.4 Leaf-виджет (уровень между `Widget` и `Painter`)

Сегодня этот уровень — племенные знания: kodkod `CodeEditor` вручную
воспроизводит то, что браузер даёт контейнерам бесплатно; те же
куски заново написаны в `TextArea`, `TableView`, terminal. Вытащить
в переиспользуемые примитивы:

- scrollbar-примитив (верт/гориз, grab, fade);
- scroll-anchor (пара doc-line/row-count — `TOP_SALT`/`TOPR_SALT`);
- публичная модель caret/selection как mixin (offset/anchor/
  sticky-col/snap — класс-level API как у `CodeEditor`, но типовой);
- gutter-примитив (ширина по цифрам, separator, TEXT_PAD);
- измеренная моно-геометрия (char_w/line_h/row_ascent — один хелпер
  над `Fonts#measure/metrics_at`);
- горизонтальное окно вьюпорта (run'ы вне окна не измеряются).

Результат: leaf-виджет уровня редактора сжимается кратно,
«нативная textarea» — первый класс, а не исключение.

## 5. HTML-словарь и атрибуты

Принцип: **никаких мёртвых атрибутов** — параметр добавляем только
там, где за ним стоит реальная семантика движка.

### 5.1 Оформление

`require "egui/html"` — opt-in модуль, расширяющий `Ui`/`Context`.
Ядро не трогаем, нулевой churn. Нейменг Crystal (`ui.div`, `ui.a`,
`ui.h1`), не HTML-синтаксис строками.

### 5.2 Прямые алиасы (~24, бесплатно)

| HTML | egui.cr |
|---|---|
| `div` | `ui.box` (ui.cr:1025) |
| `a` | `hyperlink`/`hyperlink_to` |
| `hr` | `separator` |
| `button` / `textarea` / `svg` | уже совпадают |
| `img` | `image` |
| `progress`/`meter` | `progress_bar` |
| `select` | `combo_box`/`select_box` (+ закрыть дубль) |
| `input[type=range]` | `slider` |
| `input[type=checkbox]` / `[type=radio]` | `checkbox` / `radio` |
| `input[type=number]` | `number_input` / `drag_value` |
| `input[type=color]` | `color_edit32` |
| `input[type=text]` | `text_edit_singleline` (alias `input`) |
| `input[type=date]` / `[type=time]` | `date_picker` / `time_picker` |
| `table` | `table`/`table_view` (+ закрыть дубль) |
| `canvas` | `canvas` (+ контракт Canvas2D §4.3) |
| `details`/`summary` | `collapsing_header` |
| `dialog` | `ctx.modal` (context.cr:1276) |
| `iframe` | `embedded_window` |
| `nav`/`aside` | `side_panel` |
| `header`/`footer` | `top_panel` / `bottom_panel` |
| `main` | `central_panel` |

### 5.3 Тонкий сахар (~12, день-два суммарно)

`p` (label + отступ), `h1`..`h6` (CSS-шкала 2em…0.83em),
`strong`/`em`/`code`/`mark`/`small`/`sub`/`sup` (RichText-раны),
`pre` (моно без wrap + hscroll), `span` (inline = `horizontal`
без переноса), `blockquote` (frame + левый stroke), `fieldset`/
`legend` (frame с заголовком), `br` (hard break через примитив
`Ui#end_line`), `menu`/`option`,
`title:`-параметр (тултип). Один новый примитив: `ul`/`ol`/`li`
(~40 строк над box+label).

### 5.4 Атрибуты

Универсальная пятёрка на КАЖДОМ алиасе (через базовый `Widget`):
`class:` → `style_class("sidebar.tab")`; `id:`; `style:` (inline-
оверрайды); `title:` → тултип; `disabled:` → `ui.enabled(false)`;
`hidden:` → пропуск рендера + `memory.use_id` (состояние живёт, как
в HTML) — добавить.

Поэлементные (семантика есть): `placeholder:`→`hint:`, `value:`→
Signal, `min/max/step:`, `checked:`, `selected:`, `src:`, `href:`+
`target:` (`"_blank"`→SystemPorts OpenURL), `alt:`→тултип-фоллбэк,
`rows:`/`cols:`, `dir:`→`with_rendering_direction`, `width:`/
`height:`→`add_sized`, `align:`→`label_align`, `draggable:`→
`Sense::Drag`, `autofocus:`→`request_focus`, `colspan:`/`rowspan:`.

События — блок, не параметр: `onclick` = `ui.button("Save") { save }`,
`oninput` = signal/`on_change`. Строковых колбэков не делаем.

`data-*` — `data_testid:`-метаданные для capybara-селекторов и
инспектора.

НЕ прокидываем (нет семантики): `required`/`pattern`/
`autocomplete` (нет слоя валидации), `lang` (не влияет на
фонтчейн), `role`/`aria-*` (нет a11y-слоя — будущее), `tabindex`
(Tab-навигация не портирована, см. docs/ANALYSIS.md).

`.exml` — тот же словарь: attrs уже парсятся, рендереру достаточно
распознать пятёрку на любой ноде.

Конфликты имён: egui-`label` остаётся (HTML-`label` ≈ label перед
input); `input` — НЕ один метод с `type:`, имена уже разошлись.

## 6. exml-кодоген — мгновенный первый кадр

Парсинг exml — одноразовый, но блокирует ПЕРВЫЙ кадр. Решение:
кодогенерация отдельной программой («egui-gen», вотчер/билд-степ) —
принятое направление (2026-11-11), не отложено. Препроцессор данных
в файл, который человек никогда не открывает.

Два уровня: **A (выбран)** — `.exml` → Crystal-литералы того же
`Array(Node)`, который выдаёт парсер; рендерер ОДИН, XML-парс
исчезает из рантайма, нулевой риск расхождения, парсер не попадает в
релизный бинарь. **B — не делаем**: прямые вызовы виджетов вяжут
кодоген к API, второй «рендерер» — та магия, из-за которой SFC уже
отвергали.

Гибрид — один рендерер, три фронтенда: живой файл (hot-reload,
dev) → сгенерированные литералы (release) → вшитый `read_file`-
фоллбэк (standalone). Ровно тот же принцип, что у ECSS: один
resolver, много declaration front-ends.

Честное позиционирование: Rust это умеет (Leptos `view!`, Dioxus
`rsx!`, Slint); наш козырь — тривиальность трубопровода, не
невозможность у других.

## 7. Анимации

Фундамент уже стоит; вопрос только в покрытии.

| Тип | Статус |
|---|---|
| CSS-transitions (цвет, размер, прозрачность) | ✅ есть: `transition.*`/`easing.*` + `StyleAnimations` (widget.cr:224-256), спеки |
| value-анимации | ✅ есть: `animate_value_with_time` (порт egui AnimationManager) |
| кинетика/физика | ✅ есть: `KineticScroller` + `History` |
| **пружины (spring-интерполятор)** | ❌ добавить: затухающий осциллятор как значение `transition` — `spring(smooth/bouncy/wobbly/response,damping)`; состояние (скорость) в Memory. Плюс paint-пружины hover/press, Appear-переходы (`appear:`/`appear-delay:` свойства ECSS, аналог `@starting-style`), layout-пружины, ghost попапов, reduce-motion, time-step override. Дизайн и порядок — `plans/NATIVE_HTML_DEMO.md` §3.2 (прецедент: Raven `widget/anim.c`) |
| lottie (векторные) | ✅ есть (rlottie; pure-Crystal плеер в планах lottie-port.md) |
| кадровая инфраструктура | ✅ есть: `request_repaint` + on-demand (план 0percent_cpu.md) |
| `@keyframes` + `animation:*` (`delay`/`play-state`/`direction`) | добавить: правило в stylesheet (наборы StyleVars по ключевым кадрам) + интерполяция поверх готового `StyleAnimations`; ~день-два, нулевая новая архитектура |
| `transform`-анимации (`rotate`/`scale`/`translate`) | после SDF-примитивов — постфактум transform инстансов (квад × матрица, как `rvn_drawlist_transform` у Raven); полный 2D CTM — потом, ОБЩИЙ кусок с Canvas2D Route B (§4.3) |

В SPEC.md — по закону «никаких полусвойств»: `transition` на цвет —
в спеку сразу; `transform` — только после CTM.

## 8. Инвентарь браузерных кусков

| Кусок | Статус |
|---|---|
| CSS cascade (классы, states, media, transitions, units) | есть; контракт порядка слоёв — §4.2 |
| border-radius, box-shadow, градиенты, per-side borders | есть |
| forms | есть; словарь — §5 |
| canvas | есть (pixel); Canvas2D Route A ✅ (§4.3) |
| audio | есть (system port + minaudio) |
| **video** | **example-уровень** (examples/video: ffmpeg+player) — промоутить в движок |
| svg, lottie, icons | есть |
| первый кадр | кодоген — §6 |
| SPEC.md | нет — создать (рождается из таблиц §5) |

## 9. Порядок работ

| # | Этап | Риск | Заметки |
|---|------|------|---------|
| 1 | cascade-контракт (§4.2) | низкий | вся инфраструктура есть; чистые спеки |
| 2 | контракт элемента + HTML-словарь + атрибуты (§4.1, §5) | механический, массовый | миграция examples |
| 3 | leaf-контракт (§4.4) | средний | общее из TextArea/CodeEditor/TableView/terminal |
| 4 | Canvas2D Route A (§4.3) ✅ | изолированный | клей над существующим |
| 5 | exml-кодоген (§6) | низкий | после №2 (стабильный поверхностный API) |
| 6 | SPEC.md (§3, §8) | дисциплинарный | из таблиц §5, живёт с ними синхронно |
| 7 | `@keyframes` (§7) | низкий | поверх StyleAnimations |
| 8 | video → движок (§8) | средний | промоушен из examples |
| 9 | Canvas2D Route B + 2D CTM | высокий | закрывает `transform`-анимации |

Этапы 1-2 не трогают рендеринг; 3-4 не трогают поверхностный API;
5-9 каждый независимо поставляем.

## 10. Границы (не делаем)

- Retained DOM, VDOM, строковые селекторы в рантайме, expression
  engine — решения `egui-reactive.md` §non-goals и
  `exml-sfc-codegen.md` остаются в силе.
- Контракты браузера — да; буквальная имитация браузерного API — нет.
- «Сервер прислал UI с поведением» — нет; только композиция
  известных кубиков через `Custom`.
- Полный flexbox — нет; своя модель layout (§3).
- Ядро не переписываем: аудит `docs/ARCHITECTURE.md` (шаги 5, 7 —
  `Host`/`RunOptions`, doc-sweep) идёт своим порядком.

## 11. Открытые решения (не блокируют, закрыть до старта)

- Судьба string-keyed `Runtime` exml: мост к `Signal` или остаётся
  параллельной системой (три версионированные ячейки: Signal /
  Runtime / Mvc::State — слияние не решено).
- Один event-словарь: named actions exml vs Mvc dispatch vs колбэки.
- «Компонент»: одно определение (exml `Component`/`widget`/partials
  vs ничего для MVC-приложений; суффикс `*_components/` в examples —
  MVC-сплиты, не библиотеки компонентов).

## Что получим по итогу

Sciter, каким он должен был быть: открытый, на Crystal, с честной
SPEC.md и мгновенным первым кадром. Побочный продукт — кодовая база
худеет: 11 механизмов построения → 1 контракт, 3 merge → 1, дубликаты
виджетов коллапсируют. Половина этапов — удаление, не написание.
