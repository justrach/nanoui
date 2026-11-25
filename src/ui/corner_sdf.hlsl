// Shared corner shape math, matching shader.glsl and raster.zig.
float2 corner_sdf_aa(float2 p, float2 half_size, float r_in) {
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
        float2 q = float2(cx - dx, cx - dy);
        float2 m = max(q, 0.0);
        float len = length(m);
        d = len + min(max(q.x, q.y), 0.0) - cr;
        grad = len > 0.0 ? (m.x + m.y) / len : 1.0;
    }
    return float2(d, max(grad / scale, 0.0001) * 0.5);
}

float shadow_alpha(float2 p, float2 half_size, float corner, float sigma) {
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

float shadow_dither(float2 pos) {
    uint x = (uint)pos.x;
    uint y = (uint)pos.y;
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

float4 gradient_stops(float4 uv, float y) {
    uint at = (uint)uv.z;
    float4 h = grads[at];
    uint n = (uint)h.z;
    if (n == 0u) return float4(0.0, 0.0, 0.0, 0.0);
    float t = (y - h.x) / max(h.y, 1e-4);
    if (t <= grads[at + 1u].x) return grads[at + 2u];
    for (uint k = 1u; k < n; k++) {
        float p0 = grads[at + 1u + 2u * (k - 1u)].x;
        float p1 = grads[at + 1u + 2u * k].x;
        if (t <= p1) {
            float4 c0 = grads[at + 2u + 2u * (k - 1u)];
            float4 c1 = grads[at + 2u + 2u * k];
            return lerp(c0, c1, (t - p0) / max(p1 - p0, 1e-6));
        }
    }
    return grads[at + 2u * n];
}

