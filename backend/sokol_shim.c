// egui-cr sokol shim: single translation unit that implements all sokol
// libraries and exposes a small, FFI-friendly C surface for Crystal.
//
// Callback structs (sapp_desc, sg_pass_action, sfons_desc_t) are built
// here with designated initializers so Crystal never has to mirror the
// full sokol structs.

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

// window management (defined in the section below)
void egui_cr_set_decorations(int decorated);
int egui_cr_window_position(int* x, int* y);
void egui_cr_set_transparent(void);

// vendor/sokol GLX patch hook: 1 = restrict fbconfigs to depth-32 ARGB
// visuals (per-pixel window transparency).
int egui_cr_glx_want_argb(void);

static void sh_init_cb(void) {
    // X11 borderless is applied before the window is mapped (the
    // egui_cr_x11_pre_map_hook sokol patch); other platforms undecorate
    // here, once the window exists.
    if (g_borderless) egui_cr_set_decorations(0);
    if (g_transparent) egui_cr_set_transparent();
    g_init();
}
static void sh_frame_cb(void)  { g_frame(); }
static void sh_cleanup_cb(void){ g_cleanup(); }

static void sh_event_cb(const sapp_event* ev) {
    g_event((int)ev->type, ev->mouse_x, ev->mouse_y, ev->scroll_x, ev->scroll_y,
            ev->modifiers, (unsigned)ev->mouse_button,
            (unsigned)ev->key_code, ev->char_code);
}

void egui_cr_sapp_run(cr_init_cb init, cr_frame_cb frame, cr_event_cb event,
                      cr_cleanup_cb cleanup, const char* title,
                      int width, int height, int borderless, int transparent) {
    g_init = init; g_frame = frame; g_event = event; g_cleanup = cleanup;
    g_borderless = borderless;
    g_transparent = transparent;
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
        .logger.func = slog_func,
    });
    sgl_setup(&(sgl_desc_t){
        .max_vertices = 1 << 16,
        .max_commands = 1 << 14,
        // Must match the swapchain sample count requested in
        // egui_cr_sapp_run, or sokol_gfx validation fails.
        .sample_count = sapp_sample_count(),
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
#endif

void egui_cr_begin_pass(int w, int h) {
    (void)w; (void)h;
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
    sgl_draw();
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
}

#else

// X11: handled by the visual choice alone (see above).
void egui_cr_set_transparent(void) {}

#endif

// UI-quad pipeline with blending: same geometry as the sokol_gl default
// pipeline, but blending so translucent fills (modal scrim, shadows)
// composite over what's below and the compositing manager of a
// transparent window receives a properly PREMULTIPLIED image
// (rgb: src*a + dst*(1-a), a: a + dst_a*(1-a)). Opaque quads are
// unaffected; anti-aliased edges and translucent fills come out correct
// instead of fringing.
static sgl_pipeline g_alpha_pip;

void egui_cr_alpha_pipeline_push(void) {
    if (!g_alpha_pip.id) {
        g_alpha_pip = sgl_make_pipeline(&(sg_pipeline_desc){
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
            .label = "egui-cr-alpha-pip",
        });
    }
    sgl_push_pipeline();
    sgl_load_pipeline(g_alpha_pip);
}

void egui_cr_alpha_pipeline_pop(void) {
    sgl_pop_pipeline();
}

// Blend-OFF pipeline for replace rects (Painter#rect_replace): the quad
// overwrites dst rgb AND alpha — how a widget punches per-pixel
// transparency into an opaque UI (the terminal grid) without anything
// having to blend behind it.
static sgl_pipeline g_replace_pip;

void egui_cr_replace_pipeline_push(void) {
    if (!g_replace_pip.id) {
        g_replace_pip = sgl_make_pipeline(&(sg_pipeline_desc){
            .colors[0] = {
                // RGBA write mask: the whole point is overwriting the
                // alpha — sgl's RGB-only default would mask it off.
                .write_mask = SG_COLORMASK_RGBA,
                .blend = { .enabled = false },
            },
            .label = "egui-cr-replace-pip",
        });
    }
    sgl_push_pipeline();
    sgl_load_pipeline(g_replace_pip);
}

void egui_cr_replace_pipeline_pop(void) {
    sgl_pop_pipeline();
}

// --- textures -------------------------------------------------------------

static sg_sampler g_linear_sampler;

// Upload immutable RGBA8 data as a 2D texture; returns the sg_view id
// (0 on failure). The sampler is created once and shared.
uint32_t egui_cr_make_texture(int w, int h, const void* rgba8) {
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
    return view.id;
}

// Bind a texture for the following begin/end block (must be called
// OUTSIDE begin/end — sokol_gl asserts !ctx->in_begin). Texturing must
// then be enabled separately; disable it afterwards so later untextured
// geometry falls back to the internal white texture.
void egui_cr_sgl_texture(uint32_t view_id) {
    sg_view view = {.id = view_id};
    sgl_texture(view, g_linear_sampler);
}

void egui_cr_sgl_enable_texture(void) { sgl_enable_texture(); }
void egui_cr_sgl_disable_texture(void) { sgl_disable_texture(); }

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

// --- Crystal text stack GPU bits ---------------------------------------------
//
// The sokol_gl default pipeline has NO blending (write mask RGB only), so
// the text quads need their own pipeline — same setup the fontstash backend
// used (sfons): straight alpha blend, swapchain sample count.

static sgl_pipeline g_text_pip;
void egui_cr_atlas_update(uint32_t view_id, int w, int h, const void* rgba8);

void egui_cr_text_pipeline_init(void) {
    if (g_text_pip.id) return;
    g_text_pip = sgl_make_pipeline(&(sg_pipeline_desc){
        .colors[0] = {
            // sgl's implicit default write mask is RGB-only — alpha
            // writes masked off; enable them or the framebuffer alpha
            // stays at whatever the clear left (fatal in a
            // per-pixel-transparent window).
            .write_mask = SG_COLORMASK_RGBA,
            .blend = {
                .enabled = true,
                .src_factor_rgb = SG_BLENDFACTOR_SRC_ALPHA,
                .dst_factor_rgb = SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
                // Keep the backdrop alpha: out_a = a + dst_a*(1-a). With
                // the GL defaults (ONE, ZERO) glyph pixels replace the
                // destination alpha — invisible on an opaque window, but
                // it punches holes in a transparent one.
                .src_factor_alpha = SG_BLENDFACTOR_ONE,
                .dst_factor_alpha = SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
            },
        },
        .label = "egui-cr-text-pipeline",
    });
}

// sokol_gl pipeline stack wrappers: sgl_pipeline is a struct, easier to
// keep the struct marshalling here than bind it in Crystal.
void egui_cr_text_pipeline_push(void) {
    sgl_push_pipeline();
    sgl_load_pipeline(g_text_pip);
}

void egui_cr_text_pipeline_pop(void) {
    sgl_pop_pipeline();
}

// Glyph atlas textures: RGBA8, stream-updated whenever Crystal rasterizes
// new glyphs. Per-instance (see below) — one per font backend.

// --- glyph atlases: per-instance --------------------------------------------
//
// Multiple font backends coexist (fontpreview switches FreeType /
// light-hint live): each atlas_create returns its OWN image+view pair,
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
    }
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
    }
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
    if (strcmp(css_name, "none") == 0) {
        [NSCursor setHiddenUntilMouseMoves:YES];
        return;
    }
    [sh_mac_cursor(css_name) set];
}

#else

// Other backends: cursor switching not wired. The call is a no-op.
void egui_cr_set_cursor(const char* css_name) { (void)css_name; }

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
    if (!g_borderless || !dpy || !win) return;
    sh_x11_set_motif_hints(dpy, win, 0);
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
    Display* dpy = (Display*)sapp_x11_get_display();
    Window win = (Window)sapp_x11_get_window();
    if (!dpy || !win) return;
    XResizeWindow(dpy, win, w, h);
    XFlush(dpy);
}

void egui_cr_set_window_position(int x, int y) {
    Display* dpy = (Display*)sapp_x11_get_display();
    Window win = (Window)sapp_x11_get_window();
    if (!dpy || !win) return;
    XMoveWindow(dpy, win, x, y);
    XFlush(dpy);
}

void egui_cr_window_minimize(void) {
    Display* dpy = (Display*)sapp_x11_get_display();
    Window win = (Window)sapp_x11_get_window();
    if (!dpy || !win) return;
    XIconifyWindow(dpy, win, DefaultScreen(dpy));
    XFlush(dpy);
}

void egui_cr_window_maximize(void) {
    Display* dpy = (Display*)sapp_x11_get_display();
    Window win = (Window)sapp_x11_get_window();
    if (!dpy || !win) return;
    sh_net_wm_state(dpy, win, 1, "_NET_WM_STATE_MAXIMIZED_VERT",
                    "_NET_WM_STATE_MAXIMIZED_HORZ");
}

void egui_cr_window_restore(void) {
    Display* dpy = (Display*)sapp_x11_get_display();
    Window win = (Window)sapp_x11_get_window();
    if (!dpy || !win) return;
    sh_net_wm_state(dpy, win, 0, "_NET_WM_STATE_MAXIMIZED_VERT",
                    "_NET_WM_STATE_MAXIMIZED_HORZ");
}

void egui_cr_screen_size(int* w, int* h) {
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
    HWND hwnd = (HWND)sapp_win32_get_hwnd();
    if (!hwnd) return;
    SetWindowPos(hwnd, NULL, 0, 0, w, h, SWP_NOMOVE | SWP_NOZORDER);
}

void egui_cr_set_window_position(int x, int y) {
    HWND hwnd = (HWND)sapp_win32_get_hwnd();
    if (!hwnd) return;
    SetWindowPos(hwnd, NULL, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER);
}

void egui_cr_window_minimize(void) { ShowWindow((HWND)sapp_win32_get_hwnd(), SW_MINIMIZE); }
void egui_cr_window_maximize(void) { ShowWindow((HWND)sapp_win32_get_hwnd(), SW_MAXIMIZE); }
void egui_cr_window_restore(void)  { ShowWindow((HWND)sapp_win32_get_hwnd(), SW_RESTORE); }

void egui_cr_screen_size(int* w, int* h) {
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
    Display* dpy = (Display*)sapp_x11_get_display();
    Window win = (Window)sapp_x11_get_window();
    if (!dpy || !win) return;
    sh_net_wm_moveresize(dpy, win, 8); // _NET_WM_MOVERESIZE_MOVE
}

void egui_cr_window_resize_start(int direction) {
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
    HWND hwnd = (HWND)sapp_win32_get_hwnd();
    if (!hwnd) return;
    ReleaseCapture();
    SendMessageW(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
}

void egui_cr_window_resize_start(int direction) {
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
#include <shobjidl_core.h>
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
