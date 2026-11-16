#version 450
// egui-cr video quad — vertex stage.
//
// The video pipeline draws one textured quad per frame: pos in framebuffer
// pixels, uv into the Y plane (the UV plane shares the same normalized uv —
// planes differ in memory size, not in normalized coordinates).
//
// Uniform layout mirrors the sg_shader_desc in backend/sokol_shim.c
// (sh_video_pipeline_init): ONE mat4 in the vertex stage, the colorimetry
// block lives in the fragment stage. Vulkan GLSL 450 for SPIR-V; the GL
// twins (410 / 300 es) are embedded as C strings in the shim.


layout(set = 0, binding = 0) uniform video_vs_t {
    mat4 mvp;
} vs;

layout(location = 0) in vec2 pos;
layout(location = 1) in vec2 uv0;

layout(location = 0) out vec2 v_uv;

void main() {
    v_uv = uv0;
    gl_Position = vs.mvp * vec4(pos, 0.0, 1.0);
}
