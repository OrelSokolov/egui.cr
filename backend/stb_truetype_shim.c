// egui-cr stb_truetype exposure for the Crystal text stack
// (src/egui/backend/text.cr): font parsing, glyph outlines, metrics,
// kerning — rasterization itself is Crystal-side (light Y-hint).
//
// This is a SEPARATE translation unit from sokol_shim.c on purpose:
// sokol_shim.c compiles stb_truetype through fontstash.h, which overrides
// the stb allocator (STBTT_malloc -> fons__tmpalloc, requires a live
// FONScontext as userdata) and hides everything as STBTT_STATIC. Here the
// same vendored header is compiled plain: default malloc, global symbols —
// the fontstash copy stays untouched inside its TU.
//
// The vertex buffer from egui_cr_glyph_shape is malloc'd by stb and must be
// released with egui_cr_glyph_shape_free (stbtt_FreeShape).

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

#include <stdlib.h>

void* egui_cr_font_info_new(const unsigned char* data, int font_index) {
    stbtt_fontinfo* info = (stbtt_fontinfo*)malloc(sizeof(stbtt_fontinfo));
    if (!info) return NULL;
    int offset = stbtt_GetFontOffsetForIndex(data, font_index);
    if (offset < 0 || !stbtt_InitFont(info, data, offset)) {
        free(info);
        return NULL;
    }
    return info;
}

void egui_cr_font_vmetrics(void* p, int* ascent, int* descent, int* linegap) {
    stbtt_GetFontVMetrics((stbtt_fontinfo*)p, ascent, descent, linegap);
}

int egui_cr_font_find_glyph(void* p, int unicode) {
    return stbtt_FindGlyphIndex((stbtt_fontinfo*)p, unicode);
}

void egui_cr_glyph_hmetrics(void* p, int glyph, int* advance, int* lsb) {
    stbtt_GetGlyphHMetrics((stbtt_fontinfo*)p, glyph, advance, lsb);
}

int egui_cr_glyph_kern(void* p, int g1, int g2) {
    return stbtt_GetGlyphKernAdvance((stbtt_fontinfo*)p, g1, g2);
}

float egui_cr_scale_for_pixel_height(void* p, float pixels) {
    return stbtt_ScaleForPixelHeight((stbtt_fontinfo*)p, pixels);
}

const stbtt_vertex* egui_cr_glyph_shape(void* p, int glyph, int* count) {
    stbtt_vertex* vertices = NULL;
    *count = stbtt_GetGlyphShape((stbtt_fontinfo*)p, glyph, &vertices);
    return vertices;
}

void egui_cr_glyph_shape_free(void* p, stbtt_vertex* vertices) {
    stbtt_FreeShape((stbtt_fontinfo*)p, vertices);
}
