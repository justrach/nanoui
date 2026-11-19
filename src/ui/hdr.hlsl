// An extended (scRGB) Direct3D 11 surface's two passes (d3d11_hdr.zig), as
// shader.metal's `fs_plane` and `fs_hdr_compose` draw them on Metal. They
// come after shader.hlsl in one source, so they use its Varyings, `shade`,
// `clip_coverage`, `frame_tex` and `pass_vs`.

// The plane: a `.surface_linear` texture's own colour, un-premultiplied and
// without its edge's coverage, wherever any of it shows. The hole cut in the
// UI for it carries the coverage and the texture's alpha.
float4 plane_ps(Varyings v) : SV_Target {
    float clip_cover = clip_coverage(v);
    if ((shade(v) * clip_cover).a <= 0.0) discard;
    float4 px = frame_tex.SampleLevel(sampler_images, v.v_uv, 0);
    return float4(px.a > 0.0 ? px.rgb / px.a : float3(0.0, 0.0, 0.0), 1.0);
}

// The compose: the UI (8-bit display sRGB, premultiplied) decoded to linear
// light and scaled to SDR white, the plane under it where it let it through:
//   out = scale * srgbEOTF(ui.rgb / ui.a) * ui.a + (1 - ui.a) * plane
cbuffer Hdr : register(b1) {
    float hdr_scale;     // scRGB's value of SDR white: SDRWhiteLevel / 1000
    float hdr_plane;     // 1: the plane holds a texture this frame
    float2 hdr_pad;
};
Texture2D<float4> hdr_ui : register(t0);
Texture2D<float4> hdr_plane_tex : register(t1);

float hdr_eotf(float c) {
    return c <= 0.04045 ? c / 12.92 : pow(abs((c + 0.055) / 1.055), 2.4);
}

float4 hdr_compose_ps(float4 pos : SV_Position) : SV_Target {
    int3 p = int3(int2(pos.xy), 0);
    float4 u = hdr_ui.Load(p);
    float3 lin = float3(0.0, 0.0, 0.0);
    if (u.a > 0.0) {
        float3 c = saturate(u.rgb / u.a);
        lin = float3(hdr_eotf(c.r), hdr_eotf(c.g), hdr_eotf(c.b)) * u.a;
    }
    float4 o = float4(hdr_scale * lin, u.a);
    if (hdr_plane > 0.5) {
        float4 pl = hdr_plane_tex.Load(p);
        o.rgb += (1.0 - u.a) * pl.rgb;
        o.a += (1.0 - u.a) * pl.a;
    }
    return o;
}
