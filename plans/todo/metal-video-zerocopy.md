# Metal video zero-copy — plan

**Status: DONE (see the completion notes at the bottom).**

**Prerequisite (assumed done):** the SOKOL_METAL backend of the sokol
shim exists and macOS renders through it — sgl / paint packets /
kind-3 video segments unchanged, and macOS still renders DIRECT (no
packet mailbox; the paint call IS the render thread). Everything below
builds on that.

## Goal

Eliminate the two bus crossings of the current macOS fast path
(GL: `av_hwframe_transfer_data` GPU→CPU + `sg_update_image` CPU→GPU,
measured `upd≈210–270 ms/s` at 720p60). Target pipeline:

```
VideoToolbox decode (ffmpeg hwcontext, AV_PIX_FMT_VIDEOTOOLBOX)
  → frame.data[3] = CVPixelBufferRef (IOSurface-backed, no copy)
  → CVMetalTextureCache → MTLTexture per plane (no copy)
  → sg image via desc.mtl_textures[] injection (like .vk_image on Linux)
  → the existing video quad pipeline (YUV→RGB on GPU)
```

Zero per-frame copies and zero per-frame uploads — the same
export-once-per-surface cache model as the Linux dmabuf path
(plans/completed/videoplayer.md, "Fast rendering").

## Pieces

### C shim — backend/sokol_shim.c

1. **New backend variant** `SH_VIDEO_MTL` in the SH_VIDEO family
   (`#elif defined(SOKOL_METAL) && defined(__APPLE__)`). The macros
   STAY at the top of the file — a `#if` before its `#define` dead-
   strips the whole path at -O2 (the "everything links, nothing draws"
   trap hit twice on the GL port).
2. **Per-entry state** (replaces the GL branch's `sg_image y, uv`):
   - `CVMetalTextureCacheRef` — ONE per device, created lazily from
     the SAME `id<MTLDevice>` sokol renders with (poke `_sg.mtl`
     internals the way the Vulkan path reads `_sg.vk.dev`; a
     `MTLCreateSystemDefaultDevice()` fallback is wrong — must match
     the swapchain device).
   - import cache keyed by CVPixelBuffer identity (the buffer pointer
     works; VideoToolbox cycles a small pool of surfaces exactly like
     the VA decode pool). First sight of a buffer:
     `CVMetalTextureCacheCreateTextureFromImage` twice — plane 0
     `R8Unorm`/`R16Unorm`, plane 1 `RG8Unorm`/`RG16Unorm` by the
     buffer's `CVPixelBufferGetPixelFormatType()` ('420v'/'420f' → 8
     bit, 'P010' family → 10 bit) — each wrapped into an sg image via
     `sg_image_desc.mtl_textures[SG_NUM_INFLIGHT_FRAMES]`. Later
     frames on the same buffer hit the cache. N-slot cache, eviction
     never touches the entry the last draw sampled (mirror
     `SH_VIDEO_CACHE`).
   - `CVMetalTextureRef` × 2 kept alive per cache slot — they pin the
     MTLTexture and the underlying IOSurface.
3. **New A-side entry**
   `egui_cr_video_frame_cvpixelbuffer(id, const void* cvpixbuf, int tenbit, const float* cmat, const float* range)`.
   Direct mode: store the newest buffer into the pending slot
   (newest-wins coalescing — identical to the GL pend slot, except the
   flush does NOT upload: it wraps textures). Flush runs in
   `egui_cr_begin_pass`, outside any sg pass. No `sg_update_image`
   anywhere → no VALIDATE_UPDIMG_ONCE concern at all.
4. **Lifetime / hold ring**: keep the last N=4 CVPixelBuffers
   CFRetain'd (the GL port reuses `zc_hold_frame`'s AVFrame ring; on
   the C side the CVMetalTexture keeps its IOSurface pinned, but the
   DECODER may recycle a returned buffer — the hold ring prevents
   VideoToolbox overwriting a surface the render thread still
   samples; the tearing lesson from the Linux port).
   `CVMetalTextureCacheFlush` only on entry destroy / decoder reopen.
5. **Draw**: `sh_draw_video` is already backend-neutral (two sg views
   over plane images) — only the entry struct fields differ.
6. **Shader**: third variant of the video quad pipeline — MSL source
   in `sg_shader_desc` (sokol Metal compiles source at runtime; no
   metallib bake step needed). `msl_buffer_n` / `msl_texture_n` /
   `msl_sampler_n` slots for the two uniform blocks and the y/uv
   pairs. Keep the CPU payload byte-for-byte (mvp mat4; cmat as 3×
   float4 columns + range float4 — MSL has float3x3, but reusing the
   vec4 layout keeps ONE CPU-side struct for all three backends;
   verify the MSL buffer layout against the std140 payload with the
   color test before trusting it). Math mirrors
   backend/shaders/video_quad.frag: `uv * range.z + range.w`, both
   chroma axes share the scalar scale/bias.

### Player — examples/video/player.cr

1. `setup_hw` unchanged (VideoToolbox device, hw pix fmt via
   `avcodec_get_hw_config`). The fast-path branch in `open` picks MTL
   zero-copy when the shim advertises it — extend
   `egui_cr_video_supported` semantics or add a mode query so the
   player can distinguish "GL upload" from "MTL zero-copy".
2. New `vt_zc_frame(frame)`:
   - pts/fps/size bookkeeping identical to `vt_frame`;
   - NO `av_hwframe_transfer_data` — take `frame.value.data[3]`
     (CVPixelBufferRef), route through the hold ring, call the new
     shim entry; `tenbit` from the CVPixelBuffer pixel format type;
   - colorimetry: reuse `compute_colorimetry` (the 10-bit ladders
     already normalize v/1023).
3. **Fallback ladder** (each step degrades mid-run, no reopen —
   VideoToolbox owns its surfaces):
   MTL zero-copy → VT copy-back NV12 plane upload (the CURRENT GL
   path verbatim — `sg_update_image` is backend-neutral, works on
   Metal) → sws RGBA copy-back. A texture-cache failure latches
   `egui_cr_video_failed` and the player steps down.

### Rakefile

Nothing new for video: the Metal backend task brings
`-framework Metal`; add `-framework CoreVideo` there
(CVMetalTextureCache lives in CoreVideo).

## Gotchas carried over from the GL port

- SH_VIDEO macros before first use, or -O2 eats the path silently.
- Direct mode: everything texture-related happens between passes
  (begin_pass flush), never inside one.
- Hold ring ≥ 3–4 frames or the decoder recycles surfaces under the
  sampler (torn frames / a "second video" flicker).
- Uniform layout differences between std140 and MSL — prove with the
  color test, don't assume.
- `AVERROR_EAGAIN` = `-Errno::EAGAIN.value` (macOS 35) — already
  portable; keep it that way.

## Test plan (same harness as the GL port)

- `EGUI_VIDEO_DEBUG=1`: new `mtl-zc` marker in the hwstat, and the
  objective win — `upd≈0ms` (today's GL path shows 210–270 ms/s at
  720p60).
- Screenshots (`--screenshot`, numeric RGB mean of the video area):
  fast path vs `EGUI_VIDEO_HW=0` software, ≤ ~2/255 per channel, no
  tint. 8-bit h264, 10-bit HEVC (P010), a +audio file; pause/resume,
  seek ±, EOF, restart.
- Fallback drill: a `EGUI_VIDEO_NOIMPORT`-style kill switch on the
  texture-cache wrap to prove the mid-run step-down to the NV12
  upload path (no crash, no reopen).
- Stability: a 15+ min file (watch for CVMetalTextureCache growth —
  the cache must stay bounded by the import-cache slots).

## Non-goals

- GPU-side scale/adaptation (no scale_vaapi analog; fixed native,
  capped like the Linux zc single-slot ladder).
- Windows/Android parity; IOSurface on iOS shares the code but is a
  separate verification.

## Expected result

`upd` drops to ~0, the CPU packing memcpy disappears, and 4K/6K
become bus-bound nowhere — the same class of win the Linux zero-copy
path got over its copy-back fallback.

## Completion notes (implementation as built)

- Shim: `SH_VIDEO_MTL` / `SH_VIDEO_UPLOAD` macros, `sh_video_flush_mtl`
  (wrap + 32-slot pointer-keyed import cache, MRC retain transferred
  to sg's pool — see the ownership comment there), `sh_draw_video`
  MTL guard (cur wrap if live, else upload planes), MSL shaders
  `SH_VIDEO_VS_MTL/FS_MTL` (entry `_main`, msl slots 0/1 + 0/1/0/1).
- Entry points: `egui_cr_video_frame_cvpixelbuffer`,
  `egui_cr_video_zc_supported`, `egui_cr_video_clear_fail` (ladder
  reset). w/h/tenbit derived on the C side from the buffer's pixel
  format ('P010' → R16/RG16).
- Player: `vt_zc_frame` (no transfer, `data[3]`, pts bookkeeping),
  `mtl_teardown`/`mtl_fallback` ladder, `EGUI_VIDEO_MTL=0` kill switch
  for the fallback drill. No hold ring needed: the C-side CFRetain per
  cache slot pins the surface (the plan's item 4 turned out redundant).
- Verified: `upd=0ms/0` + `mtl-zc` HUD marker; 8-bit h264 avg RGB
  matches SW (245,246,247 both); 10-bit HEVC P010 averages match, diff
  profile is pure temporal skew of testsrc2; `EGUI_VIDEO_MTL=0`
  downgrades cleanly to nv12 upload with correct color; GL backend
  rebuild still green; 6/6 crash-free runs after the zombie-MTLTexture
  fix (NSZombie caught the over-release; root cause: sg's injected
  image path is pool(+1)/release(−1) — the caller's +1 IS the pool's
  reference, an extra pin double-owns it).
