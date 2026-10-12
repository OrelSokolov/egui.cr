# Android-порт egui-cr

## Цель

Запуск egui-cr приложений на Android как нативного `NativeActivity`-APK:
arm64-v8a `.so` с Crystal-рантаймом + sokol (GLES3), без Java/Kotlin-кода
(`android:hasCode="false"`). Референс схемы —
[HertzDevil/crystal-android-hello-world](https://github.com/HertzDevil/crystal-android-hello-world)
(+ влитый в Crystal PR [#13065](https://github.com/crystal-lang/crystal/pull/13065)
«AArch64 Android support»).

## Что уже есть (проверено по коду этого репо)

- **vendored `vendor/sokol/sokol_app.h` содержит полный Android-бэкенд**:
  - EGL init/surface: `_sapp_android_init_egl` (~10695), `init_egl_surface` (~10792);
  - жизненный цикл NativeActivity: `on_start/resume/pause/stop/destroy`,
    `on_low_memory`, `on_window_focus_changed` (~11215–11311);
  - тачи: `_sapp_android_touch_event` (~10912) → `SAPP_EVENTTYPE_TOUCHES_BEGAN/MOVED/ENDED`;
  - клавиатура: key events с юникодом (`_sapp_android_key_event` ~10966) +
    экранная клавиатура `sapp_show_keyboard(bool)` (Android-ветка ~14639);
  - frame loop через AChoreographer (`_sapp_android_frame_callback` ~11104);
  - `ANativeActivity_onCreate` sokol определяет сам (~11325).
- **Зависимости почти нулевые**: crystalfonts — FreeType на чистом Crystal
  (libfreetype кросс-собирать не нужно); nanosvg / fontstash / stb_image /
  sokol — header-only C, собираются NDK-клэном в один проход.
- **Crystal 1.21.0** на этой машине знает таргет `aarch64-linux-android`
  (единственный Android-таргет; `x86_64-linux-android` в Crystal нет).
- **Инструментарий на этой машине**: SDK `/home/oleg/android-sdk`
  (`ANDROID_HOME`), NDK `25.2.9519653`, build-tools 34/35, platforms
  android-34/35/36, emulator + AVD `test_avd` (x86_64, google_apis, API 34).

## Ключевое ограничение входа (важно!)

`SOKOL_NO_ENTRY` + `sapp_run()` **не поддерживаются на Android**
(sokol_app.h:1158). На Android sokol сам даёт `ANativeActivity_onCreate` и
синхронно вызывает **`sokol_main(0, NULL)`** — мы должны вернуть
`sapp_desc` прямо из C-shim'а. Отсюда bootstrap-цепочка (см. ниже).

## Архитектура

### Поток запуска

```
APK → dlopen(libegui_cr_android.so)
  → ANativeActivity_onCreate          (sokol_app, уже есть)
    → sokol_main(argc, argv)          (новый, в shim'е, только __ANDROID__)
      → egui_cr_android_boot()        (новый Crystal `fun`)
        → __crystal_main(0, null)     (запуск user-кода: examples/hello.cr)
          → Sokol.run(app) { ... }
            — на Android: НЕ зовёт sapp_run, а регистрирует
              init/frame/event/cleanup колбеки + sapp_desc-поля
              в глобальном состоянии shim'а (egui_cr_android_set_desc) и выходит
      ← возвращаемся в sokol_main: читаем накопленный desc, отдаём sokol'у
  → sokol крутит event loop на своём потоке → init_cb → frame_cb → …
```

Bootstrap-трюк: `__crystal_main(argc, argv)` объявляется через `lib`
и вызывается вручную — стандартный приём для non-main входа
(так же делает android-ndk.cr из `android_main`). Рантайм (GC.init,
шедулер, fiber'ы) инициализируется прологом `__crystal_main`.

### APK

- `AndroidManifest.xml`: `android.app.NativeActivity`,
  `android:hasCode="false"`, `meta-data android.app.lib_name=egui_cr_android`,
  `glEsVersion 0x00030000` (GLES3).
- Без Gradle: `aapt package` / `aapt2 link` (build-tools) → zipalign →
  `apksigner sign` debug-ключом. DEX не нужен вообще.
- Иконка/ресурсы — по минимуму (label + icon из `assets/icon.png`).

## Сборочный конвейер (`scripts/build_android.sh`)

Скрипт в духе Makefile из hello-world-репо, HOST=linux-x86_64:

1. **Статические C-зависимости** (`etc/arm64-v8a/`, NDK CMake toolchain):
   - `libgc.a` — bdwgc v8.2.2 + libatomic_ops v7.6.14;
   - `libpcre2-8.a` — pcre2 10.42 (JIT, unicode);
   - `libevent.a` — пиннед коммит `8f47d8de281b877450474734594fdc0a60ee35d1`
     (последний релиз не собирается под Android; OpenSSL/mbedTLS off).
2. **Shim**: `backend/sokol_shim.c` →
   `clang --target=aarch64-linux-android34 -c` c
   `-DSOKOL_GLES3` (вместо `SOKOL_GLCORE` — обернуть в `#ifdef __ANDROID__`),
   **без** `SOKOL_NO_ENTRY` на Android, + `sokol_main`;
   плюс `android_native_app_glue.c` из `$NDK/sources/android/native_app_glue/`
   (sokol_app его требует; вендорим копию, чтобы не зависеть от пути NDK).
   nanosvg_shim / pty_shim: nanosvg — как обычно; pty — **не собирается**
   (Android: нет forkpty).
3. **Crystal**:
   `ANDROID_PLATFORM=34 crystal build -Duse_pcre2 --cross-compile --target=aarch64-linux-android -o hello.o`
   → на выходе только объектник.
4. **Линковка**:
   `clang --target=aarch64-linux-android34 -shared -o libegui_cr_android.so
   hello.o sokol_shim_android.o android_native_app_glue.o nanosvg_shim.o
   -Letc/arm64-v8a -lgc -lpcre2-8 -levent -llog -landroid -lEGL -lGLESv3 -lm`
5. **APK**: aapt + zipalign + apksigner (build-tools 34), `adb install`.

## Изменения в коде egui-cr

1. **`backend/sokol_shim.c`**
   - `#if defined(__ANDROID__)` → `#define SOKOL_GLES3`, иначе GLCORE;
     `SOKOL_NO_ENTRY` — только не-Android;
   - `sokol_main()` (только Android): зовёт `egui_cr_android_boot()`,
     возвращает desc, собранный через `egui_cr_android_set_desc(...)`
     (те же поля, что сейчас собирает `egui_cr_sapp_run`);
   - win32-специфика (перевод сообщений и пр.) — под `#ifndef __ANDROID__`.
2. **`src/egui/backend/sokol.cr`**
   - `Sokol.run` на Android (`{{ flag?(:android) }}`): регистрирует колбеки
     и desc-поля в shim и **возвращается сразу** (event loop крутит sokol
     на своём потоке; блокировка, как на десктопе, запрещена —
     `ANativeActivity_onCreate` ждёт завершения `sokol_main`);
   - `fun egui_cr_android_boot`: `GC.init` → ( translator → `GC.disable` ) →
     `Crystal.init_runtime` → `LibCrystalMain.__crystal_main(1, argv)` с
     валидным `argv = ["egui_cr"]`. Два критичных инварианта: (а) argv обязан
     быть валидным — кодген пишет `ARGC_UNSAFE`/`ARGV_UNSAFE` из параметров
     `__crystal_main`, а ленивые `ARGV`/`PROGRAM_NAME` дереберенсируют их при
     первом обращении (с `(0, nil)` — SEGV/ArgumentError); (б) звать именно
     `__crystal_main`, НЕ `Crystal.main` — последний по завершении топ-левел
     кода зовёт `exit()` и убивает NativeActivity-процесс (на Android
     `Sokol.run` возвращается сразу, а луп живёт в shim'е).
3. **Инпут (`src/egui/input.cr` / shim event-маппинг)**
   - `TOUCHES_BEGAN/MOVED/ENDED` → pointer down/move/up (первый палец);
   - два пальца: pinch → `zoom Δ`, средняя точка → pan/scroll;
   - колеса-скролла нет: drag по скролл-контейнеру → scroll
     (кинетика/момент в input.cr уже упоминается — проверить путь
     `drag deltas, kinetic scrolling, momentum`, input.cr:346);
   - mouse_x/y из touch-координат;
   - события клавиатуры: key_code + char → text events.
4. **`pixels_per_point`**: на Android `sapp_dpi_scale()` = fb/w = 1.0.
   Реальную плотность читать через `AConfiguration`/`AMotionEvent`-метрики
   в shim'е и прокинуть как переопределение ppp (см. существующий механизм
   `egui_cr_set_ppp` в shim'е).
5. **Экранная клавиатура**: фокус в текстовое поле → `sapp_show_keyboard(true)`,
   потеря фокуса/клик вне → `false`.
6. **system_ports (Android-реализации)**
   - `quit`: `ANativeActivity_finish()` (sokol и так завершает по onDestroy);
   - `clipboard`: через sapp на Android — заглушка; полноценно — JNI (позже);
   - `dialog`: file picker требует SAF через JNI — вне скоупа первой версии;
   - `screen`: размеры из sapp + плотность из п.4.
7. **Жизненный цикл**: `on_pause/on_resume` — sokol сам останавливает
   frame-callback; `on_low_memory` → хук `GC` (опционально).

## Ограничения и риски

- **Только arm64-v8a** (Crystal не имеет x86_64-android таргета).
  Эмуляторы на этой машине x86_64 → нужен образ с ARM-трансляцией
  (libndk_translation). Проверка: `adb shell getprop ro.dalvik.vm.native.bridge`.
  Если у API-34 образа нет трансляции — скачать
  `system-images;android-30;google_apis;x86_64` (там трансляция точно есть).
- API ≥ 28 (ограничение Crystal-таргета).
- libevent — только пиннед-коммит; OpenSSL нет → TLS вне скоупа.
- terminal/pty-виджет на Android невозможен (нет fork в app-процессах).
- GC консервативный (Boehm), куча невидима для Android-менеджмента памяти —
  на `on_low_memory` подчищать вручную (п.7).
- `sokol_main` вызывается синхронно в `ANativeActivity_onCreate` —
  весь Crystal-bootstrap должен быть неблокирующим.

## Фазы

- [x] **Фаза 0 — окружение**: SDK/NDK/emulator/AVD найдены, Crystal 1.21
      с таргетом подтверждён, sokol Android-бэкенд проверен по исходнику.
      Эмулятор API 34 имеет `libndk_translation.so` + `arm64-v8a` в
      abilist → arm64-код запускается напрямую (риск снят).
- [x] **Фаза 1 — минимальный .so** (`tmp/android/phase1.cr`):
      кросс-сборка deps + объектник + линковка `.so` (2.2 МБ, aarch64),
      APK, установка, запуск — `adb logcat -s egui_cr`:
      `HELLO FROM CRYSTAL`. ✅ 2026-10-12
      Уточнения по ходу: NDK r25 → API **33** максимум (не 34);
      нативные библиотеки в APK кладутся в `lib/arm64-v8a/` (для сырого
      aapt), не `jniLibs/`; aapt нужен `-I platforms/android-34/android.jar`
      и `<uses-sdk>` в манифесте.
- [x] **Фаза 2 — APK-скрипт** (`tmp/android/build_apk.sh`, финальный дом —
      `scripts/`): aapt + zipalign + apksigner, `adb install` на эмулятор,
      запуск, screencap. Install/запуск подтверждены в Фазе 1.
- [x] **Фаза 3 — sokol-кадр**: GLES3-ветка shim + bootstrap-цепочка +
      `Sokol.run` Android-режим → **рендер работает, 60 fps**. ✅ 2026-10-12
      Ключевые находки по ходу:
      - bootstrap обязан происходить на потоке лупера sokol (в
        `sh_init_cb`), НЕ в `sokol_main` (поток ANativeActivity) — иначе
        TLS фибер/GC привязываются не к тому потоку;
      - NDK r25 → API 33; GLES 3.0 (не 3.1-дефолт sokol) + контекст через
        `EGL_CONTEXT_CLIENT_VERSION`; MSAA off;
      - **Boehm GC под libndk_translation не видит гостевые стеки/регистры**
        → коллекции чистят живое (nondeterministic NULL-крэши). Пока:
        GC.disable при детекте транслятора (`File.exists?` на
        /system/lib{,64}/libndk_translation.so);
        на реальном устройстве GC включён (гипотеза — там всё нативно,
        проверить);
      - на трансляторе остался плавающий крэш ПОСЛЕ первых кадров
        (hello.cr рендерится, затем умирает; DiagApp живёт стабильно) —
        подозрение на вторую translation-специфичную проблему, нужно
        устройство для проверки.
      - ✅ 2026-10-12 (позже в тот же день): первопричина найдена и
        устранена — это НЕ translation-специфика. `__crystal_main(0, nil)`
        оставлял `ARGC_UNSAFE=0, ARGV_UNSAFE=null` → ленивая константа
        `ARGV` (`Array.new(ARGC_UNSAFE - 1)`) роняла процесс при первом
        `ARGV.size` в теле `Sokol.run` (CLI.parse). Фикс: валидный
        `argv=["egui_cr"]` + прямой `LibCrystalMain.__crystal_main`
        (без `exit()` из `Crystal.main`). hello.cr: стабильный рендер 60fps,
        soak 100+ с, OCR скриншота подтверждает UI. Осталась редкая
        (~1/10 запусков) нестабильность НА ЭМУЛЯТОРЕ: 60-секундная
        пауза на EGL-инициализации (software GL → ANR-диалог) и
        единичный SEGV на первом кадре — оба эпизода не
        воспроизводились на стабильных прогонах, проверить на
        реальном устройстве.
- [x] **Фаза 4 — UI**: `examples/hello.cr` рендерится на эмуляторе
      (тёмная тема, окно, текст, кнопки — скриншот
      tmp/android/hello_android_frame.png). Шрифты — Roboto из
      /system/fonts (SystemPorts::Fonts android-ветка).
- [ ] **Фаза 5 — инпут**: тач → pointer, pinch → zoom, drag-scroll,
      экранная клавиатура + text events, ppp по плотности экрана.
      Тачи замаплены в шиме (`sh_handle_touch`, см. комментарий в
      backend/sokol_shim.c ~391); ppp — через AConfiguration
      (`egui_cr_dpi_scale`).
      ✅ 2026-10-12 (позже): **экранная клавиатура (IME) — готова**,
      нативное поведение через Java InputConnection-мост (подход SDL):
      - `tmp/android/java/com/eguicr/ime/EguiCrActivity.java` —
        NativeActivity-сабкласс (в APK появляется classes.dex ~5.5 КБ,
        собран javac+d8 в build_apk.sh). Нулеразмерный DummyEdit-view
        + BaseInputConnection: commitText / setComposingText /
        deleteSurroundingText / performEditorAction → JNI-нативы.
        ВАЖНО: (а) static { System.loadLibrary("egui_cr_android"); } —
        иначе VM не резолвит Java_-символы (NativeActivity dlopen'ит
        .so мимо VM); (б) в имени пакета НЕ должно быть подчёркиваний
        (JNI-менглинг кодирует их как _1).
      - `backend/sokol_shim.c` (android-секция): JNI-колбеки кладут
        записи в mutex-кольцо (UI-поток!), `egui_cr_android_ime_pop`
        дренажится в Sokol#on_frame → Egui::Event; show/hide —
        `egui_cr_android_ime_set_state` через JNI (GetObjectClass от
        activity — FindClass с attach'нутого потока не видит классы
        приложения). Строки конвертируются UTF-16→UTF-8 вручную
        (GetStringUTFChars даёт modified UTF-8: эмодзи ≥U+10000 —
        CESU-8 суррогаты, битые для Crystal).
      - egui.cr: `Memory#register_text_input` (kind: plain/password/
        multiline/number + action + editor mirror: text/cursor/anchor)
        — text_edit/textarea регистрируются каждый кадр ПОСЛЕ обработки
        клавиатуры (зеркало отражает правки этого кадра);
        `Context#wants_text_input?`; Sokol#on_frame после кадра зовёт
        set_state (показ/скрытие/тип клавиатуры по фокусу, с дебаунсом)
        и пушит editor-state при изменениях. Editor mirror критичен для
        hold-to-delete: нативные редакторы постоянно отдают IME текст
        (getTextBeforeCursor/getSelectedText) и курсор
        (imm.updateSelection) — без этого Gboard при зажатом backspace
        останавливается после первого символа и не умеет word-delete.
        Composing-переписывание IME («удали N, вставь новое»)
        потребовало двух правок в общих виджетах: (а) последовательное
        применение Backspace+вставки в одном кадре (было elsif —
        вставка глоталась); (б) кратность нажатий
        (`InputState#consume_key_count` — Set схлопывал N backspace'ов
        кадра в один).
      - vendor/sokol патчи: BACK при показанной клавиатуре только
        скрывает её (quit — на повторное нажатие); raw key events
        (Enter/Backspace/стрелки/Home/End — multiline-Gboard Enter и
        USB/BT-клавиатуры) мапятся в KEY_DOWN/UP; MSG_FOCUS/NO_FOCUS
        теперь эмитят FOCUSED/UNFOCUSED-события (раньше sokol на
        Android их не слал вовсе).
      - Возврат фокуса окном (HOME/другое приложение → назад, тап в то
        же поле): sokol.cr на UNFOCUSED сбрасывает IME-состояние
        (дебаунс show/hide, g_ime_shown в шиме, egui-фокус виджета —
        как в нативных приложениях, после возврата нужен новый тап).
        Без этого дебаунс считал клавиатуру «уже показанной» и show не
        вызывался. В Java: showSoftInput после возврата молча падает
        (PHASE_CLIENT_VIEW_SERVED), а requestFocus у DummyEdit может
        навсегда вернуть false при живых всех canTakeFocus-условиях —
        лечится ретраями (250 мс, до 8) и пересозданием DummyEdit на
        втором неудачном ретрае + перепоказом в
        onWindowFocusChanged(true). d8 для dex — из build-tools 35
        (34-й R8 8.2.2-dev падает внутренним NPE на анонимных классах).
      - Memory#end_frame: клик/тап мимо focused-виджета снимает фокус
        (upstream-поведение; без этого клавиатуру не убрать тапом).
      - Манифест: `windowSoftInputMode="adjustResize"` (resize
        подхватывается sokol'ом сам — _sapp_android_frame каждый кадр
        перечитывает размеры), activity = com.eguicr.ime.EguiCrActivity.
      - Проверено на эмуляторе (tmp/android/ime_test.cr): show/hide по
        фокусу, ввод с composing-переписыванием (e→ee→eee→backspace→ee),
        парольное поле (kind=1, маска ●●), multiline (Enter → \n),
        BACK-двухступенчатый, adjustResize, эмодзи (codepoint доходит
        целый; рендерится тофу — шрифтовая цепочка без NotoColorEmoji).
      - Ограничения/TODO: русская раскладка не проверена на устройстве
        (путь кодировко-независимый, кириллица в BMP — должна работать);
        эмодзи-глифы (NotoColorEmoji в цепочку шрифтов);
        scroll-into-view сфокусированного виджета в scroll_area;
        аппаратные USB/BT-клавиатуры — сырые key events идут по маппингу
        выше, но полный текстовый ввод (латиница через keycode+meta,
        KeyCharacterMap) — отдельная фаза. Editor mirror (текст/курсор →
        IME, updateSelection) — сделан; hold-to-delete и word-delete
        работают, проверено на эмуляторе.
- [ ] **Фаза 6 — полировка**: lifecycle/pause, low-memory→GC,
      иконка приложения, README-раздел. Quit-порт сделан (см. ниже).
      ✅ 2026-10-12: quit-кнопка (SystemPorts::Quit) и BACK работают:
      sapp_quit() на Android никто не проверял (флаг ставился и
      игнорировался) — патч _sapp_android_frame зовёт
      _sapp_android_shutdown() + _exit(0) (жёсткий выход обязателен:
      фоновые потоки Crystal-рантайма гонятся с деструкторами при
      выходе → FORTIFY SIGABRT на каждый quit).
- [ ] **Фаза 7 — system ports (кроме IME/quit/screen/fonts, готовых
      раньше)**. Всё через тот же JNI-мост, что и IME: Crystal (поток
      sokol) зовёт статические хелперы EguiCrActivity; асинхронные
      результаты ОС (SAF onActivityResult, кнопки AlertDialog, смена
      системного клипборда) падают в mutex-кольцо sys-записей, которое
      Sokol#on_frame дренажит ПЕРЕД idle-check (SystemPorts::Android.pump
      → завершение detached-запросов AsyncDialogs / confirm-callback'ов —
      контракт «между кадрами» сохранён).
  - **clipboard**: sokol на Android клипборд не умеет — ClipboardPort
    (sokol.cr) ветвится в мост: set → ClipboardManager (UI-поток) +
    нативный кэш; get — из кэша, который держит актуальным Java-side
    OnPrimaryClipChangedListener (читать системный клипборд можно
    только с UI-потока).
  - **dialog (SAF)**: ACTION_OPEN_DOCUMENT / ACTION_CREATE_DOCUMENT /
    ACTION_OPEN_DOCUMENT_TREE; результат — content:// URI; чтение —
    Android.read_uri_text (ContentResolver, ≤64 КБ). AsyncDialogs
    расширен: start_detached/complete — бэкенд-дренаж вместо волокна.
    Глоб-фильтры мапятся в MIME (mime_for), смешанные/неизвестные → */*;
    `directory` игнорируется (EXTRA_INITIAL_URI требует tree-grant).
  - **notification**: NotificationChannel + notify через мост;
    на API 33+ первый вызов триггерит запрос POST_NOTIFICATIONS
    (в манифесте); до выдачи система молча дропает — приложение не
    падает.
  - **message_box**: AlertDialog через UI-поток; info/warning/error —
    fire-and-forget; confirm — НОВЫЙ перегруз с колбеком
    (`MessageBox.confirm(msg, title) { |ok| … }`): блокирующий
    вариант на Android невозможен без ANR (диалог живёт на UI-потоке
    ОС, стоп кадра = стоп диспетчеризации ввода). Синхронный confirm
    на Android показывает диалог и возвращает false (документировано).
  - **shell**: OpenUrl — Intent ACTION_VIEW напрямую из JNI-потока
    (startActivity — binder IPC, работает с любого attached-потока);
    FileOpen/RevealInFolder — false: file:// запрещён (API 24+),
    FileProvider требует res/xml + провайдера в манифесте — будущая
    фаза.
  - **user_dirs**: config/data → Context.getFilesDir, cache →
    getCacheDir, home → пакет-директория (HOME в app-процессах не
    задан — раньше home() падал в Dir.current), DOCUMENTS/DOWNLOADS/
    PICTURES/MUSIC/VIDEOS → getExternalFilesDir(type). Один JNI-вызов
    на директорию, кэшируется (UserDirs). AppConfig поехал поверх
    без изменений.
  - **демка**: examples/android_demo.cr (переименованный ime_test) —
    скроллящийся лист со всеми портами: 3 текст-поля (IME), clipboard
    copy/paste, Info/Warning/Error/Confirm, уведомление, open url,
    SAF open/save/pick-folder + превью текста, user dirs. На хосте
    тоже собирается (порты падают в десктоп-реализации).
  - Сборка: шим для Android теперь с `-fPIC` (aarch64 relocation
    против глобальных символов sokol), флаги не влияют на флейки.
  - Известные ограничения эмулятора (не блокеры): (а) холодный/перезапущенный эмулятор
    с libndk_translation периодически (≈ каждый 2–3-й запуск) даёт
    `sg_gl_create_image: assertion "img->gl.tex[slot]"` (glGenTextures
    → 0, software GL) — лечится перезапуском activity; (б) первый кадр
    debug-сборки под транслятором — до ~4–5 минут (release заметно
    быстрее); проверять на реальном устройстве.
  - ✅ Проверено на реальном устройстве (Huawei): IME, текст, уведомления,
    message box, open url, SAF open/save — работают; чинились по
    результатам проверки:
    - **pick folder не работал** — `setType` на ACTION_OPEN_DOCUMENT_TREE
      OEM-DocumentsUI (Huawei) молча отбивает; MIME больше не ставится
      для tree-режима (он там игнорируется по смыслу);
    - **clipboard не работал** — pull синхронный через UI-поток с
      bounded-wait (200 мс, CountDownLatch) при каждом get:
      OnPrimaryClipChangedListener на EMUI не стреляет, так что
      listener-кэш недостовернен; кэш остаётся фолбэком. Ошибки set/pull
      логируются в logcat (egui_cr);
    - **нет прокрутки пальцем по пустому месту** — добавлен canvas
      drag-scroll в САМ фреймворк (не android-специфика): press на
      пустом месте (нет drag-sensing виджета под пальцем) тащит
      верхний scroll-viewport (Memory#canvas_drag_*: владелец
      защёлкивается на press, дельты кормят KineticScroller — контент
      следует за пальцем, на отпускании флинг; семантика upstream egui —
      слайдеры/выделение текста/холсты рисования перехватывают жест,
      кнопки и лейблы прокручивают, как в мобильных списках). Работает и
      мышью (тест на десктопе). Спек: spec/scroll_drag_spec.cr.

## Приёмка

- `scripts/build_android.sh` с нуля собирает и ставит APK на эмулятор/устройство.
- `examples/hello.cr` (кнопка + label + окно) реагирует на тач и клавиатуру.
- Логи в logcat (`adb logcat -s egui_cr`), screencap-проверка UI.
