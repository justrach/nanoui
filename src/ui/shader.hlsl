// shader.glsl in HLSL, Shader Model 5.0, for the Direct3D 11 renderer
// (src/ui/d3d11.zig). This file and src/ui/shader.glsl are one shader in two
// languages: change one and change the other. D3DCompile picks one stage from
// `entry` (quad_vs, quad_ps, glass_ps, pass_vs, down_ps, blur_ps) with
// `target` (vs_5_0 or ps_5_0); there are no defines, so each compile sees the
// whole source and drops what its stage cannot reach.
//
// D3D's differences, none of them in the math: the instances come from a
// StructuredBuffer at t0 (gpu.zig's Instance, 160 bytes) rather than vertex
// attributes, so there is no input layout; there is no gl_VertexID, so
// SV_VertexID and SV_InstanceID are passed into the vertex shader; `flat` is
// `nointerpolation`, texelFetch is Load, mix is lerp, fract is frac, mod is
// fmod, atan's two arguments keep their order, and the GL_ES bgra swap has no
// counterpart (D3D takes BGRA natively).
//
// The frame here is top down, as in Metal: D3D's render target has row 0 at
// the top, where GL's framebuffer has it at the bottom. So down_ps reads the
// frame's rows unflipped where shader.glsl flips them with
// `frame_height - 1 - y`; every other line is the same.

// The one constant buffer every stage shares (`d3d11.zig`'s `Params`), packed
// so that no member straddles a 16-byte boundary.
cbuffer Params : register(b0) {
    float2 viewport;     // 0   the target in points
    float  scale;        // 8   the frame's pixels a point
    float  down;         // 12  down: the averaging of its squares
    float2 origin;       // 16  glass: the area's corner in frame pixels
    float2 size;         // 24  glass, down and blur: the backdrop's texels
    int4   area;         // 32  down: x0, y0, x1, y1 in frame pixels
    int    frame_height; // 48  the frame's rows
    int    radius;       // 52  blur: the radius in texels
    float  sigma;        // 56  blur: the sigma in texels
    float  pad0;         // 60  (d3d11.zig's `pane`)
    int2   dir;          // 64  blur: (1, 0) or (0, 1)
    int    start_instance; // 72  the first instance of this draw
    float  rgb_text;     // 76  0: grayscale reverse proof; 1: native RGB
    float4 text_gamma;   // 80  DirectWrite's coverage correction
    float  text_contrast; // 96
    float  gray_contrast; // 100
    float2 pad2;         // 104
};                       // 112 bytes

// One quad, byte-identical to shader.metal's `Instance` and to gpu.zig's.
struct Instance {
    float4 rect;         // x, y, w, h in points
    float4 color;        // straight alpha
    float4 border_color;
    float4 uv;           // atlas u0, v0, u1, v1
    float4 clip;         // x0, y0, x1, y1
    float  radius;
    float  border_width; // blur radius for shadows
    float  kind;
    float  clip_round;   // corners * 4096 + radius (gpu.zig's clipRound)
    // These are declared to keep the stride at 192 bytes, which is what
    // gpu.zig's `Instance` is. Without them the structured buffer steps 96 bytes
    // per element and every instance after the first reads another's fields --
    // which showed up as the D3D11/CPU parity tests failing, not as an obvious
    // misdraw. Motion is animated on the CPU and arrives already baked into
    // `rect`, `color` and `uv`; of these only the faces (`vel.zw`) and the
    // turn are read here, as shader.glsl reads them.
    float4 xf;           // angle0 rad, spin rad/s, pivot x, pivot y
    float4 pulse;        // period s, scale_amp, alpha_low, unused
    float4 vel;          // blur vector x, y in points, face, mirror x
    float4 turn;         // angle about the vertical axis, eye distance, pivot x, pivot y
    float4 m;            // a plane transform: x' = m.x x + m.z y + mt.x, y' = m.y x + m.w y + mt.y
    float4 mt;
};

StructuredBuffer<Instance> instances : register(t0);
Texture2D<float4> atlas : register(t1);
Texture2D<float4> images : register(t2);
Texture2D<float4> native_atlas : register(t4);
// The texture the app gave this frame (`ui.texture`, kind 8): one slot's,
// bound by d3d11.zig for that instance's draw alone, as shader.metal's
// `frame` is. Sampled as pictures are (linear, clamped).
Texture2D<float4> frame_tex : register(t5);
SamplerState sampler_atlas : register(s1);
SamplerState sampler_images : register(s2);

// The vertex shader's outputs and the fragment shader's inputs; the flat ones
// carry the instance's fields, as GLSL's `flat out` do.
struct Varyings {
    float4 pos : SV_Position;
    float2 v_local : TEXCOORD0;
    float2 v_world : TEXCOORD1;
    float2 v_uv : TEXCOORD2;
    float2 v_screen : TEXCOORD9;
    nointerpolation float4 i_rect : TEXCOORD3;
    nointerpolation float4 i_color : TEXCOORD4;
    nointerpolation float4 i_border_color : TEXCOORD5;
    nointerpolation float4 i_uv : TEXCOORD6;
    nointerpolation float4 i_clip : TEXCOORD7;
    nointerpolation float4 i_misc : TEXCOORD8;
};

// Target 1 is the destination's per-channel inverse blend factor. Ordinary
// premultiplied drawing repeats alpha; ClearType supplies its RGB coverage.
struct Pixel {
    float4 color : SV_Target0;
    float4 coverage : SV_Target1;
};

Pixel scalar_pixel(float4 c) {
    Pixel o;
    o.color = c;
    o.coverage = float4(c.aaa, c.a);
    return o;
}

Varyings quad_vs(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    // DrawInstanced's StartInstanceLocation only offsets vertex-buffer reads:
    // the instance comes from a structured buffer here, so the first instance
    // of this draw is added by hand.
    Instance a = instances[iid + (uint)start_instance];
    float2 corner = float2(float(vid & 1), float(vid >> 1));
    // Shadows reach three standard deviations past their box.
    float grow = (a.kind == 2.0 || a.kind == 5.0) ? a.border_width * 3.0 : 0.0;
    float2 p = a.rect.xy - grow + corner * (a.rect.zw + 2.0 * grow);
    if (a.kind == 6.0) {
        // A box along the line, a point past its round ends.
        float2 s = a.uv.xy, e = a.uv.zw;
        float len = length(e - s);
        float2 u = len > 0.0 ? (e - s) / len : float2(1.0, 0.0);
        float2 n = float2(-u.y, u.x);
        float w = a.border_width * 0.5 + 1.0;
        p = lerp(s - u * w, e + u * w, corner.x) + n * (corner.y * 2.0 - 1.0) * w;
    } else if (a.kind == 7.0) {
        // The triangle itself: its third corner twice.
        p = vid == 0 ? a.uv.xy : (vid == 1 ? a.uv.zw : a.border_color.xy);
    }
    float2 local = p - a.rect.xy;
    // The reverse of a card is seen through it: mirrored across its middle.
    if (a.vel.z == 2.0 && a.kind != 6.0 && a.kind != 7.0) p.x = 2.0 * a.vel.w - p.x;
    // A box turned about its pivot (`xf`: the angle, the pivot's x, y), as
    // shader.metal turns it; the spin (`xf.y`) is the CPU's, as raster.zig
    // reads only the angle. The box's own coordinates stay unturned.
    bool mapped = a.kind == 8.0 && any(a.border_color != float4(0.0, 0.0, 0.0, 0.0));
    if ((a.xf.x != 0.0 || mapped) && a.kind != 6.0 && a.kind != 7.0) {
        float2 d = p - a.xf.zw;
        float ca = cos(a.xf.x), sa = sin(a.xf.x);
        d = float2(ca * d.x - sa * d.y, sa * d.x + ca * d.y);
        // A texture's linear map (`gpu.affine`), after its turn.
        if (mapped) d = float2(a.border_color.x * d.x + a.border_color.y * d.y, a.border_color.z * d.x + a.border_color.w * d.y);
        p = a.xf.zw + d;
    }
    // A turn about the vertical axis through the pivot, in perspective.
    float2 landed = float2(a.m.x * p.x + a.m.z * p.y + a.mt.x, a.m.y * p.x + a.m.w * p.y + a.mt.y);
    float2 seen = landed;
    float w = 1.0;
    float ct = cos(a.turn.x);
    bool hidden = (a.vel.z == 1.0 && ct < 0.0) || (a.vel.z == 2.0 && ct >= 0.0);
    if (a.turn.x != 0.0) {
        float dx = landed.x - a.turn.z;
        float z = -dx * sin(a.turn.x);
        seen = float2(a.turn.z + dx * ct, landed.y);
        if (a.turn.y > 0.0) {
            w = max(1.0 - z / a.turn.y, 0.1);
            seen = a.turn.zw + (seen - a.turn.zw) / w;
        }
    }
    Varyings o;
    o.pos = hidden ? float4(0.0, 0.0, 0.0, 1.0) : float4((seen / viewport * float2(2.0, -2.0) + float2(-1.0, 1.0)) * w, 0.0, w);
    o.v_local = local;
    o.v_world = p;
    o.v_screen = landed;
    o.v_uv = lerp(a.uv.xy, a.uv.zw, corner);
    o.i_rect = a.rect;
    o.i_color = a.color;
    o.i_border_color = a.border_color;
    o.i_uv = a.uv;
    o.i_clip = a.clip;
    o.i_misc = float4(a.radius, a.border_width, a.kind, a.clip_round);
    return o;
}

// A dashed border's coverage at `p` (from the box's centre), as GPUI lays
// dashes (see shader.metal's `dash_cover`).
float dash_cover(float2 p, float2 half_size, float r, float w) {
    const float PI = 3.14159265;
    float dv = 1.0 / (3.0 * w);
    float sx = (2.0 * half_size.x - 2.0 * r) * dv;
    float sy = (2.0 * half_size.y - 2.0 * r) * dv;
    float cq = r * PI * 0.5 * dv;
    float2 q = abs(p) - (half_size - r);
    float t;
    if (r > 0.0 && q.x > 0.0 && q.y > 0.0) {
        float2 v = p - sign(p) * (half_size - r);
        float ang = atan2(v.y, v.x);
        if (p.x >= 0.0 && p.y < 0.0) t = sx + (ang + PI * 0.5) * r * dv;
        else if (p.x >= 0.0) t = sx + cq + sy + ang * r * dv;
        else if (p.y >= 0.0) t = 2.0 * sx + 2.0 * cq + sy + (ang - PI * 0.5) * r * dv;
        else t = 2.0 * sx + 3.0 * cq + 2.0 * sy + (ang + PI) * r * dv;
    } else if ((half_size.y - abs(p.y)) < (half_size.x - abs(p.x))) {
        t = p.y < 0.0 ? (p.x + half_size.x - r) * dv : sx + 2.0 * cq + sy + (half_size.x - r - p.x) * dv;
    } else {
        t = p.x > 0.0 ? sx + cq + (p.y + half_size.y - r) * dv : 2.0 * sx + 3.0 * cq + sy + (half_size.y - r - p.y) * dv;
    }
    float max_t = 2.0 * (sx + sy) + 4.0 * cq;
    if (max_t < 1.0) return 1.0;
    float period = max_t / floor(max_t);
    float len = 2.0 / 3.0;
    float u = t + period * 0.5 - len * 0.5;
    float centered = u - period * floor(u / period) - period * 0.5;
    float sd = (abs(centered) - len * 0.5) / dv;
    float px = max(fwidth(p.x), 0.0001);
    return clamp(0.5 - sd / px, 0.0, 1.0);
}

float rounded_box(float2 p, float2 half_size, float r) {
    float2 q = abs(p) - half_size + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// The distance to a rounded box, and half a pixel's worth of it: what Metal
// takes from fwidth, exactly, as raster.zig computes it. GPUs whose
// derivatives are coarse (dFdx from one row of a 2x2 block, dFdy from one
// column) would make it twice that at a box's corners. Deliberately no
// ddx/ddy here: D3D's are as coarse as GL's.
float2 rounded_box_aa(float2 p, float2 half_size, float r) {
    float2 q = abs(p) - half_size + r;
    float2 m = max(q, 0.0);
    float len = length(m);
    float d = len + min(max(q.x, q.y), 0.0) - r;
    float grad = len > 0.0 ? (m.x + m.y) / len : 1.0;
    return float2(d, max(grad / scale, 0.0001) * 0.5);
}

// How much of the fragment the instance's clip lets through: discarded
// outside it, cut in its rounded corners.
float clip_coverage(Varyings v) {
    if (v.v_screen.x < v.i_clip.x || v.v_screen.y < v.i_clip.y || v.v_screen.x > v.i_clip.z || v.v_screen.y > v.i_clip.w) discard;
    float clip_cover = 1.0;
    float clip_round = v.i_misc.w;
    if (clip_round > 0.0) {
        float corners = floor(clip_round / 4096.0);
        float rad = clip_round - corners * 4096.0;
        float2 ch = (v.i_clip.zw - v.i_clip.xy) * 0.5;
        float2 q = v.v_screen - v.i_clip.xy - ch;
        float2 cd = rounded_box_aa(q, ch, min(rad, min(ch.x, ch.y)));
        uint bit = q.y < 0.0 ? (q.x < 0.0 ? 1u : 2u) : (q.x < 0.0 ? 8u : 4u);
        if ((uint(corners) & bit) != 0u) clip_cover = 1.0 - smoothstep(-cd.y, cd.y, cd.x);
        if (clip_cover <= 0.0) discard;
    }
    return clip_cover;
}

// Shadows as GPUI draws them (after Evan Wallace's "fast rounded rectangle
// shadows"): the box's coverage blurred by a Gaussian, exact along x with
// erf, sampled four times along y.
float gaussian(float x, float sigma) {
    return exp(-(x * x) / (2.0 * sigma * sigma)) / (sqrt(2.0 * 3.14159265358979) * sigma);
}

float2 erf2(float2 x) {
    float2 s = sign(x), a = abs(x);
    x = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
    x *= x;
    return s - s / (x * x);
}

float blur_along_x(float x, float y, float sigma, float corner, float2 half_size) {
    float delta = min(half_size.y - corner - abs(y), 0.0);
    float curved = half_size.x - corner + sqrt(max(0.0, corner * corner - delta * delta));
    float2 integral = 0.5 + 0.5 * erf2((x + float2(-curved, curved)) * (sqrt(0.5) / sigma));
    return integral.y - integral.x;
}

float shadow_alpha(float2 p, float2 half_size, float corner, float sigma) {
    float low = p.y - half_size.y;
    float high = p.y + half_size.y;
    float start = clamp(-3.0 * sigma, low, high);
    float end = clamp(3.0 * sigma, low, high);
    float step = (end - start) / 4.0;
    float y = start + step * 0.5;
    float alpha = 0.0;
    for (int k = 0; k < 4; k++) {
        alpha += blur_along_x(p.x, p.y - y, sigma, corner, half_size) * gaussian(y, sigma) * step;
        y += step;
    }
    return alpha;
}

// A line, as shader.metal's line_color, smoothed by its exact gradient.
float4 line_color(Varyings v) {
    float2 a = v.i_uv.xy, ab = v.i_uv.zw - v.i_uv.xy;
    float len2 = dot(ab, ab);
    float t = len2 > 0.0 ? clamp(dot(v.v_world - a, ab) / len2, 0.0, 1.0) : 0.0;
    float2 off = v.v_world - (a + ab * t);
    float d = length(off);
    float grad = d > 0.0 ? (abs(off.x) + abs(off.y)) / d : 1.0;
    float aa = max(grad / scale, 0.0001) * 0.5;
    float hw = v.i_misc.y * 0.5;
    float cover = 1.0 - smoothstep(hw - aa, hw + aa, d);
    float on = v.i_border_color.x, gap = v.i_border_color.y;
    if (on > 0.0 && gap > 0.0) {
        float len = sqrt(len2);
        // Along the line unclamped: its ends are cut square, as its dashes.
        float along = (len > 0.0 ? dot(v.v_world - a, ab) / len : 0.0) + v.i_border_color.z;
        float m = along - (on + gap) * floor(along / (on + gap));
        float e = min(m, on - m);
        float ug = len > 0.0 ? (abs(ab.x) + abs(ab.y)) / len : 0.0;
        float ea = max(ug / scale, 0.0001) * 0.5;
        cover *= smoothstep(-ea, ea, e);
    }
    float alpha = v.i_color.a * cover;
    return float4(v.i_color.rgb * alpha, alpha);
}

// A triangle, as shader.metal's triangle_color.
float4 triangle_color(Varyings v) {
    float2 tri[3] = { v.i_uv.xy, v.i_uv.zw, v.i_border_color.xy };
    float area2 = (tri[1].x - tri[0].x) * (tri[2].y - tri[0].y) - (tri[1].y - tri[0].y) * (tri[2].x - tri[0].x);
    float side = area2 < 0.0 ? -1.0 : 1.0;
    uint edges = uint(v.i_border_color.z);
    float cover = 1.0;
    for (int k = 0; k < 3; k++) {
        if ((edges & (1u << uint(k))) == 0u) continue;
        // `(k + 1) % 3`, spelled out: fxc warns about the integer modulus.
        float2 p = tri[k], q = tri[k == 2 ? 0 : k + 1];
        float2 e = q - p;
        float len = max(length(e), 0.0001);
        float d = side * (e.x * (v.v_world.y - p.y) - e.y * (v.v_world.x - p.x)) / len;
        float aa = max((abs(e.x) + abs(e.y)) / len / scale, 0.0001) * 0.5;
        cover *= smoothstep(-aa, aa, d);
    }
    float alpha = v.i_color.a * cover;
    return float4(v.i_color.rgb * alpha, alpha);
}

float text_coverage(float a, float intensity, float lightness, bool subpixel) {
    float k = (subpixel ? text_contrast : gray_contrast) * clamp(3.0 - 4.0 * lightness, 0.0, 1.0);
    float v = a * (k + 1.0) / (a * k + 1.0);
    float correction = (text_gamma[0] * intensity + text_gamma[1]) * v + text_gamma[2] * intensity + text_gamma[3];
    return clamp(v + v * (1.0 - v) * correction, 0.0, 1.0);
}

Pixel glyph_pixel(Varyings v, float clip_cover) {
    float opacity = v.i_color.a * clip_cover;
    // A truncated line fading out: `border_width` points before `radius`.
    if (v.i_misc.y > 0.0) opacity *= clamp((v.i_misc.x - v.v_world.x) / v.i_misc.y, 0.0, 1.0);
    float gray = atlas.SampleLevel(sampler_atlas, v.v_uv, 0).r;
    uint2 side;
    atlas.GetDimensions(side.x, side.y);
    // Both sizes are physical pixels: rect is points, while the uv span is
    // the whole atlas sprite, padding included. At 2x DPI a one-texel sprite
    // is 0.5 points wide, not one point. scaleItems bakes animation scale
    // into rect, so only an unscaled quad may use per-channel coverage.
    float2 screen_pixels = v.i_rect.zw * scale;
    float2 atlas_texels = (v.i_uv.zw - v.i_uv.xy) * float2(side);
    bool one_to_one = all(abs(screen_pixels - atlas_texels) < float2(0.001, 0.001));
    if (rgb_text > 0.5 && one_to_one) {
        // Native glyphs are nearest-sampled, as raster.zig does. The RGB
        // texel's alpha is a tag: 1 ClearType, 128/255 native grayscale.
        int2 at = clamp(int2(v.v_uv * float2(side)), int2(0, 0), int2(side) - 1);
        float4 native = native_atlas.Load(int3(at, 0));
        float lightness = 0.30 * v.i_color.r + 0.59 * v.i_color.g + 0.11 * v.i_color.b;
        if (native.a > 0.75) {
            float3 coverage = float3(
                text_coverage(native.r, v.i_color.r, lightness, true),
                text_coverage(native.g, v.i_color.g, lightness, true),
                text_coverage(native.b, v.i_color.b, lightness, true)) * opacity;
            Pixel o;
            o.color = float4(v.i_color.rgb * coverage, dot(coverage, float3(1.0, 1.0, 1.0)) / 3.0);
            o.coverage = float4(coverage, o.color.a);
            return o;
        }
        if (native.a > 0.0) {
            float intensity = 0.25 * v.i_color.r + 0.5 * v.i_color.g + 0.25 * v.i_color.b;
            float a = text_coverage(gray, intensity, lightness, false) * opacity;
            return scalar_pixel(float4(v.i_color.rgb * a, a));
        }
    }
    float a = gray * opacity;
    return scalar_pixel(float4(v.i_color.rgb * a, a));
}

float4 shade(Varyings v) {
    float kind = v.i_misc.z;
    // A line and a triangle are drawn by their own geometry. One variable and
    // one return rather than the GLSL's two early returns: fxc's inliner calls
    // an early return of an inlined call "potentially uninitialized" (X4000),
    // which is only noise. Otherwise this is shader.glsl's `shade` exactly.
    float4 shape = float4(0.0, 0.0, 0.0, 0.0);
    if (kind == 6.0) shape = line_color(v);
    if (kind == 7.0) shape = triangle_color(v);
    if (kind == 6.0 || kind == 7.0) return shape;
    float2 half_size = v.i_rect.zw * 0.5;
    float2 p = v.v_local - half_size;
    float r = min(v.i_misc.x, min(half_size.x, half_size.y));
    float2 da = rounded_box_aa(p, half_size, r);
    float d = da.x;
    float aa = da.y;
    float coverage = 1.0 - smoothstep(-aa, aa, d);
    if (kind == 3.0) {
        // Premultiplied already: scaled by the corners' coverage and opacity.
        float4 px = images.SampleLevel(sampler_images, v.v_uv, 0);
        // Tinted: the picture's shape in one color (a mark following the theme).
        if (v.i_border_color.a > 0.0) {
            float a = px.a * v.i_border_color.a * coverage * v.i_color.a;
            return float4(v.i_border_color.rgb * a, a);
        }
        return px * (coverage * v.i_color.a);
    }
    if (kind == 8.0) {
        // An app's texture: its corners rounded as a picture's, its opacity.
        float4 tx = frame_tex.SampleLevel(sampler_images, v.v_uv, 0);
        return tx * (coverage * v.i_color.a);
    }
    if (kind == 2.0 || kind == 5.0) {
        float sigma = max(v.i_misc.y, 0.25);
        float a = shadow_alpha(p, half_size, r, sigma) * v.i_color.a;
        // Knocked out inside the box itself (see shader.metal).
        if (kind == 5.0) a *= clamp(rounded_box_aa(p - v.i_uv.xy, max(half_size - v.i_uv.z, float2(0.0, 0.0)), max(abs(r) - v.i_uv.z, 0.0)).x + 0.5, 0.0, 1.0);
        return float4(v.i_color.rgb * a, a);
    }
    // Premultiplied: the border is laid over the fill (see shader.metal).
    float4 fill = v.i_color;
    if (v.i_uv.y > 0.5 && v.i_uv.y < 1.5) {
        float gr = floor(v.i_uv.z / 256.0), gb = floor(v.i_uv.w / 256.0);
        float4 bottom = float4(gr, v.i_uv.z - gr * 256.0, gb, v.i_uv.w - gb * 256.0) / 255.0;
        fill = lerp(fill, bottom, saturate(v.v_local.y / max(v.i_rect.w, 1e-4)));
    }
    float4 c = float4(fill.rgb * fill.a, fill.a);
    float bw = v.i_misc.y;
    if (bw > 0.0 && v.i_border_color.a > 0.0) {
        float inner = smoothstep(-bw - aa, -bw + aa, d);
        float4 b = float4(v.i_border_color.rgb * v.i_border_color.a, v.i_border_color.a);
        if (v.i_uv.x > 0.5) b *= dash_cover(p, half_size, r, bw);
        c = lerp(c, b + c * (1.0 - b.a), inner);
    }
    return c * coverage;
}

Pixel quad_ps(Varyings v) {
    float clip_cover = clip_coverage(v);
    if (v.i_misc.z == 1.0) return glyph_pixel(v, clip_cover);
    return scalar_pixel(shade(v) * clip_cover);
}

// A pane of glass reads the backdrop d3d11.zig averaged and blurred for it:
// its area's corner `origin`, its size in texels `size`, the averaging
// `down`, and the frame's pixels a point `scale`.
Texture2D<float4> backdrop : register(t3);
SamplerState sampler_backdrop : register(s3);

float3 glass_texel(int2 p) {
    return backdrop.Load(int3(clamp(p, int2(0.0, 0.0), int2(size) - 1), 0)).rgb;
}

// The backdrop at pixel q of the frame, bilinear from its texels.
float3 glass_sample(float2 q) {
    float2 u = (q - origin) / down - 0.5;
    float2 f = floor(u);
    float2 w = u - f;
    int2 p = int2(f);
    float3 top = glass_texel(p) * (1.0 - w.x) + glass_texel(p + int2(1, 0)) * w.x;
    float3 bot = glass_texel(p + int2(0, 1)) * (1.0 - w.x) + glass_texel(p + int2(1, 1)) * w.x;
    return top * (1.0 - w.y) + bot * w.y;
}

float glass_lens(float t, float bezel) {
    if (bezel <= 0.0 || t >= bezel) return 0.0;
    float u = 1.0 - max(t, 0.0) / bezel;
    float v = 1.0 - u * u * u * u;
    float a = sqrt(v * sqrt(v));
    float b = u * u * u;
    float n = sqrt(a * a + b * b);
    float s = b / n, c = a / n;
    float st = s / 1.5;
    float ct = sqrt(1.0 - st * st);
    return (s * ct - c * st) / (c * ct + s * st) / 1.1180340;
}

float2 glass_normal(float2 q, float2 h, float radius) {
    float r = min(radius * 1.5, min(h.x, h.y));
    float2 a = abs(q) - (h - r);
    if (a.x > 0.0 || a.y > 0.0) {
        float2 m = max(a, float2(0.0, 0.0));
        return sign(q) * m / sqrt(m.x * m.x + m.y * m.y);
    }
    return a.x > a.y ? float2(sign(q.x), 0.0) : float2(0.0, sign(q.y));
}

float3 glass_tone(float3 c, float4 tone) {
    float l = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
    float t = tone.x + (tone.y - tone.x) * (1.0 - pow(max(1.0 - l, 0.0), tone.z));
    float k = (tone.y - tone.x) * tone.w;
    return clamp(t + (c - l) * k, 0.0, 1.0);
}

Pixel glass_ps(Varyings v) {
    float clip_cover = clip_coverage(v);
    // The pane's edge, antialiased as a quad's.
    float2 hp = v.i_rect.zw * 0.5;
    float2 da = rounded_box_aa(v.v_local - hp, hp, min(v.i_misc.x, min(hp.x, hp.y)));
    float coverage = (1.0 - smoothstep(-da.y, da.y, da.x)) * clip_cover * v.i_uv.z;

    // The optics, in the frame's pixels.
    float s = scale;
    float2 p = v.v_world * s;
    float2 h = hp * s;
    float2 q = p - v.i_rect.xy * s - h;
    float rr = min(v.i_misc.x * s, min(h.x, h.y));
    float t = max(-rounded_box(q, h, rr), 0.0);
    float bezel = v.i_uv.x * s;
    float rim_width = v.i_uv.w * s;
    float2 n = float2(0.0, 0.0);
    if (t < bezel || t < 3.0 * rim_width) n = glass_normal(q, h, rr);
    float2 at = p;
    if (t < bezel) at -= n * (v.i_uv.y * s * glass_lens(t, bezel));
    float3 c = glass_tone(glass_sample(at), v.i_border_color);
    c += (v.i_color.rgb - c) * v.i_color.a;
    if (t < 3.0 * rim_width) {
        float r = t / rim_width;
        float a = 0.35 * exp(-r * r);
        // Light from above and below: the more the edge faces it, the lighter.
        c += (abs(n.y) - c) * a;
    }
    return scalar_pixel(float4(c, 1.0) * coverage);
}

// One triangle over the whole target: a pass computes each texel.
float4 pass_vs(uint vid : SV_VertexID) : SV_Position {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    return float4(p * 2.0 - 1.0, 0.0, 1.0);
}

// The frame the down and blur passes read, rebound to t0 per pass: GLSL's
// `frame` and `src` are one texture there, as here.
Texture2D<float4> source : register(t0);

// A pane's backdrop (glass.zig's Backdrop): the frame's pixels of area
// (x0, y0, x1, y1), averaged over squares of down pixels into size texels.
float4 down_ps(float4 pos : SV_Position) : SV_Target {
    int2 gid = int2(pos.xy);
    int d = int(down);
    int x0 = area.x + gid.x * d;
    int y0 = area.y + gid.y * d;
    int x1 = min(x0 + d, area.z);
    int y1 = min(y0 + d, area.w);
    float3 sum = float3(0.0, 0.0, 0.0);
    // Rows are top down here: shader.glsl reads `frame_height - 1 - y`.
    for (int y = y0; y < y1; y++)
        for (int x = x0; x < x1; x++) sum += source.Load(int3(x, y, 0)).rgb;
    return float4(sum / float((x1 - x0) * (y1 - y0)), 1.0);
}

// The backdrop blurred by sigma texels out to radius each way, along `dir`.
float4 blur_ps(float4 pos : SV_Position) : SV_Target {
    int2 gid = int2(pos.xy);
    int2 sz = int2(size);
    float3 sum = float3(0.0, 0.0, 0.0);
    float wsum = 0.0;
    for (int k = -radius; k <= radius; k++) {
        int2 p = clamp(gid + dir * k, int2(0, 0), sz - 1);
        float w = exp(-float(k * k) / (2.0 * sigma * sigma));
        sum += source.Load(int3(p, 0)).rgb * w;
        wsum += w;
    }
    return float4(sum / wsum, 1.0);
}
