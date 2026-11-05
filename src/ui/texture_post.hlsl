// The colour stage on Direct3D 11 (d3d11_video.zig): texture_post.metal in
// HLSL, line for line. An app's ID3D11Texture2D that isn't display BGRA, or
// has a LUT, is made display sRGB at its own size before the frame samples
// it: source modes 1 and 2 are 8- and 10-bit two-plane Y'CbCr (an NV12 or
// P010 texture's luma and chroma views), 3 linear half floats; then the
// source LUT and the output LUT. color.zig computes the same on the CPU.
cbuffer PostUniforms : register(b0) {
    float4 domainMin;
    float4 domainMax;
    float4 sourceDomainMin;
    float4 sourceDomainMax;
    float lutSize;
    uint lutEnabled;
    float sourceLutSize;
    uint sourceLutEnabled;
    uint sourceMode;
    uint rangeMode;
    uint matrixMode;
    uint transferMode;
    uint hdrToneMap;
};

Texture2D<float4> source0 : register(t0);
Texture2D<float4> source1 : register(t1);
Texture3D<float4> lut : register(t2);
Texture3D<float4> sourceLut : register(t3);
SamplerState s_point : register(s0);
SamplerState s_linear : register(s1);
SamplerState s_lut : register(s2);

float4 alc_post_vs(uint vid : SV_VertexID) : SV_Position {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    return float4(p * 2.0 - 1.0, 0.0, 1.0);
}

float3 apply_cube_lut(float3 rgb, float3 dmin, float3 dmax, float size) {
    float3 n = saturate((rgb - dmin) / max(dmax - dmin, float3(1e-6, 1e-6, 1e-6)));
    float scale = (size - 1.0) / size;
    float offset = 0.5 / size;
    return lut.SampleLevel(s_lut, n * scale + offset, 0).rgb;
}

float3 apply_cube_source(float3 rgb, float3 dmin, float3 dmax, float size) {
    float3 n = saturate((rgb - dmin) / max(dmax - dmin, float3(1e-6, 1e-6, 1e-6)));
    float scale = (size - 1.0) / size;
    float offset = 0.5 / size;
    return sourceLut.SampleLevel(s_lut, n * scale + offset, 0).rgb;
}

float3 rec709_to_linear(float3 v) { return v < 0.081 ? v / 4.5 : pow(abs((v + 0.099) / 1.099), 1.0 / 0.45); }
float3 srgb_to_linear(float3 v) { return v <= 0.04045 ? v / 12.92 : pow(abs((v + 0.055) / 1.055), 2.4); }
float3 linear_to_srgb(float3 v) { v = max(v, 0.0); return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055; }
float3 pq_to_linear(float3 v) {
    const float m1 = 2610.0 / 16384.0, m2 = 2523.0 / 32.0, c1 = 3424.0 / 4096.0, c2 = 2413.0 / 128.0, c3 = 2392.0 / 128.0;
    float3 p = pow(max(v, 0.0), 1.0 / m2);
    return pow(max((p - c1) / (c2 - c3 * p), 0.0), 1.0 / m1);
}
float3 hlg_to_linear(float3 v) { return v <= 0.5 ? v * v / 3.0 : (exp((v - 0.55991073) / 0.17883277) + 0.28466892) / 12.0; }
float3 hdr_to_sdr(float3 lin, uint mode, uint toneMap) {
    float peak = mode == 3u ? 10000.0 : 1000.0;
    float3 nits = lin * peak;
    if (toneMap == 0u) return saturate(nits / 100.0);
    float l = max(dot(nits, float3(0.2627, 0.6780, 0.0593)), 0.0);
    if (l <= 0.000001) return float3(0.0, 0.0, 0.0);
    float mapped = l / (l + 100.0);
    return saturate(nits * (mapped / l));
}

float3 ycbcr_to_rgb(float y, float2 cbcr) {
    float codeMax = sourceMode == 2u ? 1023.0 : 255.0;
    float yMin = sourceMode == 2u ? 64.0 : 16.0;
    float yRange = sourceMode == 2u ? 876.0 : 219.0;
    float cMid = sourceMode == 2u ? 512.0 : 128.0;
    float cRange = sourceMode == 2u ? 896.0 : 224.0;
    float Y = rangeMode == 0u ? (y - yMin / codeMax) * (codeMax / yRange) : y;
    float2 C = rangeMode == 0u ? (cbcr - cMid / codeMax) * (codeMax / cRange) : cbcr - 0.5;
    float3 rgb;
    if (matrixMode == 1u) rgb = float3(Y + 1.402 * C.y, Y - 0.344136 * C.x - 0.714136 * C.y, Y + 1.772 * C.x);
    else if (matrixMode == 2u) rgb = float3(Y + 1.4746 * C.y, Y - 0.164553 * C.x - 0.571353 * C.y, Y + 1.8814 * C.x);
    else rgb = float3(Y + 1.5748 * C.y, Y - 0.187324 * C.x - 0.468124 * C.y, Y + 1.8556 * C.x);
    return saturate(rgb);
}

float4 alc_post_ps(float4 pos : SV_Position) : SV_Target {
    uint w, h;
    source0.GetDimensions(w, h);
    float2 uv = pos.xy / max(float2(w, h), float2(1.0, 1.0));
    float4 color = source0.SampleLevel(s_point, uv, 0);
    if (sourceMode == 1u || sourceMode == 2u) {
        // A 10-bit code sits in the top of a 16-bit word (P010).
        float ten = sourceMode == 2u ? 65535.0 / 65472.0 : 1.0;
        float3 encoded = ycbcr_to_rgb(color.r * ten, source1.SampleLevel(s_linear, uv, 0).rg * ten);
        float3 lin = transferMode == 1u ? srgb_to_linear(encoded) : (transferMode == 2u ? encoded : (transferMode == 3u ? pq_to_linear(encoded) : (transferMode == 4u ? hlg_to_linear(encoded) : rec709_to_linear(encoded))));
        if (transferMode == 3u || transferMode == 4u) lin = hdr_to_sdr(lin, transferMode, hdrToneMap);
        color = float4(linear_to_srgb(lin), 1.0);
    }
    if (sourceMode == 3u) {
        float3 l3 = max(color.rgb, 0.0);
        if (hdrToneMap == 1u) l3 = l3 / (1.0 + l3);
        color = float4(linear_to_srgb(saturate(l3)), 1.0);
    }
    if (sourceLutEnabled == 1u) color = float4(apply_cube_source(color.rgb, sourceDomainMin.rgb, sourceDomainMax.rgb, sourceLutSize), color.a);
    if (lutEnabled == 0u) return color;
    return float4(apply_cube_lut(color.rgb, domainMin.rgb, domainMax.rgb, lutSize), color.a);
}
