# Natural scheduler везде: вывести legacy-качки планировщика в ноль

> **Статус: план.** Продолжение `plans/loop_redesign.md` §8 — detached-цикл
> (Linux/Win32) уже даёт `Egui::Runtime.natural_scheduler? = true`, но
> костыли доставки (`pump_pass`) остаются в коде и держат за собой
> legacy-путь и связку «бэкенд знает домены».

## Проблема

- `on_frame_inner` (`src/egui/driver/sokol.cr:2258-2270`) поимённо зовёт
  `AsyncDialogs.pump_pass`, `Http.pump_pass`, `Mvc.pump_pass` и
  `Driver::Base.frame_scheduler_pass` (регистрация — `pty.cr:326`).
  Бэкенд знает доменные модули — та же болезнь, что B1/B2 в
  `docs/ARCHITECTURE.md`.
- Каждый `pump_pass` дублирует один и тот же guard
  `return if natural_scheduler?`.
- Legacy-путь живёт только ради macOS (AppKit требует главный поток) и
  `EGUI_RENDER_THREAD=0` (бисекция регрессий). macOS — единственная
  платформа без natural-планировщика.

## Шаг 1 — реестр legacy-качков (дёшево, шипабельно независимо)

Один контракт на драйвере вместо поимённых вызовов:

```crystal
# src/egui/driver/base.cr
# Legacy-путь (macOS, EGUI_RENDER_THREAD=0): доменные модули ставят свои
# bounded-проходы сюда при require; natural-планировщик пропускает всё.
class_property legacy_pumps : Array(Proc(Nil)) = [] of Proc(Nil)

def self.pump_legacy : Nil
  return if natural_scheduler?
  legacy_pumps.each &.call
end
```

- Каждый домен регистрируется сам при require (по образцу
  `frame_scheduler_pass` в `pty.cr`): `dialog.cr` → `AsyncDialogs.pump_pass`,
  `http.cr` → `Http.pump_pass`, `mvc/transport.cr` → `Mvc.pump_pass`,
  `driver/pty.cr` → PTY-проход.
- `on_frame_inner` сводится к `pump_legacy` + общий `take_delivered`.
- Guard `natural_scheduler?` живёт в одном месте; из самих `pump_pass`
  убирается.
- Место под переезд в `Host#before_update` (шаг 5 аудита
  `docs/ARCHITECTURE.md`) подготовлено: перенос станет механическим.

## Шаг 2 — macOS: инверсия потоков (большой кусок, отдельная веха)

Зеркально detached-циклу:

- main-поток процесса — NSApplication (чистый ObjC-bootstrap в шиме, по
  образцу Win32 file-dialog thread в `backend/sokol_shim.c`);
- рантайм Crystal + планировщик — на pthread (потоки регистрируются в
  Boehm GC);
- FramePacket/mailbox/wake-pipe из `loop_redesign.md` §8 переиспользуются
  как есть — протокол платформенно-нейтрален.

Результат: `natural_scheduler? = true` на всех платформах.

## Шаг 3 — удалить API мёртвого пути

Когда шаг 2 принят:

- удалить `pump_pass` из `AsyncDialogs` / `Http` / `Mvc` (доставка
  `on_done` прямо в фибере — уже работает);
- удалить `frame_scheduler_pass` и регистрацию в `pty.cr`;
- `EGUI_RENDER_THREAD=0` оставить как escape-hatch для бисекции, но
  платит он только вызовом `pump_legacy` из шага 1.

## Чего не делаем

Не чиним legacy-путь poll-ом по X-fd + wake-pipe: `loop_redesign.md` §1-2
доказал экспериментально, что однопоточный цикл с блокирующим
`glXSwapBuffers` чинить бессмысленно — stall презентации всё равно
замораживает всё. Путь один: detached-цикл везде, legacy — только
отладочный режим.

## Критерий готовности

- Шаг 1: `grep pump_pass src/egui/driver/sokol.cr` пуст; все спеки зелёные;
  legacy-путь (EGUI_RENDER_THREAD=0) работает на реестре — file dialog и
  PTY-приложение живут.
- Шаг 2: macOS-билд с detached-циклом: терминал/PTY качает данные во время
  свап-стаблов, ввод не теряется.
- Шаг 3: `grep -r 'pump_pass\|frame_scheduler_pass' src/` пуст.
