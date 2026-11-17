// Shared shape math from shader.glsl; raster.zig/raster_shapes.zig are
// the pixel reference. Analytic AA avoids all derivative uniformity issues.
fn rounded_box_aa(p: vec2f, half_size: vec2f, r: f32) -> vec2f {
    let q = abs(p) - half_size + r;
    let m = max(q, vec2f(0.0));
    let len = length(m);
    let d = len + min(max(q.x, q.y), 0.0) - r;
    var grad = 1.0;
    if (len > 0.0) { grad = (m.x + m.y) / len; }
    return vec2f(d, max(grad / params.scale, 0.0001) * 0.5);
}
fn corner_sdf_aa(p: vec2f, half_size: vec2f, r_in: f32) -> vec2f {
    let r = min(abs(r_in), min(half_size.x, half_size.y));
    if (r <= 0.0 || r_in < 0.0) { return rounded_box_aa(p, half_size, r); }
    let dx = half_size.x - abs(p.x); let dy = half_size.y - abs(p.y);
    let a = min(dx, dy); let b_val = max(dx, dy);
    let half_long = select(half_size.x, half_size.y, dy >= dx);
    let ext = min(1.52866495 * r, half_long);
    var d: f32; var grad: f32;
    if (b_val >= ext) { d = -a; grad = 1.0; }
    else if (b_val >= 0.63149399 * r && a > -0.25 * r) {
        let span = max(ext - 0.63149399 * r, 1e-5);
        let u = clamp((ext - b_val) / span, 0.0, 1.0);
        let uu = u * u; let uuu = uu * u;
        let c3 = 0.00759166; let c4 = 0.06728002; let c5 = 0.00003973;
        let indent = r * (c3 * uuu + c4 * uuu * u + c5 * uuu * uu);
        let slope = r * (3.0 * c3 * uu + 4.0 * c4 * uuu + 5.0 * c5 * uu * uu) / span;
        let inv_norm = 1.0 / sqrt(1.0 + slope * slope);
        d = (indent - a) * inv_norm; grad = (1.0 + slope) * inv_norm;
    } else {
        let cx = 0.950248 * r; let cr = 0.931599 * r;
        let q = vec2f(cx - dx, cx - dy); let m = max(q, vec2f(0.0));
        let len = length(m);
        d = len + min(max(q.x, q.y), 0.0) - cr;
        grad = 1.0;
        if (len > 0.0) { grad = (m.x + m.y) / len; }
    }
    return vec2f(d, max(grad / params.scale, 0.0001) * 0.5);
}
fn shadow_dither(pos: vec2f) -> f32 {
    let x = u32(pos.x); let y = u32(pos.y);
    var h1 = (x * 1664525u + y * 1013904223u) ^ 0x68bc21ebu;
    h1 ^= h1 >> 15u; h1 *= 0x85ebca6bu; h1 ^= h1 >> 13u;
    var h2 = (x * 22695477u + y * 2891336453u) ^ 0x02e5be93u;
    h2 ^= h2 >> 15u; h2 *= 0xc2b2ae35u; h2 ^= h2 >> 13u;
    let u1 = f32(h1 & 0xffffu) / 65535.0;
    let u2 = f32(h2 & 0xffffu) / 65535.0;
    return (u1 + u2 - 1.0) * (0.5 / 255.0);
}
fn gaussian(x: f32, sigma: f32) -> f32 {
    return exp(-(x * x) / (2.0 * sigma * sigma)) / (sqrt(2.0 * 3.14159265358979) * sigma);
}
fn erf2(input: vec2f) -> vec2f {
    let s = sign(input); let a = abs(input);
    var x = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
    x *= x;
    return s - s / (x * x);
}
fn blur_along_x(x: f32, y: f32, sigma: f32, corner: f32, half_size: vec2f) -> f32 {
    let delta = min(half_size.y - corner - abs(y), 0.0);
    let curved = half_size.x - corner + sqrt(max(0.0, corner * corner - delta * delta));
    let integral = 0.5 + 0.5 * erf2((x + vec2f(-curved, curved)) * (sqrt(0.5) / sigma));
    return integral.y - integral.x;
}
fn shadow_alpha(p: vec2f, half_size: vec2f, corner: f32, sigma: f32) -> f32 {
    let c = abs(corner); let low = p.y - half_size.y; let high = p.y + half_size.y;
    let start = clamp(-3.0 * sigma, low, high); let end = clamp(3.0 * sigma, low, high);
    let step = (end - start) / 8.0;
    var y = start + step * 0.5; var alpha = 0.0;
    for (var k = 0; k < 8; k++) {
        alpha += blur_along_x(p.x, p.y - y, sigma, c, half_size) * gaussian(y, sigma) * step;
        y += step;
    }
    return alpha;
}
fn dash_cover(p: vec2f, half_size: vec2f, r: f32, w: f32) -> f32 {
    let PI = 3.14159265;
    let dv = 1.0 / (3.0 * w);
    let sx = (2.0 * half_size.x - 2.0 * r) * dv;
    let sy = (2.0 * half_size.y - 2.0 * r) * dv;
    let cq = r * PI * 0.5 * dv;
    let q = abs(p) - (half_size - r);
    var t: f32;
    if (r > 0.0 && q.x > 0.0 && q.y > 0.0) {
        let v = p - sign(p) * (half_size - r); let ang = atan2(v.y, v.x);
        if (p.x >= 0.0 && p.y < 0.0) { t = sx + (ang + PI * 0.5) * r * dv; }
        else if (p.x >= 0.0) { t = sx + cq + sy + ang * r * dv; }
        else if (p.y >= 0.0) { t = 2.0 * sx + 2.0 * cq + sy + (ang - PI * 0.5) * r * dv; }
        else { t = 2.0 * sx + 3.0 * cq + 2.0 * sy + (ang + PI) * r * dv; }
    } else if ((half_size.y - abs(p.y)) < (half_size.x - abs(p.x))) {
        t = select(sx + 2.0 * cq + sy + (half_size.x - r - p.x) * dv, (p.x + half_size.x - r) * dv, p.y < 0.0);
    } else {
        t = select(2.0 * sx + 3.0 * cq + sy + (half_size.y - r - p.y) * dv, sx + cq + (p.y + half_size.y - r) * dv, p.x > 0.0);
    }
    let max_t = 2.0 * (sx + sy) + 4.0 * cq;
    if (max_t < 1.0) { return 1.0; }
    let period = max_t / floor(max_t); let len = 2.0 / 3.0;
    let u = t + period * 0.5 - len * 0.5;
    let centered = u - period * floor(u / period) - period * 0.5;
    let sd = (abs(centered) - len * 0.5) / dv;
    return clamp(0.5 - sd / max(1.0 / params.scale, 0.0001), 0.0, 1.0);
}
fn line_color(world: vec2f, i: Instance) -> vec4f {
    let a = i.uv.xy; let ab = i.uv.zw - a; let len2 = dot(ab, ab);
    var t = 0.0;
    if (len2 > 0.0) { t = clamp(dot(world - a, ab) / len2, 0.0, 1.0); }
    let off = world - (a + ab * t); let d = length(off);
    var grad = 1.0;
    if (d > 0.0) { grad = (abs(off.x) + abs(off.y)) / d; }
    let aa = max(grad / params.scale, 0.0001) * 0.5;
    let hw = i.border_width * 0.5;
    var cover = 1.0 - smoothstep(hw - aa, hw + aa, d);
    let on = i.border_color.x; let gap = i.border_color.y;
    if (on > 0.0 && gap > 0.0) {
        let len = sqrt(len2);
        var along = i.border_color.z; var ug = 0.0;
        if (len > 0.0) { along += dot(world - a, ab) / len; ug = (abs(ab.x) + abs(ab.y)) / len; }
        let m = along - (on + gap) * floor(along / (on + gap));
        let e = min(m, on - m); let ea = max(ug / params.scale, 0.0001) * 0.5;
        cover *= smoothstep(-ea, ea, e);
    }
    let alpha = i.color.a * cover;
    return vec4f(i.color.rgb * alpha, alpha);
}
fn triangle_color(world: vec2f, i: Instance) -> vec4f {
    let v = array<vec2f, 3>(i.uv.xy, i.uv.zw, i.border_color.xy);
    let area = (v[1].x - v[0].x) * (v[2].y - v[0].y) - (v[1].y - v[0].y) * (v[2].x - v[0].x);
    let side = select(1.0, -1.0, area < 0.0); let edges = u32(i.border_color.z);
    var cover = 1.0;
    for (var k = 0u; k < 3u; k++) {
        if ((edges & (1u << k)) == 0u) { continue; }
        let p = v[k]; let e = v[(k + 1u) % 3u] - p;
        let len = max(length(e), 0.0001);
        let d = side * (e.x * (world.y - p.y) - e.y * (world.x - p.x)) / len;
        let aa = max((abs(e.x) + abs(e.y)) / len / params.scale, 0.0001) * 0.5;
        cover *= smoothstep(-aa, aa, d);
    }
    let alpha = i.color.a * cover;
    return vec4f(i.color.rgb * alpha, alpha);
}

// WebGPU's trig accuracy allowance is too loose for rotated clipping at a
// pixel boundary. Reduce the angle and evaluate in f32; this agrees with
// the CPU within a few ulps instead of moving edges by hundredths of a point.
fn precise_sincos(angle: f32) -> vec2f {
    let pi = 3.141592653589793;
    var x = angle - floor((angle + pi) / (2.0 * pi)) * (2.0 * pi);
    var sign_c = 1.0;
    if (x > pi * 0.5) { x = pi - x; sign_c = -1.0; }
    else if (x < -pi * 0.5) { x = -pi - x; sign_c = -1.0; }
    let q = x*x;
    let s = x * (1.0 + q * (-1.0/6.0 + q * (1.0/120.0 + q * (-1.0/5040.0 + q * (1.0/362880.0 + q * (-1.0/39916800.0 + q/6227020800.0))))));
    let c = 1.0 + q * (-1.0/2.0 + q * (1.0/24.0 + q * (-1.0/720.0 + q * (1.0/40320.0 + q * (-1.0/3628800.0 + q/479001600.0)))));
    return vec2f(s,c*sign_c);
}
fn precise_sin(x:f32)->f32 { return precise_sincos(x).x; }
fn precise_cos(x:f32)->f32 { return precise_sincos(x).y; }

struct LocalPoint { world:vec2f, local:vec2f, screen:vec2f };
fn has_transform(i:Instance)->bool {
    return any(i.m!=vec4f(1.0,0.0,0.0,1.0)) || any(i.mt.xy!=vec2f(0.0)) || i.xf.x!=0.0 || i.xf.y!=0.0 || i.pulse.x>0.0 || i.turn.x!=0.0 || i.vel.z==2.0 || (i.kind==8.0 && any(i.border_color!=vec4f(0.0)));
}
fn inverse_frame(screen:vec2f,i:Instance)->LocalPoint {
    var landed=screen;
    if(i.turn.x!=0.0){
        let ct=precise_cos(i.turn.x);let st=precise_sin(i.turn.x);let q=screen-i.turn.zw;
        var inv=0.0;if(i.turn.y>0.0){inv=st/i.turn.y;}
        let dx=q.x/(ct-q.x*inv);let w=1.0+dx*inv;
        landed=i.turn.zw+vec2f(dx,q.y*w);
    }
    let determinant=i.m.x*i.m.w-i.m.z*i.m.y;
    let q0=landed-i.mt.xy;
    let p=vec2f(i.m.w*q0.x-i.m.z*q0.y,-i.m.y*q0.x+i.m.x*q0.y)/determinant;
    var d=p-i.xf.zw;
    if(i.kind==8.0 && any(i.border_color!=vec4f(0.0))){
        let m=i.border_color;let det=m.x*m.w-m.y*m.z;
        if(abs(det)<1e-9){return LocalPoint(p,vec2f(-1e9),landed);}
        d=vec2f(m.w*d.x-m.y*d.y,-m.z*d.x+m.x*d.y)/det;
    }
    let angle=i.xf.x+i.xf.y*params.time;let ca=precise_cos(angle);let sa=precise_sin(angle);
    var k=1.0;
    if(i.pulse.x>0.0){let s=0.5-0.5*precise_cos(6.28318530718*params.time/i.pulse.x);k=1.0+i.pulse.y*(2.0*s-1.0);}
    var local=vec2f(i.xf.z+(ca*d.x+sa*d.y)/k,i.xf.w+(-sa*d.x+ca*d.y)/k);
    if(i.vel.z==2.0){local.x=2.0*i.vel.w-local.x;}
    return LocalPoint(p,local,landed);
}
