# Запись голоса (VoiceRecorder) + voice-echo приложение

Статус: план. Выполняется на macOS (MacBook) — там есть Xcode, SDK/NDK
(`~/Library/Android/sdk`), крист и оба репо (egui.cr + minaudio.cr).
Пишется по образцу камеры (`src/egui/camera.cr` + `src/egui/backend/camera.cr`
+ camera-секция `backend/sokol_shim.c`) и аудио-порта
(`src/egui/system_ports/audio.cr` + `src/egui/backend/audio.cr`).

## Цель

1. Порт записи голоса `Egui::VoiceRecorder` в ядре egui-cr (headless,
   тестируемый) с нативной реализацией на miniaudio (capture-режим).
2. Runtime-разрешения: `RECORD_AUDIO` на Android (JNI-мост, как у камеры),
   TCC-промпт на macOS (`NSMicrophoneUsageDescription` + явный запрос).
3. `examples/voice_echo.cr` — echo-тест: кнопка записи → уровень (RMS) →
   воспроизведение записанного через `SystemPorts::Audio`.
4. Android APK `voice_echo` (arm64-v8a), проверенный на устройстве/эмуляторе.

iOS — задел (Phase 7, опционально): объекты miniaudio для ios уже умеет
собирать шарда (`rake build:ios`), но AVAudioSession-категорию и plist
добавляем отдельным шагом.

## Что уже есть (проверено по коду)

- **Воспроизведение**: `SystemPorts::Audio` + `backend/audio.cr`
  (minaudio Engine; на Android OpenSL пиннится первым, AAudio — фолбэк).
- **minaudio.cr** (OrelSokolov/minaudio.cr): `Engine`/`Sound`/`Decoder`/
  `Context.devices[:capture]` (перечисление capture-устройств есть).
  **Capture-API нет** — нет биндингов `ma_device_init`/`ma_device_read`.
- **Компилируемая единица** `ext/miniaudio.c` собирает miniaudio целиком
  (`MA_NO_ENCODING` отключает только file-writing/энкодеры) — символы
  capture-устройства уже в `libminaudio.a` / `miniaudio_android.o` /
  `miniaudio_ios_*.o`. Новых сборочных шагов в шарде не нужно.
- **Образец порта-сенсора**: камера — `Implementation.use`-шов,
  `permission_granted?` / `request_permission!` (поллинг между кадрами,
  диалог асинхронный), poll-качка данных, C-API `egui_cr_cam_*` в
  `backend/sokol_shim.c` (macOS AVFoundation / Android camera2-NDK+JNI).
- **Android-сборка**: `tmp/android/build_apk.sh <app.o> [extra.o...]` —
  линкует `.so`, `.dex` из `tmp/android/java/…/EguiCrActivity.java`,
  APK (aapt → zipalign → apksigner). Уже линкует `-laudio -lOpenSLES`
  и ждёт `lib/minaudio/ext/miniaudio_android.o` среди extra.o.
  Манифест: `tmp/android/AndroidManifest.xml` (есть CAMERA,
  POST_NOTIFICATIONS, VIBRATE — RECORD_AUDIO нет).
- **Java-мост**: `tmp/android/java/com/eguicr/ime/EguiCrActivity.java` —
  статические `hasCameraPermission`/`requestCameraPermission`
  (requestCode 1003) + `audioDiag()` — образец для микрофона.

## Архитектура

```
app (examples/voice_echo.cr)
  └─ Egui::VoiceRecorder          # ядро: headless, шов Implementation
       └─ Backend::NativeVoiceRecorder   # backend/voice_recorder.cr (opt-in
            │                             # require "egui/backend/voice_recorder")
            ├─ MinAudio::CaptureDevice    # minaudio.cr: capture без колбека не
            │                             # годится — см. ниже, колбек+буфер
            └─ LibEguiCr.mic_perm /       # sokol_shim.c: TCC/JNI-разрешение
               mic_perm_request
Воспроизведение эха — уже готовый SystemPorts::Audio (WAV-файл → Audio.play).
```

Модель данных: как у камеры — poll. Ядро видит только байты PCM
(s16le, моно, по умолчанию 16 кГц): `poll` отдаёт НОВЫЙ кусок с прошлого
вызова, приложение накапливает само. Уровень (RMS) считает приложение.

Захват без блокировки кадра: ma_device в read-режиме (`ma_device_read`)
блокируется до прихода семплов — звать его из frame-потока нельзя.
Поэтому в C-хелпере шарды устройство открывается с data-callback,
который складывает семплы в мьютекс-guarded byte-buffer; drain-функция
копирует накопленное наружу и очищает (аналог latest-frame слота камеры).

## Изменения

### Репо 1: minaudio.cr (ветка main, пуш до работ в egui.cr)

1. `ext/miniaudio.c` — новые хелперы (конфиги by-value строятся в C):
   - `minaudio_sizeof_device()`;
   - `minaudio_capture_init(void* dev, int rate, int channels)`:
     `ma_device_config` → `ma_device_type_capture`, формат `ma_format_s16`,
     data-callback → append в per-device heap-буфер (pthread mutex);
     старт НЕ здесь (как у ma_device: init → stopped);
   - `minaudio_capture_drain(void* dev, unsigned char* out, size_t cap)`
     → возвращает, сколько байт скопировано (0 = ничего нового);
   - `ma_device_start/stop/uninit` биндим напрямую (символы уже в либе).
2. `src/minaudio/lib.cr` — биндинги новых `minaudio_*` + `fun ma_device_start/ma_device_stop/ma_device_uninit(Void*) : Int32/Void`.
3. `src/minaudio/capture.cr` — `MinAudio::CaptureDevice`:
   `.new(sample_rate = 16000, channels = 1)`, `#start`, `#stop`,
   `#drain(buffer : Bytes) : Int32` (байты PCM s16), `#close`, `#sample_rate`,
   ошибки — `MinAudio::Error`, как остальная шарда.
4. `spec/` — headless-спека: без capture-устройства (CI) конструктор
   поднимает `MinAudio::Error` чисто, без сегфолта (спека помечена
   `pending!` если `Context.devices[:capture]` пуст).
5. README шарды: секция capture + примечание, что разрешение (RECORD_AUDIO /
   TCC) — обязанность приложения, без него open_device возвращает ошибку.

### Репо 2: egui.cr

6. `src/egui/voice_recorder.cr` — ядро (по образцу `camera.cr`):
   - `VoiceRecorder.permission_granted?` / `.request_permission!`
     (3-state, поллинг между кадрами);
   - `.start(sample_rate = 16000, channels = 1) : Bool`,
     `.recording? : Bool`, `.poll : Bytes?` (новый PCM с прошлого poll),
     `.stop : Nil`, `.supported?`, `.last_error`;
   - `class Implementation` — дефолт «not implemented» (как камера:
     iOS — «not implemented yet», прочие — то же);
   - `Egui::Wav.encode(pcm : Bytes, rate : Int32, channels : Int32) : Bytes`
     — минимальный WAV-писатель (44-байтовый заголовок + s16le), живёт
     здесь же: чистый Crystal, нужен echo-приложению для воспроизведения.
7. `src/egui/egui.cr` — `require "./egui/voice_recorder"` (рядом с camera).
8. `backend/sokol_shim.c` — секция mic-разрешений (переиспользуют
   `sh_sys_env`/`sh_act_class`, общий приём с камерой):
   - `__APPLE__`: `egui_cr_mic_perm` / `egui_cr_mic_perm_request` через
     `AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio` /
     `requestAccessForMediaType:AVMediaTypeAudio` (macOS 10.14+);
   - `__ANDROID__`: JNI → `hasMicPermission` / `requestMicPermission`;
   - прочие платформы: заглушки «granted» (ALSA/pulse TCC не требуют).
9. `src/egui/backend/voice_recorder.cr` — `Backend::NativeVoiceRecorder`
   (opt-in, `require "egui/backend/voice_recorder"` — тянет minaudio,
   как `backend/audio.cr` тянет его для play):
   - start: сперва permission-шов (`LibEguiCr.mic_perm`), потом
     `MinAudio::CaptureDevice`; poll — drain в переиспользуемый буфер;
   - Android-пин бэкендов захвата: AAudio первым, OpenSLES фолбэк
     (обратный порядок к playback — там OpenSL надёжнее; для capture
     AAudio с 8.0 стабилен, но фолбэк оставляем).
10. `tmp/android/java/…/EguiCrActivity.java` — `hasMicPermission` /
    `requestMicPermission` (копия камерных, requestCode **1004**).
11. `tmp/android/AndroidManifest.xml` —
    `<uses-permission android:name="android.permission.RECORD_AUDIO" />`.
12. `examples/voice_echo.cr`:
    - `require "egui/backend/audio"` + `"egui/backend/voice_recorder"`;
    - UI: permission-кнопка → Record/Stop (красная точка), полоска уровня
      (RMS последнего poll-чанка, убывает между чанками), счётчик секунд,
      Play — `Wav.encode` → `File.tempfile` → `SystemPorts::Audio.play`
      (или fallback-сообщение `Audio.last_error`);
    - состояние конечного автомата: :idle → :need_permission → :recording →
      :recorded → (play) → :recorded.
13. `spec/voice_recorder_spec.cr` — headless:
    - дефолтная Implementation: `supported? == false`, `start` → false;
    - фейковая Implementation (синтетическая синусоида в poll): поллинг,
      порядок состояний, делегирование permission-методов;
    - `Wav.encode`: заголовок (RIFF/размеры/`fmt ` PCM s16/`data`),
      длина = 44 + pcm.bytesize.
14. `scripts/make_voice_app.sh` — аналог `make_camera_app.sh`: .app-бандл
    с `NSMicrophoneUsageDescription` (TCC атрибутирует разрешение
    бандлу, не терминалу — та же причина, что у камеры).

## Порядок выполнения (фазы с контрольными точками)

- **Фаза 1 — minaudio.cr capture** (пп. 1–5): пуш, на Mac
  `shards update minaudio` в egui.cr. Точка: `crystal spec` шарды зелёные.
- **Фаза 2 — ядро порта + спеки** (пп. 6, 7, 13):
  `crystal spec spec/voice_recorder_spec.cr` зелёные, весь suite не сломан.
- **Фаза 3 — macOS-бэкенд**: пп. 8 (ветка `__APPLE__`), 9, 14.
  Точка: ручной тест — `scripts/make_voice_app.sh bin/voice_echo`,
  `open builds/VoiceEcho.app`, разрешение → запись → уровень движется →
  Play слышит эхо.
- **Фаза 4 — Android**: пп. 8 (`__ANDROID__`), 10, 11, 12.
  Сборка на Mac:
  ```
  (cd lib/minaudio && rake build:android)          # miniaudio_android.o
  crystal build examples/voice_echo.cr --cross-compile \
    --target=aarch64-linux-android -Duse_pcre2 -o tmp/android/voice_echo.o
  tmp/android/build_apk.sh tmp/android/voice_echo.o \
    lib/minaudio/ext/miniaudio_android.o
  adb install -r tmp/android/app.apk
  ```
  Точка: на устройстве/эмуляторе — системный диалог RECORD_AUDIO,
  запись (уровень в logcat: `[audio]`/`[mic]`), воспроизведение эха.
  Проверки при проблемах: `adb logcat -s egui_cr`, `audioDiag()`-стиль
  диагностики медиа-громкости уже есть в шиме.
- **Фаза 5 — зачистка**: обновить `plans/framework-todo.md` (пункт
  «Аудио-слой: … микрофон» — отметить сделанным), `docs/ARCHITECTURE.md`
  (секция system ports/камера — добавить VoiceRecorder), README examples.
- **Фаза 6 (опционально, iOS)**: `rake build:ios` объекты уже есть;
  добавить `NSMicrophoneUsageDescription` в Info.plist бандла, перед
  стартом ставить `AVAudioSession` category `PlayAndRecord`
  (`egui_cr_mic_*` в шиме уже общий для `__APPLE__`), кросс-компил
  `--target=arm64-apple-ios17.0-simulator` по схеме IOS_SUPPORT_PLAN.md.

## Риски / заметки

- **MA_NO_ENCODING** не мешает capture — отключены только энкодеры;
  WAV пишем сами (44 байта заголовка, PCM s16le — тривиально).
- **ma_device_read блокируется** — поэтому колбек+C-буфер+drain, а не
  read-режим; frame-поток только копирует готовое.
- **Отказ разрешения выглядит как ошибка устройства** — порт всегда
  стартует с permission-шва, `start` возвращает false c внятным
  `last_error` («microphone permission not granted»).
- **Android-эмулятор** имеет виртуальный микрофон («Virtual mic»,
  хост-вход) — эхо-тест можно гонять без устройства.
- **Тишина на Xiaomi/HyperOS** (playback-кейс из backend/audio.cr):
  для capture оставляем AAudio→OpenSLES фолбэк и диагностический лог
  сэмпл-рейта/каналов открытого устройства.
