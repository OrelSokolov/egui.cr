# Vendored C headers

Only the headers the build needs, vendored in-tree so the repository
builds offline. Upstream commits they were copied from:

| header | source | commit |
|---|---|---|
| `sokol/sokol_app.h`, `sokol_gfx.h`, `sokol_glue.h`, `sokol_log.h`, `util/sokol_gl.h`, `util/sokol_fontstash.h` | https://github.com/floooh/sokol | `c0db757` |
| `fontstash/fontstash.h`, `fontstash/stb_truetype.h` | https://github.com/memononen/fontstash (src/) | `b5ddc97` |
| `stb_image.h` | https://github.com/nothings/stb (v2.30) | `ae72102` |

Licenses: sokol and fontstash are zlib/libpng (see their headers); the
fontstash `stb_truetype.h` is public domain / MIT (stb).

The full reference clones (sokol, fontstash, and the egui repository
the architecture analysis in docs/ANALYSIS.md was made against) are
kept out of git in `.ref/` — see .gitignore. To refresh a vendored
header, clone the upstream, copy the file over and update the commit
column above.
