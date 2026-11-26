// egui.cr video helper: a FIXED-size VAAPI frames pool (the GStreamer
// gstvaallocator model — surfaces pre-allocated once, recycled by the
// decoder forever; the dynamic per-frame pool was the churn behind the
// ~700-frame degradation). Compiled into its own archive — only the
// video example links it (avutil deps stay out of the core shim).
#include <libavutil/hwcontext.h>
#if defined(_WIN32)
#include <initguid.h> // IID_* definitions land in this TU (no uuid.lib)
#include <libavutil/hwcontext_d3d11va.h>
#include <d3d11.h>
#include <d3d11_1.h>
#elif defined(__linux__)
#include <unistd.h> // close(2) on the exported dmabuf fds
#endif

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
#if defined(_WIN32)
    if (format == AV_PIX_FMT_D3D11) {
        // BIND_DECODER for the hwaccel; SHADER_RESOURCE keeps the array
        // texture usable as a sampling source (VideoProcessor input views
        // accept either — this covers both shapes)
        ((AVD3D11VAFramesContext*)fc->hwctx)->BindFlags =
            D3D11_BIND_DECODER | D3D11_BIND_SHADER_RESOURCE;
    }
#endif
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

#if defined(_WIN32)
// --- Windows zero-copy: D3D11VA + VideoProcessor on the shared device --
//
// The shim owns ONE ID3D11Device created next to the GL context and
// opened through WGL_NV_DX_interop2 (SH_VIDEO_DXZC in sokol_shim.c).
// Everything here runs on the A side under that device: ffmpeg's
// D3D11VA decodes into OUR fixed pool (one array texture, the pool
// create above sets BIND_DECODER|SHADER_RESOURCE), and each frame is
// converted NV12/P010→RGBA by the hardware VideoProcessor into a small
// ring of RGBA textures GL samples through the interop. The EVENT query
// after the blit is the decode-write barrier (the vaSyncSurface twin):
// D3D11 submits video-context and immediate-context work to the SAME
// queue in call order, so a completed EVENT fences both.

// The shim's device accessors (render-thread probe; sokol_shim.c).
// The interfaces are stable for the process lifetime — fetched once in
// dx_device_create and kept here (the shim's own statics are not
// visible across the archive boundary).
extern void* egui_cr_dx_device(void);
extern void* egui_cr_dx_context(void);
extern void* egui_cr_dx_video_device(void);
extern void* egui_cr_dx_video_context(void);
extern void egui_cr_dx_lock(void* ctx);
extern void egui_cr_dx_unlock(void* ctx);

static ID3D11Device* dxp_dev;
static ID3D11DeviceContext* dxp_ctx;
static ID3D11VideoDevice* dxp_vdev;
static ID3D11VideoContext* dxp_vctx;

#define DX_OUT_SLOTS 6 // RGBA ring depth (the texop mailbox coalesces)
#define DX_PIV_MAX 64  // VPIV cache slots (pool_size 34 + margin)

typedef struct {
    int ok;                          // pipeline built (first frame)
    int out_w, out_h;                // VP output size (≤2560 long side)
    int cs_set, bt709, full;         // colorspace currently configured
    ID3D11VideoProcessorEnumerator* vpe;
    ID3D11VideoProcessor* vp;
    ID3D11VideoContext1* vctx1;
    ID3D11Texture2D* out_tex[DX_OUT_SLOTS];  // shared RGBA ring
    ID3D11VideoProcessorOutputView* out_pov[DX_OUT_SLOTS];
    int next;                        // round-robin
    ID3D11Texture2D* dec_tex;        // pool array identity (VPIV cache)
    ID3D11VideoProcessorInputView* piv[DX_PIV_MAX];
} DxPipeline;

static DxPipeline g_dx;

// The Linux zc ladder twin: one fixed entry, native capped at 2560,
// even dims (chroma subsampling needs multiples of two).
static int dx_out_size(int src_w, int src_h, int* ow, int* oh) {
    if (src_w <= 0 || src_h <= 0) return -1;
    int native = src_w > src_h ? src_w : src_h;
    int scale = native < 2560 ? native : 2560;
    int w, h;
    if (src_w >= src_h) {
        w = scale;
        h = (int)((long long)src_h * scale / src_w);
    } else {
        h = scale;
        w = (int)((long long)src_w * scale / src_h);
    }
    if (w < 2) w = 2;
    if (h < 2) h = 2;
    *ow = w & ~1;
    *oh = h & ~1;
    return 0;
}

// Wrap the ffmpeg D3D11VA device around the shim's shared D3D11 device:
// ffmpeg AddRefs (and Releases on unref), our lock/unlock callbacks
// serialize its immediate/video-context calls against the VP work.
// Returns the AVBufferRef* (caller owns) or NULL.
static void dxp_log(const char* msg) {
    static int dbg = -1;
    if (dbg < 0) dbg = getenv("EGUI_VIDEO_DEBUG") ? 1 : 0;
    if (!dbg) return;
    FILE* tr = fopen("tmp\\dxzc_probe.log", "a");
    if (tr) { fprintf(tr, "%s\n", msg); fclose(tr); }
}

void* egui_video_dx_device_create(void) {
    dxp_dev = (ID3D11Device*)egui_cr_dx_device();
    if (!dxp_dev) return 0;
    AVBufferRef* dref = av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_D3D11VA);
    if (!dref) return 0;
    AVHWDeviceContext* hw = (AVHWDeviceContext*)dref->data;
    AVD3D11VADeviceContext* dx = (AVD3D11VADeviceContext*)hw->hwctx;
    dx->device = dxp_dev;
    dx->device_context = (ID3D11DeviceContext*)egui_cr_dx_context();
    dx->video_device = (ID3D11VideoDevice*)egui_cr_dx_video_device();
    dx->video_context = (ID3D11VideoContext*)egui_cr_dx_video_context();
    if (!dx->device_context || !dx->video_device || !dx->video_context) {
        av_buffer_unref(&dref);
        return 0;
    }
    dxp_ctx = dx->device_context;
    dxp_vdev = dx->video_device;
    dxp_vctx = dx->video_context;
    dxp_dev->lpVtbl->AddRef(dxp_dev);
    dxp_ctx->lpVtbl->AddRef(dxp_ctx);
    dxp_vdev->lpVtbl->AddRef(dxp_vdev);
    dxp_vctx->lpVtbl->AddRef(dxp_vctx);
    dx->lock = egui_cr_dx_lock;
    dx->unlock = egui_cr_dx_unlock;
    dx->lock_ctx = 0;
    if (av_hwdevice_ctx_init(dref) != 0) {
        av_buffer_unref(&dref);
        return 0;
    }
    return dref;
}

// Pipeline build (first frame; caller holds the device lock). Any
// failure leaves g_dx.ok = 0 — every frame would retry, and the caller
// latches zc off after the first failure anyway. src_w/h = the decode
// surface (ContentDesc input), disp_w/h = the visible picture — the
// ring slots and the reported size are DISPLAY-sized (crop + SAR), see
// dx_blit.
static int dx_pipeline_build(int src_w, int src_h, int disp_w, int disp_h) {
    int ow, oh;
    if (dx_out_size(disp_w, disp_h, &ow, &oh) != 0) return -1;
    D3D11_VIDEO_PROCESSOR_CONTENT_DESC cd;
    memset(&cd, 0, sizeof cd);
    cd.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
    cd.InputWidth = (UINT)src_w;
    cd.InputHeight = (UINT)src_h;
    cd.OutputWidth = (UINT)ow;
    cd.OutputHeight = (UINT)oh;
    if (FAILED(dxp_vdev->lpVtbl->CreateVideoProcessorEnumerator(
            dxp_vdev, &cd, &g_dx.vpe)))
        return -1;
    if (FAILED(dxp_vdev->lpVtbl->CreateVideoProcessor(
            dxp_vdev, g_dx.vpe, 0, &g_dx.vp)))
        return -1;
    if (FAILED(dxp_vctx->lpVtbl->QueryInterface(dxp_vctx,
            &IID_ID3D11VideoContext1, (void**)&g_dx.vctx1)))
        return -1;
    for (int i = 0; i < DX_OUT_SLOTS; i++) {
        D3D11_TEXTURE2D_DESC od;
        memset(&od, 0, sizeof od);
        od.Width = (UINT)ow;
        od.Height = (UINT)oh;
        od.MipLevels = 1;
        od.ArraySize = 1;
        od.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        od.SampleDesc.Count = 1;
        od.Usage = D3D11_USAGE_DEFAULT;
        od.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
        od.MiscFlags = D3D11_RESOURCE_MISC_SHARED; // interop-visible
        ID3D11Texture2D* t = NULL;
        if (FAILED(dxp_dev->lpVtbl->CreateTexture2D(dxp_dev, &od, NULL, &t)))
            return -1;
        D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC vd;
        memset(&vd, 0, sizeof vd);
        vd.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
        vd.Texture2D.MipSlice = 0;
        ID3D11VideoProcessorOutputView* pov = NULL;
        if (FAILED(dxp_vdev->lpVtbl->CreateVideoProcessorOutputView(
                dxp_vdev, (ID3D11Resource*)t, g_dx.vpe, &vd, &pov))) {
            t->lpVtbl->Release(t);
            return -1;
        }
        g_dx.out_tex[i] = t;
        g_dx.out_pov[i] = pov;
    }
    g_dx.out_w = ow;
    g_dx.out_h = oh;
    g_dx.cs_set = 0;
    g_dx.ok = 1;
    return 0;
}

// One frame: VPIV (cached per pool slice) + VPBlit into the next ring
// slot. Caller holds the device lock; the frame is fence-waited by the
// CALLER outside the lock (decode keeps running meanwhile).
static int dx_blit(AVFrame* f, ID3D11Texture2D* tex, int slice,
                   int bt709, int full, int* slot_out) {
    // visible + DISPLAY size: decode surfaces are aligned larger than
    // the picture (crop_* carries the trim), and anamorphic SAR≠1 means
    // the stored frame must be unsqueezed to square pixels — otherwise
    // the player fits the stored aspect and the picture stretches (the
    // "Карелия Тест.mp4" report). Slots are DISPLAY-sized; the VP scales
    // the visible storage rect into them.
    int vw = f->width - (int)f->crop_left - (int)f->crop_right;
    int vh = f->height - (int)f->crop_top - (int)f->crop_bottom;
    if (vw <= 0 || vh <= 0) { vw = f->width; vh = f->height; }
    if (f->sample_aspect_ratio.num > 0 && f->sample_aspect_ratio.den > 0)
        vw = (int)((long long)vw * f->sample_aspect_ratio.num /
                   f->sample_aspect_ratio.den);
    if (!g_dx.ok && dx_pipeline_build(f->width, f->height, vw, vh) != 0)
        return -1;
    dxp_log("blit: pip ok");
    // pool swap (reopen/seek): the array identity changed — drop the
    // VPIV cache (the views hold refs on the OLD array)
    if (g_dx.dec_tex != tex) {
        for (int i = 0; i < DX_PIV_MAX; i++) {
            if (g_dx.piv[i]) {
                g_dx.piv[i]->lpVtbl->Release(g_dx.piv[i]);
                g_dx.piv[i] = NULL;
            }
        }
        g_dx.dec_tex = tex;
    }
    if (slice < 0 || slice >= DX_PIV_MAX) return -1;
    if (!g_dx.piv[slice]) {
        D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC ivd;
        memset(&ivd, 0, sizeof ivd);
        ivd.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
        ivd.Texture2D.MipSlice = 0;
        ivd.Texture2D.ArraySlice = (UINT)slice;
        ID3D11VideoProcessorInputView* iv = NULL;
        if (FAILED(dxp_vdev->lpVtbl->CreateVideoProcessorInputView(
                dxp_vdev, (ID3D11Resource*)tex, g_dx.vpe, &ivd, &iv)))
            return -1;
        g_dx.piv[slice] = iv;
    }
    dxp_log("blit: piv ok");
    // stream colorimetry: bt601/709 × full/limited from the codec
    // context (Crystal passes them per frame), output sRGB — the VP
    // owns the whole YUV→RGB ladder (what compute_colorimetry feeds the
    // shader twins on the other platforms)
    if (!g_dx.cs_set || g_dx.bt709 != bt709 || g_dx.full != full) {
        DXGI_COLOR_SPACE_TYPE ics = bt709
            ? (full ? DXGI_COLOR_SPACE_YCBCR_FULL_G22_LEFT_P709
                    : DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P709)
            : (full ? DXGI_COLOR_SPACE_YCBCR_FULL_G22_LEFT_P601
                    : DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P601);
        g_dx.vctx1->lpVtbl->VideoProcessorSetStreamColorSpace1(
            g_dx.vctx1, g_dx.vp, 0, ics);
        g_dx.vctx1->lpVtbl->VideoProcessorSetOutputColorSpace1(
            g_dx.vctx1, g_dx.vp, DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709);
        g_dx.bt709 = bt709;
        g_dx.full = full;
        g_dx.cs_set = 1;
    }
    // no driver "enhancements" — the pixels are already the truth
    dxp_vctx->lpVtbl->VideoProcessorSetStreamAutoProcessingMode(
        dxp_vctx, g_dx.vp, 0, FALSE);
    RECT srcr, dstr;
    srcr.left = (LONG)f->crop_left;
    srcr.top = (LONG)f->crop_top;
    srcr.right = (LONG)(f->width - f->crop_right);
    srcr.bottom = (LONG)(f->height - f->crop_bottom);
    dstr.left = 0; dstr.top = 0;
    dstr.right = g_dx.out_w; dstr.bottom = g_dx.out_h;
    dxp_vctx->lpVtbl->VideoProcessorSetStreamSourceRect(
        dxp_vctx, g_dx.vp, 0, TRUE, &srcr);
    dxp_vctx->lpVtbl->VideoProcessorSetStreamDestRect(
        dxp_vctx, g_dx.vp, 0, TRUE, &dstr);
    dxp_vctx->lpVtbl->VideoProcessorSetOutputTargetRect(
        dxp_vctx, g_dx.vp, TRUE, &dstr);
    int slot = g_dx.next++ % DX_OUT_SLOTS;
    D3D11_VIDEO_PROCESSOR_STREAM st;
    memset(&st, 0, sizeof st);
    st.Enable = TRUE;
    st.pInputSurface = g_dx.piv[slice];
    // OutputFrame=0 (2D): the target rect comes from
    // SetOutputTargetRect above, not from this call
    if (FAILED(dxp_vctx->lpVtbl->VideoProcessorBlt(
            dxp_vctx, g_dx.vp, g_dx.out_pov[slot], 0, 1, &st)))
        return -1;
    dxp_log("blit: vpblt ok");
    *slot_out = slot;
    return 0;
}

// GPU fence outside the lock: one EVENT query after the blit, spin
// bounded (~2 s) — a live device answers in one frame's GPU time; a
// timeout means the queue is wedged (device removed) → caller latches
// off. Returns 0 on success.
static int dx_fence(void) {
    D3D11_QUERY_DESC qd;
    memset(&qd, 0, sizeof qd);
    qd.Query = D3D11_QUERY_EVENT;
    qd.MiscFlags = 0;
    ID3D11Query* q = NULL;
    if (FAILED(dxp_dev->lpVtbl->CreateQuery(dxp_dev, &qd, &q))) return -1;
    dxp_ctx->lpVtbl->End(dxp_ctx, (ID3D11Asynchronous*)q);
    dxp_ctx->lpVtbl->Flush(dxp_ctx);
    int done = 0;
    for (int spin = 0; spin < 2000; spin++) {
        BOOL hit = FALSE;
        HRESULT r = dxp_ctx->lpVtbl->GetData(dxp_ctx,
            (ID3D11Asynchronous*)q, &hit, sizeof(BOOL), 0);
        if (r == S_OK) { done = 1; break; }
        if (r != S_FALSE) break; // device error — stop spinning
        Sleep(1);
    }
    q->lpVtbl->Release(q);
    return done ? 0 : -1;
}

// One decoded D3D11VA frame → VP RGBA ring slot, fenced.
//   out[0] = slot texture pointer (GL samples it via the interop),
//   out[1] = w, out[2] = h (the blit's output size — ≤2560 long side).
// The frame itself is unref'd by the CALLER after this returns (the
// fence guarantees the surface is fully consumed).
// Returns 0 on success.
int egui_video_dx_frame(void* device_ref, void* frame,
                        int bt709, int full, long long* out) {
    (void)device_ref;
    AVFrame* f = (AVFrame*)frame;
    if (!f || f->format != AV_PIX_FMT_D3D11 || !f->data[0]) return -1;
    ID3D11Texture2D* tex = (ID3D11Texture2D*)f->data[0];
    int slice = (int)(intptr_t)f->data[1]; // array slice (AVFrame.data[1])
    int slot = -1;
    egui_cr_dx_lock(NULL);
    {
        int rc = dx_blit(f, tex, slice, bt709, full, &slot);
        int fr = (rc == 0) ? dx_fence() : -1;
        egui_cr_dx_unlock(NULL);
        if (rc != 0 || slot < 0) {
            if (getenv("EGUI_VIDEO_DEBUG"))
                fprintf(stderr, "[zc] dx blit failed slice=%d\n", slice);
            return -1;
        }
        if (fr != 0) {
            if (getenv("EGUI_VIDEO_DEBUG"))
                fprintf(stderr, "[zc] dx fence timeout (queue wedged?)\n");
            return -1;
        }
    }
    out[0] = (long long)(intptr_t)g_dx.out_tex[slot];
    out[1] = g_dx.out_w;
    out[2] = g_dx.out_h;
    return 0;
}

// Drop the VP pipeline (player close). The VPIV views hold refs on the
// decode array — releasing them first lets the pool's surfaces die with
// the frames context; the ring textures' last refs live on the GL side
// until the SH_TEX_DESTROY op unregisters them.
void egui_video_dx_pipeline_free(void) {
    egui_cr_dx_lock(NULL);
    for (int i = 0; i < DX_PIV_MAX; i++) {
        if (g_dx.piv[i]) {
            g_dx.piv[i]->lpVtbl->Release(g_dx.piv[i]);
            g_dx.piv[i] = NULL;
        }
    }
    g_dx.dec_tex = NULL;
    for (int i = 0; i < DX_OUT_SLOTS; i++) {
        if (g_dx.out_pov[i]) {
            g_dx.out_pov[i]->lpVtbl->Release(g_dx.out_pov[i]);
            g_dx.out_pov[i] = NULL;
        }
        if (g_dx.out_tex[i]) {
            g_dx.out_tex[i]->lpVtbl->Release(g_dx.out_tex[i]);
            g_dx.out_tex[i] = NULL;
        }
    }
    if (g_dx.vctx1) {
        g_dx.vctx1->lpVtbl->Release(g_dx.vctx1);
        g_dx.vctx1 = NULL;
    }
    if (g_dx.vp) {
        g_dx.vp->lpVtbl->Release(g_dx.vp);
        g_dx.vp = NULL;
    }
    if (g_dx.vpe) {
        g_dx.vpe->lpVtbl->Release(g_dx.vpe);
        g_dx.vpe = NULL;
    }
    memset(&g_dx, 0, sizeof g_dx);
    egui_cr_dx_unlock(NULL);
}
#else
// Non-Windows stubs: the D3D11VA zero-copy path is Windows-only, but
// the player's LibVideoPool bindings reference these symbols on every
// platform — the Crystal side never calls them unless the DX pipeline
// engaged (win32-only at runtime); the linker just needs them to
// exist.
void* egui_video_dx_device_create(void) { return NULL; }
int egui_video_dx_frame(void* device_ref, void* frame,
                        int bt709, int full, long long* out) {
    (void)device_ref; (void)frame; (void)bt709; (void)full; (void)out;
    return -1;
}
void egui_video_dx_pipeline_free(void) {}
#endif // _WIN32
