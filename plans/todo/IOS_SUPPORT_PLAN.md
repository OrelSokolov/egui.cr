# iOS support plan (egui.cr)

**Статус:**
- Phase 0 ✅ (arm64, Xcode 26.6 через `DEVELOPER_DIR`, SDK iphonesimulator 26.5)
- Phase 1 ✅ (`tmp/ios/phase1/` + `tmp/ios/build_phase1.sh`, оранжевый
  прямоугольник проверен пиксельно на скриншоте)
- Phase 2 ✅ (см. «Результаты фазы 2» ниже; детали патча компилятора и
  артефакты — в `tmp/ios/`)
- Phase 3 ✅ (см. «Результаты фазы 3» ниже)
- Phase 4 ✅ (см. «Результаты фазы 4» ниже; hello рендерится стабильно)
- Phase 5 — не начата (устройство, Metal, полировка — см. ниже).

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

## Phase 0 — рекогносцировка на макбуке ✅

Зафиксировано: `arm64-apple-ios17.0-simulator`, SDK
`/Applications/Xcode.app/.../iPhoneSimulator26.5.sdk`, Xcode 26.6 (активировать
через `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`,
т.к. `xcode-select` указывает на CommandLineTools). Симуляторы: iPhone 17 Pro
и др. (iOS 26.5). Компилятор: homebrew Crystal 1.20.2 + LLVM 22.1.7.

## Phase 1 — чистый C в симуляторе (проверка тулчейна) ✅

Артефакты: `tmp/ios/phase1/{main.m,Info.plist}`, `tmp/ios/build_phase1.sh`.
Скриншот `tmp/ios/phase1_shot.png` проверен пиксельно (оранжевый
прямоугольник 242/140/38 в центре). Сборка/установка/запуск без Xcode-проекта
работают.

## Результаты фазы 2 (рантайм Crystal в симуляторе) ✅

1. **Патч компилятора.** Клон Crystal 1.20.2 в `tmp/crystal-ios`, собран
   homebrew-кристаллом 1.20.2 + LLVM 22.1.7 (`make CRYSTAL=/opt/homebrew/bin/crystal
   LLVM_CONFIG=/opt/homebrew/opt/llvm/bin/llvm-config`). Патч:
   - `src/compiler/crystal/codegen/target.cr`: `def ios?`
     (`environment.starts_with?("ios")`, покрывает `ios*-simulator` и
     `ios-macabi`), `os_name` → `"darwin"` для ios, `unix?` включает ios;
   - `src/compiler/crystal/semantic/flags.cr`: флаги `darwin`+`ios` для ios-цели.
   Следствие: переиспользуются `lib_c/aarch64-darwin`, kqueue event loop,
   `_`-префикс символов — ничего из stdlib патчить не пришлось.
   Запуск: `CRYSTAL_PATH=tmp/crystal-ios/src tmp/crystal-ios/.build/crystal …`.
2. **Точка входа.** `src/crystal/system/unix/main.cr` + `src/crystal/main.cr`
   патчены: под `flag?(:ios)` entry-символ — `crystal_main_entry` (процессный
   `main` принадлежит UIKit-драйверу, кристалл запускается на фоновом
   pthread'е — планировщик Crystal не блокирует главный/UI-поток; это же
   модель для sokol-фазы).
3. **Boehm.** bdwgc v8.2.6 + libatomic_ops v7.8.0 в `tmp/ios/bdwgc`, cmake
   `-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator` →
   `build-ios-sim/libgc.a` (arm64, GC_DARWIN_THREADS с перехватом pthread).
4. **Smoke** (`tmp/ios/smoke/`): `ios_smoke.cr` + ObjC-драйвер `main.m`
   (окно с root view controller — без него UIKit убивает процесс
   NSInternalInconsistencyException'ом!) + `build_smoke.sh [--gc-none]`.
   Вывод — через NSLog с CFString-обёрткой (первый аргумент NSLog —
   NSString*, не C-строка; `puts` в ос log не попадает).
   Проверено с `-Dgc_none` и с Boehm: 10 000 аллокаций пережиты
   (`heap_size=3358720` с Boehm), spawn/sleep/channel и kqueue-таймеры
   (100 мс / 250 мс) доставлены точно по расписанию.

## Phase 3 — sokol-окно в симуляторе ✅

Артефакты: `tmp/ios/phase3/{frame.cr,main.c,Info.plist,build.sh}`.
Результаты:

1. **Патч `backend/sokol_shim.c`** (не ломает macOS-сборку — проверено):
   - платформенный выбор GL-бэкенда: `TARGET_OS_IPHONE` → `SOKOL_GLES3`
     + `SH_IOS`, иначе `SOKOL_GLCORE`;
   - все AppKit-секции (transparent, present_clear, NSCursor, window
     management, decorations, opacity, window_position, drag/resize)
     получили `&& !defined(SH_IOS)` — iOS падает в существующие no-op
     заглушки; transparent/present_clear — внутренние `SH_IOS` no-op;
   - остальные секции (detached render loop — Linux/Win32-only, X11,
     Win32) не тронуты.
2. **Точка входа** — драйвер `main.c` зовёт `crystal_main_entry` на
   главном потоке; `sapp_run` → `UIApplicationMain` (sokol UIKit-бэкенд,
   GLKView/EAGL/GLES3, свой scene delegate) — тот же «direct»-путь, что
   на macOS: кадровые коллбэки зовут Crystal-замыкания на главном потоке,
   планировщик качается через `Runtime.frame_scheduler_pass`.
3. Скриншот проверен пиксельно: центр 242/140/38 (оранжевый), петля
   идёт ровно 60 fps (CADisplayLink + vsync). Сборка нативных либ:
   `libegui_cr_sokol_ios.a` (sokol_shim + nanosvg_shim, arm64 simulator).

## Phase 4 — egui.cr hello в симуляторе ✅

Артефакты: `tmp/ios/phase4/{main.c,Info.plist,build.sh}` + `hello.o`.

1. **FreeType не потребовался**: основной стек шрифтов — чистый
   Crystal-порт (`backend/crystalfonts.cr`, freetype-cr shard); C-FFI
   FreeType — только dev-ускоритель за `C_EXTENSIONS` (выключен).
   `SystemPorts::Fonts.search_paths` darwin-ветка находит
   `/System/Library/Fonts/SFNS.ttf` (симулятор делит ФС с macOS).
2. **PCRE2** нужен (ядро egui тянет `Regex`): собран из pcre2-10.45,
   cmake `-DCMAKE_SYSTEM_NAME=iOS -DPCRE2_SUPPORT_JIT=OFF` →
   `tmp/ios/pcre2/build-ios-sim/libpcre2-8.a`.
3. Кросс-компиляция: `CRYSTAL_PATH="lib:tmp/crystal-ios/src" …
   --cross-compile --target=arm64-apple-ios17.0-simulator` —
   `examples/hello.cr` (10 МБ .o) собирается БЕЗ правок egui.cr
   (патчить пришлось только шим, фаза 3).
4. Линковка: hello.o + libegui_cr_sokol_ios.a + libpcre2-8.a + libgc.a
   + `-liconv` + фреймворки UIKit/Foundation/OpenGLES/GLKit/
   QuartzCore/CoreGraphics. Драйвер — как в фазе 3 (`crystal_main_entry`
   из `main`).
5. Рендер подтверждён пиксельным анализом скриншотов: тёмная тема,
   окно с ~12 текстовыми строками (заголовок, «Hello World!», кнопки,
   CollapsingHeader, FPS/GC-панель). Стабильно 30+ с, 60 fps.
   Маппинг тач→мышь — upstream-код sokol_app; в симуляторе без
   `simctl tap` автоматически не проверен.

**Известные iOS-особенности (Phase 5):**
- `EGUI_SHOT` (отладочный glReadPixels-захват, `sh_shot_legacy`) валит
  приложение на следующем кадре (assert в `sg_begin_pass` — чтение
  после `sg_commit` ломает GL-состояние на GLES3). Обычный рендер не
  затрагивает; при необходимости — guard `SH_IOS` в `sh_shot_legacy`.
- Ранние кадры идут в поверхность 960×1440 (до layout'а GLKView на весь
  экран); после resize рендер пересчитывается сам.
- `Info.plist` без scene-manifest: sokol-конфигурация сцены берётся из
  делегата (warning в логе, не блокер).
- **`UILaunchScreen` обязателен** в `Info.plist` (пустой `<dict/>`
  достаточно): без него UIKit даёт legacy-геометрию 320×480 pt.
- **Scissor-баг (вылечен)**: `sgl_draw()` оставляет `GL_SCISSOR_TEST`
  включённым с последним clip-ректом кадра; на GLES3 clear в
  `sg_begin_pass` обрезается этими ножницами → чёрный фон и «призраки»
  прошлых кадров. Фикс в `egui_cr_begin_pass` (шим): под `SH_IOS` перед
  `sg_begin_pass` — `glDisable(GL_SCISSOR_TEST); glScissor(0,0,w,h);`.
- **Тач→мышь (добавлено)**: upstream sokol_app на iOS шлёт только
  TOUCHES_*; шим синтезирует MOUSE_MOVE/DOWN/UP из них (BEGAN/MOVED/
  ENDED/CANCELLED), координаты — fb-пиксели. Кристалловский путь делит
  на `dpi_scale` сам.
- **Quit (добавлено)**: UIKit-бэкенд sokol_app никогда не проверяет
  `quit_requested` (кадры гонит CADisplayLink, quit-пути нет), поэтому
  `sapp_quit()` — no-op. `egui_cr_request_quit` под `SH_IOS` делает
  `exit(0)` (программный выход запрещён App Store, но для dev-билда —
  ожидаемое поведение).
- **Файловые диалоги (открытие работает)**: OpenFileDialog на iOS идёт
  через `UIDocumentPickerViewController` (системный браузер «Файлы»):
  шим `egui_cr_docpick_start/done/take/free`, модалка над
  view-контроллером sokol, `asCopy:YES` — система копирует выбранный
  файл в песочницу (путь читаем навсегда, security-scope не нужен,
  записей в Info.plist не требуется; селектор —
  `initForOpeningContentTypes:asCopy:`, iOS 14+, фреймворк
  UniformTypeIdentifiers в линковке). Crystal-сторона — native runner
  из `Dialogs.use_native_dialogs` (как win32), worker-файбер
  sleep-poll'ит `docpick_done` — блокируется только файбер, кадры
  рендерятся. Save/pick_folder на iOS пока fail-fast nil (нужен export-
  picker + security-scope запись).
- **Клавиатура (ввод работает)**: тап по текстовому полю → egui-фокус
  → `Focus#wants_text_input?` (ежекадровый флаг от TextEdit/TextArea) →
  бэкенд зовёт `egui_cr_show_keyboard` (sokol's hidden UITextField →
  системная клавиатура; ввод приходит CHAR/KEY-событиями, пробел
  синтезируется из KEY_DOWN(Space) — делегат sokol не шлёт CHAR для
  c <= 32). Тап мимо поля → `Response#clicked_elsewhere?` →
  `focus.clear` → клавиатура убирается (Esc тоже). Пример:
  `examples/text_input.cr` (автофокус при старте; сборка под сим:
  `tmp/ios/phase4/build_text.sh`, bundle `cr.egui.textinput`).
  Грабли симулятора: при включённом «Connect Hardware Keyboard» экранная
  клавиатура не показывается, хотя фокус есть (отключение требует
  ребута Simulator.app). Канвас НЕ сжимается под клавиатуру
  (keyboard_resizes_canvas в scene-режиме меряет экран, а не фрейм
  view) — текстовые поля держать вверху.

**Известные macOS-особенности (после мержа ios):**
- Флейковый стартовый крэш на macOS 26 (не iOS): NSOpenGLView
  принудительно layer-backed, и `_NSOpenGLViewBackingLayer.display`
  иногда исполняется на фоновом GCD-потоке ('DEFAULT-N'). Вкус 1
  (вылечен): GL-вызовы без текущего контекста → SIGSEGV по NULL
  TLS-контексту libGL (адрес 0x338) при первом `sg_make_image` —
  фикс: self-heal ребинд `sh_gl_rebind()` в шиме
  (begin_pass/end_pass/atlas_create перепривязывают контекст, если
  он не текущий; контекст общий, бинд с любого потока валиден).
  Вкус 2 (остался, ~10% запусков): порча autorelease pool в
  `_sapp_macos_frame` (SIGSEGV 0x10 в objc_autoreleasePoolPop) и
  SIGTRAP в `NSGraphicsContext restoreGraphicsState` — это
  внутренний небаланс самой AppKit-машины layer'а на GCD-потоке;
  патчи drawRect/timer/лока не лечат (перепробованы и откачены).
  Полное лечение — Metal-рендерер (см. Phase 5), на GLES/GLCORE
  платформы не влияет. Частота до фиксов была ~20-50%; после —
  hello ~10%, чаще у приложений с постоянным request_repaint
  (text_input с мигающим каретом — каждая перерисовка инвалидирует
  layer и повышает шанс GCD-display).

## Phase 4b — системные порты: паритет с android-system-ports ✅

Зеркально фазе 7 Android-плана: каждый системный порт, который есть у
Android-ветки, работает и на iOS (`src/egui/system_ports/ios.cr` —
UIKit-мост вместо JNI; тот же паттерн доставки «результат из ОС падает
в статику, `#pump` в `Sokol#on_frame` (рядом с Android-ring) доставляет
между кадрами», но без мьютекс-ринга — приложение однопоточное,
callback'и UIKit приходят между кадрами).

- **clipboard**: sokol на iOS не имеет буфера → `UIPasteboard` в шиме
  (`egui_cr_ios_clipboard_set/get`), ClipboardPort ветвится как на
  Android.
- **MessageBox**: `UIAlertController` над `_sapp.ios.view_ctrl`;
  info/warning/error — один OK; confirm — OK+Cancel, ответ через
  статику `egui_cr_ios_msgbox_take` → `Ios.pump` → callback;
  `AsyncDialogs.note_delivered` форсирует полный кадр (добавлен и в
  Android-pump — там confirm-ответы тоже не поднимали кадр).
- **OpenUrl**: `[[UIApplication sharedApplication] openURL:]` без
  canOpenURL (требует LSApplicationQueriesSchemes; без handlers система
  сама сообщает). RevealInFolder/FileOpen — false (нет файлового
  менеджера для песочницы).
- **Диалоги**: docpick получил режимы — open (asCopy, как раньше), save
  (export-пикер: пустой temp-файл с default_name система ПЕРЕНОСИТ в
  выбранное место — колбэк получает путь; последующая запись может
  требовать security scope), folder (`public.folder`, asCopy:NO).
  Путь через AsyncDialogs worker-fiber (sleep-poll), как open.
  Грабли: `[UTType folder]` (классовое свойство из категории
  UTCoreTypes.h, объявление не видно нашему TU — компилятор
  предупреждал «+folder not found») ронял процесс с SIGSEGV при
  первом же вызове в симуляторе. Фикс: `[UTType typeWithIdentifier:
  @"public.folder"]` (тот же UTI, обычный объявленный метод); тот же
  класс риска — fallback `[UTType data]` в open — заменён на
  typeWithIdentifier:@"public.data". Первый авто-прогон folder был
  ЛОЖНЫМ PASS: процесс падал, а светлый скриншот (спрингборд после
  крэша) принимался за пикер — после фикса модальные режимы
  проверяются и пиксельно, и живостью процесса (launchctl).
- **UserDirs**: без правок — `flag?(:darwin)` истинен на iOS, а
  ENV["HOME"]/Documents/Library в песочнице совпадают с нужным.
- **read_uri_text**: не нужен — пикер asCopy кладёт файл в песочницу,
  обычный `File.read`.
- **Контекстное меню текста** (Copy/Cut/Paste/Select All) —
  кроссплатформенное из android-ветки, работает поверх clipboard-порта.
- **Нотификации в foreground**: iOS по умолчанию глотает баннеры, пока
  приложение активно — шим ставит UNUserNotificationCenterDelegate
  (`willPresent` → `.banner|.sound`), и первая нотификация теперь
  уходит только после выдачи разрешения (auth-then-fire; раньше она
  молча терялась в гонке с системным запросом). Проверено: баннер
  виден поверх активного приложения и авто-скрывается (два прогона,
  яркая плашка y=200-360 на скриншоте через 2с после запуска).
  `simctl privacy grant/reset notifications` в этом рантайме запрещён
  («Operation not permitted») — состояние разрешения только через
  реальный системный запрос.

Демо: `examples/ios_demo.cr` (зеркало `android_demo.cr` по секциям) +
`tmp/ios/phase4/build_demo.sh` (бандл `cr.egui.iosdemo`; Info.plist
копировать из Info_demo.plist, не тащить исходное имя).

Иконка на домашнем экране: в ручном бандле нет asset-catalog —
белый плейсхолдер. Схема: `CFBundleIcons → CFBundlePrimaryIcon →
CFBundleIconFiles` в Info.plist + PNG в корне бандла (AppIcon60x60@2x/
@3x, 120/180 px, генерятся sips из assets/icon.png при сборке).
Проверено пиксельно: 4×4-отпечаток цвета иконки находится на
домашнем экране после установки (позиция свежеустановленного
приложения).

Верификация без тапов (simctl не умеет инъекцию тачей, accessibility
закрыт): `tmp/ios/phase4/demo_auto.cr` — ENV["EGUI_AUTO"] дёргает порт
на первом кадре; булевы режимы красят панель в зелёный/красный,
модальные проверяются по системному UI на скриншоте
(`check_shot.py`). Результаты (iPhone 17 Pro, simulator):
clipboard PASS (зелёная панель, раундтрип UIPasteboard), url PASS
(Safari открылся, процесс mobilesafari жив), msgbox PASS (белый алерт
~185 на затемнённом 18 фоне), confirm PASS (тот же алерт),
open/save/folder PASS (Files-пикер, mean 252, процесс жив — folder
перепроверен после фикса крэша; изначальный PASS был ложным). Спеки:
665 examples, 0 failures (3 ошибки font_cuts —
pre-existing на b54289e, окружение Noto Sans).

## Phase 5 — устройство и полировка (не начата)

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
