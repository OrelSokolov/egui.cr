// egui-cr sokol shim: single translation unit that implements all sokol
// libraries and exposes a small, FFI-friendly C surface for Crystal.
//
// Callback structs (sapp_desc, sg_pass_action, sfons_desc_t) are built
// here with designated initializers so Crystal never has to mirror the
// full sokol structs.

// pipe2/pthread extensions for the detached render loop below; must be
// set before any system header.
#if !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif

#define SOKOL_GLCORE
#define SOKOL_NO_ENTRY // we drive sapp_run from Crystal's main
#define SOKOL_IMPL
#if !defined(__APPLE__) && !defined(_WIN32)
#include <X11/Xlib.h>
#include <X11/Xcursor/Xcursor.h>
#endif
#include "sokol_app.h"
#include "sokol_gfx.h"
#define SOKOL_GLCUE_IMPL
#include "sokol_glue.h"
#define SOKOL_LOG_IMPL
#include "sokol_log.h"
#define SOKOL_GL_IMPL
#include "util/sokol_gl.h"
#define FONTSTASH_IMPLEMENTATION
#include "fontstash.h"
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define SOKOL_FONTSTASH_IMPL
#include "util/sokol_fontstash.h"

typedef void (*cr_init_cb)(void);
typedef void (*cr_frame_cb)(void);
typedef void (*cr_cleanup_cb)(void);
typedef void (*cr_event_cb)(int type, float mx, float my, float sx, float sy,
                            unsigned mods, unsigned mouse_button,
                            unsigned key_code, unsigned char_code);

static cr_init_cb   g_init;
static cr_frame_cb  g_frame;
static cr_cleanup_cb g_cleanup;
static cr_event_cb  g_event;

// from egui_cr_sapp_run: strip the system window chrome in init_cb,
// before the first frame paints (custom title bar apps draw their own).
static int g_borderless;

// from egui_cr_sapp_run: make the window per-pixel transparent (the
// swapchain alpha becomes the window alpha — splash screens, custom
// chrome).
static int g_transparent;

// Detached-render-loop routing (see the section at the end of this
// file): on Linux and Win32, paint/texture/window entry points called
// off the render thread are forwarded to the packet builder / command
// mailbox. Everywhere else (and before egui_cr_start) everything runs
// direct.
// The detached-path entry points are declared unconditionally: the
// routing prologues below call them on every platform, but on non-
// detached ones (macOS) sh_run_direct() always succeeds so the stubs
// at the bottom of this block are never reached.
typedef enum { SH_TEX_CREATE, SH_TEX_UPDATE, SH_TEX_DESTROY } sh_texop_kind;
static int sh_run_direct(void);
// pixels-per-point scale. Detached platforms: set from Crystal via
// egui_cr_set_ppp every produced frame. Direct path (macOS): set_ppp is
// never called, so egui_cr_begin_pass refreshes it from sapp_dpi_scale()
// instead — sh_draw_mesh3d divides by it to restore the 2D ortho after a
// 3D draw, and a stale 0 made that matrix NaN (every 2D draw after the
// first mesh3d in a frame silently vanished; macOS-only bug).
static float g_pkt_ppp;
static void egui_cr_pkt_pipe(int kind);
static void egui_cr_pkt_pipe_pop(void);
static void sh_texop_queue(sh_texop_kind kind, uint32_t id, int w, int h,
                           int stream, const void* data, size_t size);
static uint32_t sh_tex_make_detached(int w, int h, const void* rgba8,
                                     int stream);
// packet builder API (see the detached section)
static void egui_cr_pkt_begin(int fb_w, int fb_h);
static void egui_cr_pkt_publish(void);
static void egui_cr_pkt_scissor(float x, float y, float w, float h);
static void egui_cr_pkt_tex(uint32_t id, int nearest);
static void egui_cr_pkt_tex_on(void);
static void egui_cr_pkt_tex_off(void);
static void egui_cr_pkt_begin_quads(void);
static void egui_cr_pkt_end_quads(void);
static void egui_cr_pkt_v(float x, float y, unsigned r, unsigned g,
                          unsigned b, unsigned a);
static void egui_cr_pkt_vt(float x, float y, float u, float v, unsigned r,
                           unsigned g, unsigned b, unsigned a);
static void egui_cr_pkt_mesh3d(const float* mvp, int blend, int prim,
                               int x, int y, int w, int h, int count,
                               const unsigned char* verts);
#if defined(_SAPP_LINUX) || defined(_SAPP_WIN32)
// window-management forwarding (command mailbox wrappers, defined in the
// detached section; called from the routing prologues below)
static void sh_post_window_size(int w, int h);
static void sh_post_window_position(int x, int y);
static void sh_post_decorations(int decorated);
static void sh_post_window_opacity(float opacity);
static void sh_post_window_minimize(void);
static void sh_post_window_maximize(void);
static void sh_post_window_restore(void);
static void sh_post_screen_size(int* w, int* h);
static int sh_post_window_position_get(int* x, int* y);
static void sh_post_drag_start(void);
static void sh_post_resize_start(int dir);
static void sh_post_window_shape(const unsigned char* mask, int w, int h);
static void sh_post_cursor(const char* name);
static void sh_post_cursor_image(const unsigned char* rgba, int w, int h,
                                 int hx, int hy);
static void sh_post_clear_color(void);
#else
static int sh_run_direct(void) { return 1; }
// no-op stubs for the detached-path entry points declared above — never
// reached (sh_run_direct() always succeeds), they only let the routing
// prologues compile on non-detached platforms
static void egui_cr_pkt_begin(int fb_w, int fb_h) { (void)fb_w; (void)fb_h; }
static void egui_cr_pkt_publish(void) {}
static void egui_cr_pkt_scissor(float x, float y, float w, float h) {
    (void)x; (void)y; (void)w; (void)h;
}
static void egui_cr_pkt_tex(uint32_t id, int nearest) { (void)id; (void)nearest; }
static void egui_cr_pkt_tex_on(void) {}
static void egui_cr_pkt_tex_off(void) {}
static void egui_cr_pkt_begin_quads(void) {}
static void egui_cr_pkt_end_quads(void) {}
static void egui_cr_pkt_v(float x, float y, unsigned r, unsigned g,
                          unsigned b, unsigned a) {
    (void)x; (void)y; (void)r; (void)g; (void)b; (void)a;
}
static void egui_cr_pkt_vt(float x, float y, float u, float v, unsigned r,
                           unsigned g, unsigned b, unsigned a) {
    (void)x; (void)y; (void)u; (void)v; (void)r; (void)g; (void)b; (void)a;
}
static void egui_cr_pkt_mesh3d(const float* mvp, int blend, int prim,
                               int x, int y, int w, int h, int count,
                               const unsigned char* verts) {
    (void)mvp; (void)blend; (void)prim; (void)x; (void)y; (void)w; (void)h;
    (void)count; (void)verts;
}
static void egui_cr_pkt_pipe(int kind) { (void)kind; }
static void egui_cr_pkt_pipe_pop(void) {}
static void sh_texop_queue(sh_texop_kind kind, uint32_t id, int w, int h,
                           int stream, const void* data, size_t size) {
    (void)kind; (void)id; (void)w; (void)h; (void)stream; (void)data;
    (void)size;
}
static uint32_t sh_tex_make_detached(int w, int h, const void* rgba8,
                                     int stream) {
    (void)w; (void)h; (void)rgba8; (void)stream;
    return 0;
}
#endif

// window management (defined in the section below)
void egui_cr_set_decorations(int decorated);
int egui_cr_window_position(int* x, int* y);
void egui_cr_set_transparent(void);

// vendor/sokol GLX patch hook: 1 = restrict fbconfigs to depth-32 ARGB
// visuals (per-pixel window transparency).
int egui_cr_glx_want_argb(void);

#if defined(_SAPP_LINUX)
// forward: X11 resize synchronization (defined with the other X11
// helpers below, after the sokol headers).
static void sh_x11_sync_request_init(void);
static void sh_x11_sync_request_confirm(void);
#endif

static void sh_init_cb(void) {
    // X11 borderless is applied before the window is mapped (the
    // egui_cr_x11_pre_map_hook sokol patch); other platforms undecorate
    // here, once the window exists.
    if (g_borderless) egui_cr_set_decorations(0);
    if (g_transparent) egui_cr_set_transparent();
#if defined(_SAPP_LINUX)
    sh_x11_sync_request_init();
#endif
    g_init();
}

// ---- freeze watchdog (EGUI_WATCHDOG=1) -------------------------------
// A detached thread watching frame callbacks while the app runs.
// "stuck INSIDE"  = the frame callback never returned (blocked fiber,
//                   blocking syscall on the frame path);
// "stuck OUTSIDE" = the loop stopped calling frames at all — an
//                   X11/GL/driver stall (e.g. the XWayland DRI3 Present
//                   race worked around above). Logs the frame thread's
//                   kernel wait channel, once per stall, then re-arms.
#if defined(__linux__)
#include <stdatomic.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/syscall.h>
#include <sys/prctl.h>

static atomic_llong g_wd_frame_start_ns = 0;
static atomic_llong g_wd_frame_done_ns  = 0;
static int g_wd_enabled = -1;   /* -1 = unchecked, set on first frame */
static int g_wd_frame_tid = 0;

static long long egui_cr_wd_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000000ll + ts.tv_nsec;
}

static void egui_cr_wd_report(const char* where, long long since_ns) {
    char wchan[64] = "?";
    if (g_wd_frame_tid) {
        char path[96];
        snprintf(path, sizeof path, "/proc/self/task/%d/wchan", g_wd_frame_tid);
        int fd = open(path, O_RDONLY);
        if (fd >= 0) {
            ssize_t n = read(fd, wchan, sizeof wchan - 1);
            if (n < 0) n = 0;
            wchan[n] = '\0';
            for (ssize_t i = 0; i < n; i++)
                if (wchan[i] == '\n') { wchan[i] = '\0'; break; }
            close(fd);
        }
    }
    char buf[256];
    long long ms = (egui_cr_wd_now_ns() - since_ns) / 1000000ll;
    int len = snprintf(buf, sizeof buf,
        "[watchdog] UI stuck %s frame for %lld ms (frame thread wchan=%s)\n",
        where, ms, wchan);
    if (len > 0) (void)write(STDERR_FILENO, buf, len);
}

static void* egui_cr_wd_thread(void* unused) {
    (void)unused;
    long long reported_inside = 0, reported_outside = 0;
    for (;;) {
        struct timespec ts = {1, 0};
        nanosleep(&ts, 0);
        long long now = egui_cr_wd_now_ns();
        long long start = atomic_load(&g_wd_frame_start_ns);
        long long done  = atomic_load(&g_wd_frame_done_ns);
        if (start != 0 && now - start > 3000000000ll && reported_inside != start) {
            reported_inside = start;
            egui_cr_wd_report("INSIDE", start);
        }
        if (done != 0 && now - done > 3000000000ll && reported_outside != done) {
            reported_outside = done;
            egui_cr_wd_report("OUTSIDE (no frame callbacks)", done);
        }
    }
    return 0;
}

static void egui_cr_wd_on_frame_begin(void) {
    if (g_wd_enabled < 0) {
        g_wd_enabled = getenv("EGUI_WATCHDOG") ? 1 : 0;
        if (g_wd_enabled) {
            g_wd_frame_tid = (int)syscall(SYS_gettid);
            /* Debug runs want gdb -p to work when the UI is frozen;
             * yama ptrace_scope=1 blocks attaching to a non-child. */
            prctl(PR_SET_PTRACER, PR_SET_PTRACER_ANY);
            pthread_t t;
            if (pthread_create(&t, 0, egui_cr_wd_thread, 0) == 0)
                pthread_detach(t);
        }
    }
    atomic_store(&g_wd_frame_start_ns, egui_cr_wd_now_ns());
}

static void egui_cr_wd_on_frame_end(void) {
    atomic_store(&g_wd_frame_done_ns, egui_cr_wd_now_ns());
    atomic_store(&g_wd_frame_start_ns, 0);
}
#else
static void egui_cr_wd_on_frame_begin(void) { }
static void egui_cr_wd_on_frame_end(void)   { }
#endif

static void sh_frame_cb(void) {
    egui_cr_wd_on_frame_begin();
    g_frame();
    egui_cr_wd_on_frame_end();
#if defined(_SAPP_LINUX)
    // After g_frame the pass for THIS frame is committed (sg_commit in
    // egui_cr_end_pass); sokol swaps right after we return — the frame
    // at the current size is on its way out, so the pending resize can
    // be released (see sh_x11_sync_request_confirm).
    sh_x11_sync_request_confirm();
#endif
}
static void sh_cleanup_cb(void){ g_cleanup(); }

static void sh_event_cb(const sapp_event* ev) {
    g_event((int)ev->type, ev->mouse_x, ev->mouse_y, ev->scroll_x, ev->scroll_y,
            ev->modifiers, (unsigned)ev->mouse_button,
            (unsigned)ev->key_code, ev->char_code);
}

void egui_cr_sapp_run(cr_init_cb init, cr_frame_cb frame, cr_event_cb event,
                      cr_cleanup_cb cleanup, const char* title,
                      int width, int height, int borderless, int transparent,
                      int swap_interval) {
    g_init = init; g_frame = frame; g_event = event; g_cleanup = cleanup;
    g_borderless = borderless;
    g_transparent = transparent;
    /* Debug/env override: EGUI_NOVSYNC=1 untethers the loop from the
     * compositor's present feedback (bisects swap stalls under
     * XWayland). */
    if (getenv("EGUI_NOVSYNC")) swap_interval = 0;
#if defined(_SAPP_LINUX)
    // XWayland DRI3 deadlock workaround. Under rapid input, sokol's X11
    // loop (Xlib XPending/XNextEvent on the app connection) races with
    // Mesa's DRI3, which waits for Present "special events" on the SAME
    // connection (xcb_wait_for_special_event inside sg_begin_pass's
    // loader_dri3_get_buffers). When the Xlib read wins, the Present
    // event is consumed as an unknown XEvent and dropped — the wait
    // then blocks forever and the window freezes (0% CPU, no repaints;
    // reproducible by wiggling the pointer over any egui-cr app for a
    // few seconds under mutter/XWayland). Keeping DRI3 off routes buffer
    // exchange through DRI2 — still hardware accelerated — and the
    // special-event wait never happens. Scoped to XWayland (a Wayland
    // session plus an X display) and never overrides an explicit
    // LIBGL_DRI3_DISABLE from the environment.
    if (getenv("WAYLAND_DISPLAY") && getenv("DISPLAY") &&
        !getenv("LIBGL_DRI3_DISABLE")) {
        setenv("LIBGL_DRI3_DISABLE", "1", 1);
    }
#endif
    sapp_desc desc = {
        .init_cb = sh_init_cb,
        .frame_cb = sh_frame_cb,
        .event_cb = sh_event_cb,
        .cleanup_cb = sh_cleanup_cb,
        .width = width,
        .height = height,
        .window_title = title,
        // Full-resolution framebuffer on HighDPI/retina displays: without
        // this the compositor upscales a 1x framebuffer (~2x on retina) and
        // every rasterized glyph edge goes soft — text quality is dominated
        // by this, not by the rasterizer.
        .high_dpi = true,
        // MSAA: smooth circle/arc/line edges — EXCEPT in a transparent
        // window: the depth-32 ARGB fbconfigs GLX offers are single
        // sample, so with MSAA the chooser falls back to a 24-bit visual
        // and the compositor cannot blend per pixel. Transparent windows
        // trade MSAA for the 32-bit visual (Win32/macOS unaffected).
        .sample_count = transparent ? 1 : 4,
        // VSync (1 = on, 0 = off): off trades tear-free presentation
        // for uncapped frame rate — the perf-measuring demos want
        // that (an FPS meter reading vsync is measuring the monitor,
        // not the app).
        .swap_interval = swap_interval,
        .enable_clipboard = true, // SystemPorts::Clipboard (sapp_set/get_clipboard_string)
        .enable_dragndrop = true, // Event.dropped_files (drop.enabled gates the FILES_DROPPED event)
        .max_dropped_files = 8,
        .max_dropped_file_path_length = 8192,
        .logger.func = slog_func,
    };
    sapp_run(&desc);
}

void egui_cr_gfx_init(void) {
    sg_setup(&(sg_desc){
        .environment = sglue_environment(),
        // Defaults are 128 images / 256 views — an icon-catalog frame
        // alone rasters hundreds of Svg textures (see Svg#paint), and
        // sg_make_image past the pool fails with IMAGE_POOL_EXHAUSTED
        // (icons silently fall back to the slow vector path). The
        // pools are preallocated slot arrays, and sokol returns a
        // destroyed slot only a few frames later — budget for the
        // working set PLUS that in-flight tail. The pools are
        // preallocated slot arrays — a few hundred KB.
        .image_pool_size = 4096,
        .view_pool_size = 4096,
        .logger.func = slog_func,
    });
    sgl_setup(&(sgl_desc_t){
        // A full lucide catalog frame (hundreds of icons × dozens of
        // stroke quads each) needs well beyond sokol_gl's 64k-vertex
        // default; past the cap geometry is silently dropped
        // (_sgl_next_vertex error path). ~6 MB of vertex memory for
        // 256k vertices.
        .max_vertices = 1 << 18,
        .max_commands = 1 << 16,
        // Must match the swapchain sample count requested in
        // egui_cr_sapp_run, or sokol_gfx validation fails.
        .sample_count = sapp_sample_count(),
        // Color/depth formats from the actual environment (sokol_app
        // defaults the swapchain to a DEPTH attachment in this vendor
        // version). Without a depth format here, sokol_gl patches every
        // pipeline to depth-format NONE and disables depth writes — fine
        // for 2D, but the depth-tested 3D pipelines below would silently
        // render without depth. 2D pipelines stay unaffected: sg defaults
        // depth compare to ALWAYS with writes off, which the GL backend
        // reduces to a no-op.
        .color_format = sglue_environment().defaults.color_format,
        .depth_format = sglue_environment().defaults.depth_format,
        .logger.func = slog_func,
    });
}

FONScontext* egui_cr_sfons_create(int width, int height) {
    return sfons_create(&(sfons_desc_t){ .width = width, .height = height });
}

// Window clear color — defaults to the dark theme's base surface; the
// Crystal side pushes the active theme's panel fill each frame
// (egui_cr_set_clear_color), so a theme swap also swaps the backdrop.
static float g_clear[4] = { 0.075f, 0.075f, 0.08f, 1.0f };

#if defined(_SAPP_LINUX)
// forward: called from egui_cr_set_clear_color, defined below.
static void sh_x11_sync_window_background(float r, float g, float b);
#endif

void egui_cr_set_clear_color(float r, float g, float b, float a) {
    g_clear[0] = r;
    g_clear[1] = g;
    g_clear[2] = b;
    g_clear[3] = a;
#if defined(_SAPP_LINUX)
    if (!sh_run_direct()) { sh_post_clear_color(); return; }
    sh_x11_sync_window_background(r, g, b);
#endif
}

#if defined(_SAPP_LINUX)
// Resize-exposure backdrop: XCreateWindow passes no CWBackPixel, so the
// window background is None — when the WM grows the window ahead of the
// next glXSwapBuffers (X11 has no resize sync without the app-side
// _NET_WM_SYNC_REQUEST counter), the newly exposed strip is undefined
// content, which the compositor paints black. Keep the background pixel
// in sync with the clear color so the gap shows the theme's panel fill
// instead. The visual never changes, so its channel masks are cached
// after the first query; XSetWindowBackground itself is fire-and-forget.
static int sh_bg_cached = 0;
static int sh_bg_depth;
static unsigned long sh_bg_red_mask, sh_bg_green_mask, sh_bg_blue_mask;
static int sh_bg_set = 0;
static unsigned long sh_bg_pixel;

static unsigned long sh_x11_pack(unsigned long mask, int v8) {
    if (!mask) return 0;
    unsigned long m = mask;
    int shift = 0;
    while (!(m & 1)) { m >>= 1; shift++; }
    return (((unsigned long)v8 * m + 127) / 255) << shift; // m == 2^n - 1
}

static void sh_x11_sync_window_background(float r, float g, float b) {
    Display* dpy = (Display*)sapp_x11_get_display();
    Window win = (Window)sapp_x11_get_window();
    if (!dpy || !win) return;
    if (!sh_bg_cached) {
        XWindowAttributes wa;
        if (!XGetWindowAttributes(dpy, win, &wa) || !wa.visual) return;
        sh_bg_red_mask = wa.visual->red_mask;
        sh_bg_green_mask = wa.visual->green_mask;
        sh_bg_blue_mask = wa.visual->blue_mask;
        sh_bg_depth = wa.depth;
        sh_bg_cached = 1;
    }
    // Masks cover RGB only; on a depth-32 ARGB visual (transparent
    // windows) the alpha bits stay 0, so the exposed strip is fully
    // transparent — exactly what the transparent clear color wants.
    unsigned long px =
        sh_x11_pack(sh_bg_red_mask,   (int)(r * 255.0f + 0.5f)) |
        sh_x11_pack(sh_bg_green_mask, (int)(g * 255.0f + 0.5f)) |
        sh_x11_pack(sh_bg_blue_mask,  (int)(b * 255.0f + 0.5f));
    if (!sh_bg_set || px != sh_bg_pixel) {
        XSetWindowBackground(dpy, win, px);
        sh_bg_pixel = px;
        sh_bg_set = 1;
    }
}

// --- _NET_WM_SYNC_REQUEST (EWMH resize synchronization) ---------------------
//
// Without it an X11 resize is unsynchronized with rendering: the WM
// grows the X window at its own pace while the client learns the new
// size one frame late — every step of an interactive resize leaves a
// composited frame where the newly exposed strip has no backing buffer
// (only the window background pixel, see sh_x11_sync_window_background
// — fully transparent for transparent windows, hence the resize
// flicker of bin/terminal and bin/splash). The EWMH protocol lets the
// client throttle the WM instead (classic, non-extended flavor — what
// mutter/kwin drive; see mutter's meta-sync-counter.c):
//
//   1. the client creates an XSync counter and publishes its xid in
//      the _NET_WM_SYNC_REQUEST_COUNTER property of the toplevel
//      window (ONE value: two values would select the "extended"
//      flavor with its odd/even frame-drawn bookkeeping);
//   2. during an interactive resize the WM applies the new size to the
//      X window and sends a WM_PROTOCOLS/_NET_WM_SYNC_REQUEST
//      ClientMessage carrying the serial the counter must reach;
//   3. after presenting a frame at the new size the client sets the
//      counter to that serial (XSyncSetCounter — no round trip);
//   4. the WM watches an XSyncAlarm on the counter and does not apply
//      the NEXT resize step until the serial is reached — the window
//      only ever grows once a frame of the current size exists.
//
// sokol owns the X event loop and drops the WM's ClientMessage, so the
// vendored sokol_app.h taps every raw XEvent through
// egui_cr_x11_event_hook (the same patch pattern as the pre-map hook);
// the hook only records the requested serial. WMs without sync support
// ignore the property and none of this ever fires.
#include <X11/extensions/sync.h>

static XSyncCounter sh_sync_counter = None;
static XSyncValue sh_sync_set;            // counter value we last wrote
static unsigned long long sh_sync_target; // serial the WM asked for
static int sh_sync_target_seen;

static void sh_x11_sync_request_init(void) {
    Display* dpy = (Display*)sapp_x11_get_display();
    Window win = (Window)sapp_x11_get_window();
    if (!dpy || !win) return;
    Atom counter_atom = XInternAtom(dpy, "_NET_WM_SYNC_REQUEST_COUNTER", False);
    if (counter_atom == None) return;
    int major = 3, minor = 0; // 3.0: alarms; anything ≥3.1 also fine
    if (!XSyncInitialize(dpy, &major, &minor)) return;
    XSyncValue zero;
    XSyncIntToValue(&zero, 0);
    sh_sync_counter = XSyncCreateCounter(dpy, zero);
    if (sh_sync_counter == None) return;
    sh_sync_set = zero;
    long counter = (long)sh_sync_counter;
    XChangeProperty(dpy, win, counter_atom, XA_CARDINAL, 32,
                    PropModeReplace, (unsigned char*)&counter, 1);
}

// egui_cr_x11_event_hook (vendor/sokol/sokol_app.h patch): the WM's
// _NET_WM_SYNC_REQUEST notice arrives as a WM_PROTOCOLS ClientMessage
// on the toplevel window — record its serial for #confirm below.
void egui_cr_x11_event_hook(XEvent* event) {
    if (!sh_sync_counter || event->type != ClientMessage) return;
    XClientMessageEvent* cm = &event->xclient;
    Display* dpy = (Display*)sapp_x11_get_display();
    if (!dpy) return;
    static Atom protocols, sync_request;
    if (!protocols) {
        protocols = XInternAtom(dpy, "WM_PROTOCOLS", False);
        sync_request = XInternAtom(dpy, "_NET_WM_SYNC_REQUEST", False);
        if (!protocols || !sync_request) return;
    }
    if (cm->message_type != protocols ||
        (Atom)cm->data.l[0] != sync_request) return;
    sh_sync_target = (unsigned long long)(uint32_t)cm->data.l[2] |
                     ((unsigned long long)(uint32_t)cm->data.l[3] << 32);
    sh_sync_target_seen = 1;
}

// End of frame_cb: this frame's pass is committed (egui_cr_end_pass →
// sg_commit) and sokol swaps right after — a frame at the CURRENT size
// is on its way out, so the pending resize can be released. XSync-
// SetCounter is fire-and-forget; skipped entirely when no request is
// outstanding (zero cost on idle frames).
static void sh_x11_sync_request_confirm(void) {
    if (!sh_sync_counter || !sh_sync_target_seen) return;
    unsigned long long set = (unsigned long long)(uint32_t)XSyncValueLow32(sh_sync_set) |
                             ((unsigned long long)(uint32_t)XSyncValueHigh32(sh_sync_set) << 32);
    if (sh_sync_target == set) return;
    XSyncValue value;
    XSyncIntsToValue(&value, (int)(uint32_t)sh_sync_target,
                     (int)(uint32_t)(sh_sync_target >> 32));
    Display* dpy = (Display*)sapp_x11_get_display();
    if (!dpy) return;
    XSyncSetCounter(dpy, sh_sync_counter, value);
    sh_sync_set = value;
}
#endif

// Legacy-path EGUI_SHOT capture (same PPM format as sh_shot): a few
// early end_pass frames, for A/B against the detached replay path.
// Win32: sokol's GL backend declares the GL entry points as its own
// static loader pointers but not the GL 1.1 enums — declare the few
// constants the capture helpers use. The GL3
// glBindFramebuffer(GL_READ_FRAMEBUFFER, …) is skipped there — the
// default framebuffer is the read target anyway.
#if defined(_SAPP_WIN32)
#define GL_PACK_ALIGNMENT 0x0D05
#define GL_RGB            0x1907
#define GL_UNSIGNED_BYTE  0x1401
// glReadPixels is GL 1.1 (exported by opengl32.dll, which Crystal links)
// but sokol's private Win32 loader doesn't declare it — MSVC would take
// it as an implicit-declaration warning; declare it properly instead.
extern void glReadPixels(int x, int y, int w, int h, unsigned format,
                         unsigned type, void* data);
#endif
static void sh_shot_legacy(void) {
    static const char* dir;
    static int idx;
    static const int ticks[] = {15, 40, 80};
    if (!dir) { dir = getenv("EGUI_SHOT"); if (!dir) dir = (const char*)-1; }
    if ((intptr_t)dir == -1 || idx >= 3) return;
    static uint32_t count;
    count++;
    if (count < (uint32_t)ticks[idx]) return;
    int w = sapp_width(), h = sapp_height();
    if (w <= 0 || h <= 0) return;
    char* px = (char*)malloc((size_t)w * h * 3);
    if (!px) { idx++; return; }
    #if !defined(_SAPP_WIN32)
    glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
    #endif
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, w, h, GL_RGB, GL_UNSIGNED_BYTE, px);
    char path[512];
    snprintf(path, sizeof path, "%s/legacy_%d.ppm", dir, ticks[idx]);
    FILE* f = fopen(path, "wb");
    if (f) {
        fprintf(f, "P6\n%d %d\n255\n", w, h);
        for (int y = h - 1; y >= 0; y--)
            fwrite(px + (size_t)y * w * 3, 1, (size_t)w * 3, f);
        fclose(f);
    }
    free(px);
    idx++;
}

// Framebuffer size of the pass in progress (both paths) — the mesh3d
// restore step needs it to re-establish the default pixel-space
// viewport after a 3D draw.
static int g_fb_w, g_fb_h;

void egui_cr_begin_pass(int w, int h) {
    g_fb_w = w;
    g_fb_h = h;
    if (!sh_run_direct()) { egui_cr_pkt_begin(w, h); return; }
    // Direct path: nothing else keeps g_pkt_ppp fresh (egui_cr_set_ppp
    // is only called by the detached produce loop), yet the mesh3d
    // restore divides by it — a stale 0 turns the restored ortho into
    // NaN and silently drops every 2D draw after the first 3D mesh.
    // Refresh from the live dpi scale every frame.
    float d = sapp_dpi_scale();
    if (d > 0.0f) g_pkt_ppp = d;
    sg_begin_pass(&(sg_pass){
        .swapchain = sglue_swapchain(),
        .action = {
            .colors[0] = {
                .load_action = SG_LOADACTION_CLEAR,
                .clear_value = { g_clear[0], g_clear[1], g_clear[2], g_clear[3] },
            },
        },
    });
}

void egui_cr_end_pass(void) {
    if (!sh_run_direct()) { egui_cr_pkt_publish(); return; }
    sgl_draw();
    sg_end_pass();
    sg_commit();
    sh_shot_legacy();
}

// A pass that only clears the framebuffer to g_clear — the backdrop the
// window should show from its very first presented tick, before Crystal
// has produced any draw ops (font parsing and the first app update +
// glyph bake are the visible part of a second on large apps).
static void sh_clear_pass(void) {
    sg_begin_pass(&(sg_pass){
        .swapchain = sglue_swapchain(),
        .action = {
            .colors[0] = {
                .load_action = SG_LOADACTION_CLEAR,
                .clear_value = { g_clear[0], g_clear[1], g_clear[2], g_clear[3] },
            },
        },
    });
    sg_end_pass();
    sg_commit();
}

// --- per-pixel window transparency -----------------------------------------
//
// The transparent-window platform setup (applied in init_cb when the
// egui_cr_sapp_run flag is set): the swapchain alpha becomes the window
// alpha, so pixels the app leaves at a=0 show the desktop through.
//
//   X11: nothing to do — with sample_count 1 the GLX chooser picks an
//     alpha-capable fbconfig backed by a depth-32 ARGB visual, and the
//     compositing manager blends the window per pixel.
//   Win32: DWM ignores a WGL swapchain's alpha unless blur-behind is
//     enabled with an EMPTY region (the classic per-pixel-alpha OpenGL
//     trick, same as winit). dwmapi is loaded dynamically so no link
//     dependency is added.
//   macOS: NSWindow opaque=NO + a clear background color.

#if defined(_WIN32)

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#define SH_DWM_BB_ENABLE     0x1
#define SH_DWM_BB_BLURREGION 0x2
typedef struct {
    DWORD dwFlags;
    BOOL  fEnable;
    HRGN  hRgnBlur;
    BOOL  fTransitionOnMaximized;
} SH_DWM_BLURBEHIND;

void egui_cr_set_transparent(void) {
    HWND hwnd = (HWND)sapp_win32_get_hwnd();
    if (!hwnd) return;
    HMODULE dwm = LoadLibraryA("dwmapi.dll");
    if (!dwm) return;
    typedef HRESULT (WINAPI *PFN_DwmEnableBlurBehindWindow)(HWND, const SH_DWM_BLURBEHIND*);
    PFN_DwmEnableBlurBehindWindow f = (PFN_DwmEnableBlurBehindWindow)
        GetProcAddress(dwm, "DwmEnableBlurBehindWindow");
    if (!f) return;
    SH_DWM_BLURBEHIND bb;
    memset(&bb, 0, sizeof(bb));
    bb.dwFlags = SH_DWM_BB_ENABLE | SH_DWM_BB_BLURREGION;
    bb.fEnable = TRUE;
    bb.hRgnBlur = CreateRectRgn(0, 0, -1, -1); // empty = whole window
    f(hwnd, &bb);
    DeleteObject(bb.hRgnBlur);
}

#elif defined(__APPLE__)

void egui_cr_set_transparent(void) {
    NSWindow* win = (NSWindow*)sapp_macos_get_window();
    if (!win) return;
    win.opaque = NO;
    win.backgroundColor = [NSColor clearColor];
    // The GL surface itself defaults to "opaque": the window server then
    // ignores the framebuffer alpha and pixels cleared to a=0 composite
    // black instead of showing the desktop. Opting the surface out is
    // what actually turns the swapchain alpha into the window alpha
    // (same call SDL/winit make for transparent GL windows).
    NSOpenGLView* view = (NSOpenGLView*)win.contentView;
    NSOpenGLContext* ctx = view.openGLContext;
    GLint surface_opacity = 0;
    [ctx setValues:&surface_opacity forParameter:NSOpenGLContextParameterSurfaceOpacity];
}

#else

// X11: handled by the visual choice alone (see above).
void egui_cr_set_transparent(void) {}

#endif

// Present the backdrop color once, right after gfx init and BEFORE the
// heavy startup work (font parsing, first app update + glyph bake).
// sokol swaps no earlier than the END of the first frame callback, so
// without this the freshly mapped window shows an uninitialized (black)
// framebuffer for the whole startup. Detached path: a no-op — the
// render thread clears every pre-packet tick instead (sh_rt_frame).
#if defined(_WIN32)

void egui_cr_present_clear(void) {
    if (!sh_run_direct()) return;
    sh_clear_pass();
    HWND hwnd = (HWND)sapp_win32_get_hwnd();
    if (!hwnd) return;
    // CS_OWNDC (sokol's window class): this IS the DC the WGL context
    // was created on, so swapping here presents the cleared buffer.
    HDC dc = GetDC(hwnd);
    if (dc) { SwapBuffers(dc); ReleaseDC(hwnd, dc); }
}

#elif defined(__APPLE__)

void egui_cr_present_clear(void) {
    if (!sh_run_direct()) return;
    sh_clear_pass();
    NSWindow* win = (NSWindow*)sapp_macos_get_window();
    NSOpenGLView* view = win ? (NSOpenGLView*)win.contentView : NULL;
    NSOpenGLContext* ctx = view ? view.openGLContext : NULL;
    if (ctx) { [ctx makeCurrentContext]; [ctx flushBuffer]; }
}

#else

// X11: no mid-init swap — sokol presents through its own GLXWindow, and
// touching glXSwapBuffers from outside its loop is fragile. The pre-map
// hook (egui_cr_x11_pre_map_hook) sets the X window background pixel to
// the clear color instead: that is what the compositor shows from the
// first exposure until the first GL present.
void egui_cr_present_clear(void) {}

#endif

// UI-quad pipeline with blending: same geometry as the sokol_gl default
// pipeline, but blending so translucent fills (modal scrim, shadows)
// composite over what's below and the compositing manager of a
// transparent window receives a properly PREMULTIPLIED image
// (rgb: src*a + dst*(1-a), a: a + dst_a*(1-a)). Opaque quads are
// unaffected; anti-aliased edges and translucent fills come out correct
// instead of fringing.
static sgl_pipeline g_alpha_pip;
static sgl_pipeline g_replace_pip; // defined with its section below
static sgl_pipeline g_text_pip;

// Create the three replay pipelines if not yet present (idempotent;
// GL objects may only be made on the thread that owns the context —
// the render-thread init calls this, the push paths only load).
static void sh_ensure_pipelines(void);

static sgl_pipeline sh_make_blend_pip(const char* label) {
    return sgl_make_pipeline(&(sg_pipeline_desc){
        .colors[0] = {
            // RGBA write mask: sgl's implicit default is RGB-only,
            // which would keep the alpha at the clear value.
            .write_mask = SG_COLORMASK_RGBA,
            .blend = {
                .enabled = true,
                .src_factor_rgb = SG_BLENDFACTOR_SRC_ALPHA,
                .dst_factor_rgb = SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
                .src_factor_alpha = SG_BLENDFACTOR_ONE,
                .dst_factor_alpha = SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
            },
        },
        .label = label,
    });
}

// Depth-tested 3D pipelines (Viewport3D meshes; see egui_cr_mesh3d):
//   g_pip_3d       — depth test + write, no blending (opaque triangles).
//   g_pip_3d_blend — depth test, NO write, alpha blending (translucent
//                    surfaces, drawn after the opaque pass).
// Both inherit the context's sample_count / pixel formats via
// sgl_make_pipeline. 2D UI drawn later is never z-fought away: the 2D
// pipelines have depth compare ALWAYS + writes off (a GL no-op), so
// painter's order still decides the UI stack.
static sgl_pipeline g_pip_3d;
static sgl_pipeline g_pip_3d_blend;

static void sh_ensure_pipelines(void) {
    if (!g_alpha_pip.id)   g_alpha_pip = sh_make_blend_pip("egui-cr-alpha-pip");
    if (!g_text_pip.id)    g_text_pip = sh_make_blend_pip("egui-cr-text-pip");
    if (!g_pip_3d.id) {
        g_pip_3d = sgl_make_pipeline(&(sg_pipeline_desc){
            .depth = {
                .compare = SG_COMPAREFUNC_LESS_EQUAL,
                .write_enabled = true,
            },
            .colors[0] = {
                .write_mask = SG_COLORMASK_RGBA,
                .blend = { .enabled = false },
            },
            .label = "egui-cr-3d-pip",
        });
    }
    if (!g_pip_3d_blend.id) {
        g_pip_3d_blend = sgl_make_pipeline(&(sg_pipeline_desc){
            .depth = { .compare = SG_COMPAREFUNC_LESS_EQUAL },
            .colors[0] = {
                .write_mask = SG_COLORMASK_RGBA,
                .blend = {
                    .enabled = true,
                    .src_factor_rgb = SG_BLENDFACTOR_SRC_ALPHA,
                    .dst_factor_rgb = SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
                    .src_factor_alpha = SG_BLENDFACTOR_ONE,
                    .dst_factor_alpha = SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
                },
            },
            .label = "egui-cr-3d-blend-pip",
        });
    }
    if (!g_replace_pip.id) {
        g_replace_pip = sgl_make_pipeline(&(sg_pipeline_desc){
            .colors[0] = {
                .write_mask = SG_COLORMASK_RGBA,
                .blend = { .enabled = false },
            },
            .label = "egui-cr-replace-pip",
        });
    }
}

void egui_cr_alpha_pipeline_push(void) {
    if (!sh_run_direct()) { egui_cr_pkt_pipe(0); return; }
    sh_ensure_pipelines();
    sgl_push_pipeline();
    sgl_load_pipeline(g_alpha_pip);
}

void egui_cr_alpha_pipeline_pop(void) {
    if (!sh_run_direct()) { egui_cr_pkt_pipe_pop(); return; }
    sgl_pop_pipeline();
}

// Blend-OFF pipeline for replace rects (Painter#rect_replace): the quad
// overwrites dst rgb AND alpha — how a widget punches per-pixel
// transparency into an opaque UI (the terminal grid) without anything
// having to blend behind it.

void egui_cr_replace_pipeline_push(void) {
    if (!sh_run_direct()) { egui_cr_pkt_pipe(1); return; }
    sh_ensure_pipelines();
    sgl_push_pipeline();
    sgl_load_pipeline(g_replace_pip);
}

void egui_cr_replace_pipeline_pop(void) {
    if (!sh_run_direct()) { egui_cr_pkt_pipe_pop(); return; }
    sgl_pop_pipeline();
}

// --- 3D meshes (Viewport3D) -----------------------------------------------------

// Draw one batched 3D mesh through a depth-tested pipeline, then restore
// the default 2D state. `verts` is packed SoA: `count` vertices of 16
// bytes each (x,y,z float32 + r,g,b,a uint8). `prim`: 0 = triangles,
// 1 = lines. The restore step is mandatory: every subsequent 2D quad op
// assumes the full-framebuffer viewport and the pixel-space ortho
// projection, so a mesh drawn with a 3D projection leaves that state
// exactly as it found it (the replay also resets matrices every frame,
// so nothing leaks across frames either way).
static void sh_draw_mesh3d(const float* mvp, int blend, int prim,
                           int x, int y, int w, int h,
                           int count, const unsigned char* verts,
                           int fb_w, int fb_h, float ppp) {
    if (w <= 0 || h <= 0 || count <= 0) return;
    if (ppp <= 0.0f) ppp = 1.0f; // never divide by a stale zero below
    sh_ensure_pipelines();
    sgl_push_pipeline();
    sgl_load_pipeline(blend ? g_pip_3d_blend : g_pip_3d);
    sgl_viewport(x, y, w, h, true);
    sgl_matrix_mode_projection();
    sgl_load_matrix(mvp);
    sgl_matrix_mode_modelview();
    sgl_load_identity();
    if (prim) sgl_begin_lines(); else sgl_begin_triangles();
    const unsigned char* v = verts;
    for (int i = 0; i < count; i++, v += 16) {
        float px, py, pz;
        memcpy(&px, v, 4);
        memcpy(&py, v + 4, 4);
        memcpy(&pz, v + 8, 4);
        sgl_v3f_c4b(px, py, pz, v[12], v[13], v[14], v[15]);
    }
    sgl_end();
    sgl_pop_pipeline();
    sgl_viewport(0, 0, fb_w, fb_h, true);
    sgl_matrix_mode_projection();
    sgl_load_identity();
    sgl_ortho(0.0f, (float)fb_w / ppp, (float)fb_h / ppp, 0.0f,
              -1.0f, 1.0f);
    sgl_matrix_mode_modelview();
    sgl_load_identity();
}

// --- textures -------------------------------------------------------------

static sg_sampler g_linear_sampler;
static void sh_sampler_ensure(void) {
    if (!g_linear_sampler.id) {
        g_linear_sampler = sg_make_sampler(&(sg_sampler_desc){
            .min_filter = SG_FILTER_LINEAR, .mag_filter = SG_FILTER_LINEAR });
    }
}
// Point-sampled twin for pixel-art surfaces (the Paint canvas): created
// lazily by egui_cr_sgl_texture_nearest.
static sg_sampler g_nearest_sampler;

// view-id → image registry for textures that outlive their upload:
// immutable (make_texture) so they can be destroyed, and stream
// (make_stream_texture) so they can be updated in place. Fixed-size is
// fine — apps hold a handful of textures (a video surface, a photo),
// not thousands.
#define EGUI_CR_MAX_TEXTURES 256
static struct {
    uint32_t view_id;
    sg_image img;
    bool stream;
} g_textures[EGUI_CR_MAX_TEXTURES];
static int g_texture_count = 0;

static int sh_texture_slot(uint32_t view_id) {
    for (int i = 0; i < g_texture_count; i++) {
        if (g_textures[i].view_id == view_id) return i;
    }
    return -1;
}

// Upload immutable RGBA8 data as a 2D texture; returns a texture id
// (0 on failure) — an sg_view id on the legacy path, a shim id on the
// detached path (resolved through the render thread's texture table).
// The sampler is created once and shared.
uint32_t egui_cr_make_texture(int w, int h, const void* rgba8) {
    if (!sh_run_direct()) return sh_tex_make_detached(w, h, rgba8, 0);
    if (!g_linear_sampler.id) {
        g_linear_sampler = sg_make_sampler(&(sg_sampler_desc){
            .min_filter = SG_FILTER_LINEAR,
            .mag_filter = SG_FILTER_LINEAR,
        });
    }
    sg_image img = sg_make_image(&(sg_image_desc){
        .type = SG_IMAGETYPE_2D,
        .width = w,
        .height = h,
        .usage = {.immutable = true},
        .data = {.mip_levels[0] = {.ptr = rgba8, .size = (size_t)w * h * 4}},
    });
    if (img.id == 0) return 0;
    sg_view view = sg_make_view(&(sg_view_desc){
        .texture = {.image = img},
    });
    if (view.id == 0) return 0;
    if (g_texture_count < EGUI_CR_MAX_TEXTURES) {
        g_textures[g_texture_count].view_id = (uint32_t)view.id;
        g_textures[g_texture_count].img = img;
        g_textures[g_texture_count].stream = false;
        g_texture_count++;
    }
    return view.id;
}

// Create an EMPTY updatable RGBA8 texture (SG_USAGE_STREAM) for pixels
// that change every frame — decoded video, camera frames. Stream images
// cannot be created with initial data (sokol validation:
// WRITABLE_NO_DATA), so create empty and upload via update_texture.
uint32_t egui_cr_make_stream_texture(int w, int h) {
    if (w <= 0 || h <= 0) return 0;
    if (!sh_run_direct()) return sh_tex_make_detached(w, h, NULL, 1);
    if (g_texture_count >= EGUI_CR_MAX_TEXTURES) return 0;
    sg_image img = sg_make_image(&(sg_image_desc){
        .type = SG_IMAGETYPE_2D,
        .width = w,
        .height = h,
        .pixel_format = SG_PIXELFORMAT_RGBA8,
        .usage = {.dynamic_update = true},
        .label = "egui-cr-stream-texture",
    });
    if (img.id == 0) return 0;
    sg_view view = sg_make_view(&(sg_view_desc){
        .texture = {.image = img},
        .label = "egui-cr-stream-texture-view",
    });
    if (view.id == 0) return 0;
    g_textures[g_texture_count].view_id = (uint32_t)view.id;
    g_textures[g_texture_count].img = img;
    g_textures[g_texture_count].stream = true;
    g_texture_count++;
    return (uint32_t)view.id;
}

// Push fresh RGBA8 pixels into a stream texture (same size as created).
void egui_cr_update_texture(uint32_t view_id, int w, int h, const void* rgba8) {
    if (!sh_run_direct()) {
        if (view_id) sh_texop_queue(SH_TEX_UPDATE, view_id, w, h, 0, rgba8,
                                    (size_t)w * h * 4);
        return;
    }
    int slot = sh_texture_slot(view_id);
    if (slot < 0 || !g_textures[slot].stream) return;
    sg_image_data data;
    memset(&data, 0, sizeof(data));
    data.mip_levels[0].ptr = rgba8;
    data.mip_levels[0].size = (size_t)w * h * 4;
    sg_update_image(g_textures[slot].img, &data);
    // Same GL state-cache caveat as the glyph-atlas update path: the
    // sokol GL backend rebinds textures behind the cache's back while
    // uploading, so reset it or the next draw samples a stale slot.
    // Unlike atlases this runs every video frame, but sg_reset_state_cache
    // only clears the cache (the next apply_bindings re-sets GL state),
    // which is cheap next to a full-frame upload.
    sg_reset_state_cache();
}

// Destroy a texture created by make_texture or make_stream_texture.
void egui_cr_destroy_texture(uint32_t view_id) {
    if (!sh_run_direct()) {
        if (view_id) sh_texop_queue(SH_TEX_DESTROY, view_id, 0, 0, 0, NULL, 0);
        return;
    }
    int slot = sh_texture_slot(view_id);
    if (slot < 0) return;
    sg_destroy_view((sg_view){.id = view_id});
    sg_destroy_image(g_textures[slot].img);
    g_textures[slot] = g_textures[g_texture_count - 1];
    g_texture_count--;
}

// Bind a texture for the following begin/end block (must be called
// OUTSIDE begin/end — sokol_gl asserts !ctx->in_begin). Texturing must
// then be enabled separately; disable it afterwards so later untextured
// geometry falls back to the internal white texture.
void egui_cr_sgl_texture(uint32_t view_id) {
    if (!sh_run_direct()) { egui_cr_pkt_tex(view_id, 0); return; }
    if (!g_linear_sampler.id) sh_sampler_ensure();
    sg_view view = {.id = view_id};
    sgl_texture(view, g_linear_sampler);
}

// Same bind, point sampling — for canvases whose texels must stay crisp
// under non-integer scaling.
void egui_cr_sgl_texture_nearest(uint32_t view_id) {
    if (!sh_run_direct()) { egui_cr_pkt_tex(view_id, 1); return; }
    if (!g_nearest_sampler.id) {
        g_nearest_sampler = sg_make_sampler(&(sg_sampler_desc){
            .min_filter = SG_FILTER_NEAREST,
            .mag_filter = SG_FILTER_NEAREST,
        });
    }
    sg_view view = {.id = view_id};
    sgl_texture(view, g_nearest_sampler);
}

void egui_cr_sgl_enable_texture(void) {
    if (!sh_run_direct()) { egui_cr_pkt_tex_on(); return; }
    sgl_enable_texture();
}
void egui_cr_sgl_disable_texture(void) {
    if (!sh_run_direct()) { egui_cr_pkt_tex_off(); return; }
    sgl_disable_texture();
}

// --- sgl call wrappers ---------------------------------------------------------
//
// Crystal binds these instead of the raw sokol_gl symbols: on the
// detached path the per-frame setup (viewport/ortho/matrices) is done by
// the replay and everything else becomes packet ops; on the legacy path
// they are pass-throughs.
#if defined(_SAPP_LINUX) || defined(_SAPP_WIN32)
void egui_cr_sgl_viewport(int x, int y, int w, int h, bool origin_top_left) {
    if (!sh_run_direct()) return; // set by the replay
    sgl_viewport(x, y, w, h, origin_top_left);
}
void egui_cr_sgl_matrix_mode_projection(void) {
    if (!sh_run_direct()) return;
    sgl_matrix_mode_projection();
}
void egui_cr_sgl_matrix_mode_modelview(void) {
    if (!sh_run_direct()) return;
    sgl_matrix_mode_modelview();
}
void egui_cr_sgl_load_identity(void) {
    if (!sh_run_direct()) return;
    sgl_load_identity();
}
void egui_cr_sgl_ortho(float l, float r, float b, float t, float n, float f) {
    if (!sh_run_direct()) return;
    sgl_ortho(l, r, b, t, n, f);
}
void egui_cr_sgl_scissor_rectf(float x, float y, float w, float h,
                               bool origin_top_left) {
    if (!sh_run_direct()) { egui_cr_pkt_scissor(x, y, w, h); return; }
    sgl_scissor_rectf(x, y, w, h, origin_top_left);
}
void egui_cr_sgl_begin_quads(void) {
    if (!sh_run_direct()) { egui_cr_pkt_begin_quads(); return; }
    sgl_begin_quads();
}
void egui_cr_sgl_end(void) {
    if (!sh_run_direct()) { egui_cr_pkt_end_quads(); return; }
    sgl_end();
}
void egui_cr_sgl_v2f_c4b(float x, float y, unsigned char r, unsigned char g,
                         unsigned char b, unsigned char a) {
    if (!sh_run_direct()) { egui_cr_pkt_v(x, y, r, g, b, a); return; }
    sgl_v2f_c4b(x, y, r, g, b, a);
}
void egui_cr_sgl_v2f_t2f_c4b(float x, float y, float u, float v,
                             unsigned char r, unsigned char g,
                             unsigned char b, unsigned char a) {
    if (!sh_run_direct()) { egui_cr_pkt_vt(x, y, u, v, r, g, b, a); return; }
    sgl_v2f_t2f_c4b(x, y, u, v, r, g, b, a);
}
void egui_cr_mesh3d(const float* mvp, bool blend, int prim,
                    int x, int y, int w, int h, int count,
                    const unsigned char* verts) {
    if (!sh_run_direct()) {
        egui_cr_pkt_mesh3d(mvp, blend ? 1 : 0, prim, x, y, w, h, count, verts);
        return;
    }
    sh_draw_mesh3d(mvp, blend ? 1 : 0, prim, x, y, w, h, count, verts,
                   g_fb_w, g_fb_h, g_pkt_ppp);
}
#else /* not a detached platform (macOS): straight pass-throughs */
void egui_cr_sgl_viewport(int x, int y, int w, int h, bool origin_top_left) {
    sgl_viewport(x, y, w, h, origin_top_left);
}
void egui_cr_sgl_matrix_mode_projection(void) { sgl_matrix_mode_projection(); }
void egui_cr_sgl_matrix_mode_modelview(void) { sgl_matrix_mode_modelview(); }
void egui_cr_sgl_load_identity(void) { sgl_load_identity(); }
void egui_cr_sgl_ortho(float l, float r, float b, float t, float n, float f) {
    sgl_ortho(l, r, b, t, n, f);
}
void egui_cr_sgl_scissor_rectf(float x, float y, float w, float h,
                               bool origin_top_left) {
    sgl_scissor_rectf(x, y, w, h, origin_top_left);
}
void egui_cr_sgl_begin_quads(void) { sgl_begin_quads(); }
void egui_cr_sgl_end(void) { sgl_end(); }
void egui_cr_sgl_v2f_c4b(float x, float y, unsigned char r, unsigned char g,
                         unsigned char b, unsigned char a) {
    sgl_v2f_c4b(x, y, r, g, b, a);
}
void egui_cr_sgl_v2f_t2f_c4b(float x, float y, float u, float v,
                             unsigned char r, unsigned char g,
                             unsigned char b, unsigned char a) {
    sgl_v2f_t2f_c4b(x, y, u, v, r, g, b, a);
}
void egui_cr_mesh3d(const float* mvp, bool blend, int prim,
                    int x, int y, int w, int h, int count,
                    const unsigned char* verts) {
    sh_draw_mesh3d(mvp, blend ? 1 : 0, prim, x, y, w, h, count, verts,
                   g_fb_w, g_fb_h, g_pkt_ppp);
}
#endif

// Decode an image file (PNG/JPEG/...) via stb_image and upload it as
// RGBA8; returns the sg_view id (0 on failure).
uint32_t egui_cr_load_image(const char* path) {
    int w, h, n;
    unsigned char* data = stbi_load(path, &w, &h, &n, 4);
    if (!data) return 0;
    uint32_t view_id = egui_cr_make_texture(w, h, data);
    stbi_image_free(data);
    return view_id;
}

// Header-only image probe (stbi_info): pixel dimensions without
// decoding the pixels — layout-side sizing before/without a load.
// Returns 1 on success and fills w/h, 0 on failure.
int egui_cr_image_info(const char* path, int* w, int* h) {
    int n;
    return stbi_info(path, w, h, &n);
}

// Decode an image file into a CPU-side straight-alpha RGBA8 buffer —
// the `CustomCursorImage` source (the GPU texture from
// egui_cr_load_image can't be read back). malloc'd, exactly w*h*4
// bytes; free with egui_cr_mem_free. NULL on failure.
unsigned char* egui_cr_load_rgba(const char* path, int* w, int* h) {
    int n;
    unsigned char* data = stbi_load(path, w, h, &n, 4);
    return data; // stb_image's buffer IS straight RGBA8, heap-allocated
}

// --- Crystal text stack GPU bits ---------------------------------------------
//
// The sokol_gl default pipeline has NO blending (write mask RGB only), so
// the text quads need their own pipeline — same setup the fontstash backend
// used (sfons): straight alpha blend, swapchain sample count.

static sgl_pipeline g_text_pip;
void egui_cr_atlas_update(uint32_t view_id, int w, int h, const void* rgba8);

void egui_cr_text_pipeline_init(void) {
    sh_ensure_pipelines();
}

// sokol_gl pipeline stack wrappers: sgl_pipeline is a struct, easier to
// keep the struct marshalling here than bind it in Crystal.
void egui_cr_text_pipeline_push(void) {
    if (!sh_run_direct()) { egui_cr_pkt_pipe(2); return; }
    sh_ensure_pipelines();
    sgl_push_pipeline();
    sgl_load_pipeline(g_text_pip);
}

void egui_cr_text_pipeline_pop(void) {
    if (!sh_run_direct()) { egui_cr_pkt_pipe_pop(); return; }
    sgl_pop_pipeline();
}

// Glyph atlas textures: RGBA8, stream-updated whenever Crystal rasterizes
// new glyphs. Per-instance (see below) — one per font backend.

// --- glyph atlases: per-instance --------------------------------------------
//
// Multiple font backends coexist (fontpreview switches the FreeType C /
// Crystal backends live): each atlas_create returns its OWN image+view pair,
// and atlas_update addresses them by view id through a small registry.
// Atlases live for the process lifetime (a handful at most), so no
// destroy path is needed.

#define EGUI_CR_MAX_ATLASES 16
static struct {
    uint32_t view_id;
    sg_image img;
} g_atlases[EGUI_CR_MAX_ATLASES];
static int g_atlas_count = 0;

uint32_t egui_cr_atlas_create(int w, int h, const void* rgba8) {
    if (!sh_run_direct()) return sh_tex_make_detached(w, h, rgba8, 0);
    if (g_atlas_count >= EGUI_CR_MAX_ATLASES) return 0;
    // stream images cannot be created with initial data (sokol validation:
    // WRITABLE_NO_DATA) — create empty, then upload via sg_update_image.
    sg_image img = sg_make_image(&(sg_image_desc){
        .width = w,
        .height = h,
        .usage = {.dynamic_update = true},
        .label = "egui-cr-glyph-atlas",
    });
    if (img.id == 0) return 0;
    sg_view view = sg_make_view(&(sg_view_desc){
        .texture = {.image = img},
        .label = "egui-cr-glyph-atlas-view",
    });
    if (view.id == 0) return 0;
    g_atlases[g_atlas_count].view_id = (uint32_t)view.id;
    g_atlases[g_atlas_count].img = img;
    g_atlas_count++;
    egui_cr_atlas_update((uint32_t)view.id, w, h, rgba8);
    return (uint32_t)view.id;
}

void egui_cr_atlas_update(uint32_t view_id, int w, int h, const void* rgba8) {
    if (!sh_run_direct()) {
        if (getenv("EGUI_FRAME_DEBUG"))
            fprintf(stderr, "[tex] A queues atlas update id=%u\n", view_id);
        sh_texop_queue(SH_TEX_UPDATE, view_id, w, h, 0, rgba8,
                       (size_t)w * h * 4);
        return;
    }
    for (int i = 0; i < g_atlas_count; i++) {
        if (g_atlases[i].view_id == view_id) {
            sg_image_data data;
            memset(&data, 0, sizeof(data));
            data.mip_levels[0].ptr = rgba8;
            data.mip_levels[0].size = (size_t)w * h * 4;
            sg_update_image(g_atlases[i].img, &data);
            // _sg_gl_update_image rebinds textures on GL unit 0 behind
            // the state cache's back (bind-new → upload → restore-old),
            // which can leave the cache claiming a texture is bound
            // that GL actually swapped — the next apply_bindings then
            // skips the rebind and samples a stale slot, so glyphs
            // rasterized after startup never showed up. The official
            // "we touched GL state ourselves" escape hatch is a full
            // state-cache reset; atlas updates are rare (new glyphs
            // only), so the cost is negligible.
            sg_reset_state_cache();
            return;
        }
    }
}

// --- cursor -----------------------------------------------------------------
//
// Port of eframe/winit cursor handling: egui hands the integration a
// CSS `cursor` keyword ("pointer", "ew-resize", …) each frame; the
// integration maps it to the platform cursor.
//
//   X11/Xlib+Xcursor (Linux): theme cursor by CSS name — XDG cursor
//     themes use the CSS keywords — with a core cursor-font fallback
//     table for names the theme is missing.
//   Win32: IDC_* stock cursors (LoadCursor/SetCursor). WM_SETCURSOR is
//     answered by a subclassed WndProc — a plain SetCursor from the
//     frame callback is reverted by sokol's own WM_SETCURSOR handler
//     (it re-applies sapp_set_mouse_cursor's cursor, which knows
//     nothing about our IDC_* table) on every mouse move.
//   macOS: NSCursor class methods (the shim is compiled as ObjC there);
//     diagonal resize cursors exist only as private NSCursor methods,
//     resolved at runtime with a public fallback.

// --- cursor: custom bitmap --------------------------------------------------
//
// egui `PlatformOutput::cursor_image` (the CSS `cursor: url(…)`
// equivalent): a straight-alpha RGBA bitmap + hotspot uploaded to the
// OS as a real cursor. Same platform mapping winit uses:
//
//   X11: XcursorImage → XRender cursor (packed straight ARGB — what
//     winit's CustomCursor::new feeds XcursorImageLoadCursor).
//   Win32: CreateIconIndirect over a 32-bpp ARGB DIB section + an
//     all-zero AND mask; the subclassed WndProc re-applies it on
//     WM_SETCURSOR exactly like the IDC_* handles.
//   macOS: NSCursor initWithImage:hotspot: over an NSBitmapImageRep
//     (the winit cursor_from_image recipe — no hotspot y-flip).

// Fast-path dedupe shared by the branches: the Crystal side already
// dedupes by buffer identity, but an app rebuilding `CustomCursorImage`
// per frame would otherwise churn an XID / HCURSOR per frame — compare
// the bytes too, and forget the cache whenever a named cursor is
// applied (else the bitmap would be skipped while the window shows the
// named cursor).
static unsigned char* g_custom_prev;
static int g_custom_prev_w, g_custom_prev_h, g_custom_prev_hx, g_custom_prev_hy;

static int sh_custom_same(const unsigned char* rgba, int w, int h, int hx, int hy) {
    if (!g_custom_prev || g_custom_prev_w != w || g_custom_prev_h != h ||
        g_custom_prev_hx != hx || g_custom_prev_hy != hy)
        return 0;
    return memcmp(rgba, g_custom_prev, (size_t)w * (size_t)h * 4) == 0;
}

static void sh_custom_remember(const unsigned char* rgba, int w, int h, int hx, int hy) {
    size_t size = (size_t)w * (size_t)h * 4;
    unsigned char* copy = (unsigned char*)malloc(size);
    if (!copy) { free(g_custom_prev); g_custom_prev = NULL; return; }
    memcpy(copy, rgba, size);
    free(g_custom_prev);
    g_custom_prev = copy;
    g_custom_prev_w = w; g_custom_prev_h = h;
    g_custom_prev_hx = hx; g_custom_prev_hy = hy;
}

static void sh_custom_forget(void) {
    free(g_custom_prev);
    g_custom_prev = NULL;
}

#if defined(_SAPP_LINUX) // X11 backend (this sokol version gates it with _SAPP_LINUX, not _SAPP_X11)

static Cursor g_none_cursor; // 1x1 transparent cursor for CSS `none`
static Cursor g_current_cursor;

// Fallback shapes from the core X cursor font (cursorfont.h) for CSS
// names the theme doesn't ship — approximations, used only when
// XcursorLibraryLoadCursor fails.
typedef struct { const char* css; unsigned int shape; } cursor_fallback_t;
static const cursor_fallback_t g_cursor_fallbacks[] = {
    {"default", XC_left_ptr},      {"context-menu", XC_left_ptr},
    {"help", XC_question_arrow},   {"pointer", XC_hand2},
    {"progress", XC_watch},        {"wait", XC_watch},
    {"cell", XC_plus},             {"crosshair", XC_cross},
    {"text", XC_xterm},            {"vertical-text", XC_xterm},
    {"alias", XC_exchange},        {"copy", XC_exchange},
    {"move", XC_fleur},            {"no-drop", XC_pirate},
    {"not-allowed", XC_X_cursor},  {"grab", XC_hand1},
    {"grabbing", XC_hand2},        {"all-scroll", XC_fleur},
    {"ew-resize", XC_sb_h_double_arrow}, {"col-resize", XC_sb_h_double_arrow},
    {"ns-resize", XC_sb_v_double_arrow}, {"row-resize", XC_sb_v_double_arrow},
    {"nesw-resize", XC_top_right_corner}, {"nwse-resize", XC_bottom_right_corner},
    {"e-resize", XC_right_side},   {"w-resize", XC_left_side},
    {"n-resize", XC_top_side},     {"s-resize", XC_bottom_side},
    {"ne-resize", XC_top_right_corner},  {"sw-resize", XC_bottom_left_corner},
    {"nw-resize", XC_top_left_corner},   {"se-resize", XC_bottom_right_corner},
    {"zoom-in", XC_plus},          {"zoom-out", XC_plus},
};

void egui_cr_set_cursor(const char* css_name) {
    if (!sh_run_direct()) { sh_post_cursor(css_name); return; }
    Display* dpy = (Display*)sapp_x11_get_display();
    Window win = (Window)sapp_x11_get_window();
    if (!dpy || !win) return;
    Cursor cursor;
    if (strcmp(css_name, "none") == 0) {
        if (!g_none_cursor) {
            Pixmap pm = XCreateBitmapFromData(dpy, win, "\0", 1, 1);
            XColor black = {0};
            g_none_cursor = XCreatePixmapCursor(dpy, pm, pm, &black, &black, 0, 0);
            XFreePixmap(dpy, pm);
        }
        cursor = g_none_cursor;
    } else {
        cursor = XcursorLibraryLoadCursor(dpy, css_name);
        if (!cursor) {
            for (size_t i = 0; i < sizeof(g_cursor_fallbacks)/sizeof(g_cursor_fallbacks[0]); i++) {
                if (strcmp(css_name, g_cursor_fallbacks[i].css) == 0) {
                    cursor = XCreateFontCursor(dpy, g_cursor_fallbacks[i].shape);
                    break;
                }
            }
        }
        if (!cursor) return; // unknown name — keep the current cursor
    }
    if (cursor != g_current_cursor) {
        XDefineCursor(dpy, win, cursor);
        XFlush(dpy);
        g_current_cursor = cursor;
        sh_custom_forget(); // a named cursor replaced the bitmap
    }
}

// The last bitmap-uploaded X cursor — freed when replaced, so per-frame
// re-creation can't leak XIDs (themed/library cursors are server
// resources shared with other clients; only ours are freed).
static Cursor g_custom_x_cursor;

void egui_cr_set_cursor_image(const unsigned char* rgba, int w, int h, int hx, int hy) {
    if (!sh_run_direct()) { sh_post_cursor_image(rgba, w, h, hx, hy); return; }
    Display* dpy = (Display*)sapp_x11_get_display();
    Window win = (Window)sapp_x11_get_window();
    if (!dpy || !win || !rgba || w <= 0 || h <= 0) return;
    if (sh_custom_same(rgba, w, h, hx, hy)) return;
    XcursorImage* image = XcursorImageCreate(w, h);
    if (!image) return;
    image->xhot = (unsigned int)hx;
    image->yhot = (unsigned int)hy;
    for (size_t i = 0; i < (size_t)w * (size_t)h; i++) {
        const unsigned char* p = rgba + i * 4;
        image->pixels[i] = ((unsigned int)p[3] << 24) |
                           ((unsigned int)p[0] << 16) |
                           ((unsigned int)p[1] << 8) |
                           (unsigned int)p[2];
    }
    Cursor cursor = XcursorImageLoadCursor(dpy, image);
    XcursorImageDestroy(image);
    if (!cursor) return;
    if (cursor != g_current_cursor) {
        XDefineCursor(dpy, win, cursor);
        XFlush(dpy);
        if (g_custom_x_cursor && g_custom_x_cursor != cursor)
            XFreeCursor(dpy, g_custom_x_cursor);
        g_custom_x_cursor = cursor;
        g_current_cursor = cursor;
    }
    sh_custom_remember(rgba, w, h, hx, hy);
}

#elif defined(_WIN32)

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

static HCURSOR g_win_current;

// Win32 resets the cursor on every WM_SETCURSOR (i.e. every mouse move),
// and sokol's WndProc answers that message with the cursor from
// sapp_set_mouse_cursor — which knows nothing about our IDC_* table —
// instantly reverting a plain SetCursor to the class arrow. Subclass
// the window proc and answer WM_SETCURSOR ourselves with the current
// handle (the eframe/winit approach: winit owns WM_SETCURSOR too).
static WNDPROC g_win_prev_proc;
static LRESULT CALLBACK sh_wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_SETCURSOR && LOWORD(lp) == HTCLIENT && g_win_current) {
        SetCursor(g_win_current);
        return TRUE;
    }
    return CallWindowProc(g_win_prev_proc, hwnd, msg, wp, lp);
}

// Called from egui_cr_set_cursor (inside the frame callback), so the
// window exists and we are on its own thread — the only safe place to
// swap the WndProc.
static void sh_win_install_cursor_proc(void) {
    if (g_win_prev_proc) return;
    HWND hwnd = (HWND)sapp_win32_get_hwnd();
    if (hwnd) {
        g_win_prev_proc = (WNDPROC)SetWindowLongPtrW(hwnd, GWLP_WNDPROC,
                                                    (LONG_PTR)sh_wndproc);
    }
}

// 1x1 fully transparent cursor for CSS `none` (AND mask all ones = every
// pixel transparent). Mask scan lines are DWORD-aligned, so 1 px still
// takes 4 bytes per plane. Created once, lives for the process.
static HCURSOR sh_win_none_cursor(void) {
    static HCURSOR none;
    if (!none) {
        static const BYTE and_mask[4] = {0xFF, 0xFF, 0xFF, 0xFF};
        static const BYTE xor_mask[4] = {0x00, 0x00, 0x00, 0x00};
        none = CreateCursor(NULL, 0, 0, 1, 1, and_mask, xor_mask);
    }
    return none;
}


// winuser.h cursor resource ids (IDC_* are MAKEINTRESOURCE macros — plain
// pointers, not compile-time integers — so the numbers are spelled out,
// exactly like sokol_app's own LoadCursorW(MAKEINTRESOURCEW(32512)) table).
typedef struct { const char* css; WORD idc; } win_cursor_t;
static const win_cursor_t g_win_cursors[] = {
    {"default", 32512},        {"context-menu", 32512},   // IDC_ARROW
    {"help", 32651},           {"pointer", 32649},        // IDC_HELP / IDC_HAND
    {"progress", 32650},       {"wait", 32514},           // IDC_APPSTARTING / IDC_WAIT
    {"cell", 32515},           {"crosshair", 32515},      // IDC_CROSS
    {"text", 32513},           {"vertical-text", 32513},  // IDC_IBEAM
    {"alias", 32512},          {"copy", 32512},           // IDC_ARROW
    {"move", 32646},           {"no-drop", 32648},        // IDC_SIZEALL / IDC_NO
    {"not-allowed", 32648},    {"grab", 32646},           // IDC_NO / IDC_SIZEALL
    {"grabbing", 32646},       {"all-scroll", 32646},     // IDC_SIZEALL
    {"ew-resize", 32644},      {"col-resize", 32644},     // IDC_SIZEWE
    {"ns-resize", 32645},      {"row-resize", 32645},     // IDC_SIZENS
    {"nesw-resize", 32643},    {"nwse-resize", 32642},    // IDC_SIZENESW / IDC_SIZENWSE
    {"e-resize", 32644},       {"w-resize", 32644},       // IDC_SIZEWE
    {"n-resize", 32645},       {"s-resize", 32645},       // IDC_SIZENS
    {"ne-resize", 32643},      {"sw-resize", 32643},      // IDC_SIZENESW
    {"nw-resize", 32642},      {"se-resize", 32642},      // IDC_SIZENWSE
    {"zoom-in", 32515},        {"zoom-out", 32515},       // IDC_CROSS
};

void egui_cr_set_cursor(const char* css_name) {
    if (!sh_run_direct()) { sh_post_cursor(css_name); return; }
    // The subclass must be in place BEFORE the first SetCursor, or the
    // first mouse move resets it to the class arrow.
    sh_win_install_cursor_proc();
    HCURSOR c = NULL;
    if (strcmp(css_name, "none") == 0) {
        c = sh_win_none_cursor();
    } else {
        for (size_t i = 0; i < sizeof(g_win_cursors)/sizeof(g_win_cursors[0]); i++) {
            if (strcmp(css_name, g_win_cursors[i].css) == 0) {
                c = LoadCursorW(NULL, MAKEINTRESOURCEW(g_win_cursors[i].idc));
                break;
            }
        }
    }
    if (c && c != g_win_current) {
        SetCursor(c);
        g_win_current = c;
        sh_custom_forget(); // a named cursor replaced the bitmap
    }
}

// The last bitmap-uploaded HCURSOR — destroyed when replaced, so
// per-frame re-creation can't leak icon handles.
static HCURSOR g_win_custom;

void egui_cr_set_cursor_image(const unsigned char* rgba, int w, int h, int hx, int hy) {
    if (!sh_run_direct()) { sh_post_cursor_image(rgba, w, h, hx, hy); return; }
    // The subclass must be in place BEFORE the first SetCursor, or the
    // first mouse move resets it to the class arrow.
    sh_win_install_cursor_proc();
    if (!rgba || w <= 0 || h <= 0) return;
    if (sh_custom_same(rgba, w, h, hx, hy)) return;

    // 32-bpp ARGB DIB section, top-down so rows copy in source order.
    // BI_BITFIELDS + bV5AlphaMask is what makes CreateIconIndirect use
    // the alpha channel instead of the AND mask for transparency.
    BITMAPV5HEADER bi;
    ZeroMemory(&bi, sizeof(bi));
    bi.bV5Size = sizeof(bi);
    bi.bV5Width = w;
    bi.bV5Height = -h; // top-down
    bi.bV5Planes = 1;
    bi.bV5BitCount = 32;
    bi.bV5Compression = BI_BITFIELDS;
    bi.bV5RedMask = 0x00FF0000;
    bi.bV5GreenMask = 0x0000FF00;
    bi.bV5BlueMask = 0x000000FF;
    bi.bV5AlphaMask = 0xFF000000;

    void* bits = NULL;
    HDC hdc = GetDC(NULL);
    HBITMAP color = CreateDIBSection(hdc, (BITMAPINFO*)&bi, DIB_RGB_COLORS,
                                     &bits, NULL, 0);
    ReleaseDC(NULL, hdc);
    if (!color) return;
    unsigned char* dst = (unsigned char*)bits;
    for (size_t i = 0; i < (size_t)w * (size_t)h; i++) {
        const unsigned char* p = rgba + i * 4; // RGBA → BGRA
        dst[i * 4 + 0] = p[2];
        dst[i * 4 + 1] = p[1];
        dst[i * 4 + 2] = p[0];
        dst[i * 4 + 3] = p[3];
    }
    // All-zero AND mask: every pixel's transparency comes from alpha.
    HBITMAP mask = CreateBitmap(w, h, 1, 1, NULL);
    if (!mask) { DeleteObject(color); return; }

    ICONINFO ii;
    ZeroMemory(&ii, sizeof(ii));
    ii.fIcon = FALSE;
    ii.xHotspot = (DWORD)(hx < 0 ? 0 : hx);
    ii.yHotspot = (DWORD)(hy < 0 ? 0 : hy);
    ii.hbmColor = color;
    ii.hbmMask = mask;
    HCURSOR c = CreateIconIndirect(&ii);
    DeleteObject(color);
    DeleteObject(mask);
    if (!c) return;
    if (c != g_win_current) {
        SetCursor(c);
        if (g_win_custom && g_win_custom != c) DestroyCursor(g_win_custom);
        g_win_custom = c;
        g_win_current = c;
    } else {
        DestroyCursor(c);
    }
    sh_custom_remember(rgba, w, h, hx, hy);
}

#elif defined(__APPLE__)

// macOS: NSCursor mapping. The frame callback runs on the main thread (as
// NSCursor requires). CSS `none` hides the cursor until the mouse moves,
// matching how egui hides it during drags.

static char g_mac_cursor[32];

// Diagonal resize cursors are private NSCursor class methods (winit uses
// them too) — look them up at runtime, fall back when absent.
static NSCursor* sh_mac_private_cursor(const char* sel_name) {
    SEL sel = sel_getUid(sel_name);
    if ([NSCursor respondsToSelector:sel])
        return [NSCursor performSelector:sel];
    return nil;
}

static NSCursor* sh_mac_private_or(const char* sel_name, NSCursor* fallback) {
    NSCursor* c = sh_mac_private_cursor(sel_name);
    return c ? c : fallback;
}

static NSCursor* sh_mac_cursor(const char* css) {
    if (strcmp(css, "pointer") == 0)       return [NSCursor pointingHandCursor];
    if (strcmp(css, "grab") == 0)          return [NSCursor openHandCursor];
    if (strcmp(css, "grabbing") == 0 ||    // closed hand doubles as move/
        strcmp(css, "move") == 0 ||        // all-scroll: macOS has no
        strcmp(css, "all-scroll") == 0)    // dedicated four-way cursor
        return [NSCursor closedHandCursor];
    if (strcmp(css, "text") == 0)          return [NSCursor IBeamCursor];
    if (strcmp(css, "vertical-text") == 0) { // not in the public headers
        NSCursor* c = sh_mac_private_cursor("IBeamCursorForVerticalLayoutCursor");
        return c ? c : [NSCursor IBeamCursor];
    }
    if (strcmp(css, "crosshair") == 0 ||
        strcmp(css, "cell") == 0 ||
        strcmp(css, "zoom-in") == 0 ||     // macOS has no zoom cursors
        strcmp(css, "zoom-out") == 0)
        return [NSCursor crosshairCursor];
    if (strcmp(css, "not-allowed") == 0 ||
        strcmp(css, "no-drop") == 0)       return [NSCursor operationNotAllowedCursor];
    if (strcmp(css, "progress") == 0 ||    // macOS has no watch cursor —
        strcmp(css, "wait") == 0) {        // busy spinner (private header),
        NSCursor* c = sh_mac_private_cursor("busyButClickableCursor"); // closest
        return c ? c : [NSCursor arrowCursor];
    }
    if (strcmp(css, "alias") == 0)         return [NSCursor dragLinkCursor];
    if (strcmp(css, "copy") == 0)          return [NSCursor dragCopyCursor];
    if (strcmp(css, "ew-resize") == 0 ||
        strcmp(css, "col-resize") == 0)    return [NSCursor resizeLeftRightCursor];
    if (strcmp(css, "ns-resize") == 0 ||
        strcmp(css, "row-resize") == 0)    return [NSCursor resizeUpDownCursor];
    if (strcmp(css, "e-resize") == 0)      return [NSCursor resizeRightCursor];
    if (strcmp(css, "w-resize") == 0)      return [NSCursor resizeLeftCursor];
    if (strcmp(css, "n-resize") == 0)      return [NSCursor resizeUpCursor];
    if (strcmp(css, "s-resize") == 0)      return [NSCursor resizeDownCursor];
    if (strcmp(css, "nesw-resize") == 0)
        return sh_mac_private_or("_windowResizeNorthEastSouthWestCursor",
                                 [NSCursor resizeUpDownCursor]);
    if (strcmp(css, "nwse-resize") == 0)
        return sh_mac_private_or("_windowResizeNorthWestSouthEastCursor",
                                 [NSCursor resizeUpDownCursor]);
    if (strcmp(css, "ne-resize") == 0)
        return sh_mac_private_or("_windowResizeNorthEastCursor", [NSCursor arrowCursor]);
    if (strcmp(css, "sw-resize") == 0)
        return sh_mac_private_or("_windowResizeSouthWestCursor", [NSCursor arrowCursor]);
    if (strcmp(css, "nw-resize") == 0)
        return sh_mac_private_or("_windowResizeNorthWestCursor", [NSCursor arrowCursor]);
    if (strcmp(css, "se-resize") == 0)
        return sh_mac_private_or("_windowResizeSouthEastCursor", [NSCursor arrowCursor]);
    // default / context-menu / help and unknown names: arrow (macOS has
    // no help or context-menu cursor)
    return [NSCursor arrowCursor];
}

void egui_cr_set_cursor(const char* css_name) {
    if (strlen(css_name) >= sizeof(g_mac_cursor)) return;
    if (strcmp(g_mac_cursor, css_name) == 0) return; // dedupe per-frame calls
    strcpy(g_mac_cursor, css_name);
    sh_custom_forget(); // a named cursor replaced the bitmap
    if (strcmp(css_name, "none") == 0) {
        [NSCursor setHiddenUntilMouseMoves:YES];
        return;
    }
    [sh_mac_cursor(css_name) set];
}

// The winit cursor_from_image recipe: NSBitmapImageRep over the raw
// RGBA bytes (straight alpha), NSCursor initWithImage:hotspot: with the
// hotspot passed through unflipped. The name cache is cleared so the
// next named request re-applies instead of dedupe-skipping.
void egui_cr_set_cursor_image(const unsigned char* rgba, int w, int h, int hx, int hy) {
    if (!rgba || w <= 0 || h <= 0) return;
    if (sh_custom_same(rgba, w, h, hx, hy)) return;
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                     pixelsWide:w
                     pixelsHigh:h
                  bitsPerSample:8
                samplesPerPixel:4
                       hasAlpha:YES
                       isPlanar:NO
                 colorSpaceName:NSDeviceRGBColorSpace
                    bytesPerRow:w * 4
                     bitsPerPixel:32];
    if (!rep) return;
    memcpy([rep bitmapData], rgba, (size_t)w * (size_t)h * 4);
    NSImage* image = [[NSImage alloc] initWithSize:NSMakeSize(w, h)];
    [image addRepresentation:rep];
    NSCursor* cursor = [[NSCursor alloc] initWithImage:image
                                                hotSpot:NSMakePoint(hx, hy)];
    [cursor set];
    g_mac_cursor[0] = '\0'; // force the named path to re-apply
    sh_custom_remember(rgba, w, h, hx, hy);
}

#else

// Other backends: cursor switching not wired. The calls are no-ops.
void egui_cr_set_cursor(const char* css_name) { (void)css_name; }
void egui_cr_set_cursor_image(const unsigned char* rgba, int w, int h, int hx, int hy) {
    (void)rgba; (void)w; (void)h; (void)hx; (void)hy;
}

#endif

// --- window management -------------------------------------------------------
//
// System ports that sokol_app does not expose itself: resize, move,
// minimize/maximize/restore and the primary screen size. Title, fullscreen
// and clipboard go straight to sokol_app from Crystal (its exported
// functions are linked from this static lib).
//
//   X11: core protocol calls + _NET_WM_STATE client messages (EWMH).
//   Win32: SetWindowPos / ShowWindow / GetSystemMetrics.
//   macOS: NSWindow/NSScreen through AppKit (the shim compiles as
//   ObjC there; the calls arrive on the main thread from the frame
//   callback, as AppKit requires).

#if defined(_SAPP_LINUX)

// vendor/sokol GLX patch hook (declared at the top, called from
// _sapp_glx_choosefbconfig in sokol_app.h): transparent windows need a
// depth-32 ARGB visual so the compositor can blend the window per
// pixel — without this the chooser happily returns a depth-24 visual
// with an alpha-capable GL framebuffer, whose alpha never reaches the
// screen.
int egui_cr_glx_want_argb(void) { return g_transparent; }

// The _MOTIF_WM_HINTS property shared by the runtime decoration toggle
// and the pre-map hook below.
static void sh_x11_set_motif_hints(Display* dpy, Window win, int decorated) {
    struct {
        unsigned long flags;        // MWM_HINTS_DECORATIONS
        unsigned long functions;
        unsigned long decorations;
        unsigned long input_mode;
        unsigned long status;
    } hints;
    memset(&hints, 0, sizeof(hints));
    hints.flags = 2; // MWM_HINTS_DECORATIONS
    hints.decorations = decorated ? 1 : 0;
    Atom prop = XInternAtom(dpy, "_MOTIF_WM_HINTS", False);
    XChangeProperty(dpy, win, prop, prop, 32, PropModeReplace,
                    (unsigned char*)&hints, 5);
}

// vendor/sokol patch hook (called from _sapp_x11_show_window): strip
// decorations BEFORE the window is mapped. Stripping them from a
// mapped window makes mutter keep the old frame's bookkeeping —
// _NET_FRAME_EXTENTS stays 37px and the client gets resized to
// accommodate a title bar it no longer has.
void egui_cr_x11_pre_map_hook(Display* dpy, Window win) {
    if (!dpy || !win) return;
    // The backdrop the compositor shows from the very first exposure:
    // sokol swaps no earlier than the end of the first frame callback,
    // and the young window's undefined content reads as black. Keep the
    // X background pixel in sync with the current clear color (set
    // before the window exists — see Sokol#run's early set_clear_color).
    sh_x11_sync_window_background(g_clear[0], g_clear[1], g_clear[2]);
    if (g_borderless) sh_x11_set_motif_hints(dpy, win, 0);
    XFlush(dpy);
}

static void sh_net_wm_state(Display* dpy, Window win, long action,
                            const char* state_a, const char* state_b) {
    XEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.xclient.type = ClientMessage;
    ev.xclient.window = win;
    ev.xclient.message_type = XInternAtom(dpy, "_NET_WM_STATE", False);
    ev.xclient.format = 32;
    ev.xclient.data.l[0] = action; // 0 = unset, 1 = set, 2 = toggle
    ev.xclient.data.l[1] = (long)XInternAtom(dpy, state_a, False);
    ev.xclient.data.l[2] = state_b ? (long)XInternAtom(dpy, state_b, False) : 0;
    XSendEvent(dpy, RootWindow(dpy, DefaultScreen(dpy)), False,
               SubstructureRedirectMask | SubstructureNotifyMask, &ev);
}

void egui_cr_set_window_size(int w, int h) {
    if (!sh_run_direct()) { sh_post_window_size(w, h); return; }
    Display* dpy = (Display*)sapp_x11_get_display();
    Window win = (Window)sapp_x11_get_window();
    if (!dpy || !win) return;
    XResizeWindow(dpy, win, w, h);
    XFlush(dpy);
}

void egui_cr_set_window_position(int x, int y) {
    if (!sh_run_direct()) { sh_post_window_position(x, y); return; }
    Display* dpy = (Display*)sapp_x11_get_display();
    Window win = (Window)sapp_x11_get_window();
    if (!dpy || !win) return;
    XMoveWindow(dpy, win, x, y);
    XFlush(dpy);
}

void egui_cr_window_minimize(void) {
    if (!sh_run_direct()) { sh_post_window_minimize(); return; }
    Display* dpy = (Display*)sapp_x11_get_display();
    Window win = (Window)sapp_x11_get_window();
    if (!dpy || !win) return;
    XIconifyWindow(dpy, win, DefaultScreen(dpy));
    XFlush(dpy);
}

void egui_cr_window_maximize(void) {
    if (!sh_run_direct()) { sh_post_window_maximize(); return; }
    Display* dpy = (Display*)sapp_x11_get_display();
    Window win = (Window)sapp_x11_get_window();
    if (!dpy || !win) return;
    sh_net_wm_state(dpy, win, 1, "_NET_WM_STATE_MAXIMIZED_VERT",
                    "_NET_WM_STATE_MAXIMIZED_HORZ");
}

void egui_cr_window_restore(void) {
    if (!sh_run_direct()) { sh_post_window_restore(); return; }
    Display* dpy = (Display*)sapp_x11_get_display();
    Window win = (Window)sapp_x11_get_window();
    if (!dpy || !win) return;
    sh_net_wm_state(dpy, win, 0, "_NET_WM_STATE_MAXIMIZED_VERT",
                    "_NET_WM_STATE_MAXIMIZED_HORZ");
}

void egui_cr_screen_size(int* w, int* h) {
    if (!sh_run_direct()) { sh_post_screen_size(w, h); return; }
    Display* dpy = (Display*)sapp_x11_get_display();
    if (!dpy) { *w = 0; *h = 0; return; }
    *w = XDisplayWidth(dpy, DefaultScreen(dpy));
    *h = XDisplayHeight(dpy, DefaultScreen(dpy));
}

#elif defined(_WIN32)

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

void egui_cr_set_window_size(int w, int h) {
    if (!sh_run_direct()) { sh_post_window_size(w, h); return; }
    HWND hwnd = (HWND)sapp_win32_get_hwnd();
    if (!hwnd) return;
    SetWindowPos(hwnd, NULL, 0, 0, w, h, SWP_NOMOVE | SWP_NOZORDER);
}

void egui_cr_set_window_position(int x, int y) {
    if (!sh_run_direct()) { sh_post_window_position(x, y); return; }
    HWND hwnd = (HWND)sapp_win32_get_hwnd();
    if (!hwnd) return;
    SetWindowPos(hwnd, NULL, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER);
}

void egui_cr_window_minimize(void) {
    if (!sh_run_direct()) { sh_post_window_minimize(); return; }
    ShowWindow((HWND)sapp_win32_get_hwnd(), SW_MINIMIZE);
}
void egui_cr_window_maximize(void) {
    if (!sh_run_direct()) { sh_post_window_maximize(); return; }
    ShowWindow((HWND)sapp_win32_get_hwnd(), SW_MAXIMIZE);
}
void egui_cr_window_restore(void) {
    if (!sh_run_direct()) { sh_post_window_restore(); return; }
    ShowWindow((HWND)sapp_win32_get_hwnd(), SW_RESTORE);
}

void egui_cr_screen_size(int* w, int* h) {
    if (!sh_run_direct()) { sh_post_screen_size(w, h); return; }
    *w = GetSystemMetrics(SM_CXSCREEN);
    *h = GetSystemMetrics(SM_CYSCREEN);
}

#elif defined(__APPLE__)

// macOS: the sokol_app NSWindow, driven through AppKit. Zoom stands in
// for maximize (it toggles between the user frame and a frame filling
// the screen's visibleFrame), which matches the maximize/restore pair
// the X11 backend expresses with _NET_WM_STATE.

static NSWindow* sh_mac_window(void) {
    return (NSWindow*)sapp_macos_get_window();
}

void egui_cr_set_window_size(int w, int h) {
    NSWindow* win = sh_mac_window();
    if (!win) return;
    NSRect f = [win frame];
    f.origin.y += f.size.height - (CGFloat)h; // keep the top-left corner
    f.size.width = (CGFloat)w;
    f.size.height = (CGFloat)h;
    [win setFrame:f display:YES animate:NO];
}

void egui_cr_set_window_position(int x, int y) {
    NSWindow* win = sh_mac_window();
    if (!win) return;
    NSScreen* scr = [win screen];
    if (!scr) scr = [NSScreen mainScreen];
    if (!scr) return;
    NSRect vf = [scr visibleFrame];
    NSPoint tl; // y is bottom-up in AppKit; the port speaks top-left
    tl.x = vf.origin.x + (CGFloat)x;
    tl.y = vf.origin.y + vf.size.height - (CGFloat)y;
    [win setFrameTopLeftPoint:tl];
}

void egui_cr_window_minimize(void) {
    NSWindow* win = sh_mac_window();
    if (win) [win miniaturize:nil];
}

void egui_cr_window_maximize(void) {
    NSWindow* win = sh_mac_window();
    if (win && ![win isZoomed]) [win zoom:nil];
}

void egui_cr_window_restore(void) {
    NSWindow* win = sh_mac_window();
    if (win && [win isZoomed]) [win zoom:nil];
}

void egui_cr_screen_size(int* w, int* h) {
    NSScreen* scr = [NSScreen mainScreen];
    if (!scr) { *w = 0; *h = 0; return; }
    NSRect f = [scr frame]; // points, like sokol on macOS (high_dpi)
    *w = (int)f.size.width;
    *h = (int)f.size.height;
}

#else

// Other backends: not wired yet. The calls are no-ops.
void egui_cr_set_window_size(int w, int h) { (void)w; (void)h; }
void egui_cr_set_window_position(int x, int y) { (void)x; (void)y; }
void egui_cr_window_minimize(void) {}
void egui_cr_window_maximize(void) {}
void egui_cr_window_restore(void) {}
void egui_cr_screen_size(int* w, int* h) { *w = 0; *h = 0; }

#endif

// --- decorations / borderless ----------------------------------------------
//
// Custom chrome support (eframe `decorations: false`): strip the system
// title bar and borders — either at window creation (the borderless
// flag of egui_cr_sapp_run, applied in init_cb) or at runtime through
// SystemPorts::Window. The app then draws its own title bar and drives
// close/minimize/move/resize through the other window-management ports
// above.
//
//   X11: _MOTIF_WM_HINTS decorations=0 (honoured by all EWMH WMs).
//   Win32: clear WS_CAPTION|WS_THICKFRAME|... + SWP_FRAMECHANGED.
//   macOS: clear the NSWindowStyleMaskTitled bit (the resizable bit
//     stays on, so edge resizing keeps working).

#if defined(_SAPP_LINUX)

void egui_cr_set_decorations(int decorated) {
    if (!sh_run_direct()) { sh_post_decorations(decorated); return; }
    Display* dpy = (Display*)sapp_x11_get_display();
    Window win = (Window)sapp_x11_get_window();
    if (!dpy || !win) return;
    sh_x11_set_motif_hints(dpy, win, decorated);
    XFlush(dpy);
}

#elif defined(_WIN32)

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

void egui_cr_set_decorations(int decorated) {
    if (!sh_run_direct()) { sh_post_decorations(decorated); return; }
    HWND hwnd = (HWND)sapp_win32_get_hwnd();
    if (!hwnd) return;
    const LONG_PTR chrome = WS_CAPTION | WS_THICKFRAME | WS_SYSMENU |
                            WS_MINIMIZEBOX | WS_MAXIMIZEBOX;
    LONG_PTR style = GetWindowLongPtrW(hwnd, GWL_STYLE);
    style = decorated ? (style | chrome) : (style & ~chrome);
    SetWindowLongPtrW(hwnd, GWL_STYLE, style);
    // SWP_FRAMECHANGED re-evaluates the non-client area; keep pos/size.
    SetWindowPos(hwnd, NULL, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
}

#elif defined(__APPLE__)

void egui_cr_set_decorations(int decorated) {
    NSWindow* win = (NSWindow*)sapp_macos_get_window();
    if (!win) return;
    if (decorated) {
        win.styleMask = win.styleMask | NSWindowStyleMaskTitled;
    } else {
        win.styleMask = win.styleMask & ~NSWindowStyleMaskTitled;
    }
}

#else

void egui_cr_set_decorations(int decorated) { (void)decorated; }

#endif

// --- whole-window opacity ----------------------------------------------------
//
// Uniform runtime opacity for the WHOLE window (chrome + content), the
// terminal-emulator idiom (alacritty/Windows Terminal "window opacity").
// The GL swapchain's framebuffer alpha never survives to the compositor
// on several X11 stacks (see egui_cr_set_window_shape), so this goes
// through the platform's own window-opacity channel instead:
//
//   X11:    _NET_WM_WINDOW_OPACITY cardinal property (EWMH — needs a
//           running compositor, otherwise the WM ignores it).
//   Win32:  WS_EX_LAYERED + SetLayeredWindowAttributes(LWA_ALPHA);
//           the style bit is dropped again at full opacity.
//   macOS:  NSWindow.alphaValue.

#if defined(_SAPP_LINUX)

void egui_cr_set_window_opacity(float opacity) {
    if (!sh_run_direct()) { sh_post_window_opacity(opacity); return; }
    Display* dpy = (Display*)sapp_x11_get_display();
    Window win = (Window)sapp_x11_get_window();
    if (!dpy || !win) return;
    // Sanitize FIRST (NaN fails both bound checks, so it lands here too
    // instead of hitting the cast below as undefined behavior).
    if (!(opacity >= 0.0f && opacity <= 1.0f)) opacity = 1.0f;
    // Compute in double: 0xFFFFFFFF is NOT representable as float (it
    // rounds up to 0x100000000), so a float multiply at opacity 1.0
    // produced 2^32 — whose low 32 bits (what the 32-bit property
    // carries) are ZERO, making the window fully transparent at full
    // opacity. Double + clamp keeps 1.0 at 0xFFFFFFFF.
    double scaled = (double)opacity * 4294967295.0 + 0.5;
    unsigned long value =
        (scaled < 4294967295.0) ? (unsigned long)scaled : 0xFFFFFFFFUL;
    Atom prop = XInternAtom(dpy, "_NET_WM_WINDOW_OPACITY", False);
    XChangeProperty(dpy, win, prop, XA_CARDINAL, 32, PropModeReplace,
                    (unsigned char*)&value, 1);
    XFlush(dpy);
}

#elif defined(_WIN32)

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

void egui_cr_set_window_opacity(float opacity) {
    if (!sh_run_direct()) { sh_post_window_opacity(opacity); return; }
    HWND hwnd = (HWND)sapp_win32_get_hwnd();
    if (!hwnd) return;
    if (!(opacity >= 0.0f && opacity <= 1.0f)) opacity = 1.0f; // NaN too
    LONG_PTR ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
    if (opacity >= 1.0f) {
        // Fully opaque: drop the layered style (a layered window costs
        // the DWM an extra redirection surface).
        if (ex & WS_EX_LAYERED)
            SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex & ~WS_EX_LAYERED);
        return;
    }
    if (!(ex & WS_EX_LAYERED))
        SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex | WS_EX_LAYERED);
    BYTE alpha = (BYTE)(opacity * 255.0f + 0.5f);
    SetLayeredWindowAttributes(hwnd, 0, alpha, LWA_ALPHA);
}

#elif defined(__APPLE__)

void egui_cr_set_window_opacity(float opacity) {
    NSWindow* win = (NSWindow*)sapp_macos_get_window();
    if (!win) return;
    if (!(opacity >= 0.0f && opacity <= 1.0f)) opacity = 1.0f; // NaN too
    win.alphaValue = opacity;
}

#else

void egui_cr_set_window_opacity(float opacity) { (void)opacity; }

#endif

// Top-left corner of the window in screen coordinates, physical pixels
// (matches what egui_cr_set_window_position expects). Returns 1 on
// success, 0 when the platform or window is unavailable.
#if defined(_SAPP_LINUX)

int egui_cr_window_position(int* x, int* y) {
    if (!sh_run_direct()) return sh_post_window_position_get(x, y);
    Display* dpy = (Display*)sapp_x11_get_display();
    Window win = (Window)sapp_x11_get_window();
    *x = 0; *y = 0;
    if (!dpy || !win) return 0;
    Window root = DefaultRootWindow(dpy), child;
    int rx, ry;
    unsigned int mask;
    if (!XTranslateCoordinates(dpy, win, root, 0, 0, &rx, &ry, &child))
        return 0;
    *x = rx; *y = ry;
    return 1;
}

#elif defined(_WIN32)

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

int egui_cr_window_position(int* x, int* y) {
    *x = 0; *y = 0;
    if (!sh_run_direct()) return sh_post_window_position_get(x, y);
    HWND hwnd = (HWND)sapp_win32_get_hwnd();
    if (!hwnd) return 0;
    RECT r;
    if (!GetWindowRect(hwnd, &r)) return 0;
    *x = r.left; *y = r.top;
    return 1;
}

#elif defined(__APPLE__)

int egui_cr_window_position(int* x, int* y) {
    *x = 0; *y = 0;
    NSWindow* win = (NSWindow*)sapp_macos_get_window();
    if (!win) return 0;
    NSScreen* scr = [win screen];
    if (!scr) scr = [NSScreen mainScreen];
    if (!scr) return 0;
    NSRect f = [win frame];
    // AppKit y is bottom-up; the port speaks top-left (see
    // egui_cr_set_window_position).
    *x = (int)f.origin.x;
    *y = (int)(scr.frame.size.height - (f.origin.y + f.size.height));
    return 1;
}

#else

int egui_cr_window_position(int* x, int* y) { (void)x; (void)y; return 0; }

#endif

// --- native move/resize drag --------------------------------------------------
//
// Hand a title-bar/edge drag to the platform's own window-move loop.
// The compositor tracks the pointer, so the window follows exactly; a
// client-side move loop instead oscillates: it measures the pointer in
// window-local coordinates, and every XMoveWindow/SetWindowPos shifts
// those coordinates, feeding the next frame's delta with the window's
// own movement (async, a frame late) — visible as jitter. The eframe/
// winit `ViewportCommand::StartDrag` equivalent; GTK CSD headerbars
// use the same X11 path.
//
//   X11: _NET_WM_MOVERESIZE ClientMessage after ungrabbing the pointer
//     (the implicit grab from the press would block the WM's grab).
//     Direction: 8 = move, 0..7 = top-left/top/top-right/right/
//     bottom-right/bottom/bottom-left/left resizes.
//   Win32: ReleaseCapture + WM_NCLBUTTONDOWN with HTCAPTION / the HT*
//     edge constant — the native modal move/resize loop.
//   macOS: NSWindow perform[WindowDrag|WindowResize]WithEvent: with the
//     current NSEvent (called from the frame callback, i.e. on the main
//     thread, during a mouse-down — as AppKit requires).

#if defined(_SAPP_LINUX)

static void sh_net_wm_moveresize(Display* dpy, Window win, long direction) {
    Window root = DefaultRootWindow(dpy), child;
    int rx, ry, wx, wy;
    unsigned int mask;
    if (!XQueryPointer(dpy, win, &root, &child, &rx, &ry, &wx, &wy, &mask))
        return;
    XEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.xclient.type = ClientMessage;
    ev.xclient.window = win;
    ev.xclient.message_type = XInternAtom(dpy, "_NET_WM_MOVERESIZE", False);
    ev.xclient.format = 32;
    ev.xclient.data.l[0] = rx;
    ev.xclient.data.l[1] = ry;
    ev.xclient.data.l[2] = direction;
    ev.xclient.data.l[3] = 1; // button 1
    ev.xclient.data.l[4] = 1; // source: application
    XUngrabPointer(dpy, CurrentTime);
    XSendEvent(dpy, root, False,
               SubstructureRedirectMask | SubstructureNotifyMask, &ev);
    XFlush(dpy);
}

void egui_cr_window_drag_start(void) {
    if (!sh_run_direct()) { sh_post_drag_start(); return; }
    Display* dpy = (Display*)sapp_x11_get_display();
    Window win = (Window)sapp_x11_get_window();
    if (!dpy || !win) return;
    sh_net_wm_moveresize(dpy, win, 8); // _NET_WM_MOVERESIZE_MOVE
}

void egui_cr_window_resize_start(int direction) {
    if (!sh_run_direct()) { sh_post_resize_start(direction); return; }
    Display* dpy = (Display*)sapp_x11_get_display();
    Window win = (Window)sapp_x11_get_window();
    if (!dpy || !win || direction < 0 || direction > 7) return;
    sh_net_wm_moveresize(dpy, win, direction);
}

#elif defined(_WIN32)

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

// X11 _NET_WM_MOVERESIZE direction codes -> Win32 HT* hit-test constants.
static const WPARAM sh_win_ht[8] = {
    HTTOPLEFT, HTTOP, HTTOPRIGHT, HTRIGHT,
    HTBOTTOMRIGHT, HTBOTTOM, HTBOTTOMLEFT, HTLEFT,
};

void egui_cr_window_drag_start(void) {
    if (!sh_run_direct()) { sh_post_drag_start(); return; }
    HWND hwnd = (HWND)sapp_win32_get_hwnd();
    if (!hwnd) return;
    ReleaseCapture();
    SendMessageW(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
}

void egui_cr_window_resize_start(int direction) {
    if (!sh_run_direct()) { sh_post_resize_start(direction); return; }
    HWND hwnd = (HWND)sapp_win32_get_hwnd();
    if (!hwnd || direction < 0 || direction > 7) return;
    ReleaseCapture();
    SendMessageW(hwnd, WM_NCLBUTTONDOWN, sh_win_ht[direction], 0);
}

#elif defined(__APPLE__)

// performWindowResizeWithEvent: exists at runtime but is not in the public
// AppKit headers; declare the signature so -Wobjc-method-access stays quiet.
@interface NSWindow (EguiCrPrivateResize)
- (void)performWindowResizeWithEvent:(NSEvent *)event;
@end

void egui_cr_window_drag_start(void) {
    NSWindow* win = (NSWindow*)sapp_macos_get_window();
    if (!win) return;
    NSEvent* ev = [NSApp currentEvent];
    if (ev) [win performWindowDragWithEvent:ev];
}

void egui_cr_window_resize_start(int direction) {
    // The edge comes from the tracked event, not a direction code; the
    // borderless window keeps its resizable style bit.
    (void)direction;
    NSWindow* win = (NSWindow*)sapp_macos_get_window();
    if (!win) return;
    NSEvent* ev = [NSApp currentEvent];
    if (ev) [win performWindowResizeWithEvent:ev];
}

#else

void egui_cr_window_drag_start(void) {}
void egui_cr_window_resize_start(int direction) { (void)direction; }

#endif

// --- window shape (XShape / SetWindowRgn) -----------------------------------
//
// Binary per-pixel window shape from an 8-bit alpha mask (threshold
// 127): the cross-platform splash-screen primitive ("окно с картинкой
// разной формы"). Per-pixel translucency cannot rely on the GL swap
// chain — several X11 stacks (Mesa Xe + mutter among them) zero the
// framebuffer alpha before the compositor ever sees it — while a
// server-side shape clips output AND input deterministically, with or
// without a compositor. macOS keeps its native per-pixel alpha (the
// non-opaque NSWindow composites the GL alpha directly), so the shape
// is a no-op there.

unsigned char* egui_cr_image_alpha_mask(const char* path, int* w, int* h) {
    int n;
    unsigned char* data = stbi_load(path, w, h, &n, 4);
    if (!data) { *w = 0; *h = 0; return NULL; }
    size_t count = (size_t)(*w) * (size_t)(*h);
    unsigned char* mask = (unsigned char*)malloc(count);
    if (!mask) { stbi_image_free(data); *w = 0; *h = 0; return NULL; }
    for (size_t i = 0; i < count; i++) {
        mask[i] = data[i * 4 + 3] > 127 ? 255 : 0;
    }
    stbi_image_free(data);
    return mask;
}

void egui_cr_mem_free(void* p) { free(p); }

#if defined(_SAPP_LINUX)

#include <X11/extensions/shape.h>

void egui_cr_set_window_shape(const unsigned char* mask, int w, int h) {
    if (!sh_run_direct()) { sh_post_window_shape(mask, w, h); return; }
    Display* dpy = (Display*)sapp_x11_get_display();
    Window win = (Window)sapp_x11_get_window();
    if (!dpy || !win || !mask || w <= 0 || h <= 0) return;
    // Scanline runs of opaque pixels → YXBanded rectangles.
    int max_rects = 0;
    for (int y = 0; y < h; y++) {
        int x = 0;
        while (x < w) {
            if (mask[(size_t)y * w + x]) {
                int x0 = x;
                while (x < w && mask[(size_t)y * w + x]) x++;
                max_rects++;
                (void)x0;
            } else {
                x++;
            }
        }
    }
    XRectangle* rects = (XRectangle*)malloc(sizeof(XRectangle) * (size_t)(max_rects ? max_rects : 1));
    if (!rects) return;
    int n = 0;
    for (int y = 0; y < h; y++) {
        int x = 0;
        while (x < w) {
            if (mask[(size_t)y * w + x]) {
                int x0 = x;
                while (x < w && mask[(size_t)y * w + x]) x++;
                rects[n].x = (short)x0;
                rects[n].y = (short)y;
                rects[n].width = (short)(x - x0);
                rects[n].height = 1;
                n++;
            } else {
                x++;
            }
        }
    }
    XShapeCombineRectangles(dpy, win, ShapeBounding, 0, 0, rects, n,
                            ShapeSet, YXBanded);
    XShapeCombineRectangles(dpy, win, ShapeInput, 0, 0, rects, n,
                            ShapeSet, YXBanded);
    XFlush(dpy);
    free(rects);
}

#elif defined(_WIN32)

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

void egui_cr_set_window_shape(const unsigned char* mask, int w, int h) {
    if (!sh_run_direct()) { sh_post_window_shape(mask, w, h); return; }
    HWND hwnd = (HWND)sapp_win32_get_hwnd();
    if (!hwnd || !mask || w <= 0 || h <= 0) return;
    // count scanline runs first, then build an RGNDATA of RECTs
    DWORD count = 0;
    for (int y = 0; y < h; y++) {
        int x = 0;
        while (x < w) {
            if (mask[(size_t)y * w + x]) {
                while (x < w && mask[(size_t)y * w + x]) x++;
                count++;
            } else {
                x++;
            }
        }
    }
    DWORD size = sizeof(RGNDATAHEADER) + count * sizeof(RECT);
    RGNDATA* rd = (RGNDATA*)malloc(size);
    if (!rd) return;
    memset(rd, 0, size);
    rd->rdh.dwSize = sizeof(RGNDATAHEADER);
    rd->rdh.iType = RDH_RECTANGLES;
    rd->rdh.nCount = count;
    rd->rdh.nRgnSize = count * sizeof(RECT);
    rd->rdh.rcBound.right = (LONG)w;
    rd->rdh.rcBound.bottom = (LONG)h;
    RECT* r = (RECT*)rd->Buffer;
    DWORD n = 0;
    for (int y = 0; y < h; y++) {
        int x = 0;
        while (x < w) {
            if (mask[(size_t)y * w + x]) {
                int x0 = x;
                while (x < w && mask[(size_t)y * w + x]) x++;
                r[n].left = (LONG)x0;
                r[n].top = (LONG)y;
                r[n].right = (LONG)x;
                r[n].bottom = (LONG)y + 1;
                n++;
            } else {
                x++;
            }
        }
    }
    HRGN rgn = ExtCreateRegion(NULL, size, rd);
    free(rd);
    if (rgn) {
        // The region is owned by the window after this call.
        SetWindowRgn(hwnd, rgn, TRUE);
    }
}

#else

// macOS (and others): the window's own per-pixel alpha composites
// natively — no server-side shape needed.
void egui_cr_set_window_shape(const unsigned char* mask, int w, int h) {
    (void)mask; (void)w; (void)h;
}

#endif

// --- native file dialogs + window icon ---------------------------------------
//
// Win32 only; every other platform gets no-op stubs (the Crystal system
// ports fall back to their subprocess backends).
//
// File dialogs: the Vista IFileDialog (COM) — the Explorer-native picker,
// instant, no PowerShell/.NET startup cost. Show() blocks its thread, so
// the whole COM dance runs on a dedicated thread with its own STA; the
// Crystal side polls the done flag from the AsyncDialogs worker fiber
// (sleep-poll: the fiber yields, the frame loop keeps rendering).
//
// GUIDs are spelled out so the final link needs no uuid.lib.
#if defined(_WIN32)

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <objbase.h>
#if defined(__MINGW32__)
#include <shobjidl.h> // mingw-w64 ships the pre-split umbrella header
#else
#include <shobjidl_core.h>
#endif
#include <stdlib.h>
#include <string.h>

static const CLSID sh_CLSID_FileOpenDialog =
    {0xDC1C5A9C,0xE88A,0x4dde,{0xA5,0xA1,0x60,0xF8,0x2A,0x20,0xAE,0xF7}};
static const CLSID sh_CLSID_FileSaveDialog =
    {0xC0B4E2F3,0xBA21,0x4773,{0x8D,0xBA,0x33,0x5E,0xC9,0x46,0xEB,0x8B}};
static const IID sh_IID_IFileDialog =
    {0x42f85136,0xdb7e,0x439c,{0x85,0xf1,0xe4,0x07,0x5d,0x13,0x5f,0xc8}};
static const IID sh_IID_IShellItem =
    {0x43826d1e,0xe718,0x42ee,{0xbc,0x55,0xa1,0xe2,0x61,0xc3,0x7b,0xfe}};

typedef struct {
    int save;
    wchar_t title[512];
    wchar_t filter[2048];  // "name\0pattern\0name\0pattern\0\0" (utf-16)
    wchar_t directory[1024];
    wchar_t file_name[512]; // default file name (save dialog)
    wchar_t result[1024];   // picked path; empty on cancel/failure
    volatile LONG done;     // 0 running, 1 finished
    HANDLE thread;
} sh_file_dialog_t;

static void sh_run_com_dialog(sh_file_dialog_t* r) {
    r->result[0] = 0;
    HRESULT hr_init = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    if (FAILED(hr_init) && hr_init != RPC_E_CHANGED_MODE) return;
    IFileDialog* dlg = NULL;
    const CLSID* clsid = r->save ? &sh_CLSID_FileSaveDialog : &sh_CLSID_FileOpenDialog;
    if (SUCCEEDED(CoCreateInstance(clsid, NULL, CLSCTX_INPROC_SERVER,
                                   &sh_IID_IFileDialog, (void**)&dlg))) {
        DWORD opts = 0;
        dlg->lpVtbl->GetOptions(dlg, &opts);
        opts |= FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST;
        if (r->save) opts |= FOS_OVERWRITEPROMPT;
        dlg->lpVtbl->SetOptions(dlg, opts);
        if (r->title[0]) dlg->lpVtbl->SetTitle(dlg, r->title);
        if (r->filter[0]) {
            // "name\0pattern\0" pairs → COMDLG_FILTERSPEC array
            COMDLG_FILTERSPEC specs[32];
            int n = 0;
            const wchar_t* p = r->filter;
            while (*p && n < 32) {
                specs[n].pszName = p;
                while (*p) p++;
                p++;
                if (!*p) break;
                specs[n].pszSpec = p;
                while (*p) p++;
                p++;
                n++;
            }
            if (n) dlg->lpVtbl->SetFileTypes(dlg, (UINT)n, specs);
        }
        if (r->directory[0]) {
            IShellItem* si = NULL;
            if (SUCCEEDED(SHCreateItemFromParsingName(r->directory, NULL,
                                                      &sh_IID_IShellItem, (void**)&si))) {
                dlg->lpVtbl->SetDefaultFolder(dlg, si);
                si->lpVtbl->Release(si);
            }
        }
        if (r->file_name[0]) dlg->lpVtbl->SetFileName(dlg, r->file_name);
        // Owner must live on the dialog thread for real modality — pass
        // NULL; the frame loop keeps running anyway (see AsyncDialogs).
        if (SUCCEEDED(dlg->lpVtbl->Show(dlg, NULL))) {
            IShellItem* res = NULL;
            if (SUCCEEDED(dlg->lpVtbl->GetResult(dlg, &res))) {
                PWSTR path = NULL;
                if (SUCCEEDED(res->lpVtbl->GetDisplayName(res, SIGDN_FILESYSPATH,
                                                          &path)) && path) {
                    wcsncpy(r->result, path, 1023);
                    r->result[1023] = 0;
                    CoTaskMemFree(path);
                }
                res->lpVtbl->Release(res);
            }
        }
        dlg->lpVtbl->Release(dlg);
    }
    if (SUCCEEDED(hr_init)) CoUninitialize();
}

static DWORD WINAPI sh_dialog_thread(LPVOID param) {
    sh_file_dialog_t* r = (sh_file_dialog_t*)param;
    sh_run_com_dialog(r);
    InterlockedExchange(&r->done, 1);
    return 0;
}

static void sh_wcsncpy(wchar_t* dst, const wchar_t* src, size_t cap) {
    if (!src) { dst[0] = 0; return; }
    wcsncpy(dst, src, cap - 1);
    dst[cap - 1] = 0;
}

void* egui_cr_file_dialog_start(int save, const wchar_t* title,
                                const wchar_t* filter, const wchar_t* directory,
                                const wchar_t* file_name) {
    sh_file_dialog_t* r = (sh_file_dialog_t*)malloc(sizeof(sh_file_dialog_t));
    if (!r) return NULL;
    memset(r, 0, sizeof(*r));
    r->save = save;
    sh_wcsncpy(r->title, title, 512);
    sh_wcsncpy(r->filter, filter, 2048);
    sh_wcsncpy(r->directory, directory, 1024);
    sh_wcsncpy(r->file_name, file_name, 512);
    r->thread = CreateThread(NULL, 0, sh_dialog_thread, r, 0, NULL);
    if (!r->thread) { free(r); return NULL; }
    return r;
}

int egui_cr_file_dialog_done(void* handle) {
    if (!handle) return 1;
    return ((sh_file_dialog_t*)handle)->done;
}

const wchar_t* egui_cr_file_dialog_result(void* handle) {
    if (!handle) return L"";
    return ((sh_file_dialog_t*)handle)->result;
}

void egui_cr_file_dialog_free(void* handle) {
    if (!handle) return;
    sh_file_dialog_t* r = (sh_file_dialog_t*)handle;
    if (r->thread) {
        WaitForSingleObject(r->thread, INFINITE);
        CloseHandle(r->thread);
    }
    free(r);
}

void egui_cr_set_window_icon(const unsigned char* rgba, int w, int h) {
    HWND hwnd = (HWND)sapp_win32_get_hwnd();
    if (!hwnd || !rgba || w <= 0 || h <= 0) return;
    BITMAPV5HEADER bi;
    memset(&bi, 0, sizeof(bi));
    bi.bV5Size = sizeof(bi);
    bi.bV5Width = w;
    bi.bV5Height = -h; // top-down rows
    bi.bV5Planes = 1;
    bi.bV5BitCount = 32;
    bi.bV5Compression = BI_BITFIELDS;
    bi.bV5RedMask = 0x00FF0000;
    bi.bV5GreenMask = 0x0000FF00;
    bi.bV5BlueMask = 0x000000FF;
    bi.bV5AlphaMask = 0xFF000000;
    void* bits = NULL;
    HDC dc = GetDC(NULL);
    HBITMAP color = CreateDIBSection(dc, (BITMAPINFO*)&bi, DIB_RGB_COLORS,
                                     &bits, NULL, 0);
    ReleaseDC(NULL, dc);
    if (!color) return;
    unsigned char* dst = (unsigned char*)bits;
    for (int i = 0; i < w * h; i++) { // RGBA → BGRA premultiplied-less
        dst[i*4+0] = rgba[i*4+2];
        dst[i*4+1] = rgba[i*4+1];
        dst[i*4+2] = rgba[i*4+0];
        dst[i*4+3] = rgba[i*4+3];
    }
    HBITMAP mask = CreateBitmap(w, h, 1, 1, NULL);
    ICONINFO ii;
    memset(&ii, 0, sizeof(ii));
    ii.fIcon = TRUE;
    ii.hbmColor = color;
    ii.hbmMask = mask;
    HICON icon = CreateIconIndirect(&ii);
    if (icon) {
        static HICON prev; // WM_SETICON takes ownership — track & free
        SendMessageW(hwnd, WM_SETICON, ICON_SMALL, (LPARAM)icon);
        SendMessageW(hwnd, WM_SETICON, ICON_BIG, (LPARAM)icon);
        if (prev) DestroyIcon(prev);
        prev = icon;
    }
    DeleteObject(color);
    DeleteObject(mask);
}

#else // !defined(_WIN32)

void* egui_cr_file_dialog_start(int save, const wchar_t* title,
                                const wchar_t* filter, const wchar_t* directory,
                                const wchar_t* file_name) {
    (void)save; (void)title; (void)filter; (void)directory; (void)file_name;
    return NULL; // no native backend — the ports use their subprocess path
}
int egui_cr_file_dialog_done(void* handle) { (void)handle; return 1; }
const wchar_t* egui_cr_file_dialog_result(void* handle) { (void)handle; return L""; }
void egui_cr_file_dialog_free(void* handle) { (void)handle; }
void egui_cr_set_window_icon(const unsigned char* rgba, int w, int h) {
    (void)rgba; (void)w; (void)h;
}

#endif

// --- detached render loop (loop_redesign.md) ---------------------------------
//
// Two threads, strict ownership (the alacritty/kitty split):
//
//   main thread (A) — ALL Crystal (GC, scheduler, app.update, PTY
//     fibers, tessellation). Never touches the window system or GL.
//   render thread (R) — a C thread in this shim owning the window, the
//     GL context and the swap (X connection + GLX on Linux; the window's
//     message thread + WGL on Win32). Runs sokol's own loop with C-only
//     callbacks: window events are flattened into a ring buffer (plus a
//     doorbell byte for A's scheduler); frames come from a latest-wins
//     FramePacket mailbox that A fills by tessellating the paint command
//     list into a flat op stream; R replays the packet through sokol_gl
//     and swaps.
//
// Effect: a blocking glXSwapBuffers (XWayland/mutter can stall ~1 s)
// degrades from "the whole app is frozen" to "a frame is late" — input
// accumulates in the ring, PTY fibers keep running, app.update keeps
// producing packets, and R presents the freshest one when the
// compositor lets go.
//
// Window-management calls from A (title, cursor, clipboard, move/resize,
// …) go through a small command mailbox executed on R's thread (the X
// connection on Linux / the window's message thread on Win32); clipboard
// get / position queries are synchronous (condvar reply). Texture
// creation/updates become delta ops INSIDE the packet (GL work happens
// only on R). Legacy single-thread mode (macOS, or EGUI_RENDER_THREAD=0
// on Linux/Win32) keeps the direct paths: every routed function checks
// sh_detached() and falls through to the original body.
#if defined(_SAPP_LINUX) || defined(_SAPP_WIN32)

// --- portable primitives (thread / sync / atomics / doorbell) -----------------
//
// The loop needs: a thread for R, a mutex + condvar with a timed wait
// (the sync-mailbox roundtrips), relaxed atomics, and a one-byte doorbell
// R→A that A's Crystal scheduler can block on (evented). Linux maps those
// onto pthread + pipe. Win32: SRWLOCK + CONDITION_VARIABLE + CreateThread;
// the atomics onto Interlocked intrinsics (MSVC's C11 <stdatomic.h> needs
// /experimental:c11atomics); the doorbell onto a TCP loopback socket pair
// — anonymous pipes don't do overlapped IO, and Crystal's win32 scheduler
// (IOCP) adopts existing sockets only when they were created with
// WSA_FLAG_OVERLAPPED (see Socket's fd-constructor note in stdlib).
#if defined(_SAPP_LINUX)

#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <errno.h>
#include <time.h>
#include <limits.h>

#define SH_THREAD_LOCAL __thread
#define SH_MUTEX_STATIC_INIT PTHREAD_MUTEX_INITIALIZER
typedef _Atomic int sh_atom_i;
static int sh_ai_load(sh_atom_i* v) {
    return atomic_load_explicit(v, memory_order_relaxed);
}
static int sh_ai_xchg(sh_atom_i* v, int x) {
    return atomic_exchange(v, x);
}
static int sh_ai_xadd(sh_atom_i* v, int x) {
    return atomic_fetch_add(v, x);
}
static void sh_ai_store(sh_atom_i* v, int x) {
    atomic_store_explicit(v, x, memory_order_relaxed);
}
typedef pthread_mutex_t sh_mutex;
typedef pthread_cond_t sh_cond;
static void sh_mx_lock(sh_mutex* m)   { pthread_mutex_lock(m); }
static void sh_mx_unlock(sh_mutex* m) { pthread_mutex_unlock(m); }
static void sh_cv_init(sh_cond* c)    { pthread_cond_init(c, NULL); }
static void sh_cv_signal(sh_cond* c)  { pthread_cond_signal(c); }
static double sh_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}
// Wait on c (m held) until the monotonic *deadline*; 0 = signalled,
// -1 = timeout. pthread wants an absolute CLOCK_REALTIME abstime, so the
// remaining time is converted onto that clock first.
static int sh_cv_wait_until(sh_cond* c, sh_mutex* m, double deadline) {
    double left = deadline - sh_now();
    if (left <= 0.0) return -1;
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    double at = (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9 + left;
    ts.tv_sec = (time_t)at;
    ts.tv_nsec = (long)((at - (double)ts.tv_sec) * 1e9);
    return pthread_cond_timedwait(c, m, &ts) == 0 ? 0 : -1;
}
typedef pthread_t sh_thread;
static int sh_thread_create(sh_thread* t, void* (*fn)(void*)) {
    return pthread_create(t, NULL, fn, NULL) == 0 ? 0 : -1;
}
static void sh_thread_join(sh_thread t) { pthread_join(t, NULL); }

#else // _SAPP_WIN32

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#define SH_THREAD_LOCAL __declspec(thread)
#define SH_MUTEX_STATIC_INIT SRWLOCK_INIT
typedef long sh_atom_i; // Interlocked* intrinsics: aligned 32-bit longs
static int sh_ai_load(sh_atom_i* v) {
    return (int)*v; // relaxed load: plain read of an aligned 32-bit value
}
static int sh_ai_xchg(sh_atom_i* v, int x) {
    return (int)_InterlockedExchange(v, (long)x);
}
static int sh_ai_xadd(sh_atom_i* v, int x) {
    return (int)_InterlockedExchangeAdd(v, (long)x);
}
static void sh_ai_store(sh_atom_i* v, int x) { (void)sh_ai_xchg(v, x); }
typedef SRWLOCK sh_mutex;
typedef CONDITION_VARIABLE sh_cond;
static void sh_mx_lock(sh_mutex* m)   { AcquireSRWLockExclusive(m); }
static void sh_mx_unlock(sh_mutex* m) { ReleaseSRWLockExclusive(m); }
static void sh_cv_init(sh_cond* c)    { InitializeConditionVariable(c); }
static void sh_cv_signal(sh_cond* c)  { WakeConditionVariable(c); }
static double sh_now(void) {
    LARGE_INTEGER f, c;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart / (double)f.QuadPart;
}
static int sh_cv_wait_until(sh_cond* c, sh_mutex* m, double deadline) {
    double left = deadline - sh_now();
    if (left <= 0.0) return -1;
    DWORD ms = (DWORD)(left * 1000.0 + 0.5);
    return SleepConditionVariableSRW(c, m, ms, 0) ? 0 : -1;
}
typedef HANDLE sh_thread;
static void* (*sh_thread_fn)(void*); // the one thread spawned: R
static DWORD WINAPI sh_thread_trampoline(LPVOID param) {
    sh_thread_fn(param);
    return 0;
}
static int sh_thread_create(sh_thread* t, void* (*fn)(void*)) {
    sh_thread_fn = fn;
    *t = CreateThread(NULL, 0, sh_thread_trampoline, NULL, 0, NULL);
    return *t ? 0 : -1;
}
static void sh_thread_join(sh_thread t) {
    WaitForSingleObject(t, INFINITE);
    CloseHandle(t);
}

#endif // platform primitives

static sh_atom_i g_detached = 0;      // 1 once egui_cr_start spawned R
static sh_atom_i g_app_dead = 0;      // 1 once R's sokol loop ended
// True on the render thread (used to keep mailbox-executed calls on the
// direct path instead of re-posting into the mailbox).
static SH_THREAD_LOCAL int sh_on_render_thread = 0;

static int sh_detached(void) {
    return sh_ai_load(&g_detached) != 0;
}
static int sh_run_direct(void) {
    return !sh_detached() || sh_on_render_thread;
}

// EGUI_SHOT capture for the legacy (single-thread) path — same PPM
// output as the render-thread sh_shot, driven from egui_cr_end_pass.
static void sh_shot_legacy(void);

// ---- wake doorbell (R → A for Crystal's scheduler) --------------------------
// One byte per signal; tags distinguish init/quit from plain event
// doorbells. Non-blocking writes: a full pipe/socket just means A is
// behind and will drain everything in one read anyway.
#define SH_WAKE_EVENTS 1
#define SH_WAKE_INIT   2
#define SH_WAKE_QUIT   3
#define SH_WAKE_PRESENT 4 // R completed a render tick (≈ one present)

#if defined(_SAPP_LINUX)
static int g_a_pipe[2] = {-1, -1}; // [0] = A's read end, [1] = R's write
static void sh_wake_a(unsigned char tag) {
    if (g_a_pipe[1] < 0) return;
    char c = (char)tag;
    ssize_t n = write(g_a_pipe[1], &c, 1);
    (void)n;
}
// Called from any Crystal fiber (Context#request_repaint wake hook): the
// main loop must leave its blocking doorbell read and produce a frame.
void egui_cr_wake_main(void) { sh_wake_a(SH_WAKE_EVENTS); }

// Open the doorbell. Returns A's end (a nonblocking pipe fd), -1 on
// failure. R's write end lands in g_a_pipe[1].
static intptr_t sh_doorbell_open(void) {
    if (pipe2(g_a_pipe, O_NONBLOCK | O_CLOEXEC) != 0) return -1;
    return g_a_pipe[0];
}
static void sh_doorbell_close_a(intptr_t a_end) {
    if (a_end >= 0) close((int)a_end);
    if (g_a_pipe[1] >= 0) close(g_a_pipe[1]);
    g_a_pipe[0] = g_a_pipe[1] = -1;
}
// Non-blocking drain of A's end: up to cap bytes into buf, returns the
// total drained (0 when nothing is pending).
static int sh_doorbell_drain(intptr_t a_end, unsigned char* buf, int cap) {
    int total = 0;
    while (total < cap) {
        ssize_t n = read((int)a_end, buf + total, (size_t)(cap - total));
        if (n <= 0) break;
        total += (int)n;
    }
    return total;
}
#else // _SAPP_WIN32: TCP loopback pair

static SOCKET g_r_sock = INVALID_SOCKET; // R's write end
// Set when A (Crystal) provided R's write end itself: Crystal's IOCP
// scheduler never wakes an evented read on a foreign socket, so on
// Win32 the pair is created Crystal-side and the peer fd is handed
// over here before egui_cr_start.
static int g_doorbell_peer = 0;
void egui_cr_doorbell_set_peer(intptr_t fd) {
    g_r_sock = (SOCKET)fd;
    g_doorbell_peer = 1;
}
static void sh_wake_a(unsigned char tag) {
    if (g_r_sock == INVALID_SOCKET) return;
    char c = (char)tag;
    int n = send(g_r_sock, &c, 1, 0);
    (void)n;
}
// Called from any Crystal fiber (Context#request_repaint wake hook): the
// main loop must leave its blocking doorbell read and produce a frame.
void egui_cr_wake_main(void) { sh_wake_a(SH_WAKE_EVENTS); }

// A loopback TCP pair for the C-owned path (Linux keeps its pipe; this
// is the Win32 fallback when no peer was provided). NOTE: Crystal's
// IOCP scheduler will not wake an evented read on this foreign socket —
// on Win32 the pair must come from Crystal (egui_cr_doorbell_set_peer).
static intptr_t sh_doorbell_open(void) {
    if (g_doorbell_peer) return 0; // pair owned by Crystal; A keeps its end
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return -1;
    SOCKET srv = WSASocketW(AF_INET, SOCK_STREAM, 0, NULL, 0, WSA_FLAG_OVERLAPPED);
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    int one = 1;
    if (srv == INVALID_SOCKET ||
        setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, (const char*)&one, sizeof one) != 0 ||
        bind(srv, (struct sockaddr*)&addr, sizeof addr) != 0 ||
        listen(srv, 1) != 0) {
        if (srv != INVALID_SOCKET) closesocket(srv);
        return -1;
    }
    struct sockaddr_in bound;
    int bound_len = (int)sizeof bound;
    if (getsockname(srv, (struct sockaddr*)&bound, &bound_len) != 0) {
        closesocket(srv);
        return -1;
    }
    SOCKET a = WSASocketW(AF_INET, SOCK_STREAM, 0, NULL, 0, WSA_FLAG_OVERLAPPED);
    if (a == INVALID_SOCKET ||
        connect(a, (struct sockaddr*)&bound, sizeof bound) != 0) {
        if (a != INVALID_SOCKET) closesocket(a);
        closesocket(srv);
        return -1;
    }
    // R's end may be a plain socket: only A's end goes through Crystal's
    // IOCP event loop (blocking mode set by Socket's fd constructor).
    SOCKET r = accept(srv, NULL, NULL);
    closesocket(srv);
    if (r == INVALID_SOCKET) {
        closesocket(a);
        return -1;
    }
    g_r_sock = r;
    return (intptr_t)a;
}
static void sh_doorbell_close_a(intptr_t a_end) {
    if (a_end >= 0) closesocket((SOCKET)a_end);
    if (g_r_sock != INVALID_SOCKET) { closesocket(g_r_sock); g_r_sock = INVALID_SOCKET; }
}
// The socket stays in blocking mode for A's evented reads; peek the
// pending byte count (FIONREAD) and recv exactly that — a blocking recv
// of known-available bytes returns immediately, which is the nonblocking
// drain this needs.
static int sh_doorbell_drain(intptr_t a_end, unsigned char* buf, int cap) {
    int total = 0;
    while (total < cap) {
        u_long avail = 0;
        if (ioctlsocket((SOCKET)a_end, FIONREAD, &avail) != 0 || avail == 0) break;
        int want = (int)avail;
        if (want > cap - total) want = cap - total;
        int n = recv((SOCKET)a_end, (char*)buf + total, want, 0);
        if (n <= 0) break;
        total += n;
    }
    return total;
}
#endif // doorbell platform

// ---- input event ring --------------------------------------------------------
// The 9-field flat tuple sh_event_cb already produces, plus an optional
// malloc'd payload (FILES_DROPPED path list). Overflow drops the OLDEST
// record — latest pointer positions matter, and a 1 s swap stall
// produces at most a few hundred events.
typedef struct {
    int type;
    float mx, my, sx, sy;
    unsigned mods, mouse_button, key_code, char_code;
    void* payload;
} sh_event_rec_t;

typedef struct {
    int count;
    char* paths[8]; // max_dropped_files in the sapp_desc
} sh_drop_payload_t;

#define SH_RING_CAP 8192
static sh_event_rec_t g_ring[SH_RING_CAP];
static size_t g_ring_head = 0, g_ring_tail = 0; // head=write, tail=read
static sh_mutex g_ring_mx = SH_MUTEX_STATIC_INIT;

static void sh_drop_payload_free(sh_drop_payload_t* p) {
    if (!p) return;
    for (int i = 0; i < p->count; i++) free(p->paths[i]);
    free(p);
}

static void sh_ring_push(const sh_event_rec_t* rec) {
    sh_mx_lock(&g_ring_mx);
    size_t next = (g_ring_head + 1) % SH_RING_CAP;
    if (next == g_ring_tail) { // full — drop the oldest
        sh_drop_payload_free((sh_drop_payload_t*)g_ring[g_ring_tail].payload);
        g_ring[g_ring_tail].payload = NULL;
        g_ring_tail = (g_ring_tail + 1) % SH_RING_CAP;
        next = (g_ring_head + 1) % SH_RING_CAP;
    }
    g_ring[g_ring_head] = *rec;
    g_ring_head = next;
    sh_mx_unlock(&g_ring_mx);
}

// A-side: pop up to `cap` records into `out` (payloads become the
// caller's — free each with egui_cr_drop_payload_free).
int egui_cr_events_pop(sh_event_rec_t* out, int cap) {
    int n = 0;
    sh_mx_lock(&g_ring_mx);
    while (n < cap && g_ring_tail != g_ring_head) {
        out[n++] = g_ring[g_ring_tail];
        g_ring[g_ring_tail].payload = NULL;
        g_ring_tail = (g_ring_tail + 1) % SH_RING_CAP;
    }
    sh_mx_unlock(&g_ring_mx);
    return n;
}

void egui_cr_drop_payload_free(void* payload) {
    sh_drop_payload_free((sh_drop_payload_t*)payload);
}

static void sh_rt_event_cb(const sapp_event* ev) {
    sh_event_rec_t rec;
    memset(&rec, 0, sizeof rec);
    rec.type = (int)ev->type;
    rec.mx = ev->mouse_x;
    rec.my = ev->mouse_y;
    rec.sx = ev->scroll_x;
    rec.sy = ev->scroll_y;
    rec.mods = ev->modifiers;
    rec.mouse_button = (unsigned)ev->mouse_button;
    rec.key_code = (unsigned)ev->key_code;
    rec.char_code = ev->char_code;
    if (ev->type == SAPP_EVENTTYPE_FILES_DROPPED) {
        int count = sapp_get_num_dropped_files();
        if (count > 8) count = 8;
        sh_drop_payload_t* p =
            (sh_drop_payload_t*)calloc(1, sizeof(sh_drop_payload_t));
        if (p) {
            for (int i = 0; i < count; i++) {
                const char* path = sapp_get_dropped_file_path(i);
                p->paths[i] = path ? strdup(path) : NULL;
            }
            p->count = count;
            rec.payload = p;
        }
    }
    sh_ring_push(&rec);
    sh_wake_a(SH_WAKE_EVENTS);
}

// ---- A → R window command mailbox -------------------------------------------
// Every X-touching entry point on A posts a command instead; R executes
// the queue at the top of each render tick (before the pass, on its own
// connection). Synchronous queries (clipboard get, window position)
// wait on a per-command condvar for R's reply.
typedef enum {
    SH_CMD_WINDOW_SIZE, SH_CMD_WINDOW_POS, SH_CMD_DECOR, SH_CMD_OPACITY,
    SH_CMD_MINIMIZE, SH_CMD_MAXIMIZE, SH_CMD_RESTORE, SH_CMD_TOGGLE_FS,
    SH_CMD_DRAG, SH_CMD_RESIZE, SH_CMD_SHAPE, SH_CMD_CURSOR,
    SH_CMD_CURSOR_IMG, SH_CMD_TITLE, SH_CMD_CLIP_SET, SH_CMD_CLEAR_COLOR,
    SH_CMD_QUIT,
    // synchronous (condvar reply)
    SH_CMD_CLIP_GET, SH_CMD_WIN_POS_GET, SH_CMD_SCREEN_SIZE,
    SH_CMD_IS_FULLSCREEN,
} sh_cmd_kind;

typedef struct {
    sh_cmd_kind kind;
    int a, b, c, d;
    float f;
    void* ptr;      // malloc'd copy (string / rgba / mask), owned by the cmd
    size_t size;
    // sync reply (filled by R)
    int sync;
    int done;
    int r_int, r_a, r_b;
    char* r_str;    // strdup'd; the caller frees with egui_cr_mem_free
    sh_mutex mx;
    sh_cond cv;
} sh_cmd_t;

#define SH_CMD_CAP 128
static sh_cmd_t g_cmds[SH_CMD_CAP];
static int g_cmd_n = 0;
static sh_mutex g_cmd_mx = SH_MUTEX_STATIC_INIT;

static void sh_cmd_free(sh_cmd_t* c) {
    free(c->ptr);
    c->ptr = NULL;
}

// Post an async command; takes ownership of `ptr`.
static void sh_cmd_post_async(sh_cmd_kind kind, int a, int b, int c, int d,
                              float f, void* ptr, size_t size) {
    sh_cmd_t cmd;
    memset(&cmd, 0, sizeof cmd);
    cmd.kind = kind; cmd.a = a; cmd.b = b; cmd.c = c; cmd.d = d;
    cmd.f = f; cmd.ptr = ptr; cmd.size = size;
    sh_mx_lock(&g_cmd_mx);
    if (g_cmd_n >= SH_CMD_CAP) { // queue full: drop the request
        sh_cmd_free(&cmd);
    } else {
        g_cmds[g_cmd_n++] = cmd;
    }
    sh_mx_unlock(&g_cmd_mx);
}

static char* sh_strdup_n(const char* s) { return s ? strdup(s) : NULL; }

// Sync command round trip. Returns 0 on success, -1 on timeout / dead R
// (the reply stays zeroed — callers treat that as failure).
static int sh_cmd_roundtrip(sh_cmd_t* cmd) {
    cmd->sync = 1;
    sh_cv_init(&cmd->cv);
    sh_mx_lock(&g_cmd_mx);
    if (g_cmd_n >= SH_CMD_CAP) {
        sh_mx_unlock(&g_cmd_mx);
        sh_cmd_free(cmd);
        return -1;
    }
    g_cmds[g_cmd_n++] = *cmd;
    sh_mx_unlock(&g_cmd_mx);

    double deadline = sh_now() + 2.0; // a healthy tick is ~16 ms; 2 s covers a stall
    int ok = -1;
    sh_mx_lock(&cmd->mx);
    while (!cmd->done && sh_ai_load(&g_app_dead) == 0) {
        if (sh_cv_wait_until(&cmd->cv, &cmd->mx, deadline) != 0) break;
    }
    if (cmd->done) ok = 0;
    sh_mx_unlock(&cmd->mx);
    // On timeout the command may still sit in the queue / be in flight on
    // R — its reply memory is intentionally leaked (catastrophic path).
    if (ok == 0) sh_cmd_free(cmd);
    return ok;
}

static void sh_cmd_reply(sh_cmd_t* c) {
    sh_mx_lock(&c->mx);
    c->done = 1;
    sh_cv_signal(&c->cv);
    sh_mx_unlock(&c->mx);
}

static void sh_cmd_exec(sh_cmd_t* c) {
    switch (c->kind) {
    case SH_CMD_WINDOW_SIZE:  egui_cr_set_window_size(c->a, c->b); break;
    case SH_CMD_WINDOW_POS:   egui_cr_set_window_position(c->a, c->b); break;
    case SH_CMD_DECOR:        egui_cr_set_decorations(c->a); break;
    case SH_CMD_OPACITY:      egui_cr_set_window_opacity(c->f); break;
    case SH_CMD_MINIMIZE:     egui_cr_window_minimize(); break;
    case SH_CMD_MAXIMIZE:     egui_cr_window_maximize(); break;
    case SH_CMD_RESTORE:      egui_cr_window_restore(); break;
    case SH_CMD_TOGGLE_FS:    sapp_toggle_fullscreen(); break;
    case SH_CMD_DRAG:         egui_cr_window_drag_start(); break;
    case SH_CMD_RESIZE:       egui_cr_window_resize_start(c->a); break;
    case SH_CMD_SHAPE:        egui_cr_set_window_shape(c->ptr, c->a, c->b); break;
    case SH_CMD_CURSOR:       egui_cr_set_cursor((const char*)c->ptr); break;
    case SH_CMD_CURSOR_IMG:   egui_cr_set_cursor_image(c->ptr, c->a, c->b,
                                                       c->c, c->d); break;
    case SH_CMD_TITLE:        sapp_set_window_title((const char*)c->ptr); break;
    case SH_CMD_CLIP_SET:     sapp_set_clipboard_string((const char*)c->ptr); break;
    case SH_CMD_CLEAR_COLOR: {
        float* rgba = (float*)c->ptr; // r,g,b,a — alpha unused by the X sync
        #if defined(_SAPP_LINUX)
        sh_x11_sync_window_background(rgba[0], rgba[1], rgba[2]);
        #else
        (void)rgba; // no server-side window background on Win32
        #endif
        break;
    }
    case SH_CMD_QUIT:         sapp_quit(); break;
    case SH_CMD_CLIP_GET: {
        const char* s = sapp_get_clipboard_string();
        if (getenv("EGUI_CLIP_DEBUG"))
            fprintf(stderr, "[clip] R exec get: '%s'\n", s ? s : "(null)");
        c->r_str = sh_strdup_n(s && s[0] ? s : NULL);
        sh_cmd_reply(c);
        return; // sync: reply instead of free
    }
    case SH_CMD_WIN_POS_GET: {
        int x = 0, y = 0;
        c->r_int = egui_cr_window_position(&x, &y);
        c->r_a = x; c->r_b = y;
        sh_cmd_reply(c);
        return;
    }
    case SH_CMD_SCREEN_SIZE: {
        int w = 0, h = 0;
        egui_cr_screen_size(&w, &h);
        c->r_a = w; c->r_b = h;
        sh_cmd_reply(c);
        return;
    }
    case SH_CMD_IS_FULLSCREEN:
        c->r_int = sapp_is_fullscreen();
        sh_cmd_reply(c);
        return;
    }
    sh_cmd_free(c);
    if (c->sync) sh_cmd_reply(c); // unreachable for the async set
}

static void sh_cmds_run(void) {
    sh_cmd_t batch[SH_CMD_CAP];
    int n;
    sh_mx_lock(&g_cmd_mx);
    n = g_cmd_n;
    memcpy(batch, g_cmds, sizeof(sh_cmd_t) * (size_t)n);
    g_cmd_n = 0;
    sh_mx_unlock(&g_cmd_mx);
    for (int i = 0; i < n; i++) sh_cmd_exec(&batch[i]);
}

// ---- FramePacket: flat draw list + texture deltas ----------------------------
//
// A tessellates the paint command list into a flat opcode stream (the
// same sgl calls the single-threaded path made, serialized) plus two
// ordered texture-delta lists (pre-pass: create/update; post-pass:
// destroy — a texture drawn by this packet dies only after the NEXT
// packet's draws, never before its own). Latest-wins mailbox: A may
// publish freely; R takes the freshest packet each tick and drops stale
// ones (their pre-ops are superseded; their destroy-ops are spliced
// forward so evictions never get lost).
typedef struct {
    sh_texop_kind kind;
    uint32_t id;
    int w, h;
    int stream;  // CREATE: SG_USAGE stream (video surfaces)
    void* data;  // CREATE/UPDATE: malloc'd RGBA8 copy (CREATE may be NULL)
    size_t size;
} sh_texop_t;

enum {
    SH_OP_SCISSOR, SH_OP_PIPE, SH_OP_PIPE_POP, SH_OP_TEX, SH_OP_TEX_ON,
    SH_OP_TEX_OFF, SH_OP_BEGIN, SH_OP_END, SH_OP_V, SH_OP_VT,
    SH_OP_MESH3D,
};

typedef struct {
    int fb_w, fb_h;
    float ppp;
    float clear[4];
    uint32_t* ops; int ops_len, ops_cap;
    sh_texop_t* pre;  int pre_n,  pre_cap;   // before the pass
    sh_texop_t* post; int post_n, post_cap;  // after the next pass
} sh_packet_t;

static sh_packet_t* g_build;    // A-side builder (between publishes)
static sh_packet_t* g_pkt;      // mailbox slot: latest, maybe unconsumed
static sh_packet_t* g_pkt_last; // R-owned: replay source
static sh_mutex g_pkt_mx = SH_MUTEX_STATIC_INIT;
static float g_pkt_ppp = 1.0f;  // ppp for the packet being built (A)

static void sh_packet_free(sh_packet_t* p) {
    if (!p) return;
    for (int i = 0; i < p->pre_n; i++) free(p->pre[i].data);
    for (int i = 0; i < p->post_n; i++) free(p->post[i].data);
    free(p->ops); free(p->pre); free(p->post);
    free(p);
}

static void sh_build_ensure(void) {
    if (!g_build) g_build = (sh_packet_t*)calloc(1, sizeof(sh_packet_t));
}

static void sh_grow(void** arr, int* cap, int need, size_t elem) {
    if (*cap >= need) return;
    int ncap = *cap ? *cap : 64;
    while (ncap < need) ncap *= 2;
    *arr = realloc(*arr, (size_t)ncap * elem);
    *cap = ncap;
}

static void sh_push_words(const uint32_t* w, int n) {
    sh_build_ensure();
    sh_grow((void**)&g_build->ops, &g_build->ops_cap, g_build->ops_len + n,
            sizeof(uint32_t));
    memcpy(g_build->ops + g_build->ops_len, w, sizeof(uint32_t) * (size_t)n);
    g_build->ops_len += n;
}

static uint32_t sh_f2u(float f) { union { float f; uint32_t u; } c; c.f = f; return c.u; }
static float sh_u2f(uint32_t u) { union { float f; uint32_t u; } c; c.u = u; return c.f; }

// Queue a texture delta into the current build (allocating it if no
// frame is open — ops ride the next publish).
static void sh_texop_queue(sh_texop_kind kind, uint32_t id, int w, int h,
                           int stream, const void* data, size_t size) {
    sh_build_ensure();
    sh_texop_t op;
    memset(&op, 0, sizeof op);
    op.kind = kind; op.id = id; op.w = w; op.h = h; op.stream = stream;
    op.size = size;
    if (data && size) {
        op.data = malloc(size);
        if (op.data) memcpy(op.data, data, size);
    }
    if (kind == SH_TEX_DESTROY) {
        sh_grow((void**)&g_build->post, &g_build->post_cap, g_build->post_n + 1,
                sizeof(sh_texop_t));
        g_build->post[g_build->post_n++] = op;
    } else {
        sh_grow((void**)&g_build->pre, &g_build->pre_cap, g_build->pre_n + 1,
                sizeof(sh_texop_t));
        g_build->pre[g_build->pre_n++] = op;
    }
}

// Detached make_texture: allocate a shim-side id and queue the upload.
static uint32_t sh_tex_make_detached(int w, int h, const void* rgba8,
                                     int stream) {
    if (w <= 0 || h <= 0) return 0;
    static sh_atom_i next_id;
    static int next_init;
    if (!next_init) { sh_ai_store(&next_id, 1); next_init = 1; }
    uint32_t id = (uint32_t)sh_ai_xadd(&next_id, 1);
    sh_texop_queue(SH_TEX_CREATE, id, w, h, stream, rgba8,
                   rgba8 ? (size_t)w * h * 4 : 0);
    return id;
}

// --- packet builder API (A-side; called from Crystal paint code) --------------

static void egui_cr_pkt_begin(int fb_w, int fb_h) {
    sh_build_ensure();
    free(g_build->ops); // draw ops never carry past a publish; a fresh
    g_build->ops = NULL; // frame resets them (texture ops accumulate)
    g_build->ops_len = 0;
    g_build->fb_w = fb_w;
    g_build->fb_h = fb_h;
    g_build->ppp = g_pkt_ppp > 0.0f ? g_pkt_ppp : 1.0f;
    g_build->clear[0] = g_clear[0];
    g_build->clear[1] = g_clear[1];
    g_build->clear[2] = g_clear[2];
    g_build->clear[3] = g_clear[3];
}

// Merge a superseded packet's texture ops (`src`, OLDER) into the
// packet being published (`dst`, NEWER), keeping only one op per
// texture id: a create/update must survive the drop (no later UPDATE
// may come — the atlas can stay clean), but stale pixel copies must
// not pile up while R is stalled (each atlas upload is a full 16 MB
// buffer). On an id collision the NEWER dst op wins — the src one is
// superseded data.
static void sh_texops_splice(sh_texop_t** dst, int* dst_n, int* dst_cap,
                             sh_texop_t* src, int src_n) {
    for (int i = 0; i < src_n; i++) {
        int at = -1;
        for (int j = 0; j < *dst_n; j++)
            if ((*dst)[j].id == src[i].id) { at = j; break; }
        if (at < 0) {
            sh_grow((void**)dst, dst_cap, *dst_n + 1, sizeof(sh_texop_t));
            (*dst)[(*dst_n)++] = src[i];
        } else {
            free(src[i].data); // older copy — the newer dst op stays
        }
    }
    free(src);
}

static void egui_cr_pkt_publish(void) {
    if (!g_build) return;
    sh_packet_t* p = g_build;
    g_build = NULL;
    if (getenv("EGUI_FRAME_DEBUG"))
        fprintf(stderr, "[pkt] publish ops=%d pre=%d post=%d fb=%dx%d\n",
                p->ops_len, p->pre_n, p->post_n, p->fb_w, p->fb_h);
    sh_mx_lock(&g_pkt_mx);
    if (g_pkt) { // superseded unconsumed packet: keep its texture ops —
        // creates/updates (pre) and evictions (post) must outlive the
        // drop, deduped to the newest op per id
        sh_texop_t* pre = g_pkt->pre; int pre_n = g_pkt->pre_n;
        sh_texop_t* post = g_pkt->post; int post_n = g_pkt->post_n;
        g_pkt->pre = NULL; g_pkt->pre_n = 0;
        g_pkt->post = NULL; g_pkt->post_n = 0;
        sh_packet_free(g_pkt);
        sh_texops_splice(&p->pre, &p->pre_n, &p->pre_cap, pre, pre_n);
        sh_texops_splice(&p->post, &p->post_n, &p->post_cap, post, post_n);
    }
    g_pkt = p;
    sh_mx_unlock(&g_pkt_mx);
    if (getenv("EGUI_FRAME_DEBUG") && p->pre_n)
        fprintf(stderr, "[pkt] publish+splice pre=%d (first kind=%d id=%u)\n",
                p->pre_n, p->pre_n ? p->pre[0].kind : -1,
                p->pre_n ? p->pre[0].id : 0);
}

void egui_cr_set_ppp(float ppp) { g_pkt_ppp = ppp; }

static void egui_cr_pkt_scissor(float x, float y, float w, float h) {
    uint32_t o[5] = { SH_OP_SCISSOR, sh_f2u(x), sh_f2u(y), sh_f2u(w), sh_f2u(h) };
    sh_push_words(o, 5);
}
static void egui_cr_pkt_pipe(int kind) { // 0 alpha, 1 replace, 2 text
    uint32_t o[2] = { SH_OP_PIPE, (uint32_t)kind };
    sh_push_words(o, 2);
}
static void egui_cr_pkt_pipe_pop(void) {
    uint32_t o[1] = { SH_OP_PIPE_POP };
    sh_push_words(o, 1);
}
static void egui_cr_pkt_tex(uint32_t id, int nearest) {
    uint32_t o[3] = { SH_OP_TEX, id, (uint32_t)(nearest ? 1 : 0) };
    sh_push_words(o, 3);
}
static void egui_cr_pkt_tex_on(void)  { uint32_t o[1] = { SH_OP_TEX_ON }; sh_push_words(o, 1); }
static void egui_cr_pkt_tex_off(void) { uint32_t o[1] = { SH_OP_TEX_OFF }; sh_push_words(o, 1); }
static void egui_cr_pkt_begin_quads(void) { uint32_t o[1] = { SH_OP_BEGIN }; sh_push_words(o, 1); }
static void egui_cr_pkt_end_quads(void)    { uint32_t o[1] = { SH_OP_END }; sh_push_words(o, 1); }

static void egui_cr_pkt_v(float x, float y, unsigned r, unsigned g, unsigned b,
                   unsigned a) {
    uint32_t o[4] = { SH_OP_V, sh_f2u(x), sh_f2u(y),
                      (r & 255u) | ((g & 255u) << 8) | ((b & 255u) << 16) |
                      ((a & 255u) << 24) };
    sh_push_words(o, 4);
}
static void egui_cr_pkt_vt(float x, float y, float u, float v, unsigned r, unsigned g,
                    unsigned b, unsigned a) {
    uint32_t o[6] = { SH_OP_VT, sh_f2u(x), sh_f2u(y), sh_f2u(u), sh_f2u(v),
                      (r & 255u) | ((g & 255u) << 8) | ((b & 255u) << 16) |
                      ((a & 255u) << 24) };
    sh_push_words(o, 6);
}

// One 3D mesh per op — mvp (16 words) + flags + viewport + count, then
// the raw packed vertex bytes riding the word stream (4 words per
// 16-byte vertex). Precedent: texture pixel deltas already travel
// inside packets, so streamed geometry shares the cost model.
static void egui_cr_pkt_mesh3d(const float* mvp, int blend, int prim,
                               int x, int y, int w, int h, int count,
                               const unsigned char* verts) {
    uint32_t head[23];
    head[0] = SH_OP_MESH3D;
    for (int i = 0; i < 16; i++) head[1 + i] = sh_f2u(mvp[i]);
    head[17] = (uint32_t)((blend ? 1 : 0) | (prim ? 2 : 0));
    head[18] = (uint32_t)x;
    head[19] = (uint32_t)y;
    head[20] = (uint32_t)w;
    head[21] = (uint32_t)h;
    head[22] = (uint32_t)count;
    sh_push_words(head, 23);
    int words = count * 4;
    sh_build_ensure();
    sh_grow((void**)&g_build->ops, &g_build->ops_cap,
            g_build->ops_len + words, sizeof(uint32_t));
    if (verts) memcpy(g_build->ops + g_build->ops_len, verts,
                      (size_t)words * 4);
    g_build->ops_len += words;
}

// ---- R-side texture table -----------------------------------------------------
// id → (sg_image, sg_view). Ids are allocated on A (atomic counter) and
// created lazily here as packet pre-ops arrive; an UPDATE for a missing
// id self-heals into a CREATE (a dropped packet must not kill an atlas).
#define SH_MAX_TEX 4096
typedef struct {
    uint32_t id;
    sg_image img;
    sg_view view;
    int w, h;
} sh_tex_t;
static sh_tex_t g_tex_tab[SH_MAX_TEX];
static int g_tex_tab_n = 0;
static sh_tex_t g_white_tex; // fallback for ids that failed to create

static sh_tex_t* sh_tex_find(uint32_t id) {
    for (int i = 0; i < g_tex_tab_n; i++)
        if (g_tex_tab[i].id == id) return &g_tex_tab[i];
    return NULL;
}

static void sh_white_tex_ensure(void) {
    if (g_white_tex.img.id) return;
    unsigned char px[4] = { 255, 255, 255, 255 };
    g_white_tex.img = sg_make_image(&(sg_image_desc){
        .width = 1, .height = 1, .usage = {.immutable = true},
        .data = {.mip_levels[0] = {.ptr = px, .size = 4}},
    });
    g_white_tex.view = sg_make_view(&(sg_view_desc){
        .texture = {.image = g_white_tex.img} });
    g_white_tex.id = 0xFFFFFFFF;
}

static void sh_tex_upload(sh_tex_t* t, const void* data, size_t size) {
    sg_image_data d;
    memset(&d, 0, sizeof d);
    d.mip_levels[0].ptr = data;
    d.mip_levels[0].size = size;
    sg_update_image(t->img, &d);
    // _sg_gl_update_image rebinds textures behind the state cache's back
    // (see egui_cr_atlas_update) — reset it or the next draw samples a
    // stale slot.
    sg_reset_state_cache();
}

// Returns 0 on failure (pool exhausted / GL object creation failed).
static int sh_tex_create(uint32_t id, int w, int h, void* data, size_t size) {
    sh_tex_t* t = sh_tex_find(id);
    if (t) { // already created — treat as an update
        if (data) sh_tex_upload(t, data, size);
        return 1;
    }
    if (g_tex_tab_n >= SH_MAX_TEX) return 0;
    // dynamic_update: atlases and stream surfaces are updated in place;
    // immutable make_texture uploads are folded into the first update.
    sg_image img = sg_make_image(&(sg_image_desc){
        .width = w, .height = h,
        .usage = {.dynamic_update = true},
        .label = "egui-cr-packet-texture",
    });
    if (img.id == 0) return 0;
    sg_view view = sg_make_view(&(sg_view_desc){
        .texture = {.image = img}, .label = "egui-cr-packet-texture-view" });
    if (view.id == 0) { sg_destroy_image(img); return 0; }
    t = &g_tex_tab[g_tex_tab_n++];
    t->id = id; t->img = img; t->view = view; t->w = w; t->h = h;
    if (data) sh_tex_upload(t, data, size);
    return 1;
}

static void sh_tex_run(const sh_texop_t* op) {
    sh_tex_t* t = sh_tex_find(op->id);
    if (getenv("EGUI_FRAME_DEBUG"))
        fprintf(stderr, "[tex] run kind=%d id=%u %dx%d%s%s\n", op->kind, op->id,
                op->w, op->h, op->data ? " data" : "",
                t ? " (exists)" : " (new)");
    switch (op->kind) {
    case SH_TEX_CREATE:
        if (t && op->data) sh_tex_upload(t, op->data, op->size);
        else sh_tex_create(op->id, op->w, op->h, op->data, op->size);
        break;
    case SH_TEX_UPDATE:
        if (!t) sh_tex_create(op->id, op->w, op->h, op->data, op->size);
        else if (op->data) sh_tex_upload(t, op->data, op->size);
        break;
    case SH_TEX_DESTROY:
        if (t) {
            sg_destroy_view(t->view);
            sg_destroy_image(t->img);
            *t = g_tex_tab[g_tex_tab_n - 1];
            g_tex_tab_n--;
        }
        break;
    }
}

// ---- R-side replay ------------------------------------------------------------

static void sh_ensure_pipelines(void);

static void sh_replay(sh_packet_t* p) {
    sh_ensure_pipelines();
    sh_sampler_ensure();
    sh_white_tex_ensure();
    sg_begin_pass(&(sg_pass){
        .swapchain = sglue_swapchain(),
        .action = {
            .colors[0] = {
                .load_action = SG_LOADACTION_CLEAR,
                .clear_value = { p->clear[0], p->clear[1], p->clear[2], p->clear[3] },
            },
        },
    });
    float w = (float)p->fb_w / p->ppp;
    float h = (float)p->fb_h / p->ppp;
    sgl_viewport(0, 0, p->fb_w, p->fb_h, true);
    sgl_matrix_mode_projection();
    sgl_load_identity();
    sgl_ortho(0.0f, w, h, 0.0f, -1.0f, 1.0f);
    sgl_matrix_mode_modelview();
    sgl_load_identity();

    const uint32_t* op = p->ops;
    const uint32_t* end = p->ops + p->ops_len;
    while (op < end) {
        switch (*op++) {
        case SH_OP_SCISSOR:
            sgl_scissor_rectf(sh_u2f(op[0]), sh_u2f(op[1]), sh_u2f(op[2]),
                              sh_u2f(op[3]), true);
            op += 4;
            break;
        case SH_OP_PIPE: {
            sgl_pipeline pip = op[0] == 1 ? g_replace_pip
                            : op[0] == 2 ? g_text_pip : g_alpha_pip;
            sgl_push_pipeline();
            sgl_load_pipeline(pip);
            op += 1;
            break;
        }
        case SH_OP_PIPE_POP: sgl_pop_pipeline(); break;
        case SH_OP_TEX: {
            sh_tex_t* t = sh_tex_find(op[0]);
            sg_view view = t ? t->view : g_white_tex.view;
            if (!t) {
                sh_white_tex_ensure();
                if (getenv("EGUI_FRAME_DEBUG"))
                    fprintf(stderr, "[tex] OP_TEX unknown id=%u -> white\n", op[0]);
            }
            sgl_texture(view, op[1] ? g_nearest_sampler : g_linear_sampler);
            op += 2;
            break;
        }
        case SH_OP_TEX_ON:  sgl_enable_texture(); break;
        case SH_OP_TEX_OFF: sgl_disable_texture(); break;
        case SH_OP_BEGIN:   sgl_begin_quads(); break;
        case SH_OP_END:     sgl_end(); break;
        case SH_OP_V: {
            uint32_t c = op[2];
            sgl_v2f_c4b(sh_u2f(op[0]), sh_u2f(op[1]),
                        c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF,
                        (c >> 24) & 0xFF);
            op += 3;
            break;
        }
        case SH_OP_VT: {
            uint32_t c = op[4];
            sgl_v2f_t2f_c4b(sh_u2f(op[0]), sh_u2f(op[1]), sh_u2f(op[2]),
                            sh_u2f(op[3]), c & 0xFF, (c >> 8) & 0xFF,
                            (c >> 16) & 0xFF, (c >> 24) & 0xFF);
            op += 5;
            break;
        }
        case SH_OP_MESH3D: {
            float mvp[16];
            for (int i = 0; i < 16; i++) mvp[i] = sh_u2f(op[i]);
            int flags = (int)op[16];
            int vx = (int)op[17], vy = (int)op[18];
            int vw = (int)op[19], vh = (int)op[20];
            int count = (int)op[21];
            op += 22;
            sh_draw_mesh3d(mvp, flags & 1, (flags >> 1) & 1,
                           vx, vy, vw, vh, count,
                           (const unsigned char*)op,
                           p->fb_w, p->fb_h, p->ppp);
            op += (size_t)count * 4;
            break;
        }
        default: // corrupted stream — drop the rest of the frame
            op = end;
            break;
        }
    }
    sgl_draw();
    sg_end_pass();
    sg_commit();
}

// ---- R render tick (called from sokol's frame callback) ------------------------

// Debug frame capture (EGUI_SHOT=dir): glReadPixels of the back buffer
// right after a replay, written as PPM for the first few PRESENTED
// frames — visual verification of the packet/replay path without a
// screen grabber (XWayland windows can't be XGetImage'd). Thresholds
// are present counts, not vsync ticks: an occluded XWayland window can
// present as rarely as once a second.
static int sh_shot_ticks[] = {3, 8, 20};
static void sh_shot(sh_packet_t* p) {
    static const char* dir;
    static int idx;
    if (!dir) { dir = getenv("EGUI_SHOT"); if (!dir) dir = (const char*)-1; }
    if ((intptr_t)dir == -1 || idx >= 3) return;
    int tick = sh_shot_ticks[idx];
    static uint32_t replay_count;
    replay_count++;
    if (replay_count < (uint32_t)tick) return;
    char* px = (char*)malloc((size_t)p->fb_w * p->fb_h * 3);
    if (!px) { idx++; return; }
    #if !defined(_SAPP_WIN32)
    glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
    #endif
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, p->fb_w, p->fb_h, GL_RGB, GL_UNSIGNED_BYTE, px);
    char path[512];
    snprintf(path, sizeof path, "%s/frame_%d.ppm", dir, tick);
    FILE* f = fopen(path, "wb");
    if (f) {
        fprintf(f, "P6\n%d %d\n255\n", p->fb_w, p->fb_h);
        // flip vertically: GL origin is bottom-left
        for (int y = p->fb_h - 1; y >= 0; y--)
            fwrite(px + (size_t)y * p->fb_w * 3, 1, (size_t)p->fb_w * 3, f);
        fclose(f);
    }
    free(px);
    idx++;
}

static sh_texop_t* g_post_pending;
static int g_post_pending_n;

// Window position cache: R refreshes it every few ticks (on its own
// connection / window thread) so A reads a slightly stale position
// instead of a condvar roundtrip. Without the cache a per-frame position
// query (the borderless example's status label) serialized A to R's tick
// — and when presents stall (an occluded XWayland window) A froze for
// the full roundtrip timeout, 2 s per frame.
static sh_atom_i sh_pos_x, sh_pos_y;
static sh_atom_i sh_pos_valid;

static void sh_rt_frame(void) {
    sh_cmds_run(); // A→R window commands, on R's connection

    // Position cache for A: refresh every ~15 ticks (~250 ms at 60 Hz)
    // — a single roundtrip, amortized. First success flips sh_pos_valid
    // and A stops blocking on WIN_POS_GET roundtrips entirely.
    static uint32_t pos_tick;
    if ((pos_tick++ % 15) == 0) {
        int x = 0, y = 0;
        if (egui_cr_window_position(&x, &y)) {
            sh_ai_store(&sh_pos_x, x);
            sh_ai_store(&sh_pos_y, y);
            sh_ai_store(&sh_pos_valid, 1);
        } else if (getenv("EGUI_FRAME_DEBUG")) {
            fprintf(stderr, "[pos] cache refresh failed on R\n");
        }
    }

    sh_mx_lock(&g_pkt_mx);
    sh_packet_t* fresh = g_pkt;
    g_pkt = NULL;
    sh_mx_unlock(&g_pkt_mx);

    if (fresh) {
        if (getenv("EGUI_FRAME_DEBUG"))
            fprintf(stderr, "[pkt] render thread took packet ops=%d pre=%d\n",
                    fresh->ops_len, fresh->pre_n);
        // destroys deferred from the previous packet — its draws are done
        if (g_post_pending_n > 0) {
            for (int i = 0; i < g_post_pending_n; i++) {
                sh_tex_run(&g_post_pending[i]);
                free(g_post_pending[i].data);
            }
            free(g_post_pending);
            g_post_pending = NULL;
            g_post_pending_n = 0;
        }
        for (int i = 0; i < fresh->pre_n; i++) {
            sh_tex_run(&fresh->pre[i]);
            free(fresh->pre[i].data);
            fresh->pre[i].data = NULL;
        }
        sh_packet_free(g_pkt_last); // replaced content
        g_pkt_last = fresh;
        // this packet's destroys run before the NEXT packet's draws
        g_post_pending = fresh->post;
        g_post_pending_n = fresh->post_n;
        fresh->post = NULL;
        fresh->post_n = 0;
    }
    if (g_pkt_last) {
        sh_replay(g_pkt_last); // replay every tick: sokol swaps after us
        sh_shot(g_pkt_last);
    } else {
        // No packet yet (before the first Crystal frame): present the
        // backdrop color each tick — the young window must not sit on an
        // uninitialized (black) framebuffer while fonts load.
        sh_clear_pass();
    }
}

static void sh_rt_init_cb(void) {
    sh_on_render_thread = 1;
    if (g_borderless) egui_cr_set_decorations(0);
    if (g_transparent) egui_cr_set_transparent();
    egui_cr_gfx_init();     // sg_setup + sgl_setup — GL objects on R
    egui_cr_text_pipeline_init();
    sh_ensure_pipelines();
    sh_wake_a(SH_WAKE_INIT);
}

static void sh_rt_frame_cb(void) {
    egui_cr_wd_on_frame_begin();
    sh_rt_frame();
    egui_cr_wd_on_frame_end();
    // Present-ack: sokol swaps right after this callback returns, so
    // this byte lands ~one present later. It paces A's frame
    // production to the actual present rate (the display's vsync) —
    // the detached equivalent of the legacy loop being ticked by its
    // own swap. During a swap stall the acks stop, and A's fallback
    // timeout keeps logic running at a reduced rate instead.
    sh_wake_a(SH_WAKE_PRESENT);
}

static void sh_rt_cleanup_cb(void) { }

// ---- render thread entry / lifecycle -------------------------------------------

static char* g_rt_title;
static sh_thread g_render_thread;
static int g_rt_w, g_rt_h, g_rt_swap;

static void* sh_render_thread(void* unused) {
    (void)unused;
    sh_on_render_thread = 1;
    sapp_desc desc = {
        .init_cb = sh_rt_init_cb,
        .frame_cb = sh_rt_frame_cb,
        .event_cb = sh_rt_event_cb,
        .cleanup_cb = sh_rt_cleanup_cb,
        .width = g_rt_w,
        .height = g_rt_h,
        .window_title = g_rt_title,
        .high_dpi = true,
        .sample_count = g_transparent ? 1 : 4,
        .swap_interval = g_rt_swap,
        .enable_clipboard = true,
        .enable_dragndrop = true,
        .max_dropped_files = 8,
        .max_dropped_file_path_length = 8192,
        .logger.func = slog_func,
    };
    sapp_run(&desc); // on Win32 this owns the window's message thread
    sh_ai_store(&g_app_dead, 1);
    sh_wake_a(SH_WAKE_QUIT);
    return NULL;
}

// Spawn the render thread; returns A's doorbell end (-1 on failure).
// Crystal registers it with its scheduler (an evented read blocks the
// main fiber only, letting PTY/dialog fibers run).
intptr_t egui_cr_start(const char* title, int width, int height, int borderless,
                       int transparent, int swap_interval) {
    intptr_t a_end = sh_doorbell_open();
    if (a_end < 0) return -1;
    g_borderless = borderless;
    g_transparent = transparent;
    g_rt_w = width;
    g_rt_h = height;
    g_rt_swap = getenv("EGUI_NOVSYNC") ? 0 : swap_interval;
    g_rt_title = title ? strdup(title) : strdup("egui-cr");
#if defined(_SAPP_LINUX)
    // Same XWayland DRI3 workaround as the legacy path below.
    if (getenv("WAYLAND_DISPLAY") && getenv("DISPLAY") &&
        !getenv("LIBGL_DRI3_DISABLE")) {
        setenv("LIBGL_DRI3_DISABLE", "1", 1);
    }
#endif
    sh_ai_store(&g_app_dead, 0);
    sh_ai_store(&g_detached, 1);
    if (sh_thread_create(&g_render_thread, sh_render_thread) != 0) {
        sh_ai_store(&g_detached, 0);
        sh_doorbell_close_a(a_end);
        return -1;
    }
    return a_end;
}

void egui_cr_join(void) {
    if (sh_ai_xchg(&g_detached, 0) != 0) {
        sh_thread_join(g_render_thread);
        sh_doorbell_close_a(-1); // close R's end; A's end is Crystal's IO
    }
}

// A-side non-blocking doorbell drain (see sh_doorbell_drain): up to cap
// bytes into buf, returns the total drained. Exposed so the same Crystal
// loop works over the pipe (Linux) and socket (Win32) doorbell.
int egui_cr_doorbell_drain(intptr_t a_end, unsigned char* buf, int cap) {
    return sh_doorbell_drain(a_end, buf, cap);
}

// ---- A-side routed wrappers (sokol functions Crystal used to call raw) --------

// window-management forwarding bodies (declared with the routing block
// at the top of this file, called from the prologues above)
static void* sh_copy(const void* p, size_t n) {
    void* c = malloc(n);
    if (c && p) memcpy(c, p, n);
    return c;
}

void sh_post_window_size(int w, int h) {
    sh_cmd_post_async(SH_CMD_WINDOW_SIZE, w, h, 0, 0, 0.f, NULL, 0);
}
void sh_post_window_position(int x, int y) {
    sh_cmd_post_async(SH_CMD_WINDOW_POS, x, y, 0, 0, 0.f, NULL, 0);
}
void sh_post_decorations(int decorated) {
    sh_cmd_post_async(SH_CMD_DECOR, decorated, 0, 0, 0, 0.f, NULL, 0);
}
void sh_post_window_opacity(float opacity) {
    sh_cmd_post_async(SH_CMD_OPACITY, 0, 0, 0, 0, opacity, NULL, 0);
}
void sh_post_window_minimize(void) {
    sh_cmd_post_async(SH_CMD_MINIMIZE, 0, 0, 0, 0, 0.f, NULL, 0);
}
void sh_post_window_maximize(void) {
    sh_cmd_post_async(SH_CMD_MAXIMIZE, 0, 0, 0, 0, 0.f, NULL, 0);
}
void sh_post_window_restore(void) {
    sh_cmd_post_async(SH_CMD_RESTORE, 0, 0, 0, 0, 0.f, NULL, 0);
}
void sh_post_screen_size(int* w, int* h) {
    sh_cmd_t cmd;
    memset(&cmd, 0, sizeof cmd);
    cmd.kind = SH_CMD_SCREEN_SIZE;
    if (sh_cmd_roundtrip(&cmd) != 0) { *w = 0; *h = 0; return; }
    *w = cmd.r_a; *h = cmd.r_b;
}
int sh_post_window_position_get(int* x, int* y) {
    if (sh_ai_load(&sh_pos_valid)) {
        *x = sh_ai_load(&sh_pos_x);
        *y = sh_ai_load(&sh_pos_y);
        return 1;
    }
    // no sample yet (before R's first refresh): one blocking fetch
    sh_cmd_t cmd;
    memset(&cmd, 0, sizeof cmd);
    cmd.kind = SH_CMD_WIN_POS_GET;
    if (sh_cmd_roundtrip(&cmd) != 0) { *x = 0; *y = 0; return 0; }
    *x = cmd.r_a; *y = cmd.r_b;
    return cmd.r_int;
}
void sh_post_drag_start(void) {
    sh_cmd_post_async(SH_CMD_DRAG, 0, 0, 0, 0, 0.f, NULL, 0);
}
void sh_post_resize_start(int dir) {
    sh_cmd_post_async(SH_CMD_RESIZE, dir, 0, 0, 0, 0.f, NULL, 0);
}
void sh_post_window_shape(const unsigned char* mask, int w, int h) {
    if (!mask || w <= 0 || h <= 0) return;
    sh_cmd_post_async(SH_CMD_SHAPE, w, h, 0, 0, 0.f,
                      sh_copy(mask, (size_t)w * h), (size_t)w * h);
}
void sh_post_cursor(const char* name) {
    if (!name) return;
    sh_cmd_post_async(SH_CMD_CURSOR, 0, 0, 0, 0, 0.f, sh_strdup_n(name), 0);
}
void sh_post_cursor_image(const unsigned char* rgba, int w, int h, int hx,
                          int hy) {
    if (!rgba || w <= 0 || h <= 0) return;
    sh_cmd_post_async(SH_CMD_CURSOR_IMG, w, h, hx, hy, 0.f,
                      sh_copy(rgba, (size_t)w * h * 4), (size_t)w * h * 4);
}
void sh_post_clear_color(void) {
    // g_clear was already stored by the caller — the R side only needs
    // the X window-background sync.
    float* rgba = (float*)malloc(4 * sizeof(float));
    if (!rgba) return;
    rgba[0] = g_clear[0]; rgba[1] = g_clear[1];
    rgba[2] = g_clear[2]; rgba[3] = g_clear[3];
    sh_cmd_post_async(SH_CMD_CLEAR_COLOR, 0, 0, 0, 0, 0.f, rgba,
                      4 * sizeof(float));
}

void egui_cr_set_window_title(const char* title) {
    if (sh_run_direct()) { sapp_set_window_title(title); return; }
    sh_cmd_post_async(SH_CMD_TITLE, 0, 0, 0, 0, 0.f, sh_strdup_n(title), 0);
}

void egui_cr_clipboard_set(const char* text) {
    if (sh_run_direct()) { sapp_set_clipboard_string(text); return; }
    sh_cmd_post_async(SH_CMD_CLIP_SET, 0, 0, 0, 0, 0.f, sh_strdup_n(text), 0);
}

#if defined(_SAPP_LINUX)
// Clipboard READ on the caller's (A's) thread through a private X
// connection — the same XConvertSelection dance sokol runs on its own
// connection. The sync roundtrip below could stall behind a ~1 s
// glXSwapBuffers wait (mutter stops sending frame events to occluded
// or freshly-mapped windows; loop_redesign.md §1): a paste must not
// depend on R's tick health. The connection + request window are
// thread-local and created once.
static SH_THREAD_LOCAL Display* sh_clip_d = NULL;
static SH_THREAD_LOCAL Window sh_clip_w = None;

static void sh_clip_conn_init(void) {
    if (sh_clip_d) return;
    sh_clip_d = XOpenDisplay(NULL);
    if (!sh_clip_d) return;
    sh_clip_w = XCreateSimpleWindow(sh_clip_d,
                                    DefaultRootWindow(sh_clip_d),
                                    0, 0, 1, 1, 0, 0, 0);
}

// malloc'd copy (free with egui_cr_mem_free); NULL when empty/failed.
static char* sh_clipboard_get_x11(void) {
    sh_clip_conn_init();
    if (!sh_clip_d || sh_clip_w == None) return NULL;
    Display* d = sh_clip_d;
    Atom utf8 = XInternAtom(d, "UTF8_STRING", False);
    Atom clip = XInternAtom(d, "CLIPBOARD", False);
    Atom prop = XInternAtom(d, "EGUI_CR_SELECTION", False);
    XConvertSelection(d, clip, utf8, prop, sh_clip_w, CurrentTime);
    XFlush(d);
    XEvent ev;
    const double deadline = sh_now() + 0.5; // generous vs sokol's 0.1
    for (;;) {
        if (XCheckTypedWindowEvent(d, sh_clip_w, SelectionNotify, &ev)) break;
        const double left = deadline - sh_now();
        if (left <= 0.0) return NULL;
        struct pollfd fd = { ConnectionNumber(d), POLLIN, 0 };
        poll(&fd, 1, (int)(left * 1000.0));
    }
    if (ev.xselection.property == None) return NULL;
    Atom actual;
    int fmt;
    unsigned long items, after;
    unsigned char* data = NULL;
    char* out = NULL;
    if (XGetWindowProperty(d, ev.xselection.requestor,
                           ev.xselection.property, 0, LONG_MAX, True, utf8,
                           &actual, &fmt, &items, &after,
                           &data) == Success && data) {
        out = sh_strdup_n((const char*)data);
        XFree(data);
    }
    return out;
}
#endif // _SAPP_LINUX

// malloc'd strdup (free with egui_cr_mem_free); NULL when empty/failed.
char* egui_cr_clipboard_get(void) {
#if defined(_SAPP_LINUX)
    // Detached A thread: read through the private connection above.
    // (R keeps the mailbox path; the legacy path runs the sokol call
    // directly on the one and only thread.)
    if (sh_detached() && !sh_on_render_thread) {
        char* s = sh_clipboard_get_x11();
        if (getenv("EGUI_CLIP_DEBUG"))
            fprintf(stderr, "[clip] get x11: '%s'\n", s ? s : "(null)");
        return s;
    }
#endif
    if (sh_run_direct()) {
        const char* s = sapp_get_clipboard_string();
        if (getenv("EGUI_CLIP_DEBUG"))
            fprintf(stderr, "[clip] get direct: '%s'\n", s ? s : "(null)");
        return sh_strdup_n(s && s[0] ? s : NULL);
    }
    sh_cmd_t cmd;
    memset(&cmd, 0, sizeof cmd);
    cmd.kind = SH_CMD_CLIP_GET;
    int rc = sh_cmd_roundtrip(&cmd);
    char* s = cmd.r_str;
    cmd.r_str = NULL;
    if (getenv("EGUI_CLIP_DEBUG"))
        fprintf(stderr, "[clip] get roundtrip rc=%d: '%s'\n", rc,
                s ? s : "(null)");
    if (rc != 0) return NULL;
    return s;
}

void egui_cr_toggle_fullscreen(void) {
    if (sh_run_direct()) { sapp_toggle_fullscreen(); return; }
    sh_cmd_post_async(SH_CMD_TOGGLE_FS, 0, 0, 0, 0, 0.f, NULL, 0);
}

int egui_cr_fullscreen_q(void) {
    if (sh_run_direct()) return sapp_is_fullscreen();
    sh_cmd_t cmd;
    memset(&cmd, 0, sizeof cmd);
    cmd.kind = SH_CMD_IS_FULLSCREEN;
    if (sh_cmd_roundtrip(&cmd) != 0) return 0;
    return cmd.r_int;
}

void egui_cr_request_quit(void) {
    if (sh_run_direct()) { sapp_quit(); return; }
    sh_cmd_post_async(SH_CMD_QUIT, 0, 0, 0, 0, 0.f, NULL, 0);
}

#endif // _SAPP_LINUX || _SAPP_WIN32

#if !defined(_SAPP_LINUX) && !defined(_SAPP_WIN32)
// Legacy-path entry points that the detached section above defines for
// Linux/Win32: on macOS everything runs on the one thread, so they are
// plain sapp pass-throughs.
void egui_cr_set_window_title(const char* title) { sapp_set_window_title(title); }
void egui_cr_clipboard_set(const char* text) { sapp_set_clipboard_string(text); }
char* egui_cr_clipboard_get(void) {
    const char* s = sapp_get_clipboard_string();
    return (s && s[0]) ? strdup(s) : NULL;
}
void egui_cr_toggle_fullscreen(void) { sapp_toggle_fullscreen(); }
int egui_cr_fullscreen_q(void) { return sapp_is_fullscreen(); }
void egui_cr_request_quit(void) { sapp_quit(); }
#endif
