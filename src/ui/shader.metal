// nanoui's one shader: instanced quads that are rounded rectangles with
// borders (kind 0), glyph runs and icons sampled from the atlas (kind 1),
// shadows (kind 2): Gaussian blurs of rounded boxes, as GPUI draws them, or
// pictures sampled from the image atlas (kind 3), their corners rounded.
// Shadows of kind 5 are drawn outside their box only (knocked out); lines
// (kind 6) and filled triangles (kind 7) are drawn where they are rather
// than over their bounds; textures the app gave the frame are kind 8.
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
    float4 xf;           // angle0 rad, spin rad/s, pivot x, pivot y
    float4 pulse;        // period s, scale_amp, alpha_low, unused
    float4 vel;          // blur vector x, y in points, face (0 both, 1 front, 2 back), mirror x
    float4 turn;         // angle about the vertical axis rad, eye distance pt (0 flat), pivot x, pivot y
};

struct VOut {
    float4 pos [[position]];
    float2 local;
    float2 world;
    float2 uv;
    float2 vel [[flat]];
    float pulse_alpha [[flat]];
    uint inst [[flat]];
};

vertex VOut vs(uint vid [[vertex_id]], uint iid [[instance_id]],
               constant Instance *instances [[buffer(0)]],
               constant float2 &viewport [[buffer(1)]],
               constant float &time [[buffer(2)]]) {
    Instance i = instances[iid];
    float2 corner = float2(vid & 1, vid >> 1);
    // Shadows reach three standard deviations past their box.
    float grow = (i.kind == 2 || i.kind == 5) ? i.border_width * 3.0 : 0.0;
    float2 v = i.vel.xy;
    float vlen = length(v);
    if (vlen > 24.0) {
        v *= 24.0 / vlen;
        vlen = 24.0;
    }
    bool has_blur = (vlen > 0.5) && (i.kind == 0.0 || i.kind == 1.0 || i.kind == 3.0);
    float2 grow2 = float2(grow) + (has_blur ? abs(v) * 0.5 : float2(0.0));
    float2 p_unrot = i.rect.xy - grow2 + corner * (i.rect.zw + 2.0 * grow2);
    float2 p = p_unrot;
    float pulse_alpha = 1.0;
    float angle = i.xf.x + i.xf.y * time;
    // The reverse of a card is seen through it: mirrored across its middle.
    if (i.vel.z == 2.0) p.x = 2.0 * i.vel.w - p.x;
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
    } else if (angle != 0.0 || i.pulse.x > 0.0) {
        float2 d = p - i.xf.zw;
        if (i.pulse.x > 0.0) {
            float s = 0.5 - 0.5 * cos(2.0 * M_PI_F * time / i.pulse.x);
            float k = 1.0 + i.pulse.y * (2.0 * s - 1.0);
            d *= k;
            pulse_alpha = mix(i.pulse.z, 1.0, s);
        }
        if (angle != 0.0) {
            float ca = cos(angle);
            float sa = sin(angle);
            d = float2(ca * d.x - sa * d.y, sa * d.x + ca * d.y);
        }
        p = i.xf.zw + d;
    }
    // A turn about the vertical axis through the pivot, seen in perspective
    // from the pivot: w carries the depth, so the rounded box, its picture
    // and its clip are interpolated perspective-correct.
    float2 seen = p;
    float w = 1.0;
    float ct = cos(i.turn.x);
    bool hidden = (i.vel.z == 1.0 && ct < 0.0) || (i.vel.z == 2.0 && ct >= 0.0);
    if (i.turn.x != 0.0) {
        float dx = p.x - i.turn.z;
        float z = -dx * sin(i.turn.x);
        seen = float2(i.turn.z + dx * ct, p.y);
        if (i.turn.y > 0.0) {
            w = max(1.0 - z / i.turn.y, 0.1);
            seen = i.turn.zw + (seen - i.turn.zw) / w;
        }
    }
    VOut o;
    // A face turned away: every corner at one point, nothing drawn.
    o.pos = hidden ? float4(0.0, 0.0, 0.0, 1.0) : float4((seen / viewport * float2(2.0, -2.0) + float2(-1.0, 1.0)) * w, 0.0, w);
    o.local = p_unrot - i.rect.xy;
    o.world = p;
    o.uv = has_blur ? (i.uv.xy + (p_unrot - i.rect.xy) / max(i.rect.zw, float2(1e-4)) * (i.uv.zw - i.uv.xy)) : mix(i.uv.xy, i.uv.zw, corner);
    o.vel = has_blur ? v : float2(0.0);
    o.pulse_alpha = pulse_alpha;
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
    float c = abs(corner);
    float low = p.y - half_size.y;
    float high = p.y + half_size.y;
    float start = clamp(-3.0 * sigma, low, high);
    float end = clamp(3.0 * sigma, low, high);
    float step = (end - start) / 8.0;
    float y = start + step * 0.5;
    float alpha = 0.0;
    for (int k = 0; k < 8; k++) {
        alpha += blur_along_x(p.x, p.y - y, sigma, c, half_size) * gaussian(y, sigma) * step;
        y += step;
    }
    return alpha;
}

static float shadow_dither(float2 pos) {
    uint x = uint(pos.x);
    uint y = uint(pos.y);
    uint h1 = (x * 1664525u + y * 1013904223u) ^ 0x68bc21ebu;
    h1 ^= h1 >> 15;
    h1 *= 0x85ebca6bu;
    h1 ^= h1 >> 13;
    uint h2 = (x * 22695477u + y * 2891336453u) ^ 0x02e5be93u;
    h2 ^= h2 >> 15;
    h2 *= 0xc2b2ae35u;
    h2 ^= h2 >> 13;
    float u1 = float(h1 & 0xffffu) / 65535.0;
    float u2 = float(h2 & 0xffffu) / 65535.0;
    return (u1 + u2 - 1.0) * (0.5 / 255.0);
}

static float rounded_box(float2 p, float2 half_size, float r) {
    float2 q = abs(p) - half_size + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

static float corner_sdf(float2 p, float2 half_size, float r_in) {
    float r = min(abs(r_in), min(half_size.x, half_size.y));
    if (r <= 0.0 || r_in < 0.0) return rounded_box(p, half_size, r);
    float dx = half_size.x - abs(p.x);
    float dy = half_size.y - abs(p.y);
    float a = min(dx, dy);
    float b_val = max(dx, dy);
    float half_long = (dy >= dx) ? half_size.y : half_size.x;
    float ext = min(1.52866495 * r, half_long);
    if (b_val >= ext) return -a;
    if (b_val >= 0.63149399 * r && a > -0.25 * r) {
        float span = max(ext - 0.63149399 * r, 1e-5);
        float u = clamp((ext - b_val) / span, 0.0, 1.0);
        float u2 = u * u;
        float u3 = u2 * u;
        const float c3 = 0.00759166, c4 = 0.06728002, c5 = 0.00003973;
        float indent = r * (c3 * u3 + c4 * u3 * u + c5 * u3 * u2);
        float slope = r * (3.0 * c3 * u2 + 4.0 * c4 * u3 + 5.0 * c5 * u2 * u2) / span;
        return (indent - a) / sqrt(1.0 + slope * slope);
    }
    float cx = 0.950248 * r;
    float cr = 0.931599 * r;
    float2 q = float2(cx - dx, cx - dy);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - cr;
}

static float4 shade(VOut in, Instance i, texture2d<float> atlas, texture2d<float> images, texture2d<float> layer_tex, texture2d<float> frame);

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
        float cd = corner_sdf(q, ch, min(rad, min(ch.x, ch.y)));
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
                   texture2d<float> layer_tex [[texture(2)]],
                   texture2d<float> frame [[texture(3)]]) {
    Instance i = instances[in.inst];
    float clip_cover = clip_coverage(in, i);
    return shade(in, i, atlas, images, layer_tex, frame) * (clip_cover * in.pulse_alpha);
}

static float4 shade(VOut in, Instance i, texture2d<float> atlas, texture2d<float> images, texture2d<float> layer_tex, texture2d<float> frame) {
    if (i.kind == 11.0) {
        return layer_tex.read(uint2(in.pos.xy)) * i.color.a;
    }
    if (i.kind == 9.0 || i.kind == 10.0) {
        return float4(0.0);
    }

    bool blur = length(in.vel) > 0.5;
    if (i.kind == 1.0) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float a = 0.0;
        if (blur) {
            float2 duv = in.vel / max(i.rect.zw, float2(1e-4)) * (i.uv.zw - i.uv.xy);
            for (int k = 0; k < 5; k++) {
                float2 uvk = in.uv - duv * (float(k) * 0.25 - 0.5);
                if (uvk.x >= i.uv.x && uvk.x <= i.uv.z && uvk.y >= i.uv.y && uvk.y <= i.uv.w) {
                    a += atlas.sample(s, uvk).r;
                }
            }
            a *= 0.2 * i.color.a;
        } else {
            a = atlas.sample(s, in.uv).r * i.color.a;
        }
        // A truncated line fading out: `border_width` points before `radius`.
        if (i.border_width > 0.0) a *= clamp((i.radius - in.world.x) / i.border_width, 0.0, 1.0);
        return float4(i.color.rgb * a, a);
    }

    if (i.kind == 6.0) return line_color(in.world, i);
    if (i.kind == 7.0) return triangle_color(in.world, i);

    float2 half_size = i.rect.zw * 0.5;
    float2 p = in.local - half_size;
    float r_abs = min(abs(i.radius), min(half_size.x, half_size.y));
    float r = i.radius < 0.0 ? -r_abs : r_abs;
    float d = corner_sdf(p, half_size, r);
    float aa = max(fwidth(d), 0.0001) * 0.5;

    if (i.kind == 3.0) {
        // Premultiplied already: scaled by the corners' coverage and opacity.
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float coverage = 0.0;
        if (blur) {
            for (int k = 0; k < 5; k++) {
                float dk = corner_sdf(p - in.vel * (float(k) * 0.25 - 0.5), half_size, r);
                coverage += 1.0 - smoothstep(-aa, aa, dk);
            }
            coverage *= 0.2;
        } else {
            coverage = 1.0 - smoothstep(-aa, aa, d);
        }
        float4 px = images.sample(s, in.uv);
        // Tinted: the picture's shape in one color (a mark following the theme).
        if (i.border_color.a > 0.0) {
            float a = px.a * i.border_color.a * coverage * i.color.a;
            return float4(i.border_color.rgb * a, a);
        }
        return px * (coverage * i.color.a);
    }
    if (i.kind == 8.0) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float coverage = 1.0 - smoothstep(-aa, aa, d);
        return frame.sample(s, in.uv) * (coverage * i.color.a);
    }

    if (i.kind == 2.0 || i.kind == 5.0) {
        float sigma = max(i.border_width, 0.25);
        float a = shadow_alpha(p, half_size, r, sigma) * i.color.a;
        // Knocked out inside the box itself: `uv.xy` is where the box is
        // from the shadow's rect (the shadow's offset, negated).
        if (i.kind == 5.0) a *= clamp(corner_sdf(p - i.uv.xy, half_size, r) + 0.5, 0.0, 1.0);
        if (a > 0.0) a = clamp(a + shadow_dither(in.pos.xy), 0.0, 1.0);
        return float4(i.color.rgb * a, a);
    }

    float coverage = 0.0;
    if (blur) {
        for (int k = 0; k < 5; k++) {
            float dk = corner_sdf(p - in.vel * (float(k) * 0.25 - 0.5), half_size, r);
            coverage += 1.0 - smoothstep(-aa, aa, dk);
        }
        coverage *= 0.2;
    } else {
        coverage = 1.0 - smoothstep(-aa, aa, d);
    }
    // Premultiplied: the border is laid over the fill, not mixed with it.
    float4 c = float4(i.color.rgb * i.color.a, i.color.a);
    if (i.border_width > 0.0 && i.border_color.a > 0.0) {
        float inner = smoothstep(-i.border_width - aa, -i.border_width + aa, d);
        float4 b = float4(i.border_color.rgb * i.border_color.a, i.border_color.a);
        if (i.uv.x > 0.5) b *= dash_cover(p, half_size, r, i.border_width);
        c = mix(c, b + c * (1.0 - b.a), inner);
    }
    return c * coverage;
}
