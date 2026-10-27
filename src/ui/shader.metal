// nanoui's one shader: instanced quads that are rounded rectangles with
// borders (kind 0), glyph runs and icons sampled from the atlas (kind 1),
// shadows (kind 2): Gaussian blurs of rounded boxes, as GPUI draws them, or
// pictures sampled from the image atlas (kind 3), their corners rounded,
// and textures the app gave the frame (kind 5, a video frame), likewise;
// lines (kind 6) and filled triangles (kind 7), drawn where they are rather
// than over their bounds.
// Panes of glass (kind 4) have their own fragment function (glass.metal).
// Each is clipped to its clip rectangle, some of whose corners may be
// rounded (a box with rounded corners that clips its children).
#include <metal_stdlib>
using namespace metal;

struct Instance {
    float4 rect;         // x, y, w, h in points
    float4 color;        // straight alpha
    float4 border_color;
    float4 uv;           // atlas u0, v0, u1, v1
    float4 clip;         // x0, y0, x1, y1
    float radius;
    float border_width;  // blur radius for shadows
    float kind;
    float clip_round;    // corners * 4096 + radius (gpu.zig's clipRound)
};

struct VOut {
    float4 pos [[position]];
    float2 local;
    float2 world;
    float2 uv;
    uint inst [[flat]];
};

vertex VOut vs(uint vid [[vertex_id]], uint iid [[instance_id]],
               constant Instance *instances [[buffer(0)]],
               constant float2 &viewport [[buffer(1)]]) {
    Instance i = instances[iid];
    float2 corner = float2(vid & 1, vid >> 1);
    // Shadows reach three standard deviations past their box.
    float grow = (i.kind == 2 || i.kind == 8) ? i.border_width * 3.0 : 0.0;
    float2 p = i.rect.xy - grow + corner * (i.rect.zw + 2.0 * grow);
    if (i.kind == 6.0) {
        // A box along the line, a point past its round ends.
        float2 a = i.uv.xy, b = i.uv.zw;
        float len = length(b - a);
        float2 u = len > 0.0 ? (b - a) / len : float2(1.0, 0.0);
        float2 n = float2(-u.y, u.x);
        float e = i.border_width * 0.5 + 1.0;
        p = mix(a - u * e, b + u * e, corner.x) + n * (corner.y * 2.0 - 1.0) * e;
    } else if (i.kind == 7.0) {
        // The triangle itself: its third corner twice.
        p = vid == 0 ? i.uv.xy : (vid == 1 ? i.uv.zw : i.border_color.xy);
    }
    VOut o;
    o.pos = float4(p / viewport * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    o.local = p - i.rect.xy;
    o.world = p;
    o.uv = mix(i.uv.xy, i.uv.zw, corner);
    o.inst = iid;
    return o;
}

// Shadows as GPUI draws them (after Evan Wallace's "fast rounded rectangle
// shadows"): the box's coverage blurred by a Gaussian, exact along x with
// erf, sampled four times along y.
static float gaussian(float x, float sigma) {
    return exp(-(x * x) / (2.0 * sigma * sigma)) / (sqrt(2.0 * M_PI_F) * sigma);
}

static float2 erf2(float2 x) {
    float2 s = sign(x), a = abs(x);
    x = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
    x *= x;
    return s - s / (x * x);
}

static float blur_along_x(float x, float y, float sigma, float corner, float2 half_size) {
    float delta = min(half_size.y - corner - abs(y), 0.0);
    float curved = half_size.x - corner + sqrt(max(0.0, corner * corner - delta * delta));
    float2 integral = 0.5 + 0.5 * erf2((x + float2(-curved, curved)) * (sqrt(0.5) / sigma));
    return integral.y - integral.x;
}

static float shadow_alpha(float2 p, float2 half_size, float corner, float sigma) {
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

static float rounded_box(float2 p, float2 half_size, float r) {
    float2 q = abs(p) - half_size + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

static float4 shade(VOut in, Instance i, texture2d<float> atlas, texture2d<float> images, texture2d<float> frame);

// A dashed border's coverage at `p` (from the box's centre), as GPUI's quad
// shader lays dashes: twice the border's width long, once it apart, evenly
// round the whole perimeter clockwise from the top's start, smoothed half a
// pixel. raster.zig's `dashCover` computes the same.
static float dash_cover(float2 p, float2 half_size, float r, float w) {
    float dv = 1.0 / (3.0 * w);
    float sx = (2.0 * half_size.x - 2.0 * r) * dv;
    float sy = (2.0 * half_size.y - 2.0 * r) * dv;
    float cq = r * M_PI_F * 0.5 * dv;
    float2 q = abs(p) - (half_size - r);
    float t;
    if (r > 0.0 && q.x > 0.0 && q.y > 0.0) {
        float2 v = p - sign(p) * (half_size - r);
        float ang = atan2(v.y, v.x);
        if (p.x >= 0.0 && p.y < 0.0) t = sx + (ang + M_PI_F * 0.5) * r * dv;
        else if (p.x >= 0.0) t = sx + cq + sy + ang * r * dv;
        else if (p.y >= 0.0) t = 2.0 * sx + 2.0 * cq + sy + (ang - M_PI_F * 0.5) * r * dv;
        else t = 2.0 * sx + 3.0 * cq + 2.0 * sy + (ang + M_PI_F) * r * dv;
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
    return saturate(0.5 - sd / px);
}

// A line: round ends, half a pixel smoothed each side; its dashes cut
// square, smoothed likewise. raster.zig's `segment` computes the same.
static float4 line_color(float2 w, Instance i) {
    float2 a = i.uv.xy, ab = i.uv.zw - i.uv.xy;
    float len2 = dot(ab, ab);
    float t = len2 > 0.0 ? clamp(dot(w - a, ab) / len2, 0.0, 1.0) : 0.0;
    float d = length(w - (a + ab * t));
    float aa = max(fwidth(d), 0.0001) * 0.5;
    float cover = 1.0 - smoothstep(i.border_width * 0.5 - aa, i.border_width * 0.5 + aa, d);
    float on = i.border_color.x, off = i.border_color.y;
    if (on > 0.0 && off > 0.0) {
        // Along the line unclamped: its ends are cut square, as its dashes.
        float along = (len2 > 0.0 ? dot(w - a, ab) / sqrt(len2) : 0.0) + i.border_color.z;
        float m = along - (on + off) * floor(along / (on + off));
        float e = min(m, on - m);
        float ea = max(fwidth(along), 0.0001) * 0.5;
        cover *= smoothstep(-ea, ea, e);
    }
    float alpha = i.color.a * cover;
    return float4(i.color.rgb * alpha, alpha);
}

// A triangle: whole where the rasterizer drew it, its smoothed edges
// fading over the half pixel inside them.
static float4 triangle_color(float2 w, Instance i) {
    float2 v[3] = { i.uv.xy, i.uv.zw, i.border_color.xy };
    float area = (v[1].x - v[0].x) * (v[2].y - v[0].y) - (v[1].y - v[0].y) * (v[2].x - v[0].x);
    float side = area < 0.0 ? -1.0 : 1.0;
    uint edges = uint(i.border_color.z);
    float cover = 1.0;
    for (int k = 0; k < 3; k++) {
        if ((edges & (1u << k)) == 0u) continue;
        float2 p = v[k], q = v[(k + 1) % 3];
        float len = max(length(q - p), 0.0001);
        float d = side * ((q.x - p.x) * (w.y - p.y) - (q.y - p.y) * (w.x - p.x)) / len;
        float aa = max(fwidth(d), 0.0001) * 0.5;
        cover *= smoothstep(-aa, aa, d);
    }
    float alpha = i.color.a * cover;
    return float4(i.color.rgb * alpha, alpha);
}

// How much of the fragment the instance's clip lets through: discarded
// outside it, cut in its rounded corners.
static float clip_coverage(VOut in, Instance i) {
    if (in.world.x < i.clip.x || in.world.y < i.clip.y || in.world.x > i.clip.z || in.world.y > i.clip.w)
        discard_fragment();
    float clip_cover = 1.0;
    if (i.clip_round > 0.0) {
        float corners = floor(i.clip_round / 4096.0);
        float rad = i.clip_round - corners * 4096.0;
        float2 ch = (i.clip.zw - i.clip.xy) * 0.5;
        float2 q = in.world - i.clip.xy - ch;
        // Derivatives outside the branch on the corner: it differs by pixel.
        float cd = rounded_box(q, ch, min(rad, min(ch.x, ch.y)));
        float caa = max(fwidth(cd), 0.0001) * 0.5;
        uint bit = q.y < 0.0 ? (q.x < 0.0 ? 1u : 2u) : (q.x < 0.0 ? 8u : 4u);
        if ((uint(corners) & bit) != 0u) clip_cover = 1.0 - smoothstep(-caa, caa, cd);
        if (clip_cover <= 0.0) discard_fragment();
    }
    return clip_cover;
}

fragment float4 fs(VOut in [[stage_in]],
                   constant Instance *instances [[buffer(0)]],
                   texture2d<float> atlas [[texture(0)]],
                   texture2d<float> images [[texture(1)]],
                   texture2d<float> frame [[texture(3)]]) {
    Instance i = instances[in.inst];
    float clip_cover = clip_coverage(in, i);
    return shade(in, i, atlas, images, frame) * clip_cover;
}

static float4 shade(VOut in, Instance i, texture2d<float> atlas, texture2d<float> images, texture2d<float> frame) {
    if (i.kind == 1.0) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float a = atlas.sample(s, in.uv).r * i.color.a;
        // A truncated line fading out: `border_width` points before `radius`.
        if (i.border_width > 0.0) a *= clamp((i.radius - in.world.x) / i.border_width, 0.0, 1.0);
        return float4(i.color.rgb * a, a);
    }

    if (i.kind == 6.0) return line_color(in.world, i);
    if (i.kind == 7.0) return triangle_color(in.world, i);

    float2 half_size = i.rect.zw * 0.5;
    float2 p = in.local - half_size;
    float r = min(i.radius, min(half_size.x, half_size.y));
    float d = rounded_box(p, half_size, r);

    if (i.kind == 3.0) {
        // Premultiplied already: scaled by the corners' coverage and opacity.
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float aa = max(fwidth(d), 0.0001) * 0.5;
        float coverage = 1.0 - smoothstep(-aa, aa, d);
        float4 px = images.sample(s, in.uv);
        // Tinted: the picture's shape in one color (a mark following the theme).
        if (i.border_color.a > 0.0) {
            float a = px.a * i.border_color.a * coverage * i.color.a;
            return float4(i.border_color.rgb * a, a);
        }
        return px * (coverage * i.color.a);
    }

    if (i.kind == 5.0) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float aa = max(fwidth(d), 0.0001) * 0.5;
        float coverage = 1.0 - smoothstep(-aa, aa, d);
        return frame.sample(s, in.uv) * (coverage * i.color.a);
    }

    if (i.kind == 2.0 || i.kind == 8.0) {
        float sigma = max(i.border_width, 0.25);
        float a = shadow_alpha(p, half_size, r, sigma) * i.color.a;
        if (i.kind == 8.0) {
            float r_box = min(i.border_color.x, min(i.uv.z, i.uv.w) * 0.5);
            float d_box = rounded_box(p - i.uv.xy, i.uv.zw * 0.5, r_box);
            float aa_box = max(fwidth(d_box), 0.0001) * 0.5;
            a *= smoothstep(-aa_box, aa_box, d_box);
        }
        return float4(i.color.rgb * a, a);
    }

    float aa = max(fwidth(d), 0.0001) * 0.5;
    float coverage = 1.0 - smoothstep(-aa, aa, d);
    // Premultiplied: the border is laid over the fill, not mixed with it.
    // Mixing an opaque fill with a faint border straight made the pixels
    // between them light and nearly opaque, a bright rim round each corner.
    float4 c = float4(i.color.rgb * i.color.a, i.color.a);
    if (i.border_width > 0.0 && i.border_color.a > 0.0) {
        float inner = smoothstep(-i.border_width - aa, -i.border_width + aa, d);
        float4 b = float4(i.border_color.rgb * i.border_color.a, i.border_color.a);
        if (i.uv.x > 0.5) b *= dash_cover(p, half_size, r, i.border_width);
        c = mix(c, b + c * (1.0 - b.a), inner);
    }
    return c * coverage;
}
