# 3D support — plan

Goal: native 3D graphics inside egui-cr widgets, proven by two demos:

1. **`xor3d`** (primary) — the perceptron/MLP XOR demo (previously built in
   three.js): the four XOR points shown in input space (not linearly
   separable), then lifted into 3D by the hidden layer (separable by a
   plane), with the decision surface morphing as the network trains.
2. **`objviewer`** (secondary) — a simple .obj model viewer: drag & drop /
   file dialog, flat shading, wireframe toggle, auto-fit camera.

Rule (same as videoplayer.md): the framework only gains the generic
3D-capable paint primitive; all demo logic lives in `examples/`.

## Architectural choice: sgl-native 3D in the paint stream

Three candidate designs were considered:

| Option | Verdict |
|---|---|
| A. Offscreen render → stream texture (`create_stream`/`update`) | Works today (video.cr proves it), but every frame copies pixels through the CPU, and dev-build Crystal hot loops are 10–100x slower — the exact reason freetype/nanosvg C accelerators exist. Reject as the primary path. |
| B. Offscreen `sg_pass` → GPU texture → textured quad | Classic egui-rs approach, but needs FBO lifecycle + new packet delta-ops in the detached replay protocol. The heaviest change. Keep as a later optimization if ever needed. |
| C. **Draw 3D directly through sokol_gl in the existing paint stream** | Chosen. |

Why C is cheap here specifically:

- The whole UI already draws through sgl (`paint list → sgl quads + text
  quads → sgl_draw`). sokol_gl is fixed-function-style: it has
  model/view/projection matrices and accepts 3D vertices (`sgl_v3f_c3b`).
- The shim already wraps `sgl_viewport`, `sgl_matrix_mode_projection/
  modelview`, `sgl_load_identity`, `sgl_scissor_rectf` — and these already
  flow through **both** the direct path and the detached packet replay
  (`backend/sokol_shim.c:943-999`; the replay resets matrices every frame
  at `sokol_shim.c:3158-3163`, so 3D matrix state cannot leak across
  frames).
- Custom sgl pipelines are an established pattern
  (`g_alpha_pip`/`g_replace_pip`/`g_text_pip`, `sokol_shim.c:646-690`).
- Clipping: a 3D viewport widget is just a scissor rect — the existing
  clip mechanism works unchanged.
- Painter's algorithm is preserved: 3D content draws at its position in
  the paint list; UI drawn after it (menus, tooltips, panels) stays on
  top because 2D pipelines ignore depth.

What is genuinely missing (Phase 0 below): a depth attachment on the
swapchain, `sgl_load_mat4` exposure, depth-tested pipelines, and a
batched mesh-emit call — all small, all following existing shim patterns.

Out of scope (deliberately): no scene graph, no z-fighting against UI
layers, no textured/lighted 3D (vertex colors only), no GLTF.

## Phase 0 — shim: depth buffer + 3D pipelines + mesh emit

All in `backend/sokol_shim.c` + `src/egui/backend/sokol.cr` bindings.

1. **Depth attachment.** Both `sapp_desc` sites (`sokol_shim.c:278`,
   `sokol_shim.c:3370`) get `.depth_buffer = true`; every `sg_begin_pass`
   action clears depth. MSAA (sample_count 4) and transparent-window mode
   (sample_count 1) both keep working; the new pipelines are created with
   the context's sample count exactly like the existing ones.
   Note: the two `sapp_desc` sites must stay in sync (direct vs detached).
2. **Pipelines.** Two new sgl pipelines beside the existing three:
   - `g_pip_3d` — depth test + write, no blending (opaque triangles).
   - `g_pip_3d_blend` — depth test, **no** depth write, blending
     (translucent surfaces: decision planes, height-map meshes).
3. **`egui_cr_sgl_load_mat4(const float m[16])`** — direct call +
   one new packet op (mirrors `egui_cr_sgl_matrix_mode_projection`'s
   direct/packet split).
4. **`egui_cr_mesh3d(mvp, pip_flags, primitive, count, const float* data)`**
   — one call per mesh, vertices packed SoA: `x,y,z` f32 + `r,g,b,a` u8
   (16 bytes/vertex). Implementation:
   `sgl_push_pipeline` → load 3D pipeline → `sgl_matrix_mode_projection` →
   `sgl_load_mat4(mvp)` → `sgl_begin(primitive)` → emit `sgl_v3f_c3b` loop →
   `sgl_end()` → **restore**: `sgl_pop_pipeline`, `sgl_viewport(fb_w, fb_h,
   true)` (re-establishes the default pixel-space projection) and
   `sgl_matrix_mode_modelview; sgl_load_identity()`. The restore step is
   mandatory — subsequent 2D quad ops assume the default projection.
   Detached mode: a single packet op carrying the vertex bytes (precedent:
   texture pixel deltas already travel inside packets, so streamed video
   bitmaps the cost model).
5. **Bindings** in `src/egui/backend/sokol.cr` (`fun` decls), routed
   like `sgl_bind_texture` (`sokol.cr:161-162`).

**Verify:** a smoke binary showing a rotating depth-tested colored
pyramid over a translucent quad inside a scissored panel — wrong
triangle order must still look correct thanks to depth test. Screenshot
via the existing `scripts/make_screenshots.py` pattern.

## Phase 1 — framework: math3d, Mesh3D command, Viewport3D widget

1. **`src/egui/math3d.cr`** — `Vec3`, `Mat4` (column-major, `Float32`
   backing so it can be handed to the shim without conversion),
   `Mat4.perspective/ortho/look_at`, `*`, `#transform(Vec3)`, plus
   `#project(Vec3, viewport_rect) : Pos2?` for 3D→screen (text labels,
   point picking). `math.cr` is 2D-only today; keep the two files separate.
2. **Paint command.** `Painter#mesh3d(clip, mvp, data : Bytes, primitive,
   blend : Bool)` → a `Mesh3DCmd` beside `ImageCmd` (`painter.cr:106-118`).
   The backend walker handles it next to the image-quad case
   (`sokol.cr:1477-1508`).
3. **`src/egui/widgets/viewport3d.cr`** — `Viewport3D` widget:
   - allocates its rect, paints an opaque background quad (the existing
     replace-blend pipeline) then the caller's meshes, all under the
     widget's clip rect;
   - built-in orbit camera (yaw/pitch/distance/target): drag to rotate,
     wheel to zoom, via `Response` — the pointer-to-local-coordinates
     pattern is copied from `Canvas::Interaction` (`widgets/canvas.cr:31-60`);
   - exposes `#camera` and a `#project(Vec3) : Pos2?` helper so apps can
     label points with ordinary `painter.text`;
   - repaint gating: calls `ctx.request_repaint` while dragging/
     autorotating only.
4. **Specs** (`spec/viewport3d_spec.cr`): headless contract — clip rect
   propagation, camera matrix stability, command emission, interaction
   coordinate math (the `DummyTextureRegistry` headless pattern applies:
   the paint command is inspectable without a GPU).

**Verify:** rotating flat-shaded cube (crystal logo?) as a test widget;
screenshot; spec run.

## Phase 2 — demo: `examples/xor3d.cr` → `bin/xor3d`

Self-contained, pure Crystal + the Phase 1 seam. No changes outside
`examples/`.

- **Network:** tiny MLP 2–2–1 (tanh hidden, sigmoid output), online SGD,
  a few steps per frame — microseconds per epoch in Crystal; loss tracked
  for a sparkline (plain polyline via `painter`).
- **Panels** (`SidePanel` + existing widgets):
  - train / pause / reset, learning-rate slider, epoch + loss readout;
  - view toggle: **input space** (points pinned to the z=0 plane, plane
    fails to separate) ↔ **hidden space** (points at `(h1, h2, bias)`,
    output-neuron plane drawn translucent through them — separable);
    an animated interpolation between the two is the money shot;
  - decision surface: 32×32 height-map mesh `z = f(x1,x2)` over the input
    square, vertex-colored by class, rebuilt each frame while training
    (2k triangles — trivial for sgl);
  - autorotate toggle.
- **Geometry helpers** live in the example (`octahedron` for class
  points, grid/axes lines via the `:lines` primitive, axis tick labels
  via `#project` + `painter.text`).

**Verify:** screenshots (before/after training, both view modes); the
surface visibly converges to the XOR solution; 60 fps in release.

## Phase 3 — demo: `examples/objviewer.cr` → `bin/objviewer`

- **Loading:** drag & drop (`Event.dropped_files`, already wired through
  `input.cr:172`) and `SystemPorts::OpenFileDialog` (already exists; the
  video demo uses it). OBJ only at first.
- **Parsing — two options, in order:**
  1. *Pure Crystal parser first* (~150 lines: `v`/`vn`/`vt`/`f`, fan
     triangulation, per-face lambert shading into vertex colors). This
     covers the overwhelming majority of ASCII .obj and unblocks the demo
     without touching the build. Honestly easier than a C shim: the
     Rakefile compiles shims with `cc` today; a C++ header (tinyobjloader)
     would need a `c++` variant of the shim rule.
  2. *`vendor/tinyobjloader` + `backend/tinyobj_shim.c`* (the
     nanosvg_shim pattern: vendor the header, add the Rakefile rule with
     `SHIM_HEADERS` entry + a C++ compile flag) — only if real-world
     files demand it (n-gons with holes, MTL colors, huge meshes).
- **Viewer:** auto-fit camera to model bbox, flat/wireframe toggle,
  vertex-count/triangle stats line, checkerboard background toggle.
- **Perf note:** sgl vertex pool is ~6 MB (`sokol_shim.c:326-330`) —
  cap imported meshes around ~100k triangles initially; raising the pool
  is a one-line change in `sgl_setup` if needed.

**Verify:** screenshots with 2–3 vendored sample models (a low-poly
 Stanford-bunny-class object), drag-rotate fluency, 60 fps release.

## Risks / open questions

- **Detached-mode replay:** the new ops must round-trip through the
  packet path (`sh_run_direct()` splits). The matrix reset already in the
  replay (`sokol_shim.c:3158-3163`) covers state leaks; test detached
  mode explicitly (the debug env toggle that forces the replay path).
- **Transparent window mode** (`sample_count = 1`, `chrome` alpha path):
  depth buffer alongside a transparent framebuffer needs one smoke test
  on Linux; if it misbehaves, disable 3D widgets in transparent mode
  rather than special-casing the pipelines.
- **Packet size:** a 100k-tri mesh is ~4.8 MB of vertex data per frame
  inside the packet. Same order as streamed video frames, which already
  work; if it ever matters, add mesh caching (register geometry once,
  per-frame op = mvp only) — deferred until needed.
- **Dev builds:** non-release Crystal is slow; demos are run from `bin/`
  release builds (`rake` targets), same as the other examples.

## File summary

| Path | Change |
|---|---|
| `backend/sokol_shim.c` | depth_buffer, `g_pip_3d`/`g_pip_3d_blend`, `egui_cr_sgl_load_mat4`, `egui_cr_mesh3d` + packet ops |
| `src/egui/backend/sokol.cr` | `fun` bindings, `Mesh3DCmd` walker case |
| `src/egui/math3d.cr` | new — Vec3/Mat4/camera math |
| `src/egui/painter.cr` | `Mesh3DCmd` + `Painter#mesh3d` |
| `src/egui/widgets/viewport3d.cr` | new — orbit-camera viewport widget |
| `spec/viewport3d_spec.cr` | new — headless contract |
| `examples/xor3d.cr` | new — XOR/MLP demo |
| `examples/objviewer.cr` (+ `examples/obj/`) | new — OBJ viewer, parser first in Crystal |
| `Rakefile` | bin targets for both demos; tinyobj C++ shim rule only in Phase 3.2 |

## Acceptance checklist

- [ ] Rotating depth-tested pyramid renders correctly inside a clipped
      panel (direct **and** detached render-thread modes).
- [ ] 2D UI after a 3D viewport (overlapping window, tooltip) still
      renders correctly (default projection restored).
- [ ] `xor3d`: training visibly converges; input-space ↔ hidden-space
      toggle shows separability appearing; 60 fps release.
- [ ] `objviewer`: drag & drop loads an .obj, orbits smoothly, wireframe
      toggle works.
- [ ] Existing specs still pass; no behavior change with no 3D widgets
      on screen.
