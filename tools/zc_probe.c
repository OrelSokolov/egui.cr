// zc_probe — a headless FFmpeg/VAAPI reference and regression probe for
// the zero-copy video path (examples/video/player.cr +
// backend/video_pool.c). It is the minimal working example of:
//
//   • opening a hw VAAPI decoder with a USER-SUPPLIED FIXED surface
//     pool (the gstvaallocator model the player uses) — including the
//     ffmpeg 7.1 gotcha that ff_get_format strips a pre-attached pool
//     via ff_hwaccel_uninit BEFORE hwaccel init, so the get_format
//     callback must re-attach it (see get_fmt below);
//   • probing the decoder's REAL sw_format by decoding one frame from
//     a throwaway decoder (codecpar carries no bit depth — a 10-bit
//     HEVC in MOV probes as format=-1);
//   • the per-frame vaSyncSurface write barrier;
//   • per-surface dmabuf export via vaExportSurfaceHandle(DRM_PRIME_2)
//     with hand-declared libva ABIs (no libva-dev needed).
//
// It exists because it isolated the pool-starvation bug: the derived
// DRM frames ctx + av_hwframe_map path checks out an EXTRA surface per
// map (mode pin=3: ~25 distinct surfaces, vs 3 for a direct export),
// which starved the player's fixed pool. Keep it as the A/B harness
// for any future change to the pool/export contract.
//
// usage: zc_probe FILE [pool_size] [pin] [seconds]
//   pool_size  fixed-pool surfaces (0 = no user pool: ffmpeg's own
//              dynamic pool — the control run). Default 28.
//   pin        0 = sync only (baseline)
//              1 = direct vaExportSurfaceHandle at first sight of each
//                  surface, fd kept forever (what the player does)
//              2 = pre-export EVERY pool surface before decode (the
//                  gstvaallocator allocation-time export)
//              3 = ffmpeg derived-DRM-ctx + av_hwframe_map per first
//                  sight (the OLD player path — watch distinct_sids
//                  explode and the pool starve)
//   seconds    decode duration (default 15)
// env: ZC_PROBE_PACE=N  clock-pace the decode loop at N calls/s
//                        (the player's advance-loop shape)
//
// healthy output (6K HEVC, pool 28, pin 1): fps ≈ 100+, errs 0,
// distinct_sids small (DPB-sized), fds flat.
//
// build: cc -O2 tools/zc_probe.c -o /tmp/zc_probe
//          $(pkg-config --cflags --libs libavformat libavcodec libavutil)
//          -l:libva.so.2 (one line)
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_drm.h>
#include <libavutil/pixdesc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// libva ABI without the dev headers (same trick as backend/video_pool.c)
extern int vaSyncSurface(void *display, unsigned int surface);
extern char *vaErrorStr(int err);
extern int vaExportSurfaceHandle(void *dpy, unsigned int surface,
                                  unsigned int mem_type, unsigned int flags,
                                  void *desc);
// player miss-path replication (pin==3): derived DRM frames ctx
static AVBufferRef *g_drm_dev, *g_drm_frames;
#define VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2 0x40000000u
#define VA_EXPORT_SURFACE_READ_ONLY 0x0001u
#define VA_EXPORT_SURFACE_SEPARATE_LAYERS 0x0004u
typedef struct { void *display; unsigned int quirks; } ZcVADeviceCtx;

// VADRMPRIMESurfaceDescriptor (all-uint32 layout, probed against VA 1.22)
typedef struct { int fd; unsigned size, mod_lo, mod_hi; } ZcPrimeObj;
typedef struct {
    unsigned drm_format, num_planes, object_index[4], offset[4], pitch[4];
} ZcPrimeLayer;
typedef struct {
    unsigned width, height, drm_format, num_objects;
    ZcPrimeObj objects[4];
    unsigned num_layers;
    ZcPrimeLayer layers[4];
} ZcPrimeDesc;

static AVBufferRef *g_pool; // NULL → dynamic (control)
static enum AVPixelFormat g_hwfmt;
static void *g_vadisplay;

static enum AVPixelFormat get_fmt(AVCodecContext *c,
                                  const enum AVPixelFormat *f) {
    for (int i = 0; f[i] != AV_PIX_FMT_NONE; i++)
        if (f[i] == g_hwfmt) {
            // the egui.cr fix: ff_get_format strips a pre-attached pool
            // via ff_hwaccel_uninit BEFORE hwaccel init — re-attach here
            if (g_pool && !c->hw_frames_ctx)
                c->hw_frames_ctx = av_buffer_ref(g_pool);
            return f[i];
        }
    return f[0];
}

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void *open_decoder(AVCodecContext **out, const AVCodec *codec,
                          AVCodecParameters *par, AVRational tb,
                          AVBufferRef *dev_ref) {
    AVCodecContext *c = avcodec_alloc_context3(codec);
    if (!c) return NULL;
    if (avcodec_parameters_to_context(c, par) < 0) {
        avcodec_free_context(&c);
        return NULL;
    }
    c->pkt_timebase = tb;
    c->hw_device_ctx = av_buffer_ref(dev_ref);
    c->get_format = get_fmt;
    if (g_pool) { // pre-attach too (worker threads memdup it)
        c->hw_frames_ctx = av_buffer_ref(g_pool);
        c->extra_hw_frames = 8;
    }
    if (avcodec_open2(c, codec, NULL) < 0) {
        avcodec_free_context(&c);
        return NULL;
    }
    *out = c;
    return c;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s FILE [pool_size] [pin] [seconds]\n",
                argv[0]);
        return 1;
    }
    int pool_size = argc > 2 ? atoi(argv[2]) : 28;
    int pin = argc > 3 ? atoi(argv[3]) : 1;
    double seconds = argc > 4 ? atof(argv[4]) : 15.0;
    int n_exported = 0;

    // --- phase 1: probe the decoder's own hw frames params -------------
    AVFormatContext *fmt = NULL;
    if (avformat_open_input(&fmt, argv[1], NULL, NULL) < 0) {
        fprintf(stderr, "open failed\n");
        return 1;
    }
    avformat_find_stream_info(fmt, NULL);
    const AVCodec *codec = NULL;
    int vi = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1,
                                 (void *)&codec, 0);
    if (vi < 0) return 1;
    AVStream *st = fmt->streams[vi];
    AVRational tb = st->time_base;

    AVBufferRef *dev = NULL;
    if (av_hwdevice_ctx_create(&dev, AV_HWDEVICE_TYPE_VAAPI,
                               "/dev/dri/renderD128", NULL, 0) < 0)
        return 1;
    g_vadisplay =
        ((ZcVADeviceCtx *)((AVHWDeviceContext *)dev->data)->hwctx)->display;
    g_hwfmt = av_get_pix_fmt("vaapi");

    AVCodecContext *c = NULL;
    open_decoder(&c, codec, st->codecpar, tb, dev); // g_pool == NULL yet
    if (!c) return 1;
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frm = av_frame_alloc();
    int probe_sw = -1, pw = 0, ph = 0;
    for (;;) {
        int r = avcodec_receive_frame(c, frm);
        if (r == 0) {
            if (frm->format == g_hwfmt && frm->hw_frames_ctx) {
                AVHWFramesContext *fc = (AVHWFramesContext *)frm->hw_frames_ctx->data;
                probe_sw = fc->sw_format;
                pw = fc->width;
                ph = fc->height;
            }
            av_frame_unref(frm);
            if (probe_sw >= 0) break;
        } else if (r == AVERROR(EAGAIN)) {
            if (av_read_frame(fmt, pkt) < 0) break;
            if (pkt->stream_index == vi)
                avcodec_send_packet(c, pkt);
            av_packet_unref(pkt);
        } else break;
    }
    avcodec_free_context(&c); // close the probe decoder
    fprintf(stderr, "probe: sw=%d (%s) %dx%d\n", probe_sw,
            probe_sw >= 0 ? av_get_pix_fmt_name(probe_sw) : "?", pw, ph);
    if (probe_sw < 0) return 1;

    // --- phase 2: our fixed pool (or dynamic control) ------------------
    if (pool_size > 0) {
        g_pool = av_hwframe_ctx_alloc(dev);
        AVHWFramesContext *fc = (AVHWFramesContext *)g_pool->data;
        fc->format = g_hwfmt;
        fc->sw_format = probe_sw;
        fc->width = pw;
        fc->height = ph;
        fc->initial_pool_size = pool_size;
        if (av_hwframe_ctx_init(g_pool) < 0) {
            fprintf(stderr, "pool init failed (%d surfaces)\n", pool_size);
            return 1;
        }
        fprintf(stderr, "pool: %d fixed surfaces\n", pool_size);
        if (pin == 2) {
            // gstvaallocator model: materialize every pool surface
            // (ffmpeg's fixed pool is LAZY — surfaces appear on first
            // checkout), export ONCE, return the surface to the pool —
            // all BEFORE the decoder ever touches them. Decode then
            // writes into permanently-exported dmabufs (what gst does).
            int ok = 0;
            AVFrame *tmp = av_frame_alloc();
            for (int i = 0; i < pool_size && tmp; i++) {
                if (av_hwframe_get_buffer(g_pool, tmp, 0) < 0) break;
                unsigned sid = (unsigned)(uintptr_t)tmp->data[3];
                ZcPrimeDesc d;
                memset(&d, 0, sizeof d);
                int vas = vaExportSurfaceHandle(g_vadisplay, sid,
                        VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
                        VA_EXPORT_SURFACE_SEPARATE_LAYERS |
                        VA_EXPORT_SURFACE_READ_ONLY, &d);
                if (vas == 0) {
                    for (unsigned j = 0; j < d.num_objects; j++) {
                        int keep = dup(d.objects[j].fd);
                        close(d.objects[j].fd);
                        (void)keep;
                    }
                    ok++;
                } else {
                    fprintf(stderr, "pre-export sid=%u FAILED vas=%d (%s)\n",
                            sid, vas, vaErrorStr(vas));
                }
                av_frame_unref(tmp); // surface back to the pool
            }
            av_frame_free(&tmp);
            fprintf(stderr, "pre-exported %d/%d surfaces\n", ok, pool_size);
            n_exported += ok;
            pin = 0; // per-frame export off now
        }
    } else {
        fprintf(stderr, "pool: none (ffmpeg dynamic)\n");
    }

    // rewind the demuxer to the start
    avformat_seek_file(fmt, -1, INT64_MIN, fmt->start_time,
                       INT64_MAX, 0);

    open_decoder(&c, codec, st->codecpar, tb, dev);
    if (!c) return 1;

    // --- decode loop ----------------------------------------------------
    #define MAXSID 4096
    static unsigned sids[MAXSID];
    int nsid = 0, new_this_sec = 0;
    long reuse = 0;
    long errs = 0;
    long frames = 0, frames_sec = 0;
    double t0 = now_s(), tsec = t0, sync_ms = 0.0;
    int done = 0;

    int paced = getenv("ZC_PROBE_PACE") ? atoi(getenv("ZC_PROBE_PACE")) : 0;
    while (!done) {
        if (paced) { // clock-paced like the player: N decode calls/s
            static double last_call;
            double nw = now_s();
            if (nw - last_call < 1.0 / paced) continue;
            last_call = nw;
        }
        int r = avcodec_receive_frame(c, frm);
        if (r == 0) {
            double s0 = now_s();
            if (frm->format == g_hwfmt && frm->data[3]) {
                unsigned sid = (unsigned)(uintptr_t)frm->data[3];
                vaSyncSurface(g_vadisplay, sid);
                sync_ms += (now_s() - s0) * 1e3;
                int at = -1;
                for (int i = 0; i < nsid; i++)
                    if (sids[i] == sid) { at = i; break; }
                if (at < 0 && nsid < MAXSID) {
                    sids[nsid] = sid;
                    at = nsid++;
                    new_this_sec++;
                    if (pin == 3) {
                        // EXACT copy of the player's miss path: hold the
                        // frame, checkout a DRM frame from the DERIVED
                        // ctx (extra surface from OUR pool), map, dup
                        // the descriptor fds forever, unref both
                        if (!g_drm_frames) {
                            av_hwdevice_ctx_create(&g_drm_dev,
                                AV_HWDEVICE_TYPE_DRM,
                                "/dev/dri/renderD128", NULL, 0);
                            av_hwframe_ctx_create_derived(&g_drm_frames,
                                AV_PIX_FMT_DRM_PRIME, g_drm_dev, g_pool, 0);
                        }
                        AVFrame *sink = av_frame_alloc();
                        AVFrame *drm = av_frame_alloc();
                        av_frame_ref(sink, frm);
                        if (g_drm_frames && drm && sink &&
                            av_hwframe_get_buffer(g_drm_frames, drm, 0) == 0 &&
                            av_hwframe_map(drm, sink,
                                           AV_HWFRAME_MAP_READ) == 0) {
                            AVDRMFrameDescriptor *dd = (AVDRMFrameDescriptor *)drm->data[0];
                            int keep = dup(dd->objects[0].fd); // KEEP
                            (void)keep; // forever (player cache does)
                            keep = dup(dd->objects[dd->nb_layers > 1
                                        ? dd->layers[1].planes[0].object_index
                                        : 0].fd);
                            (void)keep;
                            n_exported++;
                        } else {
                            fprintf(stderr, "derived map FAILED\n");
                        }
                        av_frame_free(&drm);
                        av_frame_free(&sink);
                    } else if (pin) { // export ONCE, keep the fd forever
                        ZcPrimeDesc d;
                        memset(&d, 0, sizeof d);
                        int vas = vaExportSurfaceHandle(g_vadisplay, sid,
                                VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
                                VA_EXPORT_SURFACE_SEPARATE_LAYERS | VA_EXPORT_SURFACE_READ_ONLY, &d);
                        if (vas == 0) {
                            for (unsigned i = 0; i < d.num_objects; i++)
                                { int keep = dup(d.objects[i].fd); (void)keep; }
                            // our dup pins; close the export's own fds
                            for (unsigned i = 0; i < d.num_objects; i++)
                                close(d.objects[i].fd);
                            n_exported++;
                        } else {
                            fprintf(stderr,
                                    "export sid=%u FAILED vas=%d\n", sid,
                                    vas);
                        }
                    }
                } else {
                    reuse++;
                }
            }
            av_frame_unref(frm);
            frames++;
            frames_sec++;
        } else if (r == AVERROR(EAGAIN)) {
            if (av_read_frame(fmt, pkt) < 0) {
                avcodec_send_packet(c, NULL); // drain
                done = (avcodec_receive_frame(c, frm) != 0);
                if (!done) { av_frame_unref(frm); frames++; frames_sec++; }
                break;
            }
            if (pkt->stream_index == vi)
                avcodec_send_packet(c, pkt);
            av_packet_unref(pkt);
        } else {
            errs++;
            if (r != AVERROR(EAGAIN)) {
                static int last_err = 0;
                if (!last_err)
                    fprintf(stderr, "receive error: %d (%s)\n", r,
                            av_err2str(r));
                last_err = 1;
            }
            if (now_s() - t0 > seconds) break;
        }
        double now = now_s();
        if (now - tsec >= 1.0) {
            fprintf(stderr,
                    "sec=%4.1f frames=%-7ld fps=%-6.1f distinct_sids=%-5d "
                    "new_sids=%-4d reuse=%-8lu errs=%-6lu "
                    "sync=%.1fms/f\n",
                    now - t0, frames, frames_sec / (now - tsec), nsid,
                    new_this_sec, reuse, errs,
                    frames ? sync_ms / frames : 0.0);
            frames_sec = 0;
            new_this_sec = 0;
            errs = 0;
            sync_ms = 0.0;
            tsec = now;
        }
        if (now - t0 > seconds) done = 1;
    }
    fprintf(stderr, "DONE frames=%ld distinct_sids=%d reuse=%lu errs=%lu "
            "exported=%d\n",
            frames, nsid, reuse, errs, n_exported);
    return 0;
}
