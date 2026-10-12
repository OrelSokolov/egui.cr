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
      ЕЩЁ НЕ ГОТОВО: тачи не замаплены — UI не реагирует на касания.
- [ ] **Фаза 6 — полировка**: lifecycle/pause, low-memory→GC,
      quit-порт, иконка приложения, README-раздел.

## Приёмка

- `scripts/build_android.sh` с нуля собирает и ставит APK на эмулятор/устройство.
- `examples/hello.cr` (кнопка + label + окно) реагирует на тач и клавиатуру.
- Логи в logcat (`adb logcat -s egui_cr`), screencap-проверка UI.
