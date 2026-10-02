# Video player demo — plan

Just-for-fun demo: an FFmpeg-backed video player UI built on egui-cr.
Audio is explicitly out of scope; the goal is playback, pause, stop,
seek and a sane control surface.

## Framework / project split

The rule: nothing FFmpeg-related goes into the framework. egui-cr only
gains the generic GPU-texture lifecycle it is missing today — the same
capability any video/camera/animation use case needs.

### Framework additions (src/egui + backend/sokol_shim.c)

Today `TextureRegistry#register_rgba` uploads immutable data
(`SG_USAGE_IMMUTABLE`) and creates a **new** image on every call, with
no update or destroy path. Decoded video needs to push fresh pixels
into the **same** texture 24–60 times per second, or it leaks GPU
memory. Additions:

1. `backend/sokol_shim.c`
   - `egui_cr_make_stream_texture(w, h)` — empty `SG_USAGE_STREAM`
     image + view, registered in a small view-id → image table
     (mirrors the glyph-atlas registry; stream images cannot be
     created with initial data — sokol validation WRITABLE_NO_DATA).
   - `egui_cr_update_texture(view_id, w, h, rgba8)` —
     `sg_update_image` + `sg_reset_state_cache` (the GL state cache
     caveat the atlas path already documents).
   - `egui_cr_destroy_texture(view_id)` — destroy view + image and
     drop it from the registry. Immutable textures created by
     `egui_cr_make_texture` join the same registry so they can be
     released too.
2. `src/egui/backend/sokol.cr` — `fun` bindings for the three calls;
   `SokolTextureRegistry` gains `create_stream`, `update`, `destroy`.
3. `src/egui/textures.cr` — the abstract seam grows
   `create_stream(w, h)`, `update(id, w, h, data)`, `destroy(id)`;
   `DummyTextureRegistry` implements them headlessly (deterministic
   ids, id reuse on update) and specs cover the contract.

Everything else the player needs already exists: `Image` widget +
`ImageCmd`, continuous vsync frame loop with on-demand idle skip
(video playback calls `ctx.request_repaint` every frame while
playing), `SystemPorts::OpenFileDialog`, drag & drop
(`Event.dropped_files`).

### Demo project (examples/video/)

A self-contained subproject — its own sources, no changes outside
`examples/` — built to the separate `bin/video` binary:

- `examples/video/ffmpeg.cr` — hand-rolled Crystal bindings to the
  system FFmpeg libraries (`libavformat`, `libavcodec`, `libswscale`,
  `libavutil`), linked via `@[Link]` (they live in the default linker
  path on this box; pkg-config flags are the documented fallback).
  Covers exactly the demo's surface: open/read/seek, decode,
  RGBA conversion, error strings.
- `examples/video/player.cr` — `VideoPlayer` class: demux → decode →
  `sws_scale` to RGBA → push into a stream texture. Synchronous
  decode on the UI thread, paced by a monotonic master clock against
  frame PTS (decode-at-most-N-frames per UI frame to absorb bursts).
  The sapp C loop never yields to the Crystal scheduler, so decoder
  fibers would starve — an OS decode thread is future work, not
  needed at SD/HD sizes.
- `examples/video/app.cr` — the egui app: open button (native dialog)
  + drag & drop, play/pause, stop, seek slider, time display, space
  hotkey. Video is fitted into the central panel preserving aspect.
- `examples/video.cr` — entry point requiring the three above.
- `Rakefile` — add `"video"` to EXAMPLES (one line; `rake build:examples`
  then produces `bin/video`).

## Controls

- **Open** — file dialog / drag & drop onto the window.
- **Play/Pause** — toggle; pause freezes the master clock, UI keeps
  repainting.
- **Stop** — close input, free decoder + texture, back to placeholder.
- **Seek** — slider drag: `avformat_seek_file` to a keyframe +
  `avcodec_flush_buffers` + decode forward to the target.
- **Space** — play/pause hotkey.

## Test plan

- `rake spec` — framework regression + new texture-seam specs.
- `rake build:examples` — native lib rebuild (shim changes) + bin/video.
- Generate a synthetic clip (`ffmpeg -f lavfi testsrc`) and smoke-test:
  binary opens, decodes, plays, pauses, seeks, stops without leaks or
  GL validation errors.

## Status — implemented & verified

Everything above landed:

- Framework: `egui_cr_make_stream_texture` / `egui_cr_update_texture` /
  `egui_cr_destroy_texture` in the shim; `TextureRegistry` seam +
  Sokol/GPU and headless implementations; spec coverage.
- Demo: `examples/video/` (ffmpeg.cr bindings, player.cr, app.cr) +
  `examples/video.cr` entry; `bin/video` via `rake build:examples`.
- Verified: 330 specs green; full `rake build:examples`; 12 s testsrc2
  clip plays at a steady 30 fps decode to `eof`, then holds the last
  frame (Play restarts). Headless (dummy registry) run exercised
  open/advance/pause/seek-forward/seek-back/close.

Runtime debug switch: `EGUI_VIDEO_DEBUG=1 ./bin/video file.mp4` prints
one stderr line per second (state, pts, decoded frames, fps, first
pixel, advance/decode call counts) — the objective smoke channel
while screenshot tools can't see GL windows on this box.

Gotchas found on the way (worth remembering):

- GPU textures must only be created AFTER `Sokol.run` installed the
  real `SokolTextureRegistry` (the CLI-arg file opens on the first
  update, never before run); `ctx.textures` must be read lazily for
  the same reason — an eagerly captured registry is the dummy.
- A stream texture may be pushed to the GPU AT MOST ONCE per UI
  frame: sokol validates one `sg_update_image` per image and frame
  (`VALIDATE_UPDIMG_ONCE`). The catch-up decode can produce several
  frames between repaints, so the player converts every decoded
  frame into the shared RGBA buffer and blits only the newest one,
  once per `advance`/`open`/`seek`.
- `avformat_open_input` needs a NULL-initialized `AVFormatContext*`.
- Seek uses `avformat_seek_file` with `stream_index = -1` and
  AV_TIME_BASE microseconds; stream-relative timestamps made the mp4
  demuxer return EPERM.
- EOF must flip the player state from BOTH decoder-exhaustion paths
  (demux EOF + already-flushed receive), or the app keeps "playing"
  a frozen last frame.

## Format matrix — verified locally

h264 (420/422/444, 8/10-bit, mkv/mp4), hevc 10-bit, mpeg2 (ts),
mpeg4, wmv2, vp9, av1, prores — all decode with correct colors and
pacing (`EGUI_VIDEO_DEBUG=1` shows a per-second `avg=R,G,B` line;
healthy ≈ 145,121,117 on testsrc2, pure green would be ≈ 0,135,0).

Robustness after the first real-world reports:

- Stream pick goes through `av_find_best_stream` (+ decoder hint)
  instead of "first video stream" — multi-stream containers with
  cover art / dub tracks select properly now.
- Errors carry the codec name (`no decoder for codec hevc`).
- The debug line prints `adv`/`dec`/`blit`/`upd` counters — they
  caught two classes of ghosts already: the once-per-frame upload
  rule violation, and BACKGROUND-WINDOW THROTTLING (an occluded or
  screen-locked window gets ~1 repaint/s from the compositor, so
  `adv` drops while `dec` still burns the catch-up budget — that is
  the environment, not the player; a focused window paces normally).

## Open question — green screen on some real files

RESOLVED for webm: "any webm goes green" reproduced on VP8 files.
Root cause (bisected via `EGUI_VIDEO_THREADS` and per-stage probes):
the NATIVE vp8 decoder (and libvpx) with FFmpeg threading enabled
(`thread_count > 1`) emits all-zero YUV planes — which sws faithfully
converts to pure green (Y=0, Cb=Cr=0 → RGB 0,135,0) — but ONLY inside
this GUI process; the same file + settings decode fine in a plain CLI
process. VP9/AV1/H.264/HEVC/mpeg2/prores/wmv unaffected. Fix: decoders
whose name starts with `vp8` or `libvpx` run single-threaded
(`examples/video/player.cr`); everything else keeps auto slice
threading. Verified across the full matrix (webm vp8/vp9/vp9-alpha/
av1 + the mp4/mkv/ts/mov regression set) — healthy `avg=` everywhere.

Remaining known limitation: files that start mid-GOP (cut downloads)
show decoder concealment garbage until the first keyframe — inherent
to the file, any player behaves the same.

## Non-goals

Audio, subtitles, playlists, hardware decode, streaming protocols,
portable FFmpeg vendoring (system libs only), decode thread offload.
