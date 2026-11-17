// Liquid Glass: shader.glsl/ glass.metal, using separate fragment passes.
@vertex fn pass_vs(@builtin(vertex_index) vertex: u32) -> @builtin(position) vec4f {
    let p = vec2f(f32((vertex << 1u) & 2u), f32(vertex & 2u));
    return vec4f(p * 2.0 - 1.0, 0.0, 1.0);
}
@fragment fn down_fs(@builtin(position) position: vec4f) -> @location(0) vec4f {
    let start = params.area.xy + vec2i(position.xy) * i32(params.down);
    let end = min(start + vec2i(i32(params.down)), params.area.zw);
    var sum = vec3f(0.0);
    for (var y = start.y; y < end.y; y++) {
        for (var x = start.x; x < end.x; x++) { sum += textureLoad(frame_tex, vec2i(x, y), 0).rgb; }
    }
    return vec4f(sum / f32((end.x - start.x) * (end.y - start.y)), 1.0);
}
@fragment fn blur_fs(@builtin(position) position: vec4f) -> @location(0) vec4f {
    var sum = vec3f(0.0); var weight = 0.0;
    var sigma=params.sigma;
    if(params.progressive.z>0.0){let t=clamp(min(position.y-params.progressive.x,params.progressive.y-position.y)/params.progressive.z,0.0,1.0);sigma*=1.0-0.65*t*t*(3.0-2.0*t);}
    for (var k = -params.radius; k <= params.radius; k++) {
        let p = clamp(vec2i(position.xy) + params.dir * k, vec2i(0), vec2i(params.size) - 1);
        let w = exp(-f32(k * k) / (2.0 * sigma * sigma));
        sum += textureLoad(frame_tex, p, 0).rgb * w; weight += w;
    }
    return vec4f(sum / weight, 1.0);
}
fn glass_texel(p: vec2i) -> vec3f {
    return textureLoad(frame_tex, clamp(p, vec2i(0), vec2i(params.size) - 1), 0).rgb;
}
fn glass_sample(q: vec2f) -> vec3f {
    let u = (q - params.origin) / params.down - 0.5;
    let f = floor(u); let w = u - f; let p = vec2i(f);
    return mix(mix(glass_texel(p), glass_texel(p + vec2i(1,0)), w.x),
               mix(glass_texel(p + vec2i(0,1)), glass_texel(p + vec2i(1,1)), w.x), w.y);
}
fn glass_lens(t: f32, bezel: f32) -> f32 {
    if (bezel <= 0.0 || t >= bezel) { return 0.0; }
    let u = 1.0 - max(t, 0.0) / bezel;
    let v = 1.0 - u*u*u*u; let a = sqrt(v * sqrt(v)); let b = u*u*u;
    let n = sqrt(a*a+b*b); let s = b/n; let c = a/n;
    let st = s/1.5; let ct = sqrt(1.0-st*st);
    return (s*ct-c*st)/(c*ct+s*st)/1.1180340;
}
fn glass_normal(q: vec2f, h: vec2f, radius: f32) -> vec2f {
    let r = min(radius * 1.5, min(h.x,h.y));
    let a = abs(q) - (h-r);
    if (a.x>0.0 || a.y>0.0) { let m = max(a,vec2f(0.0)); return sign(q)*m/length(m); }
    if (a.x>a.y) { return vec2f(sign(q.x),0.0); }
    return vec2f(0.0,sign(q.y));
}
fn glass_tone(c: vec3f, tone: vec4f) -> vec3f {
    let l = dot(c,vec3f(0.2126,0.7152,0.0722));
    let t = tone.x + (tone.y-tone.x)*(1.0-pow(max(1.0-l,0.0),tone.z));
    return clamp(t+(c-l)*((tone.y-tone.x)*tone.w),vec3f(0.0),vec3f(1.0));
}
@fragment fn glass_fs(v: Varyings) -> @location(0) vec4f {
    let i = instances[v.idx]; let clip = clip_coverage(v,i);
    let hp = i.rect.zw*0.5;
    let da = rounded_box_aa(v.local-hp,hp,min(i.radius,min(hp.x,hp.y)));
    let coverage = (1.0-smoothstep(-da.y,da.y,da.x))*clip*i.uv.z;
    let s = params.scale; let p = v.world*s; let h = hp*s;
    let q = p-i.rect.xy*s-h; let rr = min(i.radius*s,min(h.x,h.y));
    let t = max(-rounded_box_aa(q,h,rr).x,0.0);
    let bezel = i.uv.x*s; let sidebar=i.uv.x<0.0; let rim = select(i.uv.w*s,0.0,sidebar);
    var n = vec2f(0.0);
    if (t<bezel || t<3.0*rim) { n=glass_normal(q,h,rr); }
    var at = p;
    if (t<bezel) { at-=n*(i.uv.y*s*glass_lens(t,bezel)); }
    var back=glass_sample(at);
    if(sidebar && i.uv.w>0.0){let right=(i.rect.x+i.rect.z)*s;let u=clamp((p.x-i.rect.x*s)/(2.0*h.x),0.0,1.0);back=mix(back,glass_sample(vec2f(2.0*right-p.x,p.y)),i.uv.w*u*u);}
    var c = glass_tone(back,i.border_color);
    c+=(i.color.rgb-c)*i.color.a;
    if (t<3.0*rim) { let r=t/rim; let a=0.35*exp(-r*r); c+=(abs(n.y)-c)*a; }
    return vec4f(c,1.0)*coverage;
}
