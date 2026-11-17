#version 450
// egui-cr rounded-clip mask — vertex stage (Vulkan/SPIR-V twin of the
// GLSL SH_SDF_MASK_VS string in backend/sokol_shim.c).
//
// One fullscreen-quad corner drives a rounded-rect SDF: the shape rides
// uniforms (no instance buffer — a CSS frame can bracket dozens of clip
// edges, and one update per buffer per frame would exhaust any ring).
// The fragment twin evaluates the coverage and writes stencil only.
//
// Uniform layout mirrors the sg_shader_desc in sh_sdf_ensure: block 0 is
// the mvp (framebuffer ortho), block 1 packs the shape — center/half in
// POINTS, the four corner radii, and {shape half xy, _, ppp}.

layout(set = 0, binding = 0) uniform mask_vs_mvp_t {
    mat4 mvp;
} ub_mvp;

layout(set = 0, binding = 1) uniform mask_vs_shape_t {
    vec4 rect;   // center.xy, half.xy (points)
    vec4 radii;  // tl, tr, br, bl (points)
    vec4 mparam; // shape half xy, -, ppp
} ub_shape;

layout(location = 0) in vec2 corner;

layout(location = 0) out vec2 v_p;
layout(location = 1) flat out vec2 v_half;
layout(location = 2) flat out vec4 v_radii;
layout(location = 3) flat out vec4 v_ext; // .y = ppp (the AA band scale)

void main() {
    v_p = corner * ub_shape.rect.zw;
    v_half = ub_shape.mparam.xy;
    v_radii = ub_shape.radii;
    v_ext = vec4(0.0, ub_shape.mparam.w, 0.0, 0.0);
    gl_Position = ub_mvp.mvp * vec4(ub_shape.rect.xy + v_p, 0.0, 1.0);
}
