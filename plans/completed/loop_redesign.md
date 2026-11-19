# Редизайн кадрового цикла — разделение логики и презентации

> **Статус: реализовано** (шаги 1–4 плана §5; шаг 5 — опциональная вторая
> X-connection для ввода — не делался). Фактические отличия реализации от
> плана — в §8.

Почему окно может «замереть» на секунду при живом приложении, что не так с
текущим циклом и какой цикл должен его заменить. Диагноз опирается на
инструментальный лог зависания (h2term.cr/tmp/h2term-live.log); ссылки на
файлы/строки указывают на текущий код.

TL;DR: правильного однопоточного цикла с блокирующим `glXSwapBuffers` между
очисткой ввода и логикой не существует — это уже доказал экспериментально
выпиленный adaptive present. Единственный корректный фикс — разделение
владения: весь Crystal (планировщик, логика, PTY-фиберы) на main-потоке,
отдельный C-поток в шиме владеет X-connection + GLX-контекстом + свапом.
Тогда блокирующий present деградирует из «замороженного окна» в «просадку
FPS на экране» при живых вводе, логике и PTY.

## 1. Диагноз по данным

Инструментированный прогон h2term (с включённой затем выпиленной
телеметрией кадров) показал: во время каждого «зависания»

```
[frame] 1.529 SLOW full frame: 1001ms [pumps 0ms begin 0ms update 1ms tessellate 0ms paint+swap 1000ms]
[loop] adaptive present: swap stalled 1002 ms -> swap_interval 0
[frame] 2.100 frame GAP 1572ms (swap/C-loop stall)
```

— все 40 SLOW-кадров одинаковы: `update` 0–1 мс, `pumps` 0 мс, **весь
секундный stall — внутри `glXSwapBuffers`** (XWayland/mutter перестаёт
присылать frame events → vsync-свап ждёт таймаут ~1 с). Приложение (и тем
более модалки — они рисуются в `update`, занимающем 1 мс) оправдано
полностью.

Усугубляющие факторы окружения: Mesa на Xe KMD (experimental-предупреждение
в том же логе), `transparent: true` = depth-32 ARGB-визуал, принудительный
`LIBGL_DRI3_DISABLE=1` в шиме (backend/sokol_shim.c:98 — workaround
мертвого зависания на 0% CPU при wiggle, оставлен) → обмен буферами через
медленный DRI2.

## 2. Что структурно не так в текущем цикле

Цикл — `vendor/sokol/sokol_app.h:14341`, весь на одном OS-потоке:

```
while (!quit) {
    XPending/XNextEvent      // 1. ввод — только между кадрами
    _sapp_linux_frame()      // 2. frame_cb → on_frame (src/egui/backend/sokol.cr:781):
                             //    begin → app.update → end_frame → paint_frame (sgl_*) → commit
    glXSwapBuffers           // 3. МОЖЕТ БЛОКИРОВАТЬ ~1с
    XFlush
}
```

Три дефекта:

1. **Один поток владеет четырьмя работами**: ввод, логика, GPU-сабмит,
   блокирующий present. Пока свап ждёт композитора — не читаются X-события
   (окно «мёртвое» для пользователя), не работает ничего другого.
2. **Инвертированный контроль**: цикл принадлежит sokol (C), планировщик
   Crystal — гость. Отсюда костыли `Session#evented_pass` (бounded-pass
   ~1 мс select на кадр, src/egui/terminal/pty.cr:166) и
   `AsyncDialogs.pump` — PTY-ридеры физически не могут разбудить UI, пока
   UI сам не «зайдёт» в планировщик.
3. **`request_repaint` — флаг, который некому читать**, пока поток стоит в
   свапе: wakeup-иерархия замкнута через единственный поток.

## 3. Целевая архитектура: два потока, strict ownership

Схема — как у alacritty/kitty: логика отдельно, презентация отдельно.

```
main-поток (A) — ВЕСЬ Crystal (GC живёт здесь; других вариантов у Crystal нет)
  планировщик работает естественно, без evented_pass
  ┌─────────────────────────────────────────────────────┐
  │ loop {                                               │
  │   events = drain(input_pipe)      # фибер-блокировка │
  │   if events/repaint/resize/animating?               │
  │     ctx.begin_frame; app.update; draw_list = end_frame│
  │     mailbox.publish(draw_list, texture_deltas)      │
  │   else                                                │
  │     sleep_until(next_deadline)     # epoll: PTY, таймеры│
  │ }                                                     │
  └─────────────────────────────────────────────────────┘
        ▲ input ring + wake pipe        │ FramePacket (latest-wins)
        │                               ▼
render-поток (R) — pthread в шиме, ЧИСТЫЙ C
  (по образцу уже существующего Win32 file-dialog thread)
  ┌─────────────────────────────────────────────────────┐
  │ for (;;) {                                            │
  │   poll(x11_fd, wake_pipe, vsync_tick);                │
  │   while (XPending) { XNext → tuple → ring; write(A_wake); } │
  │   packet = take_latest(mailbox);   // старые дропаются│
  │   if (packet) { texture deltas; replay; glXSwapBuffers; } │
  │   else if (repaint_flag) { replay_last; swap; }      │
  │ }                                                     │
  └─────────────────────────────────────────────────────┘
```

Эффект на сценарии со stall'ом: свап встал на 1 с → на экране стоп-кадр,
но PTY качается, ввод буферизуется, `update` продолжает бегать; когда
композитор отпустил — R презентует самый свежий кадр, пропустив устаревшие.
«Зависание» становится «просадкой FPS».

## 4. Протокол между потоками

- **Input.** R уже сегодня переводит X-события в плоские tuple
  (`sh_event_cb`, backend/sokol_shim.c:71). Дальше они идут в ring +
  запись в pipe, зарегистрированный в планировщике A. Весь переводческий
  код `on_event` (src/egui/backend/sokol.cr:720) остаётся Crystal-кодом
  на A, без изменений логики.
- **FramePacket**: `{fb_w, fb_h, ppp, clear, vertex/index-буферы, draw
  calls (pipeline, texture, clip), texture deltas}`. Заменяет текущий
  replay `PaintCmd → sgl_*` (src/egui/backend/sokol.cr:959) тесселяцией в
  плоский draw list на стороне A — это же архитектура upstream-egui
  (epaint → tessellator → mesh → renderer), т.е. движение вперёд, а не
  вбок.
- **Texture ops.** `SokolTextureRegistry` и атлас глифов
  (`AtlasFonts#touch/#flush` — растеризация и так CPU-side на A)
  превращаются в очередь delta-операций в пакете (`sg_update_image`,
  `make`, `destroy`); GL-вызовы делает только R. Idle-кэш последнего
  кадра (src/egui/backend/sokol.cr:818) живёт на R как replay_last.
- **`request_repaint`**: флаг + запись в wake pipe — работает из любого
  фибера на A.
- **Размер окна/DPI**: R кладёт в input-пакет; A больше не поллит
  `sapp_width` посреди update.
- **Курсор/clipboard/заголовок окна**: маленький command-mailbox A→R
  (X-вызовы на connection R; `XInitThreads` уже вызван,
  sokol_app.h:14297).
- **Окно создаёт R** (свой connection/GLX-контекст); A о нём знает только
  по размерам из пакетов.

## 5. Порядок миграции (каждый шаг шипабельный)

1. **Вернуть телеметрию кадров насовсем** (`SLOW full frame`, `paint+swap`
   — код уже написан в tmp/sokol-resize-revert-backup.patch, вернуть без
   adaptive-present).
2. **Вынести X/GL-цикл в pthread шима**; `frame_cb`/`event_cb` становятся
   C-only (tuple → ring → pipe). Main-поток получает естественный
   планировщик → **удалить `evented_pass` и `AsyncDialogs.pump` целиком**
   (потребует шага 3 для отрисовки, поэтому шаги 2–3 делаются парой).
3. **Тесселяция в плоский draw list на A + replay на R** — основной
   камень, один раз.
4. **Texture delta-протокол** (атлас глифов + Svg-кеш растеризации).
5. Опционально: **вторая X-connection для ввода на A** — event masks
   нескольких клиентов на одном window объединяются протоколом X11;
   тогда даже во время stall'а свапа ввод обрабатывается с нулевой
   задержкой. До этого ввод ждёт разблокировки R (латентность, но не
   потеря — ring копится).

## 6. Оговорки и риски

- Crystal-код — только на main-потоке (GC/Boehm); R — чистый C без единого
  вызова Crystal. Паттерн не новый: Win32 file-dialog thread в шиме уже
  так живёт (backend/sokol_shim.c, `egui_cr_file_dialog_*`).
- Drag окна через XGrabPointer идёт на connection R — события всё равно
  прилетают в input-ring A.
- Синхронные запросы к clipboard из A — через mailbox с ответом
  (семафор), либо вторая connection на A (шаг 5).
- macOS/Win32 первое время остаются на старом пути (`#ifdef` в шиме),
  портируются по готовности протокола.
- Wayland-native бэкенд (EGL вместо GLX/XWayland) снял бы первопричину
  стаблов у mutter — отдельный проект; предлагаемый цикл корректен
  независимо от драйвера, потому что гарантирует: ЛЮБОЙ блокирующий вызов
  present не замораживает приложение.

## 7. Критерий готовности

Воспроизведение исходного сценария (прозрачное окно, XWayland/mutter,
свап-стабл ~1 с): до — замерзшее окно, ввод и PTY стоят; после — стоп-кадр
на экране не дольше stall'а, PTY-данные продолжают обрабатываться, ввод
накапливается и обрабатывается сразу после разблокировки. Плюс: телеметрия
кадров в репо навсегда.

## 8. Как реализовано

Схема — в соответствии с §3/§4: C-pthread в `backend/sokol_shim.c`
(секция `#if defined(_SAPP_LINUX)`) владеет X-connection/GLX/свапом;
весь Crystal — на main-потоке (`run_detached` в
`src/egui/backend/sokol.cr`). FramePacket — плоский opstream
(scissor/pipe/tex/verts) + pre/post-списки текстурных операций,
latest-wins mailbox. События — ring на 8192 + wake-pipe; X-вызовы
(main-поток → render-поток: заголовок/курсор/clipboard/окно) — командный
mailbox, синхронные запросы через condvar с таймаутом 2 с. Естественный
планировщик — `src/egui/runtime.cr` (`Egui::Runtime.natural_scheduler?`).

Отличия от исходного плана, выяснившиеся при реализации:

- **Pacing по ack render-потока.** Вместо жёсткого cap 1/120 с render-поток
  шлёт байт `SH_WAKE_PRESENT` после каждого тика; main-поток ждёт его как
  doorbell (`pipe.read_timeout`, busy-fallback 1/60 с при стабле). FPS
  следует частоте дисплея (59–66), а не упирается в искусственный кап.
- **Дедуп при splice текстурных операций.** Когда свежий пакет вытесняет
  невзятый старый, их pre/post-списки сливаются по id атласа; при
  коллизии побеждает операция НОВОГО пакета, ресурс старой освобождается.
  Обратный порядок (как напрашивается) терял свежие UPDATE атласа под
  старыми CREATE — глифы пропадали/белые квадраты.
- **`evented_pass`/`AsyncDialogs.pump` не удалены, а нейтрализованы.**
  `pump` переименован в `pump_pass`, при natural-планировщике — no-op
  (доставка on_done прямо в фибре); legacy-путь (macOS,
  `EGUI_RENDER_THREAD=0` на Linux/Win32) продолжает их использовать.
  `evented_pass` — no-op при natural_scheduler.
- **Откат на старый путь** — env `EGUI_RENDER_THREAD=0`: тот же бинарь
  работает однопоточно (бисекция регрессий, платформы без нового цикла).
- Телеметрия (шаг 1): `EGUI_FRAME_DEBUG` (кадровые логи, `[loop] glx_swap
  took N ms`), `EGUI_WATCHDOG`, `EGUI_NOVSYNC`, `EGUI_SHOT=dir` —
  PPM-захват кадров через glReadPixels.

Портирование на Win32: detached-цикл больше не Linux-only. Ядро секции
шима собрано на портативных примитивах — поток (pthread / CreateThread),
mutex+condvar с timed wait (pthread / SRWLOCK + CONDITION_VARIABLE),
relaxed-атомики (C11 stdatomic / Interlocked-интринсики: stdatomic в MSVC
требует /experimental:c11atomics), doorbell (pipe2 / TCP-loopback-пара из
WSA_FLAG_OVERLAPPED-сокетов — анонимные пайпы Windows не умеют overlapped
IO, а планировщик Crystal на win32 — IOCP по сокетам). Рендер-поток
владеет окном и WGL-контекстом (штатная модель sokol_win32: окно и message
loop живут на создавшем их потоке); window-management вызовы из A идут тем
же командным mailbox. macOS остаётся на legacy-пути: AppKit требует
главный поток процесса, на котором живёт планировщик Crystal (инверсия
потоков — отдельный проект).

Тогда же закрыт «чёрный кадр» старта: sokol мапит окно до init_cb
(`_sapp_frame` зовёт init внутри первого тика), а до первого пакета R
презентовал неинициализированный framebuffer. Теперь R до первого пакета
каждый тик делает clear-пасс в цвет темы (`sh_clear_pass`); legacy-путь
презентует фон сразу после gfx-инициализации (`egui_cr_present_clear`:
SwapBuffers на Win32, flushDrawing на macOS; на X11 — background pixel
окна ставится в pre-map hook). Цвет фона постится в бэкенд до создания
окна (`Sokol.run` → ранняя `set_clear_color` из темы приложения).

Проверка. Все спеки `spec/*_spec.cr` зелёные. Прогон terminal при скрытом
окне (каждый present стаблится ~1 с): за 25 с — 1548 публикаций кадров
при 23 present; `[pkt] publish` идут непрерывно до/после/во время
`[loop] glx_swap took 1001 ms`, событие ввода доставлено на 1.092 с —
логика и ввод живут во время стабла, на экране стоп-кадр. Визуально
hello/terminal сверены покадрово с legacy-путём (EGUI_SHOT): текст, атлас,
таб-титул промпта — без регрессий. Интерактивный ввод во время стабла
отдельно не проверялся (в окружении нет инструмента инъекции ввода).
Win32-ветки шима проверены компиляцией (mingw-w64), кристаллическая
сторона — cross-compile (`--target x86_64-pc-windows-msvc`); запуск на
Windows — на машине с MSVC (Rakefile#msvc).
