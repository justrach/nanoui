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

