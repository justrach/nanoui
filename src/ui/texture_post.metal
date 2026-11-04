// The colour stage (metal_texture.zig): a frame the app gave that isn't
// display BGRA, or has a LUT, made display sRGB at its own size before the
// frame samples it. Lifted verbatim from the real app's post-process pass
// (packages/media/csrc/macos/avfoundation_shared.h, kAlcPostProcessShaderSource,
// which apps/editor/src/macos/monitor_host.m runs): source modes 1 and 2
// are 8- and 10-bit two-plane Y'CbCr, 3 linear half floats; then the
// source LUT and the output LUT. color.zig computes the same on the CPU.
// Its own `#include` and `using` lines are the ones shader.metal has. One
// change: a 10-bit code sits in the top of a 16-bit word, so R16Unorm reads
// code * 64 / 65535, a thousandth under code / 1023 (white, 940, short of
// 1.0; enough to move a PQ highlight two 8-bit steps): it is scaled back by
// 65535 / 65472 first, as color_pipeline.zig's reference reads the code.
vertex float4 alc_post_vs(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    return float4(p * 2.0 - 1.0, 0.0, 1.0);
}
struct PostUniforms { float4 domainMin; float4 domainMax; float4 sourceDomainMin; float4 sourceDomainMax; float lutSize; uint lutEnabled; float sourceLutSize; uint sourceLutEnabled; uint sourceMode; uint rangeMode; uint matrixMode; uint transferMode; uint hdrToneMap; };
float3 alc_apply_cube(float3 rgb, float3 domainMin, float3 domainMax, float lutSize, texture3d<float> lut, sampler lutSampler) {
    float3 normalized = clamp((rgb - domainMin) / max(domainMax - domainMin, float3(1e-6)), 0.0, 1.0);
    float scale = (lutSize - 1.0) / lutSize;
    float offset = 0.5 / lutSize;
    return lut.sample(lutSampler, normalized * scale + offset).rgb;
}
float3 alc_rec709_to_linear(float3 v) { return select(pow((v + 0.099) / 1.099, float3(1.0 / 0.45)), v / 4.5, v < 0.081); }
float3 alc_srgb_to_linear(float3 v) { return select(pow((v + 0.055) / 1.055, float3(2.4)), v / 12.92, v <= 0.04045); }
float3 alc_linear_to_srgb(float3 v) { v = max(v, 0.0); return select(1.055 * pow(v, float3(1.0 / 2.4)) - 0.055, 12.92 * v, v <= 0.0031308); }
float3 alc_pq_to_linear(float3 v) { const float m1=2610.0/16384.0,m2=2523.0/32.0,c1=3424.0/4096.0,c2=2413.0/128.0,c3=2392.0/128.0; float3 p=pow(max(v,0.0),float3(1.0/m2)); return pow(max((p-c1)/(c2-c3*p),0.0),float3(1.0/m1)); }
float3 alc_hlg_to_linear(float3 v) { return select((exp((v-0.55991073)/0.17883277)+0.28466892)/12.0, v*v/3.0, v <= 0.5); }
float3 alc_hdr_to_sdr(float3 linear, uint transferMode, uint toneMap) { float peak=transferMode==3u?10000.0:1000.0; float3 nits=linear*peak; if(toneMap==0u) return clamp(nits/100.0,0.0,1.0); float l=max(dot(nits,float3(0.2627,0.6780,0.0593)),0.0); if(l<=0.000001) return float3(0.0); float mapped=l/(l+100.0); return clamp(nits*(mapped/l),0.0,1.0); }
float3 alc_ycbcr_to_rgb(float y, float2 cbcr, constant PostUniforms& u) {
    float codeMax=u.sourceMode==2u?1023.0:255.0; float yMin=u.sourceMode==2u?64.0:16.0; float yRange=u.sourceMode==2u?876.0:219.0; float cMid=u.sourceMode==2u?512.0:128.0; float cRange=u.sourceMode==2u?896.0:224.0;
    float Y = u.rangeMode == 0u ? (y - yMin / codeMax) * (codeMax / yRange) : y;
    float2 C = u.rangeMode == 0u ? (cbcr - cMid / codeMax) * (codeMax / cRange) : cbcr - 0.5;
    float3 rgb;
    if (u.matrixMode == 1u) rgb = float3(Y + 1.402 * C.y, Y - 0.344136 * C.x - 0.714136 * C.y, Y + 1.772 * C.x);
    else if (u.matrixMode == 2u) rgb = float3(Y + 1.4746 * C.y, Y - 0.164553 * C.x - 0.571353 * C.y, Y + 1.8814 * C.x);
    else rgb = float3(Y + 1.5748 * C.y, Y - 0.187324 * C.x - 0.468124 * C.y, Y + 1.8556 * C.x);
    return clamp(rgb, 0.0, 1.0);
}
fragment float4 alc_post_fs(float4 pos [[position]], constant PostUniforms& u [[buffer(0)]], texture2d<float> source0 [[texture(0)]], texture2d<float> source1 [[texture(1)]], texture3d<float> lut [[texture(2)]], texture3d<float> sourceLut [[texture(3)]], sampler lutSampler [[sampler(0)]]) {
    constexpr sampler s(coord::normalized, filter::nearest, address::clamp_to_edge);
    constexpr sampler chromaSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    float2 size = float2(source0.get_width(), source0.get_height()); float2 uv = pos.xy / max(size, float2(1.0));
    float4 color = source0.sample(s, uv);
    if (u.sourceMode == 1u || u.sourceMode == 2u) {
        float ten = u.sourceMode == 2u ? 65535.0 / 65472.0 : 1.0;
        float3 encoded = alc_ycbcr_to_rgb(color.r * ten, source1.sample(chromaSampler, uv).rg * ten, u);
        float3 linear = u.transferMode == 1u ? alc_srgb_to_linear(encoded) : (u.transferMode == 2u ? encoded : (u.transferMode == 3u ? alc_pq_to_linear(encoded) : (u.transferMode == 4u ? alc_hlg_to_linear(encoded) : alc_rec709_to_linear(encoded))));
        if (u.transferMode == 3u || u.transferMode == 4u) linear = alc_hdr_to_sdr(linear, u.transferMode, u.hdrToneMap);
        color = float4(alc_linear_to_srgb(linear), 1.0);
    }
    if (u.sourceMode == 3u) {
        float3 lin = max(color.rgb, 0.0);
        if (u.hdrToneMap == 1u) lin = lin / (1.0 + lin);
        color = float4(alc_linear_to_srgb(clamp(lin, 0.0, 1.0)), 1.0);
    }
    if (u.sourceLutEnabled == 1u) color = float4(alc_apply_cube(color.rgb, u.sourceDomainMin.rgb, u.sourceDomainMax.rgb, u.sourceLutSize, sourceLut, lutSampler), color.a);
    if (u.lutEnabled == 0u) return color;
    return float4(alc_apply_cube(color.rgb, u.domainMin.rgb, u.domainMax.rgb, u.lutSize, lut, lutSampler), color.a);
}
