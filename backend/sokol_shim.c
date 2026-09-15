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

static void sh_init_cb(void)   { g_init(); }
static void sh_frame_cb(void)  { g_frame(); }
static void sh_cleanup_cb(void){ g_cleanup(); }

static void sh_event_cb(const sapp_event* ev) {
    g_event((int)ev->type, ev->mouse_x, ev->mouse_y, ev->scroll_x, ev->scroll_y,
            ev->modifiers, (unsigned)ev->mouse_button,
            (unsigned)ev->key_code, ev->char_code);
}

void egui_cr_sapp_run(cr_init_cb init, cr_frame_cb frame, cr_event_cb event,
                      cr_cleanup_cb cleanup, const char* title,
                      int width, int height) {
    g_init = init; g_frame = frame; g_event = event; g_cleanup = cleanup;
    sapp_desc desc = {
        .init_cb = sh_init_cb,
        .frame_cb = sh_frame_cb,
        .event_cb = sh_event_cb,
        .cleanup_cb = sh_cleanup_cb,
        .width = width,
        .height = height,
        .window_title = title,
        .sample_count = 4, // MSAA: smooth circle/arc/line edges
        .enable_clipboard = true, // SystemPorts::Clipboard (sapp_set/get_clipboard_string)
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

void egui_cr_set_clear_color(float r, float g, float b, float a) {
    g_clear[0] = r;
    g_clear[1] = g;
    g_clear[2] = b;
    g_clear[3] = a;
}

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

// --- cursor -----------------------------------------------------------------
//
// Port of eframe/winit cursor handling: egui hands the integration a
// CSS `cursor` keyword ("pointer", "ew-resize", …) each frame; the
// integration maps it to the platform cursor.
//
//   X11/Xlib+Xcursor (Linux): theme cursor by CSS name — XDG cursor
//     themes use the CSS keywords — with a core cursor-font fallback
//     table for names the theme is missing.
//   Win32: IDC_* stock cursors (LoadCursor/SetCursor).
//   macOS: not wired yet (needs NSCursor through the ObjC runtime).

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

typedef struct { const char* css; LPCWSTR idc; } win_cursor_t;
static const win_cursor_t g_win_cursors[] = {
    {"default", IDC_ARROW},        {"context-menu", IDC_ARROW},
    {"help", IDC_HELP},            {"pointer", IDC_HAND},
    {"progress", IDC_APPSTARTING}, {"wait", IDC_WAIT},
    {"cell", IDC_CROSS},           {"crosshair", IDC_CROSS},
    {"text", IDC_IBEAM},           {"vertical-text", IDC_IBEAM},
    {"alias", IDC_ARROW},          {"copy", IDC_ARROW},
    {"move", IDC_SIZEALL},         {"no-drop", IDC_NO},
    {"not-allowed", IDC_NO},       {"grab", IDC_SIZEALL},
    {"grabbing", IDC_SIZEALL},     {"all-scroll", IDC_SIZEALL},
    {"ew-resize", IDC_SIZEWE},     {"col-resize", IDC_SIZEWE},
    {"ns-resize", IDC_SIZENS},     {"row-resize", IDC_SIZENS},
    {"nesw-resize", IDC_SIZENESW}, {"nwse-resize", IDC_SIZENWSE},
    {"e-resize", IDC_SIZEWE},      {"w-resize", IDC_SIZEWE},
    {"n-resize", IDC_SIZENS},      {"s-resize", IDC_SIZENS},
    {"ne-resize", IDC_SIZENESW},   {"sw-resize", IDC_SIZENESW},
    {"nw-resize", IDC_SIZENWSE},   {"se-resize", IDC_SIZENWSE},
    {"zoom-in", IDC_CROSS},        {"zoom-out", IDC_CROSS},
};

void egui_cr_set_cursor(const char* css_name) {
    for (size_t i = 0; i < sizeof(g_win_cursors)/sizeof(g_win_cursors[0]); i++) {
        if (strcmp(css_name, g_win_cursors[i].css) == 0) {
            HCURSOR c = LoadCursorW(NULL, g_win_cursors[i].idc);
            if (c && c != g_win_current) {
                SetCursor(c);
                g_win_current = c;
            }
            return;
        }
    }
}

#else

// macOS / other backends: cursor switching not wired (macOS needs
// NSCursor via the ObjC runtime). The call is a no-op.
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

#if defined(_SAPP_LINUX)

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

#else

// macOS / other backends: not wired yet (needs AppKit through the ObjC
// runtime). The calls are no-ops.
void egui_cr_set_window_size(int w, int h) { (void)w; (void)h; }
void egui_cr_set_window_position(int x, int y) { (void)x; (void)y; }
void egui_cr_window_minimize(void) {}
void egui_cr_window_maximize(void) {}
void egui_cr_window_restore(void) {}
void egui_cr_screen_size(int* w, int* h) { *w = 0; *h = 0; }

#endif
