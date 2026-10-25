// egui-cr rlottie exposure for the Lottie player's stream texture
// (src/egui/backend/rlottie.cr): parse Bodymovin JSON once, report
// viewport/duration/fps/frame count, and render any frame into a
// straight-alpha RGBA8 buffer.
//
// Built and archived into its own libegui_cr_rlottie only under
// LOTTIE=1 (see Rakefile) — apps that never require
// "egui/backend/rlottie" link no C++ runtime.
//
// Notes:
//   * rlottie's C API (inc/rlottie_capi.h) is a plain-C wrapper over
//     the C++ classes, so this shim stays C like the others.
//   * rlottie renders ARGB32 PREMULTIPLIED (see Surface in rlottie.h),
//     while the texture pipeline expects straight alpha (the NanoSVG
//     bake contract). On little-endian hosts the ARGB32 word lands in
//     memory as B,G,R,A — #egui_cr_lottie_render reorders to R,G,B,A
//     and un-premultiplies in the same in-place walk, no extra buffer.
//   * Thread support is compiled out (LOTTIE_THREAD=OFF):
//     lottie_animation_render is the synchronous API called from the
//     UI thread, once per changed frame. The model cache is off too
//     (LOTTIE_CACHE=OFF) — memoization lives on the Crystal side,
//     the NanoSvgCr pattern.

#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "rlottie_capi.h"

void* egui_cr_lottie_from_data(const char* data, const char* key) {
    return lottie_animation_from_data(data, key, "");
}

void egui_cr_lottie_free(void* animation) {
    lottie_animation_destroy((Lottie_Animation*)animation);
}

void egui_cr_lottie_size(void* animation, size_t* w, size_t* h) {
    lottie_animation_get_size((const Lottie_Animation*)animation, w, h);
}

double egui_cr_lottie_duration(void* animation) {
    return lottie_animation_get_duration((const Lottie_Animation*)animation);
}

double egui_cr_lottie_framerate(void* animation) {
    return lottie_animation_get_framerate((const Lottie_Animation*)animation);
}

size_t egui_cr_lottie_total_frames(void* animation) {
    return lottie_animation_get_totalframe((const Lottie_Animation*)animation);
}

int egui_cr_lottie_render(void* animation, size_t frame,
                          unsigned char* dst, int w, int h) {
    if (!animation || !dst || w <= 0 || h <= 0) return 0;
    lottie_animation_render((Lottie_Animation*)animation, frame,
                            (uint32_t*)dst, (size_t)w, (size_t)h,
                            (size_t)w * 4);
    // ARGB32 premultiplied (LE: B,G,R,A) -> straight RGBA8.
    size_t n = (size_t)w * (size_t)h;
    for (size_t i = 0; i < n; i++) {
        unsigned char* px = dst + i * 4;
        unsigned char b = px[0], g = px[1], r = px[2], a = px[3];
        if (a != 0 && a != 255) {
            // rounded un-premultiply: round(c * 255 / a)
            r = (unsigned char)((r * 255 + a / 2) / a);
            g = (unsigned char)((g * 255 + a / 2) / a);
            b = (unsigned char)((b * 255 + a / 2) / a);
        }
        px[0] = r; px[1] = g; px[2] = b; px[3] = a;
    }
    return 1;
}

// --- render-tree geometry dump -------------------------------------
// egui_cr_lottie_dump_tree serializes the evaluated scene graph —
// lottie_animation_render_tree's LOTLayerNode tree — into compact
// JSON, PRE-rasterization: paths (points + element codes), colors,
// gradients (resolved coordinates + stops), strokes, masks, mattes.
// This is the twin-verification dataset for the pure-Crystal Lottie
// port (plans/lottie-port.md): the port's evaluator must reproduce
// these numbers within a float epsilon, so the dataset is generated
// once from rlottie (scripts/make_lottie_dataset.cr) and replayed in
// the port's specs. Returned buffer is malloc'd — free with
// egui_cr_lottie_free_dump.
//
// Path element codes are VPath::Element bytes: 0=MoveTo, 1=LineTo,
// 2=CubicTo, 3=Close (each CubicTo consumes 3 points).

typedef struct {
    char  *data;
    size_t len;
    size_t cap;
} DumpBuf;

static void dump_need(DumpBuf *b, size_t extra) {
    if (b->len + extra + 1 <= b->cap) return;
    size_t cap = b->cap ? b->cap * 2 : 4096;
    while (cap < b->len + extra + 1) cap *= 2;
    b->data = (char *)realloc(b->data, cap);
    b->cap = cap;
}

static void dumpf(DumpBuf *b, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int need = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (need <= 0) return;
    dump_need(b, (size_t)need);
    va_start(ap, fmt);
    vsnprintf(b->data + b->len, (size_t)need + 1, fmt, ap);
    va_end(ap);
    b->len += (size_t)need;
}

static void dump_string(DumpBuf *b, const char *s) {
    if (!s) { dumpf(b, "\"\""); return; }
    dumpf(b, "\"");
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        switch (*p) {
        case '"':  dumpf(b, "\\\""); break;
        case '\\': dumpf(b, "\\\\"); break;
        case '\n': dumpf(b, "\\n"); break;
        case '\r': dumpf(b, "\\r"); break;
        case '\t': dumpf(b, "\\t"); break;
        default:
            if (*p < 0x20) dumpf(b, "\\u%04x", *p);
            else dumpf(b, "%c", *p);
        }
    }
    dumpf(b, "\"");
}

static void dump_floats(DumpBuf *b, const float *pts, size_t count) {
    dumpf(b, "[");
    for (size_t i = 0; i < count; i++)
        dumpf(b, "%s%.9g", i ? "," : "", (double)pts[i]);
    dumpf(b, "]");
}

static void dump_elms(DumpBuf *b, const char *elm, size_t count) {
    dumpf(b, "[");
    for (size_t i = 0; i < count; i++)
        dumpf(b, "%s%d", i ? "," : "", (int)(unsigned char)elm[i]);
    dumpf(b, "]");
}

static void dump_path(DumpBuf *b, const float *ptPtr, size_t ptCount,
                      const char *elmPtr, size_t elmCount) {
    dumpf(b, "{\"pts\":");
    dump_floats(b, ptPtr, ptCount);
    dumpf(b, ",\"elm\":");
    dump_elms(b, elmPtr, elmCount);
    dumpf(b, "}");
}

static void dump_node(DumpBuf *b, const LOTNode *n) {
    dumpf(b, "{\"keypath\":");
    dump_string(b, n->keypath);
    dumpf(b, ",\"brush\":%d,\"fill_rule\":%d,\"color\":[%u,%u,%u,%u]",
          (int)n->mBrushType, (int)n->mFillRule,
          n->mColor.r, n->mColor.g, n->mColor.b, n->mColor.a);
    dumpf(b, ",\"stroke\":{\"enable\":%u,\"width\":%.9g,\"cap\":%d,"
             "\"join\":%d,\"miter\":%.9g,\"dash\":[",
          n->mStroke.enable, (double)n->mStroke.width,
          (int)n->mStroke.cap, (int)n->mStroke.join,
          (double)n->mStroke.miterLimit);
    for (int i = 0; i < n->mStroke.dashArraySize; i++)
        dumpf(b, "%s%.9g", i ? "," : "", (double)n->mStroke.dashArray[i]);
    dumpf(b, "]}");
    dumpf(b, ",\"gradient\":{\"type\":%d,\"stops\":[", (int)n->mGradient.type);
    for (size_t i = 0; i < n->mGradient.stopCount; i++) {
        const LOTGradientStop *s = &n->mGradient.stopPtr[i];
        dumpf(b, "%s{\"pos\":%.9g,\"rgba\":[%u,%u,%u,%u]}", i ? "," : "",
              (double)s->pos, s->r, s->g, s->b, s->a);
    }
    dumpf(b, "],\"start\":[%.9g,%.9g],\"end\":[%.9g,%.9g],"
             "\"center\":[%.9g,%.9g],\"focal\":[%.9g,%.9g],"
             "\"cradius\":%.9g,\"fradius\":%.9g}",
          (double)n->mGradient.start.x, (double)n->mGradient.start.y,
          (double)n->mGradient.end.x, (double)n->mGradient.end.y,
          (double)n->mGradient.center.x, (double)n->mGradient.center.y,
          (double)n->mGradient.focal.x, (double)n->mGradient.focal.y,
          (double)n->mGradient.cradius, (double)n->mGradient.fradius);
    if (n->mImageInfo.data) {
        dumpf(b, ",\"image\":{\"alpha\":%u,\"w\":%zu,\"h\":%zu,\"matrix\":[",
              n->mImageInfo.mAlpha, n->mImageInfo.width, n->mImageInfo.height);
        const float *m = &n->mImageInfo.mMatrix.m11;
        for (int i = 0; i < 9; i++)
            dumpf(b, "%s%.9g", i ? "," : "", (double)m[i]);
        dumpf(b, "]}");
    }
    dumpf(b, ",\"path\":");
    dump_path(b, n->mPath.ptPtr, n->mPath.ptCount,
              n->mPath.elmPtr, n->mPath.elmCount);
    dumpf(b, "}");
}

static void dump_layer(DumpBuf *b, const LOTLayerNode *l) {
    dumpf(b, "{\"keypath\":");
    dump_string(b, l->keypath);
    dumpf(b, ",\"alpha\":%u,\"visible\":%d,\"matte\":%d",
          l->mAlpha, l->mVisible, (int)l->mMatte);
    if (l->mMaskList.size > 0 && l->mMaskList.ptr) {
        dumpf(b, ",\"masks\":[");
        for (size_t i = 0; i < l->mMaskList.size; i++) {
            const LOTMask *m = &l->mMaskList.ptr[i];
            dumpf(b, "%s{\"path\":", i ? "," : "");
            dump_path(b, m->mPath.ptPtr, m->mPath.ptCount,
                      m->mPath.elmPtr, m->mPath.elmCount);
            dumpf(b, ",\"mode\":%d,\"alpha\":%u}", (int)m->mMode, m->mAlpha);
        }
        dumpf(b, "]");
    }
    if (l->mClipPath.ptCount > 0) {
        dumpf(b, ",\"clip\":");
        dump_path(b, l->mClipPath.ptPtr, l->mClipPath.ptCount,
                  l->mClipPath.elmPtr, l->mClipPath.elmCount);
    }
    if (l->mLayerList.size > 0 && l->mLayerList.ptr) {
        dumpf(b, ",\"layers\":[");
        for (size_t i = 0; i < l->mLayerList.size; i++)
            dumpf(b, "%s", i ? "," : ""), dump_layer(b, l->mLayerList.ptr[i]);
        dumpf(b, "]");
    }
    if (l->mNodeList.size > 0 && l->mNodeList.ptr) {
        dumpf(b, ",\"nodes\":[");
        for (size_t i = 0; i < l->mNodeList.size; i++)
            dumpf(b, "%s", i ? "," : ""), dump_node(b, l->mNodeList.ptr[i]);
        dumpf(b, "]");
    }
    dumpf(b, "}");
}

char* egui_cr_lottie_dump_tree(void* animation, size_t frame,
                               size_t w, size_t h) {
    if (!animation) return NULL;
    const LOTLayerNode* root =
        lottie_animation_render_tree((Lottie_Animation*)animation,
                                     frame, w, h);
    if (!root) return NULL;
    DumpBuf b = {NULL, 0, 0};
    dump_layer(&b, root);
    return b.data;
}

void egui_cr_lottie_free_dump(char* dump) {
    free(dump);
}
