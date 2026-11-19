# Multiwindow on the sokol backend — research

What has to change to support multiple OS windows. Findings are grounded in
the current code; file/line references point at the single-window
assumptions each change removes.

TL;DR: nothing fundamental blocks it. sokol_gfx already supports multiple
swapchains, and the Crystal core (`Context` per app, per-instance glyph
atlases) is multi-instance already. The work is (1) a window layer of our
own — sokol_app is single-window by upstream design and will stay that
way, (2) de-singletonizing the Crystal backend, (3) threading a window id
through the event path and the Window system port.

## Layer-by-layer status

| Layer | Status | Notes |
|---|---|---|
| `Egui::Context` / core | ready | `App#initialize` creates its own `Context` (src/egui/app.cr:11); all state is instance state — multiple contexts already coexist (headless specs do it) |
| Font atlases | ready | per-instance by view id (`egui_cr_atlas_create` registry, backend/sokol_shim.c:380-421); view ids are process-global in sg, shared fine |
| GPU textures / pipelines | ready | `egui_cr_make_texture`/`load_image` are window-agnostic; sgl supports named contexts (`sgl_make_context`/`sgl_context_draw`, vendor/sokol/util/sokol_gl.h:840-852) though one default context also works with sequential passes |
| sokol_gfx | ready | `sg_pass` takes an explicit `sg_swapchain` (`sg_swapchain` struct with `.gl.framebuffer`, vendor/sokol/sokol_gfx.h:3130-3142) — multi-swapchain is the supported API since the environment/swapchain split |
| sokol_app | blocked upstream | one window per process, by design: `_sapp.x11.window` singleton, all `sapp_*` API acts on the one window. Extra windows must be created outside sapp |
| our shim (C) | single-window | every window-management entry point fetches THE window via `sapp_x11_get_window()` / `sapp_win32_get_hwnd()` / `sapp_macos_get_window()` (backend/sokol_shim.c:757-899) |
| Crystal backend | single-window | module-level singletons in `Egui::Backend::Sokol` (src/egui/backend/sokol.cr:156-173) |
| SystemPorts::Window/Screen | single-window | one implementation, no window identity in the API (src/egui/system_ports/window.cr) |

## What has to change

### 1. C shim (backend/sokol_shim.c)

- **Second-window creation, X11 first.** `egui_cr_window_create(...)`:
  `XCreateWindow` on sapp's `Display` (`sapp_x11_get_display()`), an
  event mask, `WM_DELETE_WINDOW` protocol, an EWMH-friendly type/size.
  The X11 window-management code already in the shim (motif hints,
  `_NET_WM_STATE`, moveresize — sokol_shim.c:715-755) is reusable
  as-is once it takes a `Window` parameter instead of fetching sapp's.
- **Per-window GL context (the tricky part).** On GLX: pick an fbconfig
  compatible with sapp's visual (same sample count — sgl pipelines are
  built against `sapp_sample_count()`, sokol_shim.c:121), create a
  context that **shares display lists** with sapp's (glX share-list
  arg) so textures/views created once are valid in both. Per frame:
  `glXMakeCurrent` → draw window → `glXSwapBuffers` — sapp swaps its
  own window itself (sokol_app.h:12739 loads `glXSwapBuffers`), so
  extra windows present manually from our side.
- **Explicit swapchain pass.** `egui_cr_begin_pass` hardcodes
  `sglue_swapchain()` (sokol_shim.c:142-153). Add a variant taking the
  window's `sg_swapchain` (`.gl.framebuffer = 0` default FB of the
  current context, our width/height, matching color format and
  `sample_count`). `egui_cr_end_pass`'s `sg_commit` stays once per
  frame; per-window present is the manual swap above.
- **Event pump for extra windows.** sapp pumps its own window's events
  before `frame_cb`; poll ours there with `XCheckWindowEvent` scoped to
  our windows (never `XNextEvent` — it would steal sapp's events).
  Route through the existing `cr_event_cb` with a **window id argument**
  added to the signature (currently absent, sokol_shim.c:33-35).
- **Parameterize the singleton state:** `g_clear` per window
  (sokol_shim.c:133), per-window cursor (`XDefineCursor` is already
  per-window under the hood; track the id), window-management functions
  take a window handle/id.
- **Win32 later:** `RegisterClass` + `CreateWindowEx` + own `WndProc`
  (reuse the WM_SETCURSOR subclass pattern from sokol_shim.c:518),
  `wglCreateContext` + `wglShareLists`, same pixel format as sapp's
  (sample count!), manual `SwapBuffers`, `PeekMessage` pump in
  `frame_cb`.
- **macOS last:** NSWindow + NSOpenGLContext sharing; AppKit main-thread
  rules already hold (frame_cb is on the main thread).

### 2. Crystal backend (src/egui/backend/sokol.cr)

All module-level singletons move into a per-window instance
(`Sokol::WindowState`): `@@app`, `@@events`, `@@last_commands` /
`@@last_fb_w/h` (idle-repaint cache), `@@pixels_per_point`, `@@cursor`,
`@@transparent` (sokol.cr:156-173). Concretely:

- `run(app, ...)` stays the single-entry point for window #1; add
  `open_window(app, ...)` that creates a `WindowState` and calls the
  shim's `window_create`.
- `on_event` gains a window id and appends to **that** window's queue.
- `on_frame` iterates windows: per window — `begin_frame` →
  `app.update` → `end_frame` → `paint_frame` with its swapchain; the
  idle-repaint fast path (sokol.cr:555-560) becomes per-window.
- `paint`/`paint_frame`/`apply_scissor` use `@@pixels_per_point` —
  becomes state on the window being painted.
- `inject_event` / `last_pointer_pos` (sokol.cr:445-469) take a window
  id (WindowPort#hand_off_release needs the association).
- `QuitPort#quit` → `sapp_quit` kills everything; needs
  close-one-window (destroy ours, drop the WindowState) vs quit-app.

### 3. SystemPorts::Window / Screen

The port API has no window identity — `set_title`, `start_drag`, etc.
act on "the" window (src/egui/system_ports/window.cr). Two options:

- **a)** Add an explicit `window_id` argument (breaks all callers), or
- **b)** Upstream-egui style: viewport commands routed through the
  `Context` (`ctx.send_viewport_cmd(...)`), so the window a call
  addresses is the one the ctx belongs to. Matches how egui 0.24+ does
  multi-viewport; less port churn for app code.

Either way the `Implementation` methods need a window handle parameter;
`ScreenPort` stays global (primary monitor) or gains per-window monitor
lookup (X11: `XRRConfig`/`XMonitor` — later).

## Suggested order

1. **Phase 0 (no backend work):** floating in-window "windows" —
   `window_frame.cr` + the constrained `Area` machinery in context.cr:265
   already cover most "second window" needs inside one OS window.
2. **Phase 1 — refactor:** per-window state in Crystal + window-id
   plumbing through `on_event`/ports, still single-window behavior.
   Verifiable by specs, no C changes.
3. **Phase 2 — Linux PoC:** shim `window_create` (X11+GLX share-lists),
   explicit-swapchain `begin_pass`, manual swap, per-frame event poll,
   per-window cursor/clear. Target: the `terminal` example opening a
   second terminal window.
4. **Phase 3 — Win32** (same shape, `wglShareLists` + own WndProc).
5. **Phase 4 — macOS.**

## Risks

- **GL context sharing** is the make-or-break on every platform. If
  share-lists misbehaves (driver quirks, MSAA format mismatch), fallback
  is per-window full contexts + re-creating per-window texture copies —
  costly; better to nail the shared setup early in Phase 2.
- **Sample count consistency:** sgl pipelines are built once against
  `sapp_sample_count()`; extra windows must request the same MSAA or
  get their own sgl context (`sgl_make_context`) with its own
  `sample_count`.
- **Event-loop interference (X11):** only ever poll our windows
  (`XCheckWindowEvent` with the window id), never drain the display
  queue globally.
- **sokol_app upgrades:** the shim already carries local patches
  (`egui_cr_x11_pre_map_hook`, GLX ARGB hook). Keep new code in the shim
  proper, not more sapp patches, to reduce rebasing pain.
