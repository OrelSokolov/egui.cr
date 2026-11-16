// egui.cr video helper: a FIXED-size VAAPI frames pool (the GStreamer
// gstvaallocator model — surfaces pre-allocated once, recycled by the
// decoder forever; the dynamic per-frame pool was the churn behind the
// ~700-frame degradation). Compiled into its own archive — only the
// video example links it (avutil deps stay out of the core shim).
#include <libavutil/hwcontext.h>
#include <unistd.h>

// Returns the AVBufferRef* (caller owns) or NULL.
void* egui_video_pool_create(void* device_ref, int format, int sw_format,
                             int w, int h, int pool_size) {
    AVBufferRef* fref = av_hwframe_ctx_alloc((AVBufferRef*)device_ref);
    if (!fref) return 0;
    AVHWFramesContext* fc =
        (AVHWFramesContext*)((AVBufferRef*)fref)->data;
    fc->format = (enum AVPixelFormat)format;
    fc->sw_format = (enum AVPixelFormat)sw_format;
    fc->width = w;
    fc->height = h;
    fc->initial_pool_size = pool_size;
    if (av_hwframe_ctx_init(fref) != 0) {
        av_buffer_unref(&fref);
        return 0;
    }
    return fref;
}

// AVBufferRef deref for the Crystal diagnostics: both our pool ref and
// a frame's hw_frames_ctx are AVBufferRef* wrappers — compare their
// ->data (the pointed-to AVHWFramesContext) to tell whether decoded
// frames flow from OUR pool or the decoder made its own.
void* egui_video_ref_data(void* ref) {
    return ref ? ((AVBufferRef*)ref)->data : 0;
}

#if defined(__linux__)
// libva-dev is not on the box — declare the ABI instead: VADisplay is a
// pointer, VASurfaceID / VAStatus are plain ints. AVVAAPIDeviceContext
// (libavutil 59, "Allocated as AVHWDeviceContext.hwctx") is JUST the
// display + driver_quirks — display at offset 0 (hwcontext_vaapi.h
// includes <va/va.h>, so the real header cannot be used here).
extern int vaSyncSurface(void* display, unsigned int surface);
extern int vaExportSurfaceHandle(void* display, unsigned int surface,
                                 unsigned int mem_type, unsigned int flags,
                                 void* descriptor);
extern char* vaErrorStr(int err);
typedef struct { void* display; unsigned int driver_quirks; }
    EguiVAAPIContext;

// libva constants (va.h / va_drmcommon.h, VA 1.22)
#define ZC_VA_MEM_DRM_PRIME_2 0x40000000u
#define ZC_VA_EXPORT_READ_ONLY 0x0001u
#define ZC_VA_EXPORT_SEPARATE_LAYERS 0x0004u

// VADRMPRIMESurfaceDescriptor layout (object: fd, size, u64 modifier;
// layer: drm_format, num_planes, object_index/offset/pitch[4] —
// verified against VA 1.22 by tools/zc_probe.c)
typedef struct { int fd; unsigned size; unsigned long long modifier; }
    ZcPrimeObj;
typedef struct {
    unsigned drm_format, num_planes;
    unsigned object_index[4], offset[4], pitch[4];
} ZcPrimeLayer;
typedef struct {
    unsigned fourcc, width, height, num_objects;
    ZcPrimeObj objects[4];
    unsigned num_layers;
    ZcPrimeLayer layers[4];
} ZcPrimeDesc;

static void* zc_va_display(void* device_ref) {
    AVHWDeviceContext* hwctx =
        (AVHWDeviceContext*)((AVBufferRef*)device_ref)->data;
    if (hwctx->type != AV_HWDEVICE_TYPE_VAAPI || !hwctx->hwctx)
        return 0;
    return ((EguiVAAPIContext*)hwctx->hwctx)->display;
}
#endif

// Per-frame decode-write barrier for the zero-copy path (replaces the
// per-frame av_hwframe_map, whose ffmpeg-7.1 VA→DRM export leaks one
// dmabuf fd per map — with export-once-per-surface the map runs a few
// dozen times per file, too rarely to order the decode). surface_id =
// the frame's VASurfaceID (AVFrame.data[3]). Returns 0 on success.
int egui_video_sync_surface(void* device_ref, unsigned int surface_id) {
#if defined(__linux__)
    void* display = zc_va_display(device_ref);
    if (!display || (int)surface_id < 0 /* VA_INVALID_SURFACE */)
        return -1;
    int r = vaSyncSurface(display, surface_id);
    if (r != 0)
        fprintf(stderr, "[zc] vaSyncSurface=%d display=%p\n", r, display);
    return r;
#else
    (void)device_ref; (void)surface_id;
    return -1;
#endif
}

// Per-surface dmabuf export for the zero-copy path — replaces ffmpeg's
// derived-DRM-ctx + av_hwframe_map miss path: that path checks out an
// EXTRA VA surface from our pool per map (the derived ctx's get_buffer
// pulls its own surface), which bloated the decoder's working set from
// ~3 to ~25 surfaces and starved the fixed pool (repro: tools/zc_probe.c
// pin=3 vs pin=1). A direct export touches only the shown surface.
//
// out (12 × i64, filled only on success):
//   [0] fd OWNED by the caller, [1] size, [2] w, [3] h,
//   [4] pitch_y, [5] pitch_uv, [6] off_y, [7] off_uv,
//   [8] modifier, [10] fc_y, [11] fc_uv (per-plane drm fourcc)
// Returns 0 on success.
int egui_video_export_surface(void* device_ref, unsigned int surface_id,
                              long long* out) {
#if defined(__linux__)
    void* display = zc_va_display(device_ref);
    if (!display) return -1;
    ZcPrimeDesc d;
    __builtin_memset(&d, 0, sizeof d);
    int vas = vaExportSurfaceHandle(display, surface_id,
                                    ZC_VA_MEM_DRM_PRIME_2,
                                    ZC_VA_EXPORT_READ_ONLY |
                                    ZC_VA_EXPORT_SEPARATE_LAYERS, &d);
    if (vas != 0) {
        fprintf(stderr, "[zc] export sid=%u failed: %d (%s)\n",
                surface_id, vas, vaErrorStr(vas));
        return -1;
    }
    if (d.num_layers < 1 || d.num_objects < 1) {
        for (unsigned i = 0; i < d.num_objects; i++)
            close(d.objects[i].fd);
        return -1;
    }
    unsigned oi0, oi1, fc_y, fc_uv;
    if (d.num_layers >= 2) {
        // two layers ('R16 ' + 'GR32' style) — planes as layers
        oi0 = d.layers[0].object_index[0];
        oi1 = d.layers[1].object_index[0];
        fc_y = d.layers[0].drm_format;
        fc_uv = d.layers[1].drm_format;
        out[4] = d.layers[0].pitch[0];
        out[5] = d.layers[1].pitch[0];
        out[6] = d.layers[0].offset[0];
        out[7] = d.layers[1].offset[0];
    } else {
        // one subsampled layer ('P010'/'NV12') — planes as plane[0/1]
        if (d.layers[0].num_planes < 2) {
            for (unsigned i = 0; i < d.num_objects; i++)
                close(d.objects[i].fd);
            return -1;
        }
        oi0 = d.layers[0].object_index[0];
        oi1 = d.layers[0].object_index[1];
        fc_y = d.layers[0].drm_format;
        int tenbit = fc_y == 0x30313050u; // 'P010'
        if (tenbit || fc_y == 0x3231564eu) { // 'NV12'
            fc_y = tenbit ? 0x20363152u : 0x20203852u; // 'R16 '/'R8  '
            fc_uv = tenbit ? 0x32335247u : 0x38385247u; // 'GR32'/'GR88'
        } else {
            fc_uv = fc_y;
        }
        out[4] = d.layers[0].pitch[0];
        out[5] = d.layers[0].pitch[1];
        out[6] = d.layers[0].offset[0];
        out[7] = d.layers[0].offset[1];
    }
    if (oi0 != oi1 || oi0 >= d.num_objects) {
        // split Y/UV GEM objects — the single-dmabuf import model does
        // not cover this shape; this driver does not produce it
        for (unsigned i = 0; i < d.num_objects; i++)
            close(d.objects[i].fd);
        return -1;
    }
    out[0] = d.objects[oi0].fd; // OWNED: caller caches or closes
    out[1] = d.objects[oi0].size;
    out[2] = d.width;
    out[3] = d.height;
    *(unsigned long long*)&out[8] = d.objects[oi0].modifier;
    out[10] = fc_y;
    out[11] = fc_uv;
    if (getenv("EGUI_VIDEO_DEBUG"))
        fprintf(stderr, "[zc] export sid=%u fd=%d %ux%u fc=%x/%x "
                "pitch=%d/%d off=%d/%d size=%u\n",
                surface_id, d.objects[oi0].fd, d.width, d.height,
                fc_y, fc_uv, (int)out[4], (int)out[5], (int)out[6],
                (int)out[7], d.objects[oi0].size);
    return 0;
#else
    (void)device_ref; (void)surface_id; (void)out;
    return -1;
#endif
}
