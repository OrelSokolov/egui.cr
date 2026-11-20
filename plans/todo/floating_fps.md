# Настраиваемый FPS-лимит рендеринга (energy_mode)

## Проблема

Present-рейт жёстко привязан к vsync монитора (60/144/160 Гц). Для
энергосбережения нужен лимит: пресеты 25/30/60/90/144/160 и произвольное
значение, управляемое глобальным флагом из UI:

- `energy_mode = :saving` → 30 fps;
- `energy_mode = :normal` → 50/60 fps (по частоте монитора);
- `energy_mode = :game` → лимит по монитору, fallback 60.

## Факты (проверено по кодовой базе)

- `sokol_gfx` не имеет FPS-контроля вообще — это чистый рендер-API.
  Пейсинг живёт в `sokol_app` через `swap_interval` в `sapp_desc`
  (`backend/sokol_shim.c:1595`, `sokol.cr:938/1082`).
- `swap_interval` поддерживает значения `N > 1` — «свапать каждый N-й
  vsync»: честно работает на D3D11 (`vendor/sokol/sokol_app.h:9185`),
  WGL (`SwapIntervalEXT`, :9485), GLX (:14518), EGL (:14409).
  30 fps на 60 Гц = interval 2 — самый чистый путь для делителей
  частоты монитора.
- Vendored-версия sokol_app НЕ имеет runtime-переключения
  (`sapp_set_swap_interval()` появился в апстриме позже) — interval
  читается из `desc` в момент презента. Но `sokol_app.h` уже
  патчится (X11 event hook), так что замена чтения `desc.swap_interval`
  на mutable-глобал или прямой вызов `eglSwapInterval` /
  `wglSwapIntervalEXT` / `glXSwapIntervalEXT` из шима на render-потоке —
  маленький патч.
- `sapp_cancel_frame()` (пропуск презента целиком) в vendored-версии
  тоже нет — это единственный чистый способ arbitrary-лимита.
- Частоту монитора sokol не отдаёт — нужен свой запрос:
  `XRRConfigCurrentRate` (X11), `EnumDisplaySettingsW` (Win32),
  Wayland сложнее (`wl_output`). В кодовой базе этого пока нет.

## Хорошая новость: архитектура уже готова

- Detached-режим: Crystal-продакшн пейсится present-ack'ами
  (`sh_wake_a(SH_WAKE_PRESENT)`, `backend/sokol_shim.c:6036`;
  `src/egui/driver/sokol.cr:1140`–1147). Замедлили презент →
  автоматически замедлился весь пайплайн; 60 Гц fallback-watchdog
  остаётся страховкой как есть.
- Render thread делает `sh_replay` каждый vsync даже в idle
  (`sokol_shim.c:5964`) → лимит present-рейта и есть правильный рычаг
  энергосбережения: реже replay → меньше GPU/CPU → меньше wakeups.
- Legacy-путь: `frame_cb` тикает со скоростью свапа — замедлится тем
  же механизмом.
- On-demand repaint главного потока уже экономит CPU в idle; фича
  добавляет лимит именно на present-рейт.

## Дизайн energy_mode (с поправками)

- `:saving` → 30 fps: реализуется как **делитель реальной частоты**
  монитора (60→2, 90→3, 144→5 (28.8), 160→5 (32)) — честнее, чем
  фиксированные 30 через frame-skip.
- `:normal` → interval 1 (частота монитора). 50/60 не является
  делителем 144/160 Гц — вариант «ровно 60» на высокочастотных
  мониторах требует arbitrary-лимитера (см. ниже).
- `:game` → interval 1, fallback 60 если refresh не удалось узнать.
- Arbitrary-значения (25/50, 90 на 144 Гц, настраиваемый лимит):
  без `sapp_cancel_frame` только frame-skip (свап каждый vsync,
  тяжёлая работа каждый N-й тик) — на двойной буферизации чередует
  кадры N-1/N-2: для статичного UI незаметно, в анимации judder.
  Для чистого результата — бэкпортировать `sapp_cancel_frame`
  (патч небольшой, в апстриме уже есть).

## План реализации

1. **Runtime-делитель**: `Egui.set_frame_divisor(n)` → shim-функция
   `egui_cr_set_frame_divisor`, дёргает платформенный swap-interval
   setter на render-потоке (+ микропатч vendored `sokol_app.h` для
   D3D11-пути, где interval передаётся в `Present` напрямую).
2. **Опрос refresh rate монитора** в шиме (X11: `XRRConfigCurrentRate`,
   Win32: `EnumDisplaySettingsW`; Wayland — отдельная задача).
3. **`energy_mode :saving/:normal/:game`** поверх (1)+(2) — этого
   достаточно для :saving/:normal/:game.
4. (Опционально) **Бэкпорт `sapp_cancel_frame`** для произвольных
   25/50/90/160 и настраиваемого лимита из UI.

## Перепроверка 2026-11-20

- Подтверждено «не начато»: ни `energy_mode`, ни делителя, ни опроса
  refresh rate в кодовой базе нет; vendored sokol по-прежнему без
  `sapp_set_swap_interval` / `sapp_cancel_frame`.
- **Metal-путь уже делит частоту на `swap_interval`**:
  `_sapp_macos_mtl_start_display_link` ставит
  `preferredFrameRateRange = max_fps / desc.swap_interval`
  (`vendor/sokol/sokol_app.h:5527`); GL-путь на macOS — NSOpenGL
  `NSOpenGLContextParameterSwapInterval` (`:6536`), но он игнорируется
  системой с macOS 13 (кадры гоняет NSTimer, см. `:5719`).
- Появился готовый крючок: detached-режим хранит интервал в глобале
  `g_rt_swap` (`backend/sokol_shim.c:10017`).
- Пример-паттерн env-оверрайда: `EGUI_MSAA` → `sh_msaa_resolve`
  (`sokol_shim.c:843`); по нему сделан `EGUI_FPS_DIVISOR`.
- `sokol_shim.c` — единая TU: `sokol_app.h` включён с `SOKOL_IMPL`,
  приватные (`static`) функции sokol вызываются из шима напрямую —
  публичный API sokol расширять не нужно.
- Refresh rate на macOS уже есть внутри sokol:
  `_sapp_macos_max_fps()` = `[NSScreen.mainScreen maximumFramesPerSecond]`
  (`sokol_app.h:5476`); для X11 решено через `dlopen("libXrandr.so.2")`
  (без жёсткой линковки `-lXrandr`), Win32 — `EnumDisplaySettingsW`;
  Wayland — fallback 60 (как и было запланировано, отдельная задача).

## Реализация (2026-11-20, шаги 1–3)

- **sokol_app.h (микропатч)**: глобал `_sapp_egui_rt_interval` (-1 =
  следовать desc) + `_sapp_egui_interval()`; все потребители
  `desc.swap_interval` (Metal display link, NSOpenGL, iOS display
  link, D3D11 Present, WGL, EGL, GLX, Sleep-fallback) читают его;
  `_sapp_macos_mtl_start_display_link` ре-аплаит
  `preferredFrameRateRange` и на unpause-ветке.
- **shim**: `egui_cr_set_frame_divisor(n)` (клэмп ≥1 + платформенный
  re-apply: живой Metal display link, NSOpenGL best-effort, GLX; D3D11
  подхватывает сам — читает глобал на каждом Present; WGL/EGL
  применяются при (пере)создании контекста — true mid-session смена
  на detached render-потоке требует пакета, вне скоупа; Vulkan —
  present mode фиксируется при создании swapchain, делитель живёт
  только для новых окон) и `egui_cr_refresh_rate()` (macOS —
  `_sapp_macos_max_fps`, Win32 — `EnumDisplaySettingsW`, X11 —
  Xrandr через dlopen, fallback 60). `EGUI_FPS_DIVISOR=N` в шиме —
  оверрайд при старте (по образцу `EGUI_MSAA`).
- **Crystal**: `Driver::Sokol.set_frame_divisor / refresh_rate /
  energy_mode=` (+ фасад `Egui.*` в driver_selector.cr);
  `:saving` → делитель `round(refresh/30)` (60→2, 90→3, 144→5,
  160→5), `:normal`/`:game` → 1.
- Шаг 4 (`sapp_cancel_frame`, произвольные 25/50/90) — не сделан,
  по востребованности.

## Верификация (2026-11-20)

- Шим собирается в обоих бэкендах: `rake build:native` (GL) и
  `rake BACKEND=metal build:native` — чисто.
- `examples/hello` собрался и отработал 6 с под `EGUI_FPS_DIVISOR=2`
  без падений (окно убито по таймеру — exit 143).
- API-пробник `tmp/fps_api_probe.cr` (собирался против изолированной
  копии src — см. ниже): `refresh_rate: 60`, `set_frame_divisor(2)`,
  `energy_mode= :saving/:normal` переключаются, неизвестный режим
  (`:turbo`) кидает ArgumentError. Окно жило 4 с, делитель 2.
- Глазами FPS-делитель пока не проверен: запустить
  `EGUI_FPS_DIVISOR=2 ./bin/apps/hello` и сравнить плавность/нагрузку
  (заодно `:saving` из UI, когда появится переключатель).
- Нюанс на момент проверки: рабочее дерево не собирается целиком из-за
  незавершённой popup-exit-анимации (Ур.3) — `context.cr`:
  `close_popup` использует `POPUP_EXIT_MS` без префикса `Memory::`
  (в изолированной копии для пробника это чинилось одной строкой).
  К пробнику/фичей floating_fps отношения не имеет.
