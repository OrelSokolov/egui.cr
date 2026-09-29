// egui-cr NanoSVG exposure for the Svg widget's texture bake
// (src/egui/backend/nanosvg.cr): parse SVG source into shapes
// (viewBox applied, units converted at the given DPI) and rasterize
// to a straight-alpha RGBA8 buffer with anti-aliasing. The Crystal
// side installs this as the PRIMARY rasterizer and keeps the built-in
// software rasterizer (src/egui/widgets/svg.cr #rasterize) as the
// fallback — the freetype.cr/text.cr pattern applied to vector art.
//
// Notes:
//   * nsvgParse MODIFIES the input buffer in place — the caller passes
//     a private mutable copy, never a Crystal string's memory.
//   * An image that parsed but produced no shapes (unsupported or
//     empty content) is reported as NULL so the caller falls back to
//     its own parser, which may understand the file differently.
//   * A rasterizer is created per call: bakes are rare (cache misses
//     only), so there is nothing to gain from keeping one alive.

#define NANOSVG_ALL_COLOR_KEYWORDS
#define NANOSVG_IMPLEMENTATION
#include "nanosvg.h"
#define NANOSVGRAST_IMPLEMENTATION
#include "nanosvgrast.h"

void* egui_cr_svg_parse(char* input, float dpi) {
    NSVGimage* image = nsvgParse(input, "px", dpi);
    if (image && !image->shapes) {
        nsvgDelete(image);
        return NULL;
    }
    return image;
}

void egui_cr_svg_free(void* image) {
    nsvgDelete((NSVGimage*)image);
}

void egui_cr_svg_size(void* image, float* w, float* h) {
    *w = ((NSVGimage*)image)->width;
    *h = ((NSVGimage*)image)->height;
}

int egui_cr_svg_rasterize(void* image, float tx, float ty, float scale,
                          unsigned char* dst, int w, int h) {
    NSVGrasterizer* rast = nsvgCreateRasterizer();
    if (!rast) return 0;
    nsvgRasterize(rast, (NSVGimage*)image, tx, ty, scale, dst, w, h, w * 4);
    nsvgDeleteRasterizer(rast);
    return 1;
}
