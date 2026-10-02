# Слот иконки приложения слева в заголовке окна (Windows-стиль)

## Цель

Слева в caption — место для иконки приложения (как в Windows: иконка 16×16 у левого края, заголовок/вкладки начинаются только после неё). Вкладки (`TitleBarTabs`) не трогаем — они получают уже уменьшенную `content_area` и сдвигаются автоматически.

## Изменения

### 1. `src/egui/containers/window_frame.cr` — хранение и отрисовка иконки

- Class-level API (рядом с хуком `caption`):
  - `WindowFrame.icon=(icon : NamedTuple(rgba: Bytes, width: Int32, height: Int32)?)` — тот же формат, что `Sokol.run(icon:)`; `WindowFrame.icon?` — геттер. Читаем через `WindowFrame.`-квалификатор из `draw` (урок про отдельные копии `@@` у подклассов).
  - `@@icon_texture : UInt64 = 0` — ленивая регистрация текстуры: в `draw` при установленной иконке один раз вызвать `ctx.textures.register_rgba(w, h, rgba)` и закешировать id (каждый кадр не перерегистрировать).
- Windows-стиль:
  - константы `ICON_SIZE = 16.0`, `ICON_PAD = 10.0` (отступ слева), `ICON_GAP = 8.0` (воздух после иконки до заголовка/вкладок).
  - отрисовка в новом хуке `paint_icon(bar)` (вызывается из `draw` до контента/заголовка): прямоугольник 16×16 на `bar.left + ICON_PAD`, вертикально центрирован в ВЕРХНЕЙ стандартной полосе (`CAPTION_H`, как кнопки), `painter.image(rect, @@icon_texture)` на слое z=1 (там же, где заливка caption), клип — bar. Иконка не установлена → слот не резервируется, вид как сейчас.
  - `paint_title` (`Windows`): при установленной иконке текст начинается после слота (`TITLE_PAD + ICON_SIZE + ICON_GAP` вместо `TITLE_PAD`), как в Win11.
  - `content_area` (`Windows`): при установленной иконке `area.left = bar.left + ICON_PAD + ICON_SIZE + ICON_GAP` — вкладки начинаются строго после иконки, сам `TitleBarTabs` не меняется.
- Ubuntu/MacOS: иконку не рисуют и слот не резервируют (это идиома Windows-стиля по запросу).

### 2. `src/egui/backend/sokol.cr` — прокинуть иконку из `run(icon:)`

В `self.run`: если передан `icon:`, дополнительно `WindowFrame.icon = icon` (нативная иконка Win32 уже ставится — теперь и клиентский caption покажет её же).

### 3. `examples/notepad.cr` — показать слот в демо

`require "./icon"` (там `ICON_64_RGBA`, 64×64 RGBA, require-безопасный — без `Sokol.run`) и передать в `Sokol.run(..., icon: {rgba: ICON_64_RGBA, width: 64, height: 64}, decorations: false)`. Иконка появится и в нативном окне (Win32), и в нашем caption слева от вкладок.

### 4. Спеки — `spec/title_bar_tabs_spec.cr` (+ `window_frame_spec.cr`)

- Иконка установлена → `content_area.left` == `ICON_PAD + ICON_SIZE + ICON_GAP`; в paint-командах появляется `ImageCmd` внутри caption-полосы (16×16, слева).
- Иконка установлена, контента нет → заголовок сдвинут вправо (TextCmd.pos.x >= слот), без иконки — как раньше (`TITLE_PAD`).
- Иконка сброшена (`WindowFrame.icon = nil`) → нет `ImageCmd`, `content_area.left == 0`.
- Существующие спеки не ломаются: без иконки поведение идентично (все текущие тесты иконку не ставят; `after_each` добавить `WindowFrame.icon = nil`).

### 5. Документация `components.md`

Дополнить запись о caption-хуке: слот иконки слева (Windows-стиль), автопрокидывание из `Sokol.run(icon:)`, вкладки начинаются после иконки.

## Проверка

- `crystal spec` — все зелёные (295 + ~3 новых).
- `crystal build examples/notepad.cr -o bin/notepad --link-flags "-L$(pwd)/lib"` + smoke-запуск `timeout 3s ./bin/notepad` (открытие окна без падения).
- Глазами: иконка слева, вкладки после неё, без иконки — вёрстка прежняя.
