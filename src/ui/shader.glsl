// shader.metal and glass.metal in GLSL 3.30, and GLSL ES 3.00 for OpenGL
// ES (Android), for the OpenGL renderer (opengl.zig), which builds each
// program from this file with one of QUAD_VS, QUAD_FS, GLASS_FS, PASS_VS,
// DOWN_FS or BLUR_FS defined. The frame is drawn upside down as GL keeps
// it (row 0 at the bottom); the instances' points and the backdrop's
// texels are top down, as in Metal.

#if defined(QUAD_VS)
layout(location = 0) in vec4 a_rect;   // x, y, w, h in points
layout(location = 1) in vec4 a_color;  // straight alpha
layout(location = 2) in vec4 a_border_color;
layout(location = 3) in vec4 a_uv;     // atlas u0, v0, u1, v1
layout(location = 4) in vec4 a_clip;   // x0, y0, x1, y1
layout(location = 5) in vec4 a_misc;   // radius, border width, kind, clip_round
layout(location = 6) in vec4 a_xf;     // angle, spin, pivot x, pivot y
layout(location = 7) in vec4 a_pulse;  // period, scale amplitude, alpha low
layout(location = 8) in vec4 a_vel;    // motion blur vector in points, face, mirror x
layout(location = 9) in vec4 a_turn;   // angle about the vertical axis, eye distance, pivot x, pivot y
uniform vec2 viewport;
uniform float time;
out vec2 v_local;
out vec2 v_world;
out vec2 v_uv;
flat out vec4 i_rect;
flat out vec4 i_color;
flat out vec4 i_border_color;
flat out vec4 i_uv;
flat out vec4 i_clip;
flat out vec4 i_misc;
out vec2 v_vel;
out float v_pulse_alpha;

void main() {
    vec2 corner = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
    // Shadows reach three standard deviations past their box.
    float grow = (a_misc.z == 2.0 || a_misc.z == 5.0) ? a_misc.y * 3.0 : 0.0;
    vec2 velocity = a_vel.xy;
    float vlen = length(velocity);
    if (vlen > 24.0) {
        velocity *= 24.0 / vlen;
        vlen = 24.0;
    }
    bool has_blur = vlen > 0.5 && (a_misc.z == 0.0 || a_misc.z == 1.0 || a_misc.z == 3.0);
    vec2 grow2 = vec2(grow) + (has_blur ? abs(velocity) * 0.5 : vec2(0.0));
    vec2 p_unrot = a_rect.xy - grow2 + corner * (a_rect.zw + 2.0 * grow2);
    vec2 p = p_unrot;
    float pulse_alpha = 1.0;
    float angle = a_xf.x + a_xf.y * time;
    // The reverse of a card is seen through it: mirrored across its middle.
    if (a_vel.z == 2.0) p.x = 2.0 * a_vel.w - p.x;
    if (a_misc.z == 6.0) {
        // A box along the line, a point past its round ends.
        vec2 a = a_uv.xy, b = a_uv.zw;
        float len = length(b - a);
        vec2 u = len > 0.0 ? (b - a) / len : vec2(1.0, 0.0);
        vec2 n = vec2(-u.y, u.x);
        float e = a_misc.y * 0.5 + 1.0;
        p = mix(a - u * e, b + u * e, corner.x) + n * (corner.y * 2.0 - 1.0) * e;
    } else if (a_misc.z == 7.0) {
        // The triangle itself: its third corner twice.
        p = gl_VertexID == 0 ? a_uv.xy : (gl_VertexID == 1 ? a_uv.zw : a_border_color.xy);
    } else if (angle != 0.0 || a_pulse.x > 0.0) {
        vec2 d = p - a_xf.zw;
        if (a_pulse.x > 0.0) {
            float s = 0.5 - 0.5 * cos(6.28318530718 * time / a_pulse.x);
            float k = 1.0 + a_pulse.y * (2.0 * s - 1.0);
            d *= k;
            pulse_alpha = mix(a_pulse.z, 1.0, s);
        }
        if (angle != 0.0) {
            float ca = cos(angle), sa = sin(angle);
            d = vec2(ca * d.x - sa * d.y, sa * d.x + ca * d.y);
        }
        p = a_xf.zw + d;
    }
    // A turn about the vertical axis through the pivot, in perspective.
    vec2 seen = p;
    float w = 1.0;
    float ct = cos(a_turn.x);
    bool hidden = (a_vel.z == 1.0 && ct < 0.0) || (a_vel.z == 2.0 && ct >= 0.0);
    if (a_turn.x != 0.0) {
        float dx = p.x - a_turn.z;
        float z = -dx * sin(a_turn.x);
        seen = vec2(a_turn.z + dx * ct, p.y);
        if (a_turn.y > 0.0) {
            w = max(1.0 - z / a_turn.y, 0.1);
            seen = a_turn.zw + (seen - a_turn.zw) / w;
        }
    }
    gl_Position = hidden ? vec4(0.0, 0.0, 0.0, 1.0) : vec4((seen / viewport * vec2(2.0, -2.0) + vec2(-1.0, 1.0)) * w, 0.0, w);
    v_local = p_unrot - a_rect.xy;
    v_world = p;
    v_uv = has_blur ? a_uv.xy + (p_unrot - a_rect.xy) / max(a_rect.zw, vec2(1e-4)) * (a_uv.zw - a_uv.xy) : mix(a_uv.xy, a_uv.zw, corner);
    v_vel = has_blur ? velocity : vec2(0.0);
    v_pulse_alpha = pulse_alpha;
    i_rect = a_rect;
    i_color = a_color;
    i_border_color = a_border_color;
    i_uv = a_uv;
    i_clip = a_clip;
    i_misc = a_misc;
}
#endif

#if defined(QUAD_FS) || defined(GLASS_FS)
in vec2 v_local;
in vec2 v_world;
in vec2 v_uv;
flat in vec4 i_rect;
flat in vec4 i_color;
flat in vec4 i_border_color;
flat in vec4 i_uv;
flat in vec4 i_clip;
flat in vec4 i_misc;
in vec2 v_vel;
in float v_pulse_alpha;
out vec4 frag;
// The frame's pixels a point.
uniform float scale;

// A dashed border's coverage at `p` (from the box's centre), as GPUI lays
// dashes (see shader.metal's `dash_cover`).
float dash_cover(vec2 p, vec2 half_size, float r, float w) {
    const float PI = 3.14159265;
    float dv = 1.0 / (3.0 * w);
    float sx = (2.0 * half_size.x - 2.0 * r) * dv;
    float sy = (2.0 * half_size.y - 2.0 * r) * dv;
    float cq = r * PI * 0.5 * dv;
    vec2 q = abs(p) - (half_size - r);
    float t;
    if (r > 0.0 && q.x > 0.0 && q.y > 0.0) {
        vec2 v = p - sign(p) * (half_size - r);
        float ang = atan(v.y, v.x);
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

float rounded_box(vec2 p, vec2 half_size, float r) {
    vec2 q = abs(p) - half_size + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// The distance to a rounded box, and half a pixel's worth of it: what
// Metal takes from fwidth, exactly, as raster.zig computes it. GPUs whose
// derivatives are coarse (dFdx from one row of a 2×2 block, dFdy from one
// column) would make it twice that at a box's corners.
float shadow_dither(vec2 pos) {
    uint x = uint(pos.x), y = uint(pos.y);
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

vec2 rounded_box_aa(vec2 p, vec2 half_size, float r) {
    vec2 q = abs(p) - half_size + r;
    vec2 m = max(q, 0.0);
    float len = length(m);
    float d = len + min(max(q.x, q.y), 0.0) - r;
    float grad = len > 0.0 ? (m.x + m.y) / len : 1.0;
    return vec2(d, max(grad / scale, 0.0001) * 0.5);
}

vec2 corner_sdf_aa(vec2 p, vec2 half_size, float r_in) {
    float r = min(abs(r_in), min(half_size.x, half_size.y));
    if (r <= 0.0 || r_in < 0.0) return rounded_box_aa(p, half_size, r);
    float dx = half_size.x - abs(p.x);
    float dy = half_size.y - abs(p.y);
    float a = min(dx, dy);
    float b_val = max(dx, dy);
    float half_long = (dy >= dx) ? half_size.y : half_size.x;
    float ext = min(1.52866495 * r, half_long);
    float d, grad;
    if (b_val >= ext) {
        d = -a;
        grad = 1.0;
    } else if (b_val >= 0.63149399 * r && a > -0.25 * r) {
        float span = max(ext - 0.63149399 * r, 1e-5);
        float u = clamp((ext - b_val) / span, 0.0, 1.0);
        float uu = u * u;
        float uuu = uu * u;
        const float c3 = 0.00759166, c4 = 0.06728002, c5 = 0.00003973;
        float indent = r * (c3 * uuu + c4 * uuu * u + c5 * uuu * uu);
        float slope = r * (3.0 * c3 * uu + 4.0 * c4 * uuu + 5.0 * c5 * uu * uu) / span;
        float inv_norm = 1.0 / sqrt(1.0 + slope * slope);
        d = (indent - a) * inv_norm;
        grad = (1.0 + slope) * inv_norm;
    } else {
        float cx = 0.950248 * r;
        float cr = 0.931599 * r;
        vec2 q = vec2(cx - dx, cx - dy);
        vec2 m = max(q, 0.0);
        float len = length(m);
        d = len + min(max(q.x, q.y), 0.0) - cr;
        grad = len > 0.0 ? (m.x + m.y) / len : 1.0;
    }
    return vec2(d, max(grad / scale, 0.0001) * 0.5);
}

// How much of the fragment the instance's clip lets through: discarded
// outside it, cut in its rounded corners.
float clip_coverage() {
    if (v_world.x < i_clip.x || v_world.y < i_clip.y || v_world.x > i_clip.z || v_world.y > i_clip.w) discard;
    float clip_cover = 1.0;
    float clip_round = i_misc.w;
    if (clip_round > 0.0) {
        float corners = floor(clip_round / 4096.0);
        float rad = clip_round - corners * 4096.0;
        vec2 ch = (i_clip.zw - i_clip.xy) * 0.5;
        vec2 q = v_world - i_clip.xy - ch;
        vec2 cd = corner_sdf_aa(q, ch, min(rad, min(ch.x, ch.y)));
        uint bit = q.y < 0.0 ? (q.x < 0.0 ? 1u : 2u) : (q.x < 0.0 ? 8u : 4u);
        if ((uint(corners) & bit) != 0u) clip_cover = 1.0 - smoothstep(-cd.y, cd.y, cd.x);
        if (clip_cover <= 0.0) discard;
    }
    return clip_cover;
}
#endif

#if defined(QUAD_FS)
uniform sampler2D atlas;
uniform sampler2D images;

// Shadows as GPUI draws them (after Evan Wallace's "fast rounded rectangle
// shadows"): the box's coverage blurred by a Gaussian, exact along x with
// erf, sampled eight times along y.
float gaussian(float x, float sigma) {
    return exp(-(x * x) / (2.0 * sigma * sigma)) / (sqrt(2.0 * 3.14159265358979) * sigma);
}

vec2 erf2(vec2 x) {
    vec2 s = sign(x), a = abs(x);
    x = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
    x *= x;
    return s - s / (x * x);
}

float blur_along_x(float x, float y, float sigma, float corner, vec2 half_size) {
    float delta = min(half_size.y - corner - abs(y), 0.0);
    float curved = half_size.x - corner + sqrt(max(0.0, corner * corner - delta * delta));
    vec2 integral = 0.5 + 0.5 * erf2((x + vec2(-curved, curved)) * (sqrt(0.5) / sigma));
    return integral.y - integral.x;
}

float shadow_alpha(vec2 p, vec2 half_size, float corner, float sigma) {
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

// A line, as shader.metal's line_color, smoothed by its exact gradient.
vec4 line_color() {
    vec2 a = i_uv.xy, ab = i_uv.zw - i_uv.xy;
    float len2 = dot(ab, ab);
    float t = len2 > 0.0 ? clamp(dot(v_world - a, ab) / len2, 0.0, 1.0) : 0.0;
    vec2 off = v_world - (a + ab * t);
    float d = length(off);
    float grad = d > 0.0 ? (abs(off.x) + abs(off.y)) / d : 1.0;
    float aa = max(grad / scale, 0.0001) * 0.5;
    float hw = i_misc.y * 0.5;
    float cover = 1.0 - smoothstep(hw - aa, hw + aa, d);
    float on = i_border_color.x, gap = i_border_color.y;
    if (on > 0.0 && gap > 0.0) {
        float len = sqrt(len2);
        // Along the line unclamped: its ends are cut square, as its dashes.
        float along = (len > 0.0 ? dot(v_world - a, ab) / len : 0.0) + i_border_color.z;
        float m = along - (on + gap) * floor(along / (on + gap));
        float e = min(m, on - m);
        float ug = len > 0.0 ? (abs(ab.x) + abs(ab.y)) / len : 0.0;
        float ea = max(ug / scale, 0.0001) * 0.5;
        cover *= smoothstep(-ea, ea, e);
    }
    float alpha = i_color.a * cover;
    return vec4(i_color.rgb * alpha, alpha);
}

// A triangle, as shader.metal's triangle_color.
vec4 triangle_color() {
    vec2 v[3] = vec2[3](i_uv.xy, i_uv.zw, i_border_color.xy);
    float area = (v[1].x - v[0].x) * (v[2].y - v[0].y) - (v[1].y - v[0].y) * (v[2].x - v[0].x);
    float side = area < 0.0 ? -1.0 : 1.0;
    uint edges = uint(i_border_color.z);
    float cover = 1.0;
    for (int k = 0; k < 3; k++) {
        if ((edges & (1u << uint(k))) == 0u) continue;
        vec2 p = v[k], q = v[(k + 1) % 3];
        vec2 e = q - p;
        float len = max(length(e), 0.0001);
        float d = side * (e.x * (v_world.y - p.y) - e.y * (v_world.x - p.x)) / len;
        float aa = max((abs(e.x) + abs(e.y)) / len / scale, 0.0001) * 0.5;
        cover *= smoothstep(-aa, aa, d);
    }
    float alpha = i_color.a * cover;
    return vec4(i_color.rgb * alpha, alpha);
}

vec4 shade() {
    float kind = i_misc.z;
    if (kind == 6.0) return line_color();
    if (kind == 7.0) return triangle_color();
    if (kind == 1.0) {
        float a = 0.0;
        if (length(v_vel) > 0.5) {
            vec2 duv = v_vel / max(i_rect.zw, vec2(1e-4)) * (i_uv.zw - i_uv.xy);
            for (int k = 0; k < 5; k++) {
                vec2 uvk = v_uv - duv * (float(k) * 0.25 - 0.5);
                if (all(greaterThanEqual(uvk, i_uv.xy)) && all(lessThanEqual(uvk, i_uv.zw))) a += texture(atlas, uvk).r;
            }
            a *= 0.2 * i_color.a;
        } else {
            a = texture(atlas, v_uv).r * i_color.a;
        }
        // A truncated line fading out: `border_width` points before `radius`.
        if (i_misc.y > 0.0) a *= clamp((i_misc.x - v_world.x) / i_misc.y, 0.0, 1.0);
        return vec4(i_color.rgb * a, a);
    }
    vec2 half_size = i_rect.zw * 0.5;
    vec2 p = v_local - half_size;
    float r_abs = min(abs(i_misc.x), min(half_size.x, half_size.y));
    float r = i_misc.x < 0.0 ? -r_abs : r_abs;
    vec2 da = corner_sdf_aa(p, half_size, r);
    float d = da.x;
    float aa = da.y;
    float coverage = 0.0;
    if (length(v_vel) > 0.5) {
        for (int k = 0; k < 5; k++) {
            float dk = corner_sdf_aa(p - v_vel * (float(k) * 0.25 - 0.5), half_size, r).x;
            coverage += 1.0 - smoothstep(-aa, aa, dk);
        }
        coverage *= 0.2;
    } else {
        coverage = 1.0 - smoothstep(-aa, aa, d);
    }
    if (kind == 3.0) {
        // Premultiplied already: scaled by the corners' coverage and opacity.
        vec4 px = texture(images, v_uv);
#ifdef GL_ES
        // BGRA pixels, which OpenGL ES took for RGBA.
        px = px.bgra;
#endif
        // Tinted: the picture's shape in one color (a mark following the theme).
        if (i_border_color.a > 0.0) {
            float a = px.a * i_border_color.a * coverage * i_color.a;
            return vec4(i_border_color.rgb * a, a);
        }
        return px * (coverage * i_color.a);
    }
    if (kind == 2.0 || kind == 5.0) {
        float sigma = max(i_misc.y, 0.25);
        float a = shadow_alpha(p, half_size, r, sigma) * i_color.a;
        if (kind == 5.0) a *= clamp(corner_sdf_aa(p - i_uv.xy, half_size, r).x + 0.5, 0.0, 1.0);
        if (a > 0.0) a = clamp(a + shadow_dither(v_world * scale), 0.0, 1.0);
        return vec4(i_color.rgb * a, a);
    }
    // Premultiplied: the border is laid over the fill (see shader.metal).
    vec4 c = vec4(i_color.rgb * i_color.a, i_color.a);
    float bw = i_misc.y;
    if (bw > 0.0 && i_border_color.a > 0.0) {
        float inner = smoothstep(-bw - aa, -bw + aa, d);
        vec4 b = vec4(i_border_color.rgb * i_border_color.a, i_border_color.a);
        if (i_uv.x > 0.5) b *= dash_cover(p, half_size, r_abs, bw);
        c = mix(c, b + c * (1.0 - b.a), inner);
    }
    return c * coverage;
}

void main() {
    float clip_cover = clip_coverage();
    frag = shade() * (clip_cover * v_pulse_alpha);
}
#endif

#if defined(GLASS_FS)
// Where the pane's backdrop lies: its area's corner in the frame's pixels,
// its size in texels, the averaging, and the frame's pixels a point.
uniform sampler2D backdrop;
uniform vec2 origin;
uniform vec2 size;
uniform float down;

vec3 glass_texel(ivec2 p) {
    return texelFetch(backdrop, clamp(p, ivec2(0), ivec2(size) - 1), 0).rgb;
}

// The backdrop at pixel q of the frame, bilinear from its texels.
vec3 glass_sample(vec2 q) {
    vec2 u = (q - origin) / down - 0.5;
    vec2 f = floor(u);
    vec2 w = u - f;
    ivec2 p = ivec2(f);
    vec3 top = glass_texel(p) * (1.0 - w.x) + glass_texel(p + ivec2(1, 0)) * w.x;
    vec3 bot = glass_texel(p + ivec2(0, 1)) * (1.0 - w.x) + glass_texel(p + ivec2(1, 1)) * w.x;
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

vec2 glass_normal(vec2 q, vec2 h, float radius) {
    float r = min(radius * 1.5, min(h.x, h.y));
    vec2 a = abs(q) - (h - r);
    if (a.x > 0.0 || a.y > 0.0) {
        vec2 m = max(a, vec2(0.0));
        return sign(q) * m / sqrt(m.x * m.x + m.y * m.y);
    }
    return a.x > a.y ? vec2(sign(q.x), 0.0) : vec2(0.0, sign(q.y));
}

vec3 glass_tone(vec3 c, vec4 tone) {
    float l = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
    float t = tone.x + (tone.y - tone.x) * (1.0 - pow(max(1.0 - l, 0.0), tone.z));
    float k = (tone.y - tone.x) * tone.w;
    return clamp(t + (c - l) * k, 0.0, 1.0);
}

void main() {
    float clip_cover = clip_coverage();
    // The pane's edge, antialiased as a quad's.
    vec2 hp = i_rect.zw * 0.5;
    vec2 da = rounded_box_aa(v_local - hp, hp, min(i_misc.x, min(hp.x, hp.y)));
    float coverage = (1.0 - smoothstep(-da.y, da.y, da.x)) * clip_cover * i_uv.z;

    // The optics, in the frame's pixels.
    float s = scale;
    vec2 p = v_world * s;
    vec2 h = hp * s;
    vec2 q = p - i_rect.xy * s - h;
    float rr = min(i_misc.x * s, min(h.x, h.y));
    float t = max(-rounded_box(q, h, rr), 0.0);
    float bezel = i_uv.x * s;
    float rim_width = i_uv.w * s;
    vec2 n = vec2(0.0);
    if (t < bezel || t < 3.0 * rim_width) n = glass_normal(q, h, rr);
    vec2 at = p;
    if (t < bezel) at -= n * (i_uv.y * s * glass_lens(t, bezel));
    vec3 c = glass_tone(glass_sample(at), i_border_color);
    c += (i_color.rgb - c) * i_color.a;
    if (t < 3.0 * rim_width) {
        float r = t / rim_width;
        float a = 0.35 * exp(-r * r);
        // Light from above and below: the more the edge faces it, the lighter.
        c += (abs(n.y) - c) * a;
    }
    frag = vec4(c, 1.0) * coverage;
}
#endif

#if defined(PASS_VS)
// One triangle over the whole target: a pass computes each texel.
void main() {
    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
#endif

#if defined(DOWN_FS) || defined(BLUR_FS)
// A pane's backdrop (glass.zig's Backdrop): the frame's pixels of area
// (x0, y0, x1, y1), averaged over squares of down pixels into size texels,
// blurred by sigma texels out to radius each way.
uniform ivec2 size;
out vec4 frag;
#endif

#if defined(DOWN_FS)
uniform sampler2D frame;
uniform ivec4 area;
uniform int down;
uniform int frame_height;

void main() {
    ivec2 gid = ivec2(gl_FragCoord.xy);
    int x0 = area.x + gid.x * down;
    int y0 = area.y + gid.y * down;
    int x1 = min(x0 + down, area.z);
    int y1 = min(y0 + down, area.w);
    vec3 sum = vec3(0.0);
    for (int y = y0; y < y1; y++)
        for (int x = x0; x < x1; x++) sum += texelFetch(frame, ivec2(x, frame_height - 1 - y), 0).rgb;
    frag = vec4(sum / float((x1 - x0) * (y1 - y0)), 1.0);
}
#endif

#if defined(BLUR_FS)
uniform sampler2D src;
uniform int radius;
uniform float sigma;
uniform ivec2 dir;

void main() {
    ivec2 gid = ivec2(gl_FragCoord.xy);
    vec3 sum = vec3(0.0);
    float wsum = 0.0;
    for (int k = -radius; k <= radius; k++) {
        ivec2 p = clamp(gid + dir * k, ivec2(0), size - 1);
        float w = exp(-float(k * k) / (2.0 * sigma * sigma));
        sum += texelFetch(src, p, 0).rgb * w;
        wsum += w;
    }
    frag = vec4(sum / wsum, 1.0);
}
#endif
