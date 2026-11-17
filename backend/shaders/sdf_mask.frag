#version 450
// egui-cr rounded-clip mask — fragment stage (Vulkan/SPIR-V twin).
//
// The minimal fill branch of the SDF shader: signed distance to the
// rounded rect, one smoothstep AA band scaled by pixels-per-point. The
// pipelines that run this (g_sdf_mask_pip / g_sdf_unmask_pip) write
// stencil only — the color output exists for toolchain safety and is
// masked off (SG_COLORMASK_NONE).

layout(location = 0) in vec2 v_p;
layout(location = 1) flat in vec2 v_half;
layout(location = 2) flat in vec4 v_radii;
layout(location = 3) flat in vec4 v_ext;

layout(location = 0) out vec4 frag_color;

float sd_round_box(vec2 p, vec2 half_size, vec4 radii) {
    float r = p.x < 0.0 ? (p.y < 0.0 ? radii.x : radii.w)
                        : (p.y < 0.0 ? radii.y : radii.z);
    r = min(r, min(half_size.x, half_size.y));
    vec2 q = abs(p) - half_size + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void main() {
    float ppp = max(v_ext.y, 1.0);
    float d = sd_round_box(v_p, v_half, v_radii) * ppp;
    float cov = 1.0 - smoothstep(-1.0, 1.0, d);
    if (cov <= 0.0) discard;
    frag_color = vec4(1.0);
}
