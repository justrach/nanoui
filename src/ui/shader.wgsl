// Instance plumbing follows shader.hlsl; analytic AA and shading follow
// shader.glsl. shader.metal and raster.zig define the reference behavior.
// Keep the coefficients synchronized (tests_shader_sync.zig).
struct Params {
    viewport: vec2f, scale: f32, time: f32, origin: vec2f, size: vec2f,
    area: vec4i, down: f32, sigma: f32, radius: i32, frame_height: i32, dir: vec2i, pad: vec2i, progressive: vec4f,
};
// gpu.Instance, field for field: 192 bytes on this branch.
struct Instance {
    rect: vec4f, color: vec4f, border_color: vec4f, uv: vec4f, clip: vec4f,
    radius: f32, border_width: f32, kind: f32, clip_round: f32,
    xf: vec4f, pulse: vec4f, vel: vec4f, turn: vec4f, m: vec4f, mt: vec4f,
};
@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var<storage, read> instances: array<Instance>;
@group(0) @binding(2) var<storage, read> gradients: array<vec4f>;
@group(1) @binding(0) var frame_tex: texture_2d<f32>;
@group(1) @binding(1) var frame_external: texture_external;
@group(0) @binding(3) var atlas: texture_2d<f32>;
@group(0) @binding(4) var images: texture_2d<f32>;
@group(0) @binding(5) var samp: sampler;
struct Varyings {
    @builtin(position) position: vec4f,
    @location(0) local: vec2f,
    @location(1) world: vec2f,
    @location(2) uv: vec2f,
    @location(3) velocity: vec2f,
    @location(4) pulse_alpha: f32,
    @location(5) @interpolate(flat) idx: u32,
    @location(6) screen: vec2f,
};
@vertex fn quad_vs(@builtin(vertex_index) vertex: u32, @builtin(instance_index) idx: u32) -> Varyings {
    let i = instances[idx];
    let corner = vec2f(f32(vertex & 1u), f32(vertex >> 1u));
    var grow = 0.0;
    if (i.kind == 2.0 || i.kind == 5.0) { grow = i.border_width * 3.0; }
    var velocity = i.vel.xy;
    var vlen = length(velocity);
    if (vlen > 24.0) { velocity *= 24.0 / vlen; vlen = 24.0; }
    let has_blur = vlen > 0.5 && (i.kind == 0.0 || i.kind == 1.0 || i.kind == 3.0);
    var grow2 = vec2f(grow);
    if (has_blur) { grow2 += abs(velocity) * 0.5; }
    if (any(i.m != vec4f(1.0,0.0,0.0,1.0)) || any(i.mt.xy != vec2f(0.0)) || i.xf.x != 0.0 || i.xf.y != 0.0 || i.pulse.x > 0.0 || i.turn.x != 0.0 || (i.kind == 8.0 && any(i.border_color != vec4f(0.0)))) { grow2 += vec2f(1.0 / params.scale); }
    let unrot = i.rect.xy - grow2 + corner * (i.rect.zw + 2.0 * grow2);
    var p = unrot;
    var alpha = 1.0;
    let angle = i.xf.x + i.xf.y * params.time;
    if (i.vel.z == 2.0) { p.x = 2.0 * i.vel.w - p.x; }
    if (i.kind == 6.0) {
        let a = i.uv.xy; let b = i.uv.zw;
        let len = length(b - a);
        var u = vec2f(1.0, 0.0);
        if (len > 0.0) { u = (b - a) / len; }
        let n = vec2f(-u.y, u.x);
        let e = i.border_width * 0.5 + 1.0;
        p = mix(a - u * e, b + u * e, corner.x) + n * (corner.y * 2.0 - 1.0) * e;
    } else if (i.kind == 7.0) {
        p = i.border_color.xy;
        if (vertex == 0u) { p = i.uv.xy; }
        if (vertex == 1u) { p = i.uv.zw; }
    } else if (angle != 0.0 || i.pulse.x > 0.0 || (i.kind == 8.0 && any(i.border_color != vec4f(0.0)))) {
        var d = p - i.xf.zw;
        if (i.pulse.x > 0.0) {
            let s = 0.5 - 0.5 * precise_cos(6.28318530718 * params.time / i.pulse.x);
            d *= 1.0 + i.pulse.y * (2.0 * s - 1.0);
            alpha = mix(i.pulse.z, 1.0, s);
        }
        if (angle != 0.0) {
            let ca = precise_cos(angle); let sa = precise_sin(angle);
            d = vec2f(ca * d.x - sa * d.y, sa * d.x + ca * d.y);
        }
        if (i.kind == 8.0 && any(i.border_color != vec4f(0.0))) {
            let m = i.border_color;
            d = vec2f(m.x*d.x+m.y*d.y,m.z*d.x+m.w*d.y);
        }
        p = i.xf.zw + d;
    }
    let landed = vec2f(i.m.x*p.x+i.m.z*p.y+i.mt.x,i.m.y*p.x+i.m.w*p.y+i.mt.y);
    var seen = landed;
    var w = 1.0;
    let ct = precise_cos(i.turn.x);
    let hidden = (i.vel.z == 1.0 && ct < 0.0) || (i.vel.z == 2.0 && ct >= 0.0);
    if (i.turn.x != 0.0) {
        let dx = landed.x - i.turn.z;
        let z = -dx * precise_sin(i.turn.x);
        seen = vec2f(i.turn.z + dx * ct, landed.y);
        if (i.turn.y > 0.0) {
            w = max(1.0 - z / i.turn.y, 0.1);
            seen = i.turn.zw + (seen - i.turn.zw) / w;
        }
    }
    var out: Varyings;
    out.position = vec4f((seen / params.viewport * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0)) * w, 0.0, w);
    if (hidden) { out.position = vec4f(0.0, 0.0, 0.0, 1.0); }
    out.local = unrot - i.rect.xy;
    out.world = p;
    out.screen = landed;
    out.uv = mix(i.uv.xy, i.uv.zw, corner);
    out.velocity = vec2f(0.0);
    if (has_blur) {
        out.uv = i.uv.xy + (unrot - i.rect.xy) / max(i.rect.zw, vec2f(1e-4)) * (i.uv.zw - i.uv.xy);
        out.velocity = velocity;
    }
    out.pulse_alpha = alpha;
    out.idx = idx;
    return out;
}
fn clip_coverage(v: Varyings, i: Instance) -> f32 {
    if (any(v.screen < i.clip.xy) || any(v.screen > i.clip.zw)) { discard; }
    var cover = 1.0;
    if (i.clip_round != 0.0) {
        let corners = floor(abs(i.clip_round) / 4096.0);
        let rad = select(1.0,-1.0,i.clip_round<0.0)*(abs(i.clip_round) - corners * 4096.0);
        let half_size = (i.clip.zw - i.clip.xy) * 0.5;
        let q = v.screen - i.clip.xy - half_size;
        let cd = corner_sdf_aa(q, half_size, sign(rad)*min(abs(rad), min(half_size.x, half_size.y)));
        var bit = 4u;
        if (q.y < 0.0) { bit = select(2u, 1u, q.x < 0.0); }
        else { bit = select(4u, 8u, q.x < 0.0); }
        if ((u32(corners) & bit) != 0u) { cover = 1.0 - smoothstep(-cd.y, cd.y, cd.x); }
        if (cover <= 0.0) { discard; }
    }
    return cover;
}
fn shade(v: Varyings, i: Instance) -> vec4f {
    if (i.kind == 10.0 || i.kind == 11.0) {
        var fade = 1.0;
        if (i.border_color.z > 0.0) { fade = min(fade,clamp((v.world.y-i.border_color.x)/i.border_color.z,0.0,1.0)); }
        if (i.border_color.w > 0.0) { fade = min(fade,clamp((i.border_color.y-v.world.y)/i.border_color.w,0.0,1.0)); }
        return textureLoad(frame_tex, vec2i(v.position.xy), 0) * (i.color.a * fade);
    }

    if (i.kind == 6.0) { return line_color(v.world, i); }
    if (i.kind == 7.0) { return triangle_color(v.world, i); }
    if (i.kind == 1.0) {
        var a = 0.0;
        if (length(v.velocity) > 0.5) {
            let duv = v.velocity / max(i.rect.zw, vec2f(1e-4)) * (i.uv.zw - i.uv.xy);
            for (var k = 0; k < 5; k++) {
                let uv = v.uv - duv * (f32(k) * 0.25 - 0.5);
                if (all(uv >= i.uv.xy) && all(uv <= i.uv.zw)) { a += textureSampleLevel(atlas, samp, uv, 0.0).r; }
            }
            a *= 0.2 * i.color.a;
        } else { a = textureSampleLevel(atlas, samp, v.uv, 0.0).r * i.color.a; }
        if (i.border_width > 0.0) { a *= clamp((i.radius - v.world.x) / i.border_width, 0.0, 1.0); }
        return vec4f(i.color.rgb * a, a);
    }
    let half_size = i.rect.zw * 0.5;
    let p = v.local - half_size;
    let r_abs = min(abs(i.radius), min(half_size.x, half_size.y));
    let r = select(r_abs, -r_abs, i.radius < 0.0);
    let da = corner_sdf_aa(p, half_size, r);
    let d = da.x; let aa = da.y / max(sqrt(abs(i.m.x*i.m.w-i.m.y*i.m.z)),0.001);
    var coverage = 0.0;
    if (length(v.velocity) > 0.5) {
        for (var k = 0; k < 5; k++) {
            let dk = corner_sdf_aa(p - v.velocity * (f32(k) * 0.25 - 0.5), half_size, r).x;
            coverage += 1.0 - smoothstep(-aa, aa, dk);
        }
        coverage *= 0.2;
    } else { coverage = 1.0 - smoothstep(-aa, aa, d); }
    if (i.kind == 8.0) { return textureSampleLevel(frame_tex,samp,v.uv,0.0)*(coverage*i.color.a); }
    if (i.kind == 3.0) {
        let px = textureSampleLevel(images, samp, v.uv, 0.0);
        if (i.border_color.a > 0.0) {
            let a = px.a * i.border_color.a * coverage * i.color.a;
            return vec4f(i.border_color.rgb * a, a);
        }
        return px * (coverage * i.color.a);
    }
    if (i.kind == 2.0 || i.kind == 5.0) {
        let sigma = max(i.border_width, 0.25);
        var a = shadow_alpha(p, half_size, r, sigma) * i.color.a;
        if (i.kind == 5.0) { a *= clamp(corner_sdf_aa(p - i.uv.xy, half_size, r).x + 0.5, 0.0, 1.0); }
        if (a > 0.0) { a = clamp(a + shadow_dither(v.world * params.scale), 0.0, 1.0); }
        return vec4f(i.color.rgb * a, a);
    }
    var fill = i.color;
    if (i.uv.y > 1.5) { fill = gradient_stops(i.uv, v.local.y); }
    else if (i.uv.y > 0.5 && i.uv.y < 1.5) {
        let gr = floor(i.uv.z / 256.0); let gb = floor(i.uv.w / 256.0);
        let bottom = vec4f(gr, i.uv.z - gr * 256.0, gb, i.uv.w - gb * 256.0) / 255.0;
        fill = mix(fill, bottom, clamp(v.local.y / max(i.rect.w, 1e-4), 0.0, 1.0));
    }
    var c = vec4f(fill.rgb * fill.a, fill.a);
    let bw = i.border_width;
    if (bw > 0.0 && i.border_color.a > 0.0) {
        let inner = smoothstep(-bw - aa, -bw + aa, d);
        var b = vec4f(i.border_color.rgb * i.border_color.a, i.border_color.a);
        if (i.uv.x > 0.5) { b *= dash_cover(p, half_size, r_abs, bw); }
        c = mix(c, b + c * (1.0 - b.a), inner);
    }
    return c * coverage;
}
@fragment fn quad_fs(input: Varyings) -> @location(0) vec4f {
    var v = input;
    let i = instances[v.idx];
    if (i.kind != 6.0 && i.kind != 7.0 && has_transform(i)) {
        let point = inverse_frame(v.position.xy / params.scale, i);
        v.screen = point.screen;
        v.world = point.world;
        v.local = point.local - i.rect.xy;
        let edge_slack = select(0.0, 0.0001, any(i.m != vec4f(1.0,0.0,0.0,1.0)) || any(i.mt.xy != vec2f(0.0)));
        if (length(i.vel.xy) <= 0.5 && (i.kind == 0.0 || i.kind == 1.0 || i.kind == 3.0 || i.kind == 8.0 || i.kind == 12.0)) {
            if(any(point.local < i.rect.xy-vec2f(edge_slack)) || any(point.local > i.rect.xy+i.rect.zw+vec2f(edge_slack))) { discard; }
        }
        if (i.kind == 1.0 || i.kind == 3.0 || i.kind == 8.0) { v.uv = i.uv.xy + v.local / i.rect.zw * (i.uv.zw-i.uv.xy); }
    }
    let clip = clip_coverage(v, i);
    return shade(v, i) * (clip * v.pulse_alpha);
}

fn gradient_stops(uv: vec4f, y: f32) -> vec4f {
    let at = u32(uv.z); let h = gradients[at]; let n = u32(h.z);
    if (n == 0u) { return vec4f(0.0); }
    let t = (y - h.x) / max(h.y, 1e-4);
    if (t <= gradients[at + 1u].x) { return gradients[at + 2u]; }
    for (var k = 1u; k < n; k++) {
        let p0 = gradients[at + 1u + 2u * (k - 1u)].x;
        let p1 = gradients[at + 1u + 2u * k].x;
        if (t <= p1) {
            return mix(gradients[at + 2u + 2u * (k - 1u)], gradients[at + 2u + 2u * k], (t - p0) / max(p1 - p0, 1e-6));
        }
    }
    return gradients[at + 2u * n];
}

@fragment fn external_fs(input: Varyings) -> @location(0) vec4f {
    var v=input;let i=instances[v.idx];
    if(has_transform(i)){
        let point=inverse_frame(v.position.xy/params.scale,i);v.screen=point.screen;v.world=point.world;v.local=point.local-i.rect.xy;
        if(any(point.local<i.rect.xy)||any(point.local>i.rect.xy+i.rect.zw)){discard;}
        v.uv=i.uv.xy+v.local/i.rect.zw*(i.uv.zw-i.uv.xy);
    }
    let clip=clip_coverage(v,i);
    let h=i.rect.zw*0.5;let r=min(abs(i.radius),min(h.x,h.y));
    let da=corner_sdf_aa(v.local-h,h,select(r,-r,i.radius<0.0));
    let aa=da.y/max(sqrt(abs(i.m.x*i.m.w-i.m.y*i.m.z)),0.001);
    let coverage=1.0-smoothstep(-aa,aa,da.x);
    let pixel=clamp(textureSampleBaseClampToEdge(frame_external,samp,v.uv),vec4f(0.0),vec4f(1.0));
    return pixel*(coverage*clip*i.color.a*v.pulse_alpha);
}
