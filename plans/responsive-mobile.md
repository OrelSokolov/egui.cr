# Responsive / мобильная зрелость стилей и лейаута

> **Статус (2026-10): Этапы 1–3 РЕАЛИЗОВАНЫ** (спеки: `spec/
> length_units_spec.cr`, `spec/widget_size_spec.cr`, `spec/
> media_conditions_spec.cr`; `transition` из animations.md Ур.1 тоже
> вошёл — `spec/style_transitions_spec.cr`). Из Этапов 4–6 готова
> кристалльная часть (спека `spec/responsive_extras_spec.cr`):
> Этап 4 — модель `SafeArea` + вырезание из корневого региона в
> `begin_frame` + `env(safe-area-inset-*)`-единицы, ДЕТЕКТОР ГОТОВ:
> `egui_cr_safe_area` в `backend/sokol_shim.c` (UIKit safeAreaInsets
> на iOS, WindowInsets через JNI на Android, desktop = no-op) →
> `RawInput.safe_area` → `begin_frame` (backend-значение бьёт
> ручной сеттер); проверено на iPhone 17 Pro-симуляторе; Этап 5 — `Context#font_scale=` → `rem`; Этап 6
> (частично) — hover-правила читаются как base при `pointer: coarse`;
> Этап 7 (частично) — перенос по переполнению: `#horizontal` и
> горизонтальные strip-панели wrap по умолчанию (`flex-wrap: wrap`,
> opt-out `wrap: false`), вложенный ряд в горизонтальном родителе —
> блок с новой полной строки, лейбл в ряду переносится, когда шире
> всей строки (спека `spec/row_wrap_spec.cr`).
> Осталось: fontScale/reduced-motion из ОС (JNI/ObjC-шимы — safe-area
> детектор того же класса уже есть как образец), hit-target floor
> 44/48pt, мультитач (уже чей-то WIP в рабочей копии), Этап 7
> (layout-проп row/column через media).

Контекст: интерфейсы уже крутятся на мобильных экранах (Android/iOS-планы
см. `ANDROID_SUPPORT_PLAN.md`, `plans/IOS_SUPPORT_PLAN.md`), а система
стилей умеет только абсолютные значения. Ниже — полный список изменений
до «максимально зрелого» responsive-уровня, с привязкой к коду и фазами.

Диагноз по текущему коду (проверено):

- `Egui::Ecss.parse_value` (`src/egui/ecss.cr:361`) понимает только
  `true/false`, цвета `#hex`, строки в кавычках и голые `Float64`.
  `width: 50%` → warn «unparseable value» и объявление теряется.
- Стилевых пропсов размеров у виджетов нет вообще (единственные —
  `width` сепаратора = толщина линии, `src/egui/widgets/separator.cr:17`,
  и `min_width` табов, `src/egui/containers/title_bar_tabs.cr:104`).
- `MediaCond` (`src/egui/stylesheet.cr:281`) — только `min-width`/
  `max-width`; `orientation` и прочее отбрасывается (строка 306).
  Суффиксы значений глотаются без разбора (`"600em"` → 600, строка 299).
- Деревьев компонентов нет и не нужно: проценты/`rem` разрешаются
  против containing block'а (`Ui`) и корневого шрифта — это честная
  семантика, не эмуляция (см. разговор: immediate mode, `Ui` без
  `@parent`, `src/egui/ui.cr:61`).
- Viewport уже гонится в stylesheet каждый кадр
  (`src/egui/context.cr:338`) — медиа-условия живые, per-frame.
- DPI уже покрыт: `dpi_scale` из sokol + Android-шим через
  `AConfiguration` (`src/egui/backend/sokol.cr:1348-1354`).
- Safe area в проекте отсутствует целиком (0 упоминаний).
- `InputState` одно-указательная (`src/egui/input.cr:192-197`) —
  мультитач/щипок не моделируются.

## Этап 1 — единицы длины в ECSS (ядро, всё остальное стоит на этом)

Модель значения: новый тип в union `StyleValue` (`Bool | Color32 |
Float64 | String | StyleLength`):

```crystal
struct StyleLength
  getter value : Float64
  getter unit : Symbol # :px :percent :vw :vh :vmin :vmax :rem
end
```

Синтаксис (по умолчанию число = пункты, как сейчас):

| Запись   | Смысл                                                        |
|----------|--------------------------------------------------------------|
| `120`    | пункты (px), обратная совместимость                          |
| `50%`    | доля от базы containing block'а (см. ниже)                   |
| `50vw/vh`| доля от `ctx.input.screen_rect.width/height`                 |
| `4vmin/vmax` | min/max из сторон вьюпорта                               |
| `1.25rem`| `k * ctx.style.font_size` (корневой базовый шрифт; с Этапа 5 — умноженный на системный fontScale) |
| `auto`   | не входит — не изобретать до реальной потребности            |

База процентов (решение по итогам разбора `#horizontal`,
`src/egui/ui.cr:832`):

- ось X: `ui.max_rect.width`; в горизонтальном лейауте — минус один
  `item_spacing.x` (даёт математически ровный сплит для пары 50/50:
  `(W − s)/2` каждому; погрешность для n>2 остаётся, точный сплит —
  `ui.columns(n)` / `fraction:`, они знают n);
- итог всегда clamp к `available_width` — переполнение невозможно
  (max-size правило аллокации, `src/egui/ui.cr:118+`);
- ось Y: только там, где containing block вертикально определён
  (панели, viewport); в top-down «бесконечных» регионах (например
  `#frame` с inner-высотой `1e6`, `src/egui/ui.cr:806`) — считать
  не от чего, документируем: percent-height вне определённых
  контейнеров игнорируется с warn'ом.

Точки правки:

- `parse_value` / `Doc.format_value` (`src/egui/ecss.cr:361/244`) —
  парсинг и дамп суффиксных значений;
- `MediaCond.parse` (`src/egui/stylesheet.cr:299`) — заодно строгий
  разбор единиц в условиях (только `px`/голое число, `em` → warn);
- хелпер разрешения на стороне потребителя:
  `vars.length_px(key, ui, axis)` → `Float64?` (px как есть, unit-ные —
  по правилам выше); кладётся рядом с `StyleProp`-механикой
  (`src/egui/widgets/styled_part.cr`).

Спеки: расширить `spec/ecss_spec.cr` (парсинг/дамп/round-trip), новый
`spec/length_units_spec.cr` (разрешение против фейкового `Ui`:
percent в vertical/horizontal, clamp, vw/vh против `screen_rect`,
rem против `style.font_size`).

## Этап 2 — размерные пропы виджетов

Общие для всех виджетов пропы через каскад (класс → `#id` → inline):

- `width` / `min_width` / `max_width` — желаемая ширина и клампы,
  значения в любых единицах Этапа 1;
- `height` / `min_height` / `max_height` — только там, где база
  определена (см. Этап 1);
- применяются в точке расчёта natural size каждого виджета
  (`widget.ui(ui)`), через общий хелпер, чтобы поведение было
  единообразным: `width` < natural → растягиваем, > available →
  clamp (существующая гарантия), `min_width` — floor после разрешения;
- минимальный набор виджетов первой волны: Button, TextInput/
  TextArea, Slider, Checkbox, SelectBox, ProgressBar, Label (wrap
  против computed width), Expander, Separator (переименовать толщину
  линии в `stroke_width`, `width` отдать лейауту — breaking, отметить);
- Inspector (`src/egui/inspector.cr`) должен показывать резолвнутые
  значения (px после разрешения units) — иначе стили неудобно дебажить.

Спеки: `spec/label_padding_spec.cr`-стиль — по виджету: natural width,
width-override, min/max clamp, percent в ряду.

## Этап 3 — медиа-условия

Расширение `MediaCond` + `matches?` (`src/egui/stylesheet.cr`):

- `(orientation: portrait | landscape)` — из `screen_rect` (w vs h);
- `min-height` / `max-height`;
- `(pointer: coarse | fine | none)` и `(hover: hover | none)` —
  канонический CSS-способ включать touch-режим стилями. Источник
  истины — флаг «бэкенд видел touch-события» (Android/iOS-бэкенды
  шлют TOUCHES; desktop — `fine`), хранится в Context, обновляется
  при первом touch-событии (sticky, деградация `fine → coarse`
  безопасна);
- несколько условий через `and` уже поддерживаются синтаксисом.

Правка `Ecss.parse`-варнинга «is not a width condition» на честный
список поддерживаемых фич.

Спеки: `spec/ecss_spec.cr` — parse/match каждого условия, связки `and`.

## Этап 4 — safe area (чёлка, статус-бар, home-индикатор)

- Бэкенд-инсеты в пунктах: Android — `WindowInsets` через JNI-вызов
  из шима (Java-кода в приложении нет, но JNI из native — легально;
  слушать `insetsChanged`), iOS — `UIScreen.safeAreaInsets` через
  ObjC-шим. Модель: `ctx.safe_area : Rect` (top/bottom/left/right).
- Корневая раскладка (панели от краёв `screen_rect`) обязана
  вычитать инсеты по стороне; `viewport_width` для медиа-условий —
  как решим: от screen_rect (стабильнее) с фиксацией в доке.
- В стилях — функции-значения `env(safe-area-inset-top)` и т.п.
  (парсятся на Этапе 1 как отдельный вид `StyleLength`, резолвятся
  на Этапе 4, когда инсеты появятся).

Спеки: headless-контекст с фейковыми inset'ами → панели не заходят
под них.

## Этап 5 — системный масштаб шрифта (accessibility)

- Android `Configuration.fontScale` (JNI из шима), iOS Dynamic Type
  (`UIFontMetrics`/`UIContentSizeCategory`, ObjC-шим).
- Единая точка: `ctx.font_scale` (default 1.0), применяется как
  множитель к `style.font_size` при формировании корневой базы
  → `rem` Этапа 1 автоматически масштабирует весь UI, а не только
  текст (главная причина, почему rem вообще вводим).
- Решить и зафиксировать: интерактивные размеры (`interact_size`,
  hit-таргеты Этапа 6) масштабируются тем же коэффициентом.

Спеки: headless `font_scale = 1.3` → `1rem` = 1.3 базы; layout-тест
кнопки вырос.

## Этап 6 — touch-эргономика

- Минимальная hit-зона: когда `pointer: coarse` (см. Этап 3) —
  floor 44pt (Apple HIG) / 48dp (Material) на интерактивные ректы
  (взаимодействие с Этапом 5: floor до fontScale). Место —
  `Response`/аллокация или per-widget `interact_rect` expansion,
  решить по месту; важно: расширяется hit-зона, а не отрисовка.
- `:hover`-состояния: на `hover: none` каскад должен игнорировать
  hover-правила (иначе липкие подсветки после тапа). Одна проверка
  в разрешении каскада.
- Long-press как жест: контекстные меню (`spec/context_menu_spec.cr`)
  получают touch-триггер (долгое нажатие ~500ms без движения).
- Мультитач: расширение `InputState` — список активных указателей
  вместо одного (`input.cr:192-197`, back-compat: `pointer_*`
  остаётся как «первичный указатель»); жест pinch-zoom как
  производное (для viewport3d/canvas в первую очередь).

Спеки: coarse → hover-правило не применяется; long-press открывает
меню; два указателя → pinch-дельта.

## Этап 7 — стили управляют лейаутом (flex-direction)

Самый большой кусок, последним:

- проп `layout: row | column` (вариант `row_wrap`) на контейнерах,
  читаемый `#horizontal`/`#vertical`/`#scope` из каскада — тогда
  media-запрос может развернуть ряд в колонку на узком экране;
- код по-прежнему может форсировать (`layout:` в API = override
  стиля), иначе стили молча меняют раскладку;
- сюда же при необходимости `gap` (сейчас `item_spacing` из темы).

Спеки: `@media (max-width: 600px) { toolbar { layout: column } }`
меняет раскладку при изменении viewport_width в headless-тесте.

## Порядок и зависимости

```
Этап 1 (единицы) ──► Этап 2 (width/min/max пропы)
       │
       ├─► Этап 3 (media-условия: orientation/height/pointer)
       │         └─► Этап 6 (touch: зависит от pointer/hover)
       │
       └─► Этап 4 (safe area)   [шим-работа, параллельно]

Этап 5 (fontScale) ──► замыкается на rem из Этапа 1
Этап 7 (layout-проп) — последним, когда 1–3 обкатаны
```

Breaking changes (явно, в один релиз с notes):

- `width` сепаратора → `stroke_width` (старое имя deprecated-период);
- ужесточение разбора единиц в `@media` (мусорные суффиксы теперь
  warn вместо тихого глотания);
- `StyleValue` union расширяется — внешние матчи `case when Float64`
  по значению длины перестают срабатывать (мест в коде мало,
  проверяется grep'ом).

Приёмка по этапу: все спеки зелёные + прогон `examples/
widgets_gallery.cr` и `examples/paint/` на десктопе и Android-девайсе
(или эмуляторе из ANDROID_SUPPORT_PLAN), скриншоты до/после в
`screenshots/` не обязательны, но Inspector должен показывать
резолвнутые размеры (Этап 2).
