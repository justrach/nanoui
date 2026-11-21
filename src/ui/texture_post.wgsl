// texture_post.hlsl / texture_post.metal in WGSL. color.zig is the CPU reference.
struct PostUniforms {
    domain_min: vec4f, domain_max: vec4f, source_domain_min: vec4f, source_domain_max: vec4f,
    lut_size: f32, lut_enabled: u32, source_lut_size: f32, source_lut_enabled: u32,
    source_mode: u32, range_mode: u32, matrix_mode: u32, transfer_mode: u32,
    hdr_tone_map: u32,
};
@group(0) @binding(0) var<uniform> u: PostUniforms;
@group(0) @binding(2) var source0: texture_2d<f32>;
@group(0) @binding(3) var source1: texture_2d<f32>;
@group(0) @binding(4) var point_sampler: sampler;
@group(0) @binding(5) var lut: texture_3d<f32>;
@group(0) @binding(6) var source_lut: texture_3d<f32>;
@group(0) @binding(7) var linear_sampler: sampler;
@group(1) @binding(1) var external_source: texture_external;
@vertex fn pass_vs(@builtin(vertex_index) vertex: u32) -> @builtin(position) vec4f {
    let p=vec2f(f32((vertex<<1u)&2u),f32(vertex&2u));
    return vec4f(p*2.0-1.0,0.0,1.0);
}
fn cube_lut(rgb:vec3f)->vec3f {
    let n=clamp((rgb-u.domain_min.rgb)/max(u.domain_max.rgb-u.domain_min.rgb,vec3f(1e-6)),vec3f(0.0),vec3f(1.0));
    return textureSampleLevel(lut,linear_sampler,n*((u.lut_size-1.0)/u.lut_size)+0.5/u.lut_size,0.0).rgb;
}
fn cube_source(rgb:vec3f)->vec3f {
    let n=clamp((rgb-u.source_domain_min.rgb)/max(u.source_domain_max.rgb-u.source_domain_min.rgb,vec3f(1e-6)),vec3f(0.0),vec3f(1.0));
    return textureSampleLevel(source_lut,linear_sampler,n*((u.source_lut_size-1.0)/u.source_lut_size)+0.5/u.source_lut_size,0.0).rgb;
}
fn rec709_linear(v:vec3f)->vec3f { return select(pow(abs((v+0.099)/1.099),vec3f(1.0/0.45)),v/4.5,v<vec3f(0.081)); }
fn srgb_linear(v:vec3f)->vec3f { return select(pow(abs((v+0.055)/1.055),vec3f(2.4)),v/12.92,v<=vec3f(0.04045)); }
fn linear_srgb(input:vec3f)->vec3f { let v=max(input,vec3f(0.0));return select(1.055*pow(v,vec3f(1.0/2.4))-0.055,12.92*v,v<=vec3f(0.0031308)); }
fn pq_linear(v:vec3f)->vec3f {
    let m1=2610.0/16384.0;let m2=2523.0/32.0;let c1=3424.0/4096.0;let c2=2413.0/128.0;let c3=2392.0/128.0;
    let p=pow(max(v,vec3f(0.0)),vec3f(1.0/m2));
    return pow(max((p-c1)/(c2-c3*p),vec3f(0.0)),vec3f(1.0/m1));
}
fn hlg_linear(v:vec3f)->vec3f { return select((exp((v-0.55991073)/0.17883277)+0.28466892)/12.0,v*v/3.0,v<=vec3f(0.5)); }
fn hdr_sdr(lin:vec3f)->vec3f {
    let peak=select(1000.0,10000.0,u.transfer_mode==3u); let nits=lin*peak;
    if(u.hdr_tone_map==0u){return clamp(nits/100.0,vec3f(0.0),vec3f(1.0));}
    let l=max(dot(nits,vec3f(0.2627,0.6780,0.0593)),0.0);
    if(l<=0.000001){return vec3f(0.0);}
    return clamp(nits*((l/(l+100.0))/l),vec3f(0.0),vec3f(1.0));
}
fn ycbcr_rgb(y:f32,cbcr:vec2f)->vec3f {
    let ten=u.source_mode==2u;
    let code_max=select(255.0,1023.0,ten);let y_min=select(16.0,64.0,ten);let y_range=select(219.0,876.0,ten);
    let c_mid=select(128.0,512.0,ten);let c_range=select(224.0,896.0,ten);
    var Y=y;var C=cbcr-0.5;
    if(u.range_mode==0u){Y=(y-y_min/code_max)*(code_max/y_range);C=(cbcr-c_mid/code_max)*(code_max/c_range);}
    var rgb=vec3f(Y+1.5748*C.y,Y-0.187324*C.x-0.468124*C.y,Y+1.8556*C.x);
    if(u.matrix_mode==1u){rgb=vec3f(Y+1.402*C.y,Y-0.344136*C.x-0.714136*C.y,Y+1.772*C.x);}
    if(u.matrix_mode==2u){rgb=vec3f(Y+1.4746*C.y,Y-0.164553*C.x-0.571353*C.y,Y+1.8814*C.x);}
    return clamp(rgb,vec3f(0.0),vec3f(1.0));
}
fn grade(input:vec4f)->vec4f {
    var color=input;
    if(u.source_mode==3u){
        var lin=max(color.rgb,vec3f(0.0));
        if(u.hdr_tone_map==1u){lin=lin/(1.0+lin);}
        color=vec4f(linear_srgb(clamp(lin,vec3f(0.0),vec3f(1.0))),1.0);
    }
    if(u.source_mode==4u){color=vec4f(linear_srgb(clamp(color.rgb,vec3f(0.0),vec3f(1.0))),color.a);}
    if(u.source_lut_enabled==1u){color=vec4f(cube_source(color.rgb),color.a);}
    if(u.lut_enabled==1u){color=vec4f(cube_lut(color.rgb),color.a);}
    return color;
}
@fragment fn post_fs(@builtin(position) pos:vec4f)->@location(0) vec4f {
    let uv=pos.xy/vec2f(textureDimensions(source0));
    var color=textureSampleLevel(source0,point_sampler,uv,0.0);
    if(u.source_mode==1u || u.source_mode==2u){
        let ten=select(1.0,65535.0/65472.0,u.source_mode==2u);
        let encoded=ycbcr_rgb(color.r*ten,textureSampleLevel(source1,linear_sampler,uv,0.0).rg*ten);
        var lin=rec709_linear(encoded);
        if(u.transfer_mode==1u){lin=srgb_linear(encoded);}else if(u.transfer_mode==2u){lin=encoded;}
        else if(u.transfer_mode==3u){lin=pq_linear(encoded);}else if(u.transfer_mode==4u){lin=hlg_linear(encoded);}
        if(u.transfer_mode==3u || u.transfer_mode==4u){lin=hdr_sdr(lin);}
        color=vec4f(linear_srgb(lin),1.0);
    }
    return grade(color);
}
@fragment fn post_external_fs(@builtin(position) pos:vec4f)->@location(0) vec4f {
    let uv=pos.xy/vec2f(textureDimensions(external_source));
    return grade(clamp(textureSampleBaseClampToEdge(external_source,linear_sampler,uv),vec4f(0.0),vec4f(1.0)));
}
