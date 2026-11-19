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

## Статус

Не начато. Порядок: (1) → (2) → (3); (4) по востребованности.
