# macOS: Metal как опция сборки (BACKEND=metal)

## Статус: сделано

Metal — **опция при компиляции**, NSOpenGL (GL) остаётся бэкендом по
умолчанию на macOS:

    BACKEND=metal rake build:release[hello]   # macOS + Metal (CAMetalLayer)
    rake build:release                        # как раньше: Cocoa + NSOpenGL

`BACKEND=metal` — только macOS (на Linux/Windows Rakefile отвергает
значение; зеркально `BACKEND=vulkan`, который только Linux — VULKAN.md).

## Зачем

OpenGL на macOS давно в maintenance-режиме (deprecate с 10.14, баги в
драйвере не чинят). Чистый Metal — путь вперёд: CADisplayLink-тайминг
вместо NSTimer, стабильные драйверы, HDR-возможности. Плюс симметрия с
Vulkan-опцией Linux-сборки: один и тот же проект собирается на
«родном» GPU-API каждой платформы.

## Как устроено

- **Rakefile**: `BACKEND=gl|vulkan|metal`. Нативный шим компилируется с
  `-DSOKOL_METAL`, примеры линкуются с `-framework Metal` вместо
  `-framework OpenGL` (Cocoa/QuartzCore/AVFoundation/CoreMedia/IOKit
  общие). Штамп `lib/.native-backend` роняет объект и архив при смене
  бэкенда — как у Vulkan.
- **shard.yml**: darwin `link_flags` несут `-framework Metal` постоянно
  (нужен для `crystal spec`/`shards build` под metal-сборкой; для
  GL-сборки непотянутый фреймворк безвреден).
- **backend/sokol_shim.c**: на macOS рендер идёт через sokol_app's
  Cocoa+CAMetalLayer путь (`_sapp_macos_mtl_init`), кадры гонит
  CADisplayLink. UI-шейдер — sokol_gl's встроенный AIR-байткод
  (`_sgl_shd_*_metal_macos`), ничего компилировать не нужно. GL-специфика
  изолирована `#ifdef`-ами по образцу Vulkan:
  - `sh_gl_ok()` (guard macOS-26 nil-контекста) — только под GLCORE;
  - прозрачность: `CAMetalLayer.opaque = NO` вместо
    `NSOpenGLContextParameterSurfaceOpacity`;
  - `present_clear`: end_default_pass сам презентует drawable — без
    flushBuffer;
  - vsync-off (`EGUI_NOVSYNC`/`swap_interval=0`): у Metal деление на
    ноль в display-link rate, поэтому маппится в
    `desc.metal.disable_display_sync`, `swap_interval` держится ≥ 1;
  - скриншоты (`--screenshot`, EGUI_SHOT): вместо glReadPixels —
    CPU-чтение текстуры drawable (`sh_mtl_grab_rgba`, двухфазно: кадр N
    retain'ит drawable, чтение на кадре N+1 — command buffer уже
    завершён).
- **vendor/sokol/sokol_app.h** (патч egui-cr): `_sapp_macos_mtl_init`
  ставит `layer.framebufferOnly = false` — иначе CPU-чтение drawable
  запрещено и скриншотные пути не работают.

## Известные ограничения (деградации как у Vulkan-опции)

- SDF/rounded-clip маска: MSL-двойника шейдера sdf_mask нет —
  скруглённые клипы деградируют до прямоугольного scissor (у попапов
  квадратные углы). Порт = MSL-source в `sg_shader_desc` (sokol_gfx
  умеет) или AIR в `backend/shaders/`.
- GPU-сегмент EGUI_BENCH (GL_TIME_ELAPSED): недоступен, фиолетового
  бара нет. Metal-замена — GPUStart/GPUEnd у MTLCommandBuffer (sg не
  экспонирует command buffer).
- VSync: swap_interval>1 делит display-link rate (2 = 30 FPS),
  untethered — через disable_display_sync, см. выше.

## Видео (zero-copy, как у Vulkan-варианта)

VideoToolbox-кадры идут без единой копии пикселей: декодер пишет в
CVPixelBuffer (IOSurface), рендер оборачивает его плоскости в
MTLTexture через `CVMetalTextureCache` (`sh_video_flush_mtl` в
backend/sokol_shim.c) — sg-обёртки инжектируются через
`sg_image_desc.mtl_textures`. Обёртки кэшируются по указателю буфера
(пул поверхностей фиксирован), YUV→RGB — MSL-шейдер видеопайплайна
(`SH_VIDEO_VS_MTL/FS_MTL`, рантайм-компиляция). Лестница фолбэков:
mtl-zc → NV12/P010 plane upload (как GL) → sws copy-back;
`EGUI_VIDEO_MTL=0` форсирует вторую ступень для тестов. Ключевая
метрика HUD: `upd=0ms` (у GL-пути было 210–270 мс/с CPU на аплоаде).

## Критерий готовности (выполнен)

`BACKEND=metal rake build:dev[hello]` на macOS (arm64, Sequoia+)
собирает бинарник, который открывает окно, рендерит UI (очистка цветом
темы + виджеты/текст), пишет валидный `--screenshot` PNG и выходит с
exit 0. Проверено на hello, widgets_gallery, rounded_window (прозрачное
окно). `BACKEND=metal rake spec` — сьюта зелёная.

## Проверено

- `BACKEND=metal`: нативная сборка, линковка примеров, взаимное
  переключение со сборкой gl (штамп рушит и пересобирает архив).
- Metal-бинарники: hello / widgets_gallery / rounded_window рендерятся,
  `--screenshot` пишет корректный PNG (не пустой кадр), exit 0.
- `rake spec` под GL и `BACKEND=metal rake spec` — без регрессий.
