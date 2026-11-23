# Отрисовка в скрытом/нефокусном окне (idle / not focused gate)

## Проблема

Каждое окно egui.cr рендерит полные кадры на каждом vsync-тике **безусловно** —
независимо от того, в фокусе ли окно, видимо ли оно, изменилось ли что-то в UI.
10 окон = 10 процессов, каждый стабильно нагружает GPU полными кадрами
60/120 Гц; скрытые окна бьются за GPU наравне с видимыми.

## Факты (проверено по кодовой базе)

- **Рендер-поток replay'ит последний пакет каждый тик безусловно**
  (`backend/sokol_shim.c:9874`): `sh_replay(g_pkt_last)` → полный проход
  всего UI + swap на каждом vsync, даже когда не пришло ни события, ни
  свежего пакета. Сделано сознательно ради composited scroll/flings
  (`sh_scroll_fling_tick`, `sokol_shim.c:9930`).
- **ICONIFIED дропается.** Sokol отдаёт `SAPP_EVENTTYPE_ICONIFIED`
  (X11: `vendor/sokol/sokol_app.h:14092`, Win32: `:10088`), но shim его не
  транслирует — в `backend/sokol_shim.c` нет ни `ICONIFIED`, ни occlusion.
  Crystal-сторона не узнаёт о минимизации; в `src/egui/driver/sokol.cr`
  есть только `window_minimize` как команда (:937), не как состояние.
- **macOS (GL, сборка по умолчанию)**: кадр гоняет 1-мс NSTimer →
  `setNeedsDisplay` → `drawRect` → полный кадр (`sokol_app.h:5719`,
  `:6529-6551`). Occlusion-гейта нет вовсе. Metal-путь формально имеет
  гейт (`_sapp_macos_mtl_is_obscured`, `sokol_app.h:6555`), но
  obscured-режим — тот же таймер на 16.7 мс (`:5474`), т.е. 60 fps в
  скрытое окно и там.
- **Linux/GNOME**: mutter перестаёт слать frame-callbacks перекрытым
  окнам, `glXSwapBuffers` заглохает (документировано в шиме:
  `sokol_shim.c:10160`, `:9771`, `:9574`). Ответ на stalled presents —
  **не пауза, а 60 Гц fallback на A-стороне** (`sokol.cr:1389-1393`):
  пока repaint run активен и acks starving, CPU-конвейер крутится на
  60 Гц даже в невидимое окно.
- **Win32**: swap в скрытое окно продолжается без троттлинга.
- Legacy-цикл (macOS/Android): `sh_frame_cb` → `g_frame()` каждый тик —
  там же полный кадр; occlusion не проверяется.
- On-demand repaint Crystal-стороны уже экономит CPU на логике
  (`frame_pending?` гейт, `sokol.cr:1458`), но R-сторона всё равно
  рисует и свапает каждый тик.
- Анимации/spinner/appear не знают о видимости и держат
  `needs_repaint?` навсегда → A-сторона тоже полноценно живёт в
  скрытом окне.

## Дизайн

Три независимых уровня, каждый можно включать отдельно:

1. **Гейт replay по свежести (главная экономия, не зависит от WM)**
   В `sh_rt_frame` рисовать `sh_replay` только когда есть причина:
   свежий пакет, живой fling/composited scroll, pending resize
   (`g_rsz_at`), pending screenshot, staging-изменения (текстуры,
   видео-кадры). Иначе — не вызывать `sh_replay` вовсе (swap sokol
   после нас; без отрисовки просто остаётся прежний кадр на экране).
   Флаг `EGUI_IDLE_NO_REPLAY=0` для A/B-отката. Внимание: некоторые
   бэкенды требуют хотя бы один pass перед своим внутренним_PRESENT
   (X11 GLX неявно свапает только после отрисовки) — проверить, что
   пропуск тика не ломает present-модель sokol (если ломает — рисовать
   пустой `sh_clear_pass` вместо replay, это на порядки дешевле).

2. **Протащить состояние окна в Crystal**
   - Транслировать `SAPP_EVENTTYPE_ICONIFIED` (и UNMINIMIZED — в
     vendored sokol это пара ICONIFIED с параметром) в существующий
     event-канал как новое `Egui::Event` или флаг на Driver.
   - macOS: подписка на `NSWindowDidChangeOcclusionStateNotification`
     и `NSWindowDidMiniaturizeNotification` в шиме (категория на view
     уже есть — см. ShPinch, `sokol_shim.c:1282`).
   - Открыть `Egui::Driver::Sokol.window_visible?` / событие
     `:occluded`, чтобы app-код и анимации могли ставить себя на паузу.

3. **Понизить A-side fallback при occlusion**
   Когда presents starving И окно известно как скрытое — fallback
   60 Гц → 5–10 Гц (достаточно для PTY/dialog-логики), полный ритм по
   событию возврата видимости. Точка: `sokol.cr:1393` (`fallback = 1/60`).

## Шаги

- [x] Гейт replay в `sh_rt_frame` (R-сторона, Linux/Win32 detached):
      unfocused/minimized → replay не чаще 1 Гц; свежий пакет и живой
      composited scroll (`g_scroll_dirty`) рисуются немедленно.
      Трекинг фокуса — в `sh_rt_event_cb` (FOCUSED/UNFOCUSED/ICONIFIED/
      RESTORED). Флаг отката не нужен: гейт привязан к событиям фокуса,
      а не к env-переменной.
- [x] Транслировать ICONIFIED/UNMINIMIZED в Crystal-состояние
      (`@@focused`/`@@iconified` + `Sokol.window_focused?`) — события
      уже шли через общий канал, добавлены константы 15/16 и кейсы в
      `translate_event`.
- [x] Legacy-путь (macOS/Android): гейт 1 fps в `on_frame` — skipped
      tick не делает никакой egui-работы, sokol перепрезентует прежний
      буфер; возврат фокуса проходит гейт сразу.
      **Фикс 2026-11-20:** первые события ввода не снимали гейт —
      колёсико над нефокусным окном клалось в `@@events`, но
      early-return откладывал кадр до 1-гц тика → фриз ~1 с на старте
      прокрутки. Теперь `@@events.empty?` в условии гейта: ожидающий
      ввод красит немедленно (та же семантика, что `events_n > 0` на
      detached-пути).
- [x] A-side fallback 60 Гц → 1 Гц при occlusion (Linux/Win32
      detached): `fallback` пересчитывается в каждой итерации цикла
      `run_detached`; реальные события ввода (колёсико, hover) всегда
      продюсируют кадр немедленно.
- [ ] Прогнать бенчи (`bench/`) и глазами ключевые окна: scroll fling,
      video, terminal, анимации — убедиться, что ни одна живая активность
      не попала под гейт.
- [ ] macOS: `NSWindowDidChangeOcclusionStateNotification` — окно,
      полностью перекрытое другим (но в фокусе по key-статусу), сейчас
      продолжает рендерить на полной ставке (фокус у macOS — key-окно,
      перекрытие фокус не снимает).
- [ ] Пауза анимаций/appear в скрытом окне на уровне app-кода (springs,
      spinner, appear — сейчас они крутятся 1 раз/с вместо честной паузы).
- [ ] Сравнить GPU/CPU на 10 окнах до/после (EGUI_FRAME_DEBUG +
      Activity Monitor), затем решить, нужен ли отдельный «深度» режим
      (полная остановка replay при occlusion).

## Риски

- Пустой тик без pass'а: у sokol (GLX/D3D) present привязан к
  frame-callback — нужен либо дешёвый clear-pass, либо проверка, что
  пропуск безопасен (Metal: конец pass'а сам презентует drawable;
  GL: swap после frame_cb — проверять по бэкендам).
- Перекрытое (не минимизированное) окно на GNOME: swap stall и так
  ломает пейсинг — гейт replay снимает и это (нечего рисовать).
- Видео/audio: видеокадры приходят как staging-опыты — должны быть в
  списке «причин рисовать», иначе картинка замрёт.
