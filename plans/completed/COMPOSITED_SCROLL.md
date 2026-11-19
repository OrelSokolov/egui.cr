# Compositor scrolling — скролл на render-потоке (как у браузера)

> Статус: этапы 0–3 реализованы (2026-11-15). Спеки:
> `spec/composited_scroll_spec.cr` (5). A/B-инвариант этапа 1
> (попиксельная идентичность при delta=0) подтверждён на offset
> 1200/2400 (AE=0) и 0 (AE = пол шума WM-декорации, 2011 px,
> одинаково в classic-vs-classic).

## Диагноз (исходная жалоба)

Под внешней CPU-нагрузкой (чужие процессы) прокрутка дёргается, тогда
как браузер остаётся плавным. Базлайн (`tmp/scroll_baseline.py`,
`bin/html/html_gallery`, wheel 12 Гц, `yes`×44 на 22 ядрах):

| фаза | pubs/s | gap p50 | gap p95 | gap max | >32 мс |
|---|---|---|---|---|---|
| idle | 85.9 | 15.4 мс | 18.2 мс | 20.3 мс | 0 |
| wheel | 59.9 | 16.7 мс | 18.4 мс | 20.2 мс | 0 |
| **wheel+load** | **41.7** | **22.5 мс** | **40.0 мс** | **66.5 мс** | **30** |

Причина: каждый тик колеса = полный кадр Crystal на main-потоке
(`produce_frame`), оффсет скролла запечён в геометрию тесселяции.
Планировщик не даёт main-потоку слот в 16-мс окне → контент-кадры
пропускаются. Браузер же обслуживает скролл compositor-потоком по
заранее растеризованным слоям — main thread не участвует.

## Решение

**Оффсет скролла становится параметром времени презентации.** Render-
поток (R) применяет его при replay — Crystal не просыпается на тик
скролла вообще; main-поток только догоняет (catch-up кадры), и под
голоданием R продолжает скроллить по overscan-запасу.

Ключевой трюк реализации: **band через clip**. ScrollArea расширяет
ambient clip на overscan (2 вьюпорта) — а clip единственное, что читают
ВСЕ куллинги (galley-строки, paint-cache захват/реплей, exml-поддеревья,
virtual-строки), поэтому band-контент остаётся растеризованным ниже
сгиба без единой правки в каждом потребителе.

### Протокол по потокам

```
A (Crystal, main)                      R (C pthread, шим)
─────────────────────────────────────  ─────────────────────────────
scroll_begin(id, window, offset,…) →   дескриптор в пакете:
  контент против clip=band               {id, window, offset, max,
  (window = viewport ∩ ambient)           band, speed, z, axes}
                                        + blockers (не-композитные
                                          синки из Memory#scroll_rects)
                                        колесо над дескриптором:
                                        applied = clamp(applied+Δ,
                                          [offset−band, offset+band]∩[0,max])
                                        событие НЕ в ring; wake(A)
read-back: egui_cr_scroll_offsets  ←    applied-таблица (id → offset)
  ДО begin_frame:                       fling: velocity из межтиковых
  offset → Memory, velocity→0,          интервалов, decay per tick
  gesture-set                           (half-life 0.12 с, стоп 15 px/s —
                                        параметры KineticScroller)
catch-up кадр: geometry по              replay: translate(applied−offset)
adopted offset → хит-тест               целыми пикселями фреймбуфера;
совпадает с экраном                     scissor внутри брекета:
                                        translate ∩ window (вложенные
                                        брекеты суммируются)
```

Авторитет: во время жеста (свежее колесо < 150 мс или жив fling)
оффсет Р-шный; после — каждый новый пакет ведёт оффсетом записи
(программные скроллы, scroll_to, thumb-drag).

### Точки в коде

| Что | Где |
|---|---|
| `ScrollBracketCmd` (begin/end, window/offset/band/z) | `src/egui/painter.cr` |
| `Painter#scroll_begin/#scroll_end`, mesh3d-fallback (брекет→Noop + reclip к window), `#scroll_layer_ids` | `src/egui/painter.cr` |
| `ScrollArea(composited: true)`, band=clip, virtual-полоса по band, гейт KineticScroller по `ctx.composited_gesture?` | `src/egui/containers/scroll_area.cr` |
| `Context#composited_gesture?/#clear_composited_gestures/#add_composited_gesture` | `src/egui/context.cr` |
| `Driver::Base#composited_scroll?` (default false — headless/legacy безопасно) | `src/egui/driver/base.cr` |
| FFI: `pkt_scroll_begin/end`, `pkt_blocker`, `scroll_offsets`, `scroll_dirty`; adoption + blockers в `produce_frame`; `frame_pending?` + scroll_dirty | `src/egui/driver/sokol.cr` |
| `SH_OP_SCROLL_BEGIN/END`, дескрипторы+blockers в пакете, replay-стек брекетов (modelview translate, scissor/mask трансяция), applied-таблица, `sh_scroll_consume` (перехват колеса в `sh_rt_event_cb`, chaining, band-clamp), `sh_scroll_fling_tick` | `backend/sokol_shim.c` |

### Гейты/фолбэки

- нет detached-потока (macOS/Android/`EGUI_RENDER_THREAD=0`) →
  `composited:` инертен, обычный путь;
- `EGUI_SDF=1` → composited выключен (SDF-инстансы вне modelview);
- Mesh3DCmd в band → брекет молча заменяется на классику (reclip);
- `EGUI_COMPOSITED_SCROLL=0` — kill-switch;
- ctrl+wheel и колёса над blockers (textarea/terminal/plot) идут
  старым путём в ring;
- скроллбар-thumb рисуется в catch-up кадрах: под голоданием
  обновляется с лагом (полиш уровня Chrome — композиторный thumb —
  отдельно).

## Приёмка (как проверять)

1. Спеки: `crystal spec spec/composited_scroll_spec.cr` — эмиссия
   брекета, band-куллинг (ряд ниже сгиба в пакете, за band — нет),
   mesh3d-fallback, гейт кинетики, инертность без драйвера.
2. Идентичность этапа 1: `python3 tmp/composited_ab.py 0 400 1200 2400`
   — AE ≤ пол шума (2011 px WM-декорации, виден и в classic-vs-classic).
3. Поведение под нагрузкой (суть жалобы): `examples/composited_scroll.cr`
   (сборка `bin/dbg/composited_scroll`), под `yes`×N крутить колесо —
   контент движется каждый vsync, `[pkt] publish` в EGUI_FRAME_DEBUG=1
   показывает редкие catch-up кадры вместо 60/с.
4. Клик-после-скролла: после композитного скролла клики попадают в
   виджеты, которые видны (adoption до begin_frame).

## Известные ограничения / следующие шаги

- twinshot-автоматизация A/B (сейчас — ручной скрипт + шум WM);
- пер-id гейт для subtree-кэша внутри band (сейчас вложенные брекеты
  реплеятся как записано — консистентно, но не оптимально);
- композиторный скроллбар-thumb на R;
- textarea/terminal (свои синки) — кандидаты на тот же механизм через
  публичный API брекетов позже;
- блокеры свежести: колёса над только-что-исчезнувшим дескриптором
  (пер-кадровая гонка id) — закрыто поколениями пакетов (prune в
  sh_rt_frame), но стоит нагрузки в тестах.
