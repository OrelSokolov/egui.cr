// egui-cr sokol shim: single translation unit that implements all sokol
// libraries and exposes a small, FFI-friendly C surface for Crystal.
//
// Callback structs (sapp_desc, sg_pass_action, sfons_desc_t) are built
// here with designated initializers so Crystal never has to mirror the
// full sokol structs.

#define SOKOL_GLCORE
#define SOKOL_NO_ENTRY // we drive sapp_run from Crystal's main
#define SOKOL_IMPL
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
        .logger.func = slog_func,
    });
}

FONScontext* egui_cr_sfons_create(int width, int height) {
    return sfons_create(&(sfons_desc_t){ .width = width, .height = height });
}

void egui_cr_begin_pass(int w, int h) {
    (void)w; (void)h;
    sg_begin_pass(&(sg_pass){
        .swapchain = sglue_swapchain(),
        .action = {
            .colors[0] = {
                .load_action = SG_LOADACTION_CLEAR,
                .clear_value = { 0.075f, 0.075f, 0.08f, 1.0f },
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

// Bind a texture for the following sgl vertices (inside begin/end).
void egui_cr_sgl_texture(uint32_t view_id) {
    sg_view view = {.id = view_id};
    sgl_texture(view, g_linear_sampler);
}

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
