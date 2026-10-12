# iOS support plan (egui.cr)

**Статус:** ничего не начато. Этот документ — handoff для сессии на MacBook с
iOS-симулятором. Самодостаточный: весь контекст ниже.

**Цель:** запустить egui.cr-приложение в iOS-симуляторе, затем на устройстве.
Порядок: сначала чистый C, потом рантайм Crystal, потом sokol, потом egui.cr.

## Отправные факты (проверено в этой сессии)

1. **GC писать свой не нужно.** Андроид-порт
   [OrelSokolov/crystal-android-hello-world](https://github.com/OrelSokolov/crystal-android-hello-world)
   (форк HertzDevil) использует обычный Boehm: bdwgc v8.2.2 кросс-компилируется
   NDK-шным cmake в `libgc.a`, линкуется `-lgc`. Никакого кастомного GC.
   Точка смены бэкенда в stdlib — `tmp/crystal-1.21.0/src/gc.cr:140`:
   `{% if flag?(:gc_none) %} require "gc/none" {% else %} require "gc/boehm" {% end %}`.
   Т.е. `-Dgc_none` доступен как аварийный режим (ничего не освобождает).

2. **libevent не блокер.** В Crystal 1.21 есть нативные циклы:
   `tmp/crystal-1.21.0/src/crystal/event_loop/{kqueue,epoll/iocp/io_uring}.cr`,
   libevent — лишь один из бэкендов. На iOS есть kqueue. Андроид-репо
   пришлось собирать libevent только потому, что оно на Crystal 2023 года.

3. **sokol уже умеет iOS.** `vendor/sokol/sokol_app.h` содержит UIKit-бэкенд:
   на iOS доступны `SOKOL_METAL` (MTKView, CoreGraphics) и `SOKOL_GLES3`
   (GLKit/EAGL). GLES3 на iOS объявлен deprecated, но работает — начинаем с
   него, Metal потом. Sokol-рендер egui от бэкенда не зависит.

4. **Rakefile уже знает objc-ветку.** Для macOS `sokol_shim` уже компилируется
   как Objective-C (Cocoa/NSOpenGL), см. `Rakefile` ~строки 72–75. iOS-ветка
   будет аналогичной.

5. **Компилятор — главная неизвестная.** Андроид-репо требует сборку Crystal
   с коммитом HertzDevil (таргет `aarch64-linux-android`). Для iOS нужен
   аналогичный пласт: тройка `arm64-apple-ios-simulator` /
   `arm64-apple-ios` в компиляторе. Возможные проблемы: дефолты libc,
   выбор event loop по платформе, PIC. См. фазу 2.

## Что умирает на iOS

- pty/fork/exec — `bin/terminal` и pty-бэкенд (`libegui_cr_pty.a`,
  `backend/pty_shim.c`) не переносятся.
- части `sysinfo` (может собраться, может нет — проверять).
- Пути окружения: HOME недоступен, свои контейнеры — всё через Apple-фреймворки.

## Phase 0 — рекогносцировка на макбуке

```bash
uname -m                      # arm64 (Apple Silicon) => симулятор arm64; x86_64 => симулятор x86_64
xcodebuild -version
xcrun simctl list devices available | head -20
crystal --version             # стоит ли 1.21; исходники в tmp/crystal-1.21.0
llc --version | grep -i ios   # какие iOS-тройки поддерживает LLVM кристалла
```

Зафиксировать: тройку симулятора (например `arm64-apple-ios17.0-simulator`),
SDK (`xcrun --sdk iphonesimulator --show-sdk-path`).

## Phase 1 — чистый C в симуляторе (проверка тулчейна)

Минимальное UIKit-приложение на C/objc без Xcode-проекта:

- `main.m`: `UIApplicationMain` + AppDelegate с `window` + root view
  controller, рисующий цветной прямоугольник через `UIView`.
- Сборка:
  ```bash
  clang -target arm64-apple-ios17.0-simulator -isysroot $(xcrun --sdk iphonesimulator --show-sdk-path) \
    -fobjc-arc main.m -o MyApp -framework UIKit -framework Foundation
  ```
- Бандл: каталог с `MyApp`, `Info.plist` (минимальный: CFBundleIdentifier,
  CFBundleExecutable, UIApplicationSceneManifest не обязателен для простого случая).
- Запуск: `xcrun simctl boot <device>; xcrun simctl install booted <bundle>; xcrun simctl launch booted <bundle-id>`.
- Скриншот для проверки: `xcrun simctl io booted screenshot /tmp/ios1.png`.

**DoD:** цветной прямоугольник на скриншоте. Это доказывает, что умеем
собирать/ставить/запускать без Xcode-проекта.

## Phase 2 — рантайм Crystal в симуляторе

Цель: Boehm + файберы + kqueue + (опц.) pcre2 под симулятором.

1. **Boehm:**
   ```bash
   git clone -b v8.2.6 https://github.com/ivmai/bdwgc.git && cd bdwgc
   git clone -b v7.8.0 https://github.com/ivmai/libatomic_ops.git libatomic_ops
   cmake -B build -DCMAKE_SYSTEM_NAME=iOS \
     -DCMAKE_OSX_SYSROOT=iphonesimulator -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
     -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF
   cmake --build build   # => build/libgc.a
   ```
2. **pcre2** (нужен, только если тянется `Regex`; собрать на всякий случай,
   как в андроид-репо: cmake `-DCMAKE_SYSTEM_NAME=iOS`, `PCRE2_SUPPORT_JIT=OFF`
   — JIT в iOS-процессе под W^X может не работать):
   аналогично, получаем `libpcre2-8.a`.
3. **Кросс-компиляция** smoke-программы:
   ```crystal
   # smoke.cr: аллокации в цикле + GC.stat / spawn + sleep + канал
   ```
   ```bash
   crystal build --cross-compile --target=arm64-apple-ios17.0-simulator -Duse_pcre2 -o smoke smoke.cr
   # печатает команду линковки; линковать clang'ом симулятора + libgc.a (+pcre2)
   ```
   Если компилятор отвергает тройку или выбирает неверный event loop —
   смотреть патч HertzDevil для Android (ссылка в README андроид-репо) и
   делать зеркальный для iOS: mapping тройки, `flag?(:ios)`, дефолт kqueue
   вместо libevent. Исходники компилятора: `tmp/crystal-1.21.0`.
4. Полученный `.o` влинковать в бандл фазы 1 (main.m вызывает crystal-main:
  символ `main` кристалла переименовать/обернуть, напр. через `wmain`-подобный
  shim: в андроид-репо точка входа — `ANativeActivity_onCreate`, у нас будет
  обычный вызов из `application:didFinishLaunchingWithOptions:`).
5. Вывод — в `os_log` (`NSLog`), читать `xcrun simctl spawn booted log stream`.

**Изоляция сбоев:** сначала `-Dgc_none` (проверяет всё, кроме Boehm), затем с
Boehm. Если падает только Boehm — смотреть `GC_set_max_heap_size`, win-стиль
ограничения роста кучи (для устройства это станет обязательным из-за jetsam).

**DoD:** логи показывают: N аллокаций пережили сборку (память не растёт),
spawn/sleep отработали, событие по таймеру пришло через kqueue-цикл.

## Phase 3 — sokol-окно в симуляторе

1. Скомпилировать `vendor/sokol/sokol_app.h` (+ `sokol_gfx.h`, `sokol_gl.h`)
   как ObjC: `-x objective-c -fobjc-arc -DSOKOL_GLES3`, таргет симулятора.
   `backend/sokol_shim.c` сейчас заточен под X11/Cocoa — нужна iOS-ветка
   (`#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE`): main-петля отдаётся
   UIApplicationMain + CADisplayLink, кадр зовёт существующий
   `sh_frame_cb`-путь (как в Cocoa-ветке).
2. Rakefile: новая ветка сборки `sokol_shim` для iOS по образцу macOS-ветки
   (~строки 72–75, 154–156): компиляция .m, `-isysroot iphonesimulator`.
3. Нарисовать очищенный цветом кадр через `sg_apply_viewport + sg_begin_pass`.

**DoD:** sokol-окно с чистым цветом/треугольником в симуляторе, скриншот.

## Phase 4 — egui.cr hello в симуляторе

1. FreeType для симулятора (cmake, `-DCMAKE_SYSTEM_NAME=iOS`; или взять
   freetype-cr и его sysroot-сборку — как собирается сейчас под macOS,
   см. `Rakefile` ~154–156).
2. Собрать нативные либы: `libegui_cr_sokol.a` (sokol_shim + nanosvg_shim как
   обычно) + freetype — всё таргетом симулятора.
3. Кросс-компилировать `examples/hello.cr` тем же `--cross-compile`, влинковать
   в бандл. Волокна рантайма поверх CADisplayLink-петли: убедиться, что
   блокирующий стиль главного цикла (как на десктопе) заменяется на
   «один кадр за тик display link» — при необходимости через тот же механизм,
   что в Cocoa-ветке шима.
4. Скриншоты: `xcrun simctl io booted screenshot`; сравнить с десктопным
   `bin/hello`.

**DoD:** hello.cr рисует текст и виджеты в симуляторе, реакция на тач
(маппинг touch → mouse-события sokol уже есть в sokol_app).

## Phase 5 — устройство и полировка

- Таргет `arm64-apple-ios` (устройство), подпись, provisioning.
- Jetsam: ограничить кучу Boehm (`GC_set_max_heap_size`,
  `GC_set_free_space_divisor`) — иначе ОС будет убивать приложение.
- Metal вместо GLES3: переключить `SOKOL_METAL`, скомпилировать шейдеры под
  Metal (`sokol-shdc`), остальное без изменений.
- Отключить/заэкранировать непереносимое: pty-бэкенд, fork/exec-пути,
  `sysinfo`-зависимости.
- `widgets_gallery` как приёмочный тест; завести `examples/ios_hello` с
  минимальным бандлом и Rake-задачей `rake ios:sim`.

## Альтернатива, если симулятор закапризничает

Mac Catalyst: тройка `arm64-apple-ios-macabi` — UIKit-приложение, работающее
как обычный macOS-процесс. Промежуточный шаг без симулятора и подписи:
тот же UIKit-код, но обычная память/процессы. Пригодится для отладки
рантайма (фаза 2) при проблемах с симулятором.

## Известные риски

- **Тройка не принимается компилятором** — самый вероятный блокер; лечится
  патчем компилятора по образцу Android-коммита.
- **Boehm под iOS-устройством**: jetsam, W^X. В симуляторе это не проявится —
  не считать фазу 2 доказательной для устройства.
- **pcre2 JIT** под iOS не работает — собирать с `PCRE2_SUPPORT_JIT=OFF`.
- **Event loop выбор**: если stdlib по флагу `ios` выберет libevent —
  форсировать kqueue патчем (см. фазу 2, п.3).
