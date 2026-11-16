#version 450
// egui-cr video quad — fragment stage: YUV → RGB.
//
// Two planes sampled separately (the zero-copy import hands us a VASurface
// as two Vulkan images / GL textures):
//   y_tex  — R16 for P010 (10-bit in the top of 16-bit containers) or
//            R8 for NV12
//   uv_tex — GR32 (P010) or GR88 (NV12), interleaved U,V
// Both come back UNSIGNED-NORMALIZED, so the SAME shader serves 8- and
// 10-bit surfaces: the quantization ladder is CPU-side math folded into
// `range` (mpv does exactly this).
//
// Colorimetry is uniform-driven — resolved on the CPU from the stream
// metadata (bt709/bt601 × full/limited × 8/10-bit):
//   y  = raw.r * range.x + range.y
//   uv = raw.rg * range.zw + vec2(range.w)   (single chroma pair: both
//                                             axes share scale/offset in
//                                             every standard range)
//   rgb = cmat * vec3(y, uv)
// Examples the CPU sends:
//   BT.709 limited 10-bit (NV12-ish ladder on P010):
//     range = (1024/876, -64/876, 1024/876, -64/876)*... see player.cr
//   BT.709 full 10-bit (Panasonic 6K pc-range):
//     range ≈ (1.0, 0, 1.0, 0), cmat = full-range 709 matrix
//
// Output alpha is 1.0 — the video quad blends over the UI by the
// pipeline's alpha blend state, tinting can come later as a vec4.


layout(set = 0, binding = 1) uniform video_fs_t {
    mat3 cmat;   // YUV → RGB (range-decoded values in)
    vec4 range;  // y_scale, y_bias, uv_scale, uv_bias
} fs;

layout(set = 1, binding = 0) uniform texture2D y_tex;
layout(set = 1, binding = 1) uniform texture2D uv_tex;
layout(set = 1, binding = 32) uniform sampler y_smp;
layout(set = 1, binding = 33) uniform sampler uv_smp;

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag_color;

void main() {
    float y = texture(sampler2D(y_tex, y_smp), v_uv).r;
    vec2 uv = texture(sampler2D(uv_tex, uv_smp), v_uv).rg;
    y = y * fs.range.x + fs.range.y;
    uv = uv * fs.range.z + fs.range.w;
    vec3 rgb = fs.cmat * vec3(y, uv.x, uv.y);
    frag_color = vec4(clamp(rgb, 0.0, 1.0), 1.0);
}
