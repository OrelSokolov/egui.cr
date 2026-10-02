# Widget Inspector — план

> **Статус: РЕАЛИЗОВАНО** (см. галочки в фазах). Спеки:
> `spec/inspector_spec.cr` + `spec/inspector_panel_spec.cr` (полный
> набор зелёный). Демо: `bin/inspector_demo` (`rake build:examples`).
> Отклонения от исходного плана, принятые по ходу:
>
> * авто-id у каждого виджета — детерминированный (stable auto id из
>   иерархии), а СТРОКИ-имена для отображения — случайные на вид
>   6-символьные [A-Za-z] (`Id#short_label`): per-instance random
>   сломал бы hover/click/focus (Memory хранит их по Id) и overrides
>   не держались бы между кадрами;
> * пик правым кликом открывает popup «Inspect <Kind> · <имя>»;
>   под курсором часто несколько виджетов (composite: Markdown и его
>   RichLabel-и, окно/панель) — пик-меню перечисляет ВСЕХ
>   (`Memory#widgets_at`, снаружи внутрь), каждый пункт выбирает свой
>   Id; приложение со своим контекстным меню на этом виджете главнее
>   (`Context#popup_opened_this_frame?`);
> * `background` — единственный ключ заливки (CSS-семантика): во
>   вкладке «Элемент» базовая правка действует во всех состояниях
>   (inline-семантика), hover/active-значения — тот же ключ с
>   переключателем «Состояние» (База/Hover/Active, как во вкладке
>   «Класс»); отдельных ключей `fill_hovered`/`fill_active` больше
>   нет, разрешение состояния автоматическое
>   (`Widget#background_color`).
> * Панели ресайзятся по умолчанию (egui `Panel::resizable`): грип
>   на внутренней кромке (drag, cursor ns/ew-resize), размер
>   персистится в Memory по id панели, clamp [PANEL_MIN_SIZE, 90%
>   экрана]; `resizable: false` для фиксированных полос (хром окна).
>   `height:`/`width:` панелей теперь — начальный размер.
> * Export Style: кнопка в шапке инспектора открывает модал со
>   сниппетом (textarea + «Копировать» в буфер) — «Элемент»
>   экспортирует `ctx.set_id_style(...)`, «Класс» —
>   `ctx.stylesheet.rule(...)` включая state-оверлеи.
> * overflow-y: `panel_ui` оборачивает top-down панели (side/central)
>   в ScrollArea по умолчанию (контент влезает — как раньше, бара
>   нет; не влезает — колесо + overlay-бар вместо каши на срезе);
>   горизонтальные top/bottom-полосы — одна строка, без скролла;
>   панель инспектора скроллит своё тело сама (шапка закреплена).
>   Механика — `Ui#v_overflow` (аллокация вниз не клампится, высота
>   для fill-виджетов остаётся честной); флаг наследуется
>   `Ui#child_ui` вместе с layer/clip — иначе вложенные регионы
>   (`#horizontal`-строки) у сгиба слипались и перекрывались.
>   Исключение — `Ui#add_sized`: ячейка точного размера жёсткая
>   граница (флаг не наследует), виджет внутри не может её
>   перерасти даже в скролл-контенте (фикс: кнопки шапки инспектора
>   вылезали за 26px-строку).
>
> Не сделано (осознанно, следующий шаг): свип `id:`/`style_properties`
> по остальным виджетам (TextEdit, TextArea, NumberInput, DragValue,
> RadioButton, Segmented, HotkeyEdit, DatePicker) — они честно
> показываются в инспекторе как «нет стилизуемых свойств»; экспорт
> правок в `sheet.rule(...)`-сниппет.

## Инспектор для «рукописных» частей (СДЕЛАНО)

Проблема: части UI, рисующиеся painter-вызовами напрямую (не через
`Ui#add`), не имели Widget-экземпляра — `Context#interact` писал meta
из `current_widget` (nil) — правый клик по ним ничего не выбирал, и
стилевых ключей они не читали. Решение (`src/egui/widgets/styled_part.cr`):

* `Widget#inspector_kind` — имя вида для meta (по умолчанию имя
  класса; у part-двойников своё);
* `Egui::StyledPart` — мета-двойник include Widget: kind, style_class,
  `style_properties`, label + публичные ридеры каскада `#vars(ctx, id,
  state)` (класс-правила + per-element override, публичная обёртка
  защищённого `Widget#style_vars`);
* `Context#with_inspector_widget(part) { interact … }` — ручной аналог
  того, что `Ui#add` делает с `current_widget` (инспектор выключен →
  plain yield, нулевая цена);
* `Inspector::WidgetMeta#id` — id, под которым meta записана (спеки,
  адресация).

Этим механизмом закрыто:

* **меню** (`containers/menu.cr`): `MenuItemPart` (`menu.item`) и
  `MenuButtonPart` (`menu.button`) — background (hover-подсветка,
  :active у bar-кнопки = меню открыто), text_color, font_size,
  padding (box). Смысловые fallback-и — прежние Visuals-слоты
  (`menu_highlight_fill`/`menu_highlight_text`).
* **табы в заголовке окна** (`containers/title_bar_tabs.cr`):
  `TitleBarTabs::TabPart` (`title_bar.tab`) — min_width, rounding,
  pad_x, font_size, top_gap, background (база = активная карточка,
  :hover = неактивная), text_color, text_idle, close_hover,
  plus_hover. Card/X/+ пишут meta; константы Win11 — fallback-и.
* **контейнерный Tabs** (`containers/tabs.cr`): per-card meta
  (`Tabs::TabPart`, класс `tabs.tab`) и чтение оверлеев
  hover/selected ЧЕРЕЗ per-Id каскад — раньше читался только класс,
  и вкладка «Элемент» на карточку не действовала. Корень `tabs`
  (tab_spacing, rule_color, background, merge_selected) — shadow-meta
  под (неинтерактирующим) scroll-id, чтобы «Класс» знал свойства.
* **табы шапки самой панели инспектора** (`inspector.cr`):
  `Inspector::TabPart` (класс `inspector.tab`) — background
  (база + :hover/:selected), text_color, underline_color. Раньше
  ячейки были голыми `row.interact` — meta не писалась вовсе, правый
  клик открывал ПУСТОЙ пик-попап. Заодно `Ui#add_sized` выровнен с
  `Ui#add` по `current_widget` (Export/✕ в шапке — обычные `Button` —
  тоже не писали meta).
* **сайдбар** (`containers/sidebar.cr`): `Sidebar::TabPart`
  (`sidebar.tab` — height, font_size, font_family, text_color,
  padding, background + :hover/:selected) и `Sidebar::ClosePart`
  (`sidebar.close` — background + :hover, text_color) на вложенных X.
  Раньше interact строк писался как весь `Sidebar` (без свойств), и
  оверлеи читались из класса напрямую, минуя per-Id каскад — вкладка
  «Элемент» на строку не действовала.
* **терминал** (`terminal/widget.cr`): класс `terminal` расширен с
  одного `font_family` до font_size, background, text_color,
  cursor_color, selection_overlay, scrollbar_color,
  scrollbar_active_color — применяются на per-frame twin темы
  (`Terminal::Theme#twin`), SGR-разрешение цветов идёт через него.
* инспектор: fallback виджета (`StyleProp#fallback`) в display-значениях
  теперь РАНЬШЕ theme-слота — иначе терминал показывал бы
  `button_weak`/тему приложения вместо своих #16161e/14pt;
* `font_family` редактируется НЕ свободным текстом, а выпадающим
  списком загруженных в приложение гарнитур
  (`Context#font_family_catalog` = зарезервированный "monospace" +
  все стеки из `register_font_family`/`Sokol.register_font`); нулевой
  пункт «(наследуется)» снимает ключ. Значение вне каталога (опечатка
  из кода) честно показывается первым пунктом.

Спеки: `spec/inspector_parts_spec.cr`.

## Захардкожено, но могло бы быть в инспекторе — план

Обзор «что в системе задано константами/темой, а не правилами».
Формат: место → предлагаемый класс → ключи. Приоритет по частоте
касания пользователем.

1. **Скроллбары ScrollArea** (`containers/scroll_area.cr:29+`; BAR_W=8,
   CLASSIC_W=16, thumb/track цвета, стрелки) — класс `scrollbar`
   (+ `:hover`/`:active` у thumb): width, thumb_fill, track_fill,
   rounding, arrows (bool). Пер-инстанс — `scroll_area { … }`-ключи на
   контейнере. Скроллбар textarea (`widgets/textarea.cr` BAR_W=8)
   — тот же класс.
2. **Рамка и кнопки окна** (`containers/window_frame.cr`): у каждого
   скина (Windows/XP/Ubuntu/MacOS) блоки констант — BTN_W/CAPTION_H,
   палитры hover/press/close. Классы `window_frame.caption_button`
   (+ :hover/:active), `window_frame.border`. Много ручной работы
   (4 скина), но механика StyledPart уже готова.
3. **ComboBox** (`containers/combo_box.cr`): кнопка + popup-строки
   рисуются вручную — item height/inset, highlight, max_height.
   Классы `combo` / `combo.item` (+ :hover/:selected).
4. **TreeView** (`containers/tree_view.cr`): indent, chevron, иконки,
   выделение строки. Класс `tree.row` (+ :hover/:selected),
   `tree.arrow`.
5. **Plot** (`containers/plot.cr`): палитра серий (5 цветов), цвета
   осей/сетки, размер точек/толщина линий. Класс `plot` + `plot.line`.
6. **DatePicker** (`widgets/date_picker.cr` CELL=30, шапка, выделение
   дня) — класс `date_picker` / `date_picker.cell` (+ :selected).
7. **Виджеты «без свойств»** (заявлены в шапке как осознанно
   отложенные): TextEdit, TextArea (selection/caret цвета, padding),
   NumberInput (кнопки-стрелки), DragValue, RadioButton, Segmented
   (ячейки + разделители), HotkeyEdit, CollapsingHeader (стрелка,
   indent) — стандартный свип `style_properties` + чтение через
   `style_vars`, как уже сделано у Button/Checkbox.
8. **Popup/контекстное меню-рамка** (`Context#popup`): rounding,
   stroke, тень, padding — сейчас зашиты в painter. Класс `popup`.
9. **Tooltips** — цвета/задержка; класс `tooltip`.
10. **Page header** (`containers/page.cr` HEADER_H, BACK_D, TITLE_PT)
    — класс `page.header`.
11. **Скроллбар терминала** — геометрия (BAR_W=10, THUMB_MIN_H) ещё
    константы; цвета уже стилизуемы через `terminal` (см. выше).

Общий принцип для всех пунктов тот же, что в этом проходе: объявить
ключи в `StyleProp`-декларациях (виджет или StyledPart), читать через
`style_vars`/`part.vars`, fallback — сегодняшняя константа; инспектор
подхватит сам, без отдельного кода UI.

Рантайм-инспектор в духе Chrome DevTools для egui.cr: правый клик по
виджету → «Inspect» → нижняя панель с редактором стилей на лету.

Обсуждение предыстории (почему без дерева): инспектор правит ровно
**две** вещи — стиль **класса** (правило в `ctx.stylesheet`) и стиль
**конкретного Id** (runtime-override). Никакого DOM-дерева и родителей
не строим: identity виджета — это его `Id`, которого достаточно для
обоих режимов правки.

## Принципы

- **Две вкладки, два источника правды.** «Класс» пишет в
  `StyleSheet#rule("button", …)`, «Элемент» пишет в
  `Context#id_style_overrides[Id]`. Больше инспектор ничего не меняет.
- **Словарь свойств живут в самом виджете.** Какие свойства стилизуемы,
  объявляет виджет через `Widget#style_properties` (список ключей
  `StyleVars`, которые он реально читает). Инспектор — generic: строит
  редакторы по декларациям, ничего не зная о конкретных виджетах.
  Виджет без деклараций → вкладка «Элемент» честно пишет «нет
  стилизуемых свойств».
- **Один словарь ключей.** Свойство виджета = ключ `StyleVars`
  (`fill`, `text_color`, `padding`, `rounding`, …). Второго словаря
  (отдельного «списка полей инспектора») не заводим — это и есть
  «указано в properties, а не захардкожено».
- **Immediate mode = live бесплатно.** Правка правила/override
  применяется со следующего кадра без какого-либо «apply»: виджеты
  перечитывают каскад каждый кадр.
- **Инспектор всегда побеждает.** Слой per-Id накладывается СВЕРХ
  inline-`#style` из кода приложения — иначе инспектор невозможно
  использовать на виджетах с зашитыми оверрайдами. Это debug-инструмент,
  он обязан видеть результат своей правки.

## Каскад (после изменения)

```
theme (ctx.theme.style)
  → class rules        sheet.resolve(class)
  → state overlay      sheet.resolve(class, state)   (:hover/:active)
  → inline overrides   Widget#style { }               (код приложения)
  → ID override        ctx.id_style_overrides[id]     (инспектор) ← НОВОЕ
```

ID-override — верхний слой; чистится вручную из инспектора («Reset»),
никогда не автоматически.

---

## Фаза 1 — явные Id у всех виджетов

Явный Id — адрес вкладки «Элемент» и человеческое имя в инспекторе;
задаётся при создании.

- [x] `Widget` (widget.cr):
  - `@explicit_id : Id?`; builder `#with_id(name : String) : self`;
  - именованный параметр `id : String? = nil` в конструкторах всех
    виджетов (механический свип по `widgets/*.cr`; контейнеры не
    трогаем — их внутренние interact'ы живут на авто-id);
  - `protected def resolve_id(ui : Ui) : Id` — явный Id или
    `ui.next_widget_id`; каждый виджет в `#ui` зовёт его вместо
    `ui.next_widget_id` напрямую.
- [x] `Context#claim_widget_id(id : Id, kind : String) : Nil`:
  - `Set(Id)` на кадр, очищается в `begin_frame`;
  - повторный claim → `raise Egui::DuplicateWidgetIdError` с сообщением
    вида ``Duplicate widget id "save" (Egui::Button)``;
  - вызов — в `Ui#add` (единственная точка, где известен класс
    виджета и где проходят ВСЕ пользовательские экземпляры);
  - авто-id НЕ клеймятся — их дубликаты остаются на нынешнем тихом
    учёте (`Memory@duplicate_ids`). Raise — только про явные Id.
- [x] Стабильность: один и тот же экземпляр клеймит свой Id раз в кадр
  (Set чистится в begin_frame) — норма. Два экземпляра с одинаковой
  строкой (в т.ч. в разных окнах) — raise в первом же кадре, это и
  требуется.
- [x] Спека: дубликат явного Id → raise; уникальные явные Id двух
  кнопок в одном окне работают (state не путается).

## Фаза 2 — style_properties в самом виджете

- [x] `Egui::StyleProp` (stylesheet.cr или новый inspector.cr):
  `key : String` (ключ StyleVars), `kind : Symbol`
  (`:color | :number | :box | :bool`), `label : String?`,
  `states : Bool = false` (имеет ли смысл редактировать `:hover` /
  `:active`-оверлей этого ключа — у кнопок да, у label нет).
- [x] `Widget#style_properties : Array(StyleProp)` — в модуле по
  умолчанию `[]` (виджет без стилей). Виджеты-«участники» объявляют
  ровно те ключи, которые читают:
  - `Button`: `background` (states: true), `stroke`, `text_color`,
    `font_size`, `padding`(box), `rounding`, `bevel_light`,
    `bevel_dark`, `shadow.color/blur/spread/x/y/inset` (states: true);
  - `Checkbox`, `ToggleButton`, `SelectableLabel`: базовый набор
    (`text_color`, …) — по факту читаемых ключей;
  - `Label`: `text_color`, `font_size`;
  - `Hyperlink`: `text_color` (states: true), `font_size`,
    `hyperlink_color`, `underline` (states: true, fallback: true) —
    HTML `<a>`: подчёркнутый и окрашенный по умолчанию, перекраска
    hover/active через правила `link` / `link:hover` / `link:active`
    (как у кнопки), `underline(false)` = `text-decoration: none`;
  - `Slider`, `Separator`, `ProgressBar`, `Spinner`: по факту;
  - общий хелпер `StyleProps.textlike` / `StyleProps.buttonlike`,
    чтобы списки не дублировать.
- [x] Спека: у `Button` декларации соответствуют реально читаемым
  ключам (сверка списка с `#ui`).

## Фаза 3 — per-Id слой каскада (архитектурное изменение)

- [x] `Context#id_style_overrides : Hash(Id, StyleVars)` + апи
  `#set_id_style(id, key, value)` / `#clear_id_style(id, key?)`
  (каждая мутация → `request_repaint`; хранится на Context, живёт пока
  живёт процесс — это debug-состояние, не персист).
- [x] `Widget#style_vars(ui : Ui, id : Id, class_path : String?,
  state : String? = nil) : StyleVars` — единая точка чтения сырых
  ключей: `sheet.resolve(class, state)`; если есть override для `id` —
  merge-КОПИЯ поверх (общий кэш `resolve` не мутируем!), иначе общий
  кэш как есть (нулевая цена, пока инспектор не трогал виджет).
  Все прямые `class_vars.…`-чтения в виджетах (Button: `padding`,
  `rounding`, `bevel_*`, `shadow?`) переводятся на этот хелпер — иначе
  per-Id правка этих ключей не применится.
- [x] `Widget#effective_style(ui, id, class_vars = nil, state = nil)`:
  сигнатура получает `id`; после inline `#style` применяется
  `id_style_overrides[id]` через тот же `StyleVars#apply_over`.
  Свип по всем виджетам, зовущим `effective_style`.
- [x] Спеки: порядок каскада (id-override побеждает inline и класс);
  `style_vars` не мутирует кэш `resolve`; отсутствие override не
  создаёт копий.

## Фаза 4 — ядро инспектора (`src/egui/inspector.cr`)

Активация: `Sokol.run(app, inspector: :on | :hidden)` (Symbol, `:off` по
умолчанию) → `ctx.inspector_enabled = true`; `:hidden` стартует с
закрытой панелью (вызов — F12 или правый клик → «Inspect»).

- [x] `Egui::Inspector` — состояние + рендер:
  - `@selected : Id?`; `@tab : Symbol` (:class | :element);
  - `@open : Bool` (панель видна; тумблер — F12 и кнопка ✕);
  - `@pending_pick : Pos2?`.

### Регистрация мета (kind по Id)

- [x] `Ui#add` ставит `ctx.current_widget = widget` вокруг
  `widget.ui(self)` (поле, не стек — parents не нужны).
- [x] `Context#interact` при `inspector_enabled?` пишет
  `@widget_meta[id] = WidgetMeta{kind, style_class, style_properties,
  id_name (строка явного Id или nil)}`; ротация prev/current в
  `begin_frame` тем же паттерном, что `widget_rects`. В проде
  (флаг off) — нулевая цена.
- [x] `WidgetMeta` хранит ещё `label : String?` (текст кнопки/label —
  где виджет его отдаёт; опционально, для читаемости заголовка).

### Пик правым кликом → «Inspect»

- [x] До `app.update` (кадр N): `input.secondary_pressed?` + pos →
  hit-test по `prev_widget_rects` (+ clips/layers как в
  `Memory#topmost_at`) → `@pending_pick = {id, pos}`.
- [x] После `app.update`: если в этом кадре приложение НЕ открыло свой
  popup (проверка по memory popups — приложение с собственным
  контекстным меню на этом виджете главнее) → открыть popup-меню
  инспектора на pos: один пункт «Inspect <Kind>» (+ серая строка с
  id). Клик выбирает: `@selected = id`, `@tab = :element`.
- [x] Правый клик мимо виджетов — ничего.
- [x] Подсветка выбранного: каждый кадр рамка (1.5 px, accent-цвет) по
  `prev_widget_rects[selected]` на Foreground-слое; Id исчез из
  регистрации → плашка «виджет не найден в этом кадре».

### Нижняя панель (единственная позиция — снизу)

- [x] `ctx.bottom_panel("inspector", height: 200)` рисуется ДО
  `app.update` (клалит полосу первым → прижата к нижнему краю, под
  app-панелями; available_rect считает её автоматически).
- [x] Шапка: `SegmentedControl` «Класс | Элемент», справа ✕.
- [x] Вкладка «Класс»:
  - combo классов: все встреченные в кадре (`widget_meta` uniq
    `style_class`) + `ctx.stylesheet.classes`;
  - строки свойств = union `style_properties` виджетов этого класса;
  - каждая строка: чекбокс «переопределено» + редактор по `kind`
    (`:color` → ColorPicker, `:number` → DragValue, `:box` → 4
    NumberInput, `:bool` → checkbox) + reset (снимает ключ);
  - для props с `states: true` — переключатель базовое/:hover/:active,
    правка пишет `sheet.rule("<class>")` или
    `sheet.rule("<class>:<state>")`.
- [x] Вкладка «Элемент»:
  - заголовок: kind, явный Id строкой или `Id(0x…)`, rect (w×h);
  - строки свойств из `WidgetMeta#style_properties`; текущее значение =
    merged (class + id_override) через `style_vars`;
  - правка пишет `ctx.set_id_style(id, key, v)`; «Reset» — по ключу и
    «Reset all»;
  - `style_properties` пуст → «Виджет не имеет стилизуемых свойств».
- [x] Хуки рендера:
  `begin_frame → inspector.before_update → app.update →
  end_frame (→ inspector.after_update — после отложенного central
  panel, чтобы pick-решение видело все контекстные меню кадра)`.
  Один-меню-правило: у виджета с собственным контекстным меню пункт
  «Inspect …» дописывается последним пунктом ЭТОГО меню
  (`Response#context_menu` → `Inspector#render_menu_tail`); отдельное
  pick-меню открывается только у виджетов без своего меню.

## Фаза 5 — демо `bin/inspector_demo` и свип

- [x] `examples/inspector_demo.cr`: окно с `heading`, тремя `Button`
  (у двух явные id: `"save"`, `"cancel"`, третья без), `Label`,
  `Hyperlink`, `Checkbox`, `Slider`, `Separator`, `ProgressBar`, плюс
  один полностью «не-стилизуемый» виджет (для вкладки «Элемент» без
  свойств). Запуск: `Sokol.run(..., inspector: :on)`.
- [x] Rakefile: `EXAMPLES += "inspector_demo"`, проверить
  `rake build:examples` → `bin/inspector_demo` запускается.
- [x] Свип остальных виджетов — ЧАСТИЧНО (см. статус в шапке):
      готово: Button, Label, Hyperlink, Checkbox, Separator, Slider,
      ToggleButton, SelectableLabel, ProgressBar, Spinner; остальные
      ждут (`id:` параметр + декларации по факту читаемых ключей).
- [x] Ui-хелперы: `id:` параметр у самых ходовых (`ui.button(text, id:)`,
  `ui.checkbox(..., id:)`) — convenience поверх `with_id`.

## Фаза 6 — спеки и доки

- [x] `spec/inspector_spec.cr`:
  - дубликат явного Id → raise; разные явные Id — ок;
  - `set_id_style` меняет отрисовку (`end_frame` paint cmd: fill
    кнопки другой), каскад id > inline > class;
  - `sheet.rule` правка на лету меняет отрисовку;
  - регистрация `widget_meta` при enabled, отсутствие при disabled;
  - пик: synthetic secondary press над prev rect → popup → выбор.
- [x] Обновить `components.md` (строка в таблице/фазе) и README при
  необходимости.

## Открытые вопросы (решать по ходу, не блокеры)

- Экспорт правок (dump `sheet.rule(...)`-сниппетом) — НЕ в этом
  цикле; `StyleSheet#selectors/#dump` уже дают данные.
- У вложенных виджетов с составным id (Slider: rail+handle) —
  `style_properties` объявляет контейнерный виджет, interact id
  внутренний; meta пишется по фактическому interact-id, для стартеров
  достаточно (Slider читает стили по основному id).
- `inspector: :on` в проде запрещает nothing — флаг чисто additive;
  `Memory#topmost_at` приватный → нужен public read-only аналог или
  `#inspect`-обёртка для hit-test пика.

## Фаза 7 — сохранение правок в `.ecss` (СДЕЛАНО)

«Поправил интерфейс — сохранил»: правки инспектора живут в текстовом
`.ecss`-файле рядом с бинарником, только в debug-сборках. Формат и
семантика — `src/egui/ecss.cr` (заголовок файла), спеки —
`spec/ecss_spec.cr`, включая сквозной клик-тест обеих вкладок.

- [x] Опт-ин макросом в классе приложения:

  ```crystal
  class NotepadApp < Egui::App
    enable_ecss "notepad"        # → <dir_бинарника>/style_notepad.ecss
  end
  ```

  Файл — плоско рядом с бинарником (поддиректория `<app_id>/`
  конфликтовала бы с самим бинарником `bin/notepad`). В release макрос
  раскрывается в пустоту — файл никогда не читается и не пишется.
- [x] Файл = diff правок инспектора (НЕ дамп всей StyleSheet): классы
  (`button:hover { background: #5a5a5aff; }`), элементы с ЯВНЫМИ id
  (`#save:active { … }`); auto-id (`#0x…`) фильтруется при записи и
  при парсинге (warning в STDERR — сырое значение auto-id не значит
  ничего в другом процессе; правки такого элемента живут только
  в рантайме, вкладка «Элемент» показывает предупреждение);
  числа/строки/цвета `#rgb|#rrggbb|#rrggbbaa`. Парсер лояльный:
  битые строки — warning в STDERR, приложение не падает.
- [x] Write-through в память: каждая правка инспектора (обе вкладки,
  color popup, Reset all) применяется к контексту И записывается в
  документ сессии. На диск — ТОЛЬКО по кнопке «Сохранить» в шапке
  панели (никакой записи на каждое изменение).
- [x] Hot reload в обратную сторону: `Context#begin_frame` следит за
  mtime/size — внешняя правка файла в редакторе перезагружается на
  лету (журнал applied-ключей корректно снимает удалённые ключи,
  восстанавливая тему).
- [x] Смена темы (`ctx.theme = …`) подменяет StyleSheet — правила
  переносятся на новый лист (`Ecss::Session#reapply`).

## Фаза 8 — связанность вкладок (СДЕЛАНО)

- [x] Выбрал элемент → нажал «Класс» → вкладка открывается на классе
  ПОСЛЕДНЕГО выбранного элемента (`Inspector#class_sel` синхронизируется
  с `WidgetMeta#style_class` при переключении), а не на первом по
  алфавиту. Workflow «выбрал элемент — правлю его класс» без ручного
  поиска в комбобоксе.
