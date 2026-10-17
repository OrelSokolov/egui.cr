# Linux: Vulkan как опция сборки (BACKEND=vulkan)

## Статус: сделано

Vulkan — **опция при компиляции**, GL (GLX) остаётся бэкендом по
умолчанию для всех платформ:

    BACKEND=vulkan rake build:release[hello]   # Linux + Vulkan
    rake build:release                          # как раньше: GL/GLX

## Зачем

GLX-путь ломается при рассинхроне версий драйвера NVIDIA (модуль ядра ≠
userspace libGLX) — типичный сценарий после `apt upgrade` без
перезагрузки:

    [sapp][panic] LINUX_GLX_CREATE_CONTEXT_FAILED:
    Failed to create GL context via glXCreateContextAttribsARB

Vulkan-путь такому рассинхрону не подвержен (wgpu-приложения на той же
машине продолжают работать). Сборка с `BACKEND=vulkan` делает запуск
устойчивым к обновлениям драйвера.

## Как устроено

- **Rakefile**: `BACKEND=gl|vulkan` (по умолчанию `gl`; `vulkan` —
  только Linux). Нативный шим компилируется с `-DSOKOL_VULKAN`,
  примеры линкуются с `-lvulkan`. Штамп `lib/.native-backend` роняет
  объект и архив при смене бэкенда — таймстемпы alone не видят смену
  -D, иначе в архив попадал бы объект чужого бэкенда
  (`build:dev`/`spec` поэтому теперь зависят от `build:native`).
- **backend/sokol_shim.c**: `SOKOL_GLCORE` → `SOKOL_VULKAN` по дефайну.
  GL-специфика изолирована: захват `EGUI_SHOT` (glReadPixels) под
  Vulkan — no-op. Остальной X11-код (визуалы, sync-request, фон окна,
  курсоры) общий — X11-бэкенд sokol_app один на оба рендера.
- **Шейдер UI**: ничего компилировать не нужно — vendored
  `util/sokol_gl.h` уже несёт встроенный SPIR-V
  (`_sgl_shd_*_bytecode_spirv_vk`) и сам подставляет его под
  `SOKOL_VULKAN`; GLSL-вариант остаётся для GL, HLSL — для Windows.
- **vendor/sokol/sokol_app.h** (патчи egui-cr):
  - `_sapp_vk_create_swapchain`: `compositeAlpha` больше не
    захардкожен OPAQUE — для прозрачных окон берётся
    `PRE_MULTIPLIED` из `supportedCompositeAlpha` (фолбэк `OPAQUE`);
  - `_sapp_linux_run`: под Vulkan при прозрачности выбирается
    depth-32 ARGB X11-visual (тот же `egui_cr_glx_want_argb` хук, что
    у GLX-патча fbconfig).
- **Линковка**: GNU ld.bfd не резолвит символы статического архива из
  shared-библиотек, стоящих ДО него, а Crystal ставит
  `-legui_cr_sokol` после группы `-lX11/-lGL` — Rakefile передаёт путь
  до `lib/libegui_cr_sokol.a` явно, раньше shared-либ (позже `-l`
  безвреден: его члены уже втянуты).

## Зависимости

Сборка: `libvulkan-dev` (vulkan/vulkan.h), линковка `-lvulkan`.
Рантайм: `libvulkan1` + ICD драйвера (`mesa-vulkan-drivers` для
Intel/AMD, проприетарный NVIDIA ICD для NVIDIA). crosspack.yml не
менялся: пакеты по умолчанию собираются на GL (`libgl1` в
runtime-deps); при переключении поставки на Vulkan заменить на
`libvulkan1` + драйвера.

## Известные ограничения

- Окно всё равно создаётся через X11/XWayland — Wayland-бэкенда в
  vendored `sokol_app.h` нет (отдельная задача).
- При выходе validation layer ругается на недоуничтоженные
  VkCommandBuffer до vkDestroyDevice (косметика teardown в vendored
  sokol; выход чистый, exit 0).
- Захват кадров `EGUI_SHOT` (glReadPixels) под Vulkan отключён.
- VSync: sokol на Vulkan различает только FIFO/IMMEDIATE —
  `swap_interval`>1 не поддерживается (на GL поддерживается).

## Критерий готовности (выполнен)

`BACKEND=vulkan rake build:dev[hello]` на Linux собирает бинарник,
который запускается в Wayland-сессии через XWayland на машине с
рассинхроном драйвера NVIDIA, где GL-сборка падает с
`LINUX_GLX_CREATE_CONTEXT_FAILED` — проверено на такой машине:
окно открывается, UI рендерится (очистка цветом темы + виджеты/текст),
закрытие чистое (exit 0).

## Проверено

- `BACKEND=vulkan` и `BACKEND=gl`: нативная сборка, линковка примеров,
  взаимное переключение (штамп роняет и пересобирает архив).
- Vulkan-бинарник: hello (текст/виджеты/панели) и logos (векторная
  графика) рендерятся; wmctrl-закрытие → exit 0.
- GL-сборка линкуется (запуск на этой машине невозможен — тот самый
  GLX-рассинхрон; на машине без рассинхрона работает как раньше).
- `rake spec`: 736 примеров, 0 ошибок; 3 падения — font-catalog
  (`wght:` ось, зависит от установленных в системе шрифтов), не
  связаны с бэкендом.
