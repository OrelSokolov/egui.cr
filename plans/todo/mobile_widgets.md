# Мобильные виджеты: план закрытия нехватки

Контекст: фреймворк позиционируется для нативных мобильных приложений
(Android/iOS, см. ANDROID_SUPPORT_PLAN.md, IOS_SUPPORT_PLAN.md), но
виджетный набор вырос из десктопного egui — большинства стандартных
элементов мобильного UI (Material 3 / iOS HIG) нет, их собирают вручную
из flex + painter в примерах. Цель плана — добавить недостающие
виджеты как обычные компоненты фреймворка (классы в `src/egui/widgets/`
и `src/egui/containers/`, хелперы в `ui.cr`, стилизация через
`style_class`/`style_properties` + ECSS, темы в `default_theme.cr`).

**Жёсткие ограничения всего плана:**

- Обратная совместимость: только ДОБАВЛЯЮЩИЕ изменения. Существующие
  сигнатуры `ui.cr`, классы виджетов и ECSS-ключи не меняются; suite
  спек обязанным остаётся зелёным на старте и финише каждой фазы.
- Каждый виджет — по образцу существующих: `include Widget`,
  `style_class`, `style_properties`, `ui(ui) : Response` (эталон —
  `widgets/spinner.cr`). Реактивные перегрузки (`sig`-версии) — по
  образцу `checkbox(sig)`/`slider(sig)` в `ui.cr`.
- Все жестовые виджеты строятся поверх уже имеющегося input-слоя
  (`Event#from_touch`, `touch_pointer`, увеличенный tap slop для
  пальца) — новый native-слой не нужен.
- Верификация визуального — по AGENTS.md: глазами через пример из
  `examples/`, без пиксель-дифф пайплайнов. Спеки — headless-логика
  (лейаут, стейт, коллбеки, ECSS-резолв).

## Статусы

| # | Виджет | Фаза | Статус |
|---|--------|------|--------|
| 1 | Switch (мобильный) | 1 | ✅ v1 |
| 2 | Snackbar / Toast | 1 | ✅ v1 (индикатор и action есть; таймер авто-скрытия на стороне приложения) |
| 3 | List tile / ListView | 1 | ✅ v1 (тайл; ListView = scroll_area + тайлы, виртуализация не тронута) |
| 4 | Bottom navigation bar | 2 | ✅ v1 |
| 5 | Top app bar | 2 | ✅ v1 |
| 6 | FAB | 2 | ✅ v1 |
| 7 | Card | 3 | ✅ v1 |
| 8 | Chip | 3 | ✅ v1 |
| 9 | Badge | 3 | ✅ v1 |
| 10 | Stepper | 3 | ✅ v1 |
| 11 | Avatar | 3 | ✅ v1 |
| 12 | Search bar | 3 | ✅ v1 |
| 13 | Bottom sheet | 4 | ✅ v1 |
| 14 | Modal dialog / AlertDialog | 4 | ✅ v1 |
| 15 | Pull-to-refresh | 4 | ✅ v1 (индикатор; триггер от overscroll ждёт экспозиции overscroll в scroll_area) |
| 16 | Swipe actions (dismissible) | 5 | ✅ v1 |
| 17 | Pager / carousel + page indicator | 5 | ✅ v1 |
| 18 | Range slider | 6 | ✅ v1 |
| 19 | Pin / OTP input | 6 | ✅ v1 |
| 20 | Rating bar | 6 | ✅ v1 |
| 21 | Circular progress | 6 | ✅ v1 |
| 22 | Skeleton / placeholder | 6 | ✅ v1 |
| 23 | Tooltip | 7 | ✅ v1 |
| 24 | Safe area / insets | 7 | ✅ v1 |

## Фаза 1 — базовые элементы (объём одной экранной формы)

### 1. Switch

`widgets/switch.cr` — мобильный toggle-трек с ручкой и пружинной
анимацией (`spring.cr` уже есть). `toggle_button` остаётся как есть;
switch — отдельный визуальный элемент (Material switch / iOS switch).
Ручка и трек — через `style_properties` (`track_color`, `thumb_color`,
`on_color`, `size`). Пишется поверх того же стейта, что checkbox:
`ui.switch(checked, ...)` + `ui.switch(sig)`.

- Спека `spec/switch_spec.cr`: клик меняет состояние, ECSS-ключи
  резолвятся, анимация не держит репаинт после успокоения (тот же
  контракт видимости, что у spinner).
- Пример: экран настроек (переключатели + разделители).

### 2. Snackbar / Toast

`widgets/snackbar.cr` + хелпер на `overlay.cr` (позиционирование
снизу уже есть у overlay). API: `ui.snackbar(id, text, action: nil?,
duration: …)` — стейт «какой снackbar открыт» хранится в memory по id
(как popup-ы), таймаут через input time + `request_repaint`. Поддержка
опционального action-текста с коллбеком. Снизу с отступом, над bottom
navigation (координата подъёма — параметр).

- Спека: появляется/исчезает по времени, action стреляет один раз,
  одновременен только один снackbar на скоуп.
- Тему (Snackbar/Toast-стайл) — в `default_theme.cr`.

### 3. List tile / ListView

`widgets/list_tile.cr` — строка «leading (icon/avatar) + title +
subtitle + trailing (switch/chevron/badge)» на flex. Хелпер
`ui.list_tile(leading:, title:, subtitle: nil?, trailing: nil?, &on_click)`
+ версия с массивом тайлов = `ListView`. Это база мобильных списков —
сначала тайл, группировка/виртуализация подстраивает существующий
`scroll_area` + `virtual_scroll` (проверить связку в spec/virtual_scroll_spec.cr).

- Спека: лейаут-математика headless (высота строки от subtitle,
  выравнивание trailing), клик по строке — один Response.
- Пример: список контактов/настроек.

## Фаза 2 — каркас экрана

### 4. Bottom navigation bar

`containers/bottom_nav.cr` — фиксированная нижняя панель из 3–5
пунктов (icon + label), выбранный пункт — tint + optional badge.
Тесно связано с #9 (badge) и #24 (safe area). Контракт: занимает
нижний слот экрана (высота из стиля), body остаётся у приложения —
по образцу того, как `sidebar`/`page` делят площадь.

- Спека: переключение пунктов, Id-стабильность между кадрами,
  ECSS-ключи (item color, active color, height).
- Пример: приложение с 4 табами (Home/Search/Profile/Settings).

### 5. Top app bar

`containers/app_bar.cr` — мобильный тулбар: back-кнопка (опционально),
заголовок, до 2–3 action-иконок. Вариант collapsing (сжимается при
скролле body) — вторым шагом, через уже имеющийся scroll-смещения
контракт; если выйдет дорого — отрезать в отдельный пункт, не тянуть
за собой фазу.

- Спека: headless-лейаут (высота, размещение actions), back/action
  коллбеки.

### 6. FAB

`widgets/fab.cr` — круглая кнопка 56pt с тенью и иконкой, позиция —
через `overlay` (комментарий про FAB в `widgets/overlay.cr` уже
задуман). Extended-вариант (иконка + текст) — параметром.

- Спека: клик, ECSS (цвет, размер, тень), не перехватывает клики
  body под собой.

## Фаза 3 — контентные элементы

### 7. Card

`widgets/card.cr` — контейнер с elevation/tint/радиусом, children —
блок. По сути тонкая обёртка над painter-ом (rect + shadow + clip),
стили через ECSS. Дешёвый, но нужен почти всем экранам.

### 8. Chip

`widgets/chip.cr` — Assist/Filter/Input-чип: капсула (радиус = h/2,
капсульный painter уже есть — см. spec/capsule_spec.cr) + иконка +
label + optional close-крестик. Filter-вариант — выбранное состояние.
Хелпер `ui.chip_row(chips)` — переносимый ряд (row wrap уже есть —
см. spec/row_wrap_spec.cr).

### 9. Badge

`widgets/badge.cr` — маленький круг/капсула с числом, доклеивается на
любой виджет: `ui.badge(count, on: …)` или позиционно через overlay.
Не путать с системным badge иконки приложения (system_ports/badge.cr) —
это in-app элемент.

### 10. Stepper

`widgets/stepper.cr` — «− значение +», min/max/step. Дешёвый
(sinonim drag_value по стейту), iOS-стиль.

### 11. Avatar

`widgets/avatar.cr` — круг с картинкой (texture id / remote_image) или
инициалами на tint-фоне, размер из стиля. Мелкий.

### 12. Search bar

`widgets/search_bar.cr` — мобильное поле поиска поверх text_edit:
иконка лупы, clear-крестик при непустом тексте, cancel-кнопка
(опционально). По сути стилизованная обёртка + поведение.

## Фаза 4 — оверлеи и жест-обратная связь

### 13. Bottom sheet

`containers/bottom_sheet.cr` — шторка снизу: drag за «ручку»,
drag-to-dismiss, затемнение фона, полувысота/полная. Стейт открытости —
spring (уже есть). Самый сложный контейнер плана — делать после того,
как осядут snackbar/dialog (общая слойная механика overlay/layer).

### 14. Modal dialog / AlertDialog

`widgets/dialog.cr` — мобильный AlertDialog: заголовок + текст + до 3
кнопок, затемнение, по центру. Частный случай — `about_modal`; общий
делаем по его образцу, но с универсальным API. HTML-`dialog`
(html.cr:713) остаётся как есть — это другой слой.

### 15. Pull-to-refresh

Дополнение к `scroll_area`: при overscroll сверху — индикатор
(раскрывающийся spinner), отпускание стреляет `on_refresh`. Overscroll
расстояние и порог — из стиля. Требует доступа к overscroll-стейту
scroll_area — проверить текущее поведение за краем (spec/composited_scroll_spec.cr),
если overscroll не отслеживается — сначала маленький шаг «экспонировать
overscroll», потом виджет.

## Фаза 5 — жесты списков и страницы

### 16. Swipe actions (dismissible)

`widgets/swipe_item.cr` — обёртка строки списка: свайп влево/вправо
открывает 1–2 action-кнопки под строкой, полный свайп — dismiss с
коллбеком. Пороги из стиля, отскок — spring. База — pointer drag
(`from_touch` уже различает палец: увеличенный slop).

### 17. Pager / carousel + page indicator

`containers/pager.cr` — горизонтальные свайп-страницы (по образцу
tabs, но жест вместо клика) + `widgets/page_indicator.cr` (точки).
Стейт страницы — по Id, синхронизация с индикатором.

## Фаза 6 — дешёвые добивки (мелкие, одна фаза)

- **18. Range slider** — две ручки на треке `slider.cr` (TickPart/TipPart
  уже в файле — переиспользовать), min<=value<=max инвариант в спеке.
- **19. Pin/OTP input** — N одно-символьных text_edit-ячеек с
  автопереходом фокуса и paste-обработкой; фокус-цепочка через
  существующий focus-механизм.
- **20. Rating bar** — ряд звёзд-иконок (icons.cr), шаг 1 или 0.5.
- **21. Circular progress** — кольцо поверх painter-а (дуга = Spinner
  без вращения), fraction 0..1, опционально текст в центре.
- **22. Skeleton / placeholder** — серые капсулы/прямоугольники с
  shimmer-анимацией (тот же repaint-контракт, что spinner). Хелпер
  `ui.skeleton_list(n)`.

## Фаза 7 — системные вещи

- **23. Tooltip** — единый виджет/хелпер `ui.tooltip(id, text, &body)`:
  long-press на таче, hover на мыши (двойное поведение уже различимо
  через `touch_pointer`). Сейчас tip есть только у slider (TipPart).
- **24. Safe area / insets** — не виджет, а порт: экспонировать
  системные insets (чёлка, home indicator, жест-бар) в `system_ports`
  + `ui.safe_area(&body)`-обёртка, добавляющая паддинги. Без него
  bottom nav и FAB не знают отступа снизу. Android-часть — через
  существующий apk-пайплайн (builds/), iOS — через ios_demo-шеймы;
  если нативная часть затянется — порт отрезать в отдельный план,
  виджеты фаз 1–5 параметризуются отступом вручную.

## Порядок и проверка

- Фазы 1→2→3 дают типовой экран настроек/списка — после них фреймворк
  уже пригоден для простых мобильных приложений; фазы 4–7 можно
  двигать по потребности.
- Каждая фаза: спеки headless-логики + пример(ы) в `examples/`
  (глазная проверка пользователем — по AGENTS.md) + прогон suite.
- Темы: новые ключи стилей добавлять в `default_theme.cr`; каталог
  мобильной темы (Material-подобной) — отдельным решением после
  фазы 2, пока виджеты стилизуются ECSS поверх текущей темы.
- Пример-витрину `examples/mobile_gallery.cr` (аналог
  widgets_gallery) вести с фазы 1 и пополнять каждый фазой — он же
  источник скриншотов.

---

## Итог реализации (2026-11-20)

Все 24 пункта реализованы в v1. Файлы: `src/egui/widgets/{switch,
snackbar,list_tile,fab,card,chip,badge,stepper,avatar,search_bar,dialog,
pull_to_refresh,swipe_item,page_indicator,range_slider,pin_input,
rating_bar,circular_progress,skeleton,tooltip}.cr`,
`src/egui/containers/{bottom_nav,app_bar,bottom_sheet,pager,safe_area}.cr`,
агрегирующий require — `src/egui/widgets/mobile.cr` (после `./egui/ui`).

Спеки (103 примера, зелёные): `spec/switch_spec.cr`,
`mobile_phase1/nav/content/sheets/gestures/extras/system_spec.cr`.

Галерея: `examples/mobile_gallery.cr` → `bin/apps/mobile_gallery`
(`rake build:dev[mobile_gallery]`), 4 таба bottom-nav: Controls,
Lists, Sheets, Extras + AppBar/FAB/Snackbar поверх.

Известные v1-ограничения (детали — в шапках файлов): snackbar без
встроенного таймера; pull-to-refresh без overscroll-триггера;
bottom-sheet без drag-to-dismiss и detents; safe-area — app-side
обёртка, нативный порт insets — отдельная задача (п.24 фазы 7).

---

## EXML-словарь (2026-11-23, фаза 5 плана exml-codegen)

Каталог мобильных виджетов доступен из разметки: `src/egui/exml_mobile.cr`
(`require "../src/egui/exml_mobile"`) — глобальные `widget`-хендлеры
(`Kind::Custom`, без правок ядра exml.cr, по образцу exml_formula).
Теги: `screen`/`screen-body` (скаффолд: фиксированные бары + скроллящееся
тело, слот навбара вырезается автоматически — `nav_height`), `app-bar`/
`appbar-action`, `bottom-nav`/`nav-item` (bind → float-слот), `fab`
(сам оборачивается в overlay-якорь), `snackbar`, `card`, `list-tile`
(дети → trailing), `switch`, `stepper`, `rating-bar`, `range-slider`
(bind_lo/bind_hi), `search-bar`, `pin-input` (on_filled), `chip-row`/
`chip` (bind = filter-слот), `swipe-item`/`swipe-action`, `pager`
(дети в видимую страницу, `{_i}` = индекс), `page-indicator`,
`pull-to-refresh`, `avatar`, `badge` (только standalone — `on:`-якорь
нужен builtin-ref), `skeleton`, `circular-progress`, `safe-area`.
НЕ теги (ctx-презентеры, app-side): Dialog, BottomSheet; `<tooltip>`
отложен (body-блок требует Response ребёнка, render возвращает Nil).

Галерея на разметке: `assets/mobile_gallery.exml` +
`examples/mobile_gallery_exml.cr` (store+actions, презентеры в коде);
codegen — `EXML_APPS` в Rakefile → `examples/mobile_components/
mobile_gallery_gen.cr`, `Document.hybrid` (дев — живая разметка,
релиз — литералы). Смоук: `spec/exml_mobile_spec.cr` (9 headless,
хит-тест требует persistent Renderer и settle-кадров перед тапом —
якоря оверлеев садятся на measured size со второго кадра) +
`spec/mobile_gallery_exml_live_spec.cr` (Capybara).

Сопутствующий фикс ядра: интерполяция неизвестного `{слота}` теперь
warn-once в STDERR (`Runtime#interpolate` → `warn_slot_miss`, скоупы
форвардят в корень — repeat-скоуп не спамит каждый кадр). Из этого же
— прикладное правило: слоты, читаемые разметкой с первого кадра,
должны быть опубликованы до рендера (см. `init_store` галереи).
