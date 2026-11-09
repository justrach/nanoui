//! An app's ID3D11Texture2D in the frame (`Texture.d3d11_texture`: a Media
//! Foundation decoder's NV12 or P010 surface, a BGRA or half-float one):
//! what its format makes it, the colour stage that makes it display BGRA on
//! the GPU (`Post`, running `texture_post.hlsl`: the Metal colour stage's
//! maths), and the CPU's way in (`readBack`: a staging copy, converted by
//! `texture_cpu.zig`), which the CPU renderer draws with and the GPU falls
//! back on where the colour stage can't be compiled (Wine).
const std = @import("std");
const gpu = @import("gpu.zig");
const color = @import("color.zig");
const texture_cpu = @import("texture_cpu.zig");
const api = @import("d3d11_glue.zig");
const d3d11_device = @import("d3d11_device.zig");
const source = @embedFile("texture_post.hlsl");

const Com = api.Com;
const HRESULT = api.HRESULT;

// DXGI_FORMAT_*.
pub const nv12: u32 = 103;
pub const p010: u32 = 104;
pub const rgba16f: u32 = 10;
pub const r8g8_unorm: u32 = 49;
pub const r16_unorm: u32 = 56;
pub const r16g16_unorm: u32 = 35;
const srv_texture2d: u32 = 4;
const topology_list: u32 = 4;
const CreateTexture3D = 6;

/// What a texture of DXGI format `dxgi` holds; null for one nanoui can't draw.
pub fn formatOf(dxgi: u32) ?gpu.Format {
    return switch (dxgi) {
        api.bgra8 => .bgra8,
        nv12 => .ycbcr420_8,
        p010 => .ycbcr420_10,
        rgba16f => .rgba16f,
        else => null,
    };
}

/// `ID3D11Texture2D::GetDesc`.
pub fn describe(tex: *Com) api.Texture2DDesc {
    var d: api.Texture2DDesc = .{ .width = 0, .height = 0 };
    tex.slot(*const fn (*Com, *api.Texture2DDesc) callconv(.winapi) void, 10)(tex, &d);
    return d;
}

/// `t` as the colour stage sees it: the texture's own format, and the size
/// shown (the app's, within the texture; the texture's when it gave none —
/// a decoder's surface may be taller than its picture, 1088 for 1080).
pub fn effective(t: gpu.Texture, d: api.Texture2DDesc) gpu.Texture {
    var e = t;
    e.format = formatOf(d.format) orelse t.format;
    e.width = if (t.width > 0) @min(t.width, d.width) else d.width;
    e.height = if (t.height > 0) @min(t.height, d.height) else d.height;
    return e;
}

/// Whether the subresource exists and the texture can be drawn at all.
pub fn usable(t: gpu.Texture, d: api.Texture2DDesc) bool {
    return formatOf(d.format) != null and t.subresource < d.array * @max(d.mips, 1) and d.sample_count <= 1 and d.width > 0 and d.height > 0;
}

/// The copy's box: the shown size, even for the planar formats (their
/// chroma is a texel to two).
fn copyBox(e: gpu.Texture, d: api.Texture2DDesc) api.Box {
    var w = e.width;
    var h = e.height;
    if (d.format == nv12 or d.format == p010) {
        w = @min((w + 1) & ~@as(u32, 1), d.width);
        h = @min((h + 1) & ~@as(u32, 1), d.height);
    }
    return .{ .right = w, .bottom = h };
}

fn copy(ctx: *Com, dst: *Com, src: *Com, sub: u32, box: *const api.Box) void {
    ctx.slot(*const fn (*Com, *Com, u32, u32, u32, u32, *Com, u32, ?*const api.Box) callconv(.winapi) void, api.CopySubresourceRegion)(ctx, dst, 0, 0, 0, 0, src, sub, box);
}

/// The texture's pixels on the CPU, through a staging copy on its own
/// device, converted as the colour stage converts them. Null when it can't
/// be read.
pub fn readBack(gpa: std.mem.Allocator, t: gpu.Texture) ?texture_cpu.Held {
    const tex: *Com = @ptrCast(@alignCast(t.d3d11_texture orelse return null));
    const d = describe(tex);
    if (!usable(t, d)) return null;
    const e = effective(t, d);
    const device = d3d11_device.deviceOf(tex) orelse return null;
    const ctx = d3d11_device.contextOf(device);
    const box = copyBox(e, d);
    const sd: api.Texture2DDesc = .{ .width = box.right, .height = box.bottom, .format = d.format, .usage = api.usage_staging, .cpu = api.cpu_read };
    var staging: ?*Com = null;
    api.must(device.slot(*const fn (*Com, *const api.Texture2DDesc, ?*const anyopaque, *?*Com) callconv(.winapi) HRESULT, api.CreateTexture2D)(device, &sd, null, &staging), "CreateTexture2D(read back)") catch return null;
    defer staging.?.release();
    copy(ctx, staging.?, tex, t.subresource, &box);
    var mapped: api.Mapped = undefined;
    api.must(ctx.slot(*const fn (*Com, *Com, u32, u32, u32, *api.Mapped) callconv(.winapi) HRESULT, api.Map)(ctx, staging.?, 0, api.map_read, 0, &mapped), "Map(read back)") catch return null;
    defer ctx.slot(*const fn (*Com, *Com, u32) callconv(.winapi) void, api.Unmap)(ctx, staging.?, 0);
    const pitch: usize = mapped.row_pitch;
    const p0: texture_cpu.Plane = .{ .bytes = mapped.data, .width = e.width, .height = e.height, .stride = pitch };
    // A planar texture's chroma follows its luma, a row pitch apart.
    const p1: ?texture_cpu.Plane = if (d.format == nv12 or d.format == p010) .{ .bytes = mapped.data + pitch * box.bottom, .width = (e.width + 1) / 2, .height = (e.height + 1) / 2, .stride = pitch } else null;
    return texture_cpu.fromPlanes(gpa, e, p0, p1);
}

/// A copy of the app's subresource the colour stage can read (a decoder's
/// surfaces are made for decoding, not sampling), with its plane views:
/// luma and chroma for NV12 (R8, R8G8) and P010 (R16, R16G16), the whole
/// texture otherwise.
pub const Source = struct {
    tex: ?*Com = null,
    views: [2]?*Com = .{ null, null },
    format: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,

    pub fn deinit(s: *Source) void {
        for (s.views) |v| if (v) |x| x.release();
        if (s.tex) |t| t.release();
        s.* = .{};
    }

    /// The copy of `src`'s subresource `sub`, its `box`, made now.
    pub fn take(s: *Source, device: *Com, ctx: *Com, src: *Com, sub: u32, format: u32, box: api.Box) bool {
        if (s.tex == null or s.format != format or s.w != box.right or s.h != box.bottom) {
            s.deinit();
            const desc: api.Texture2DDesc = .{ .width = box.right, .height = box.bottom, .format = format, .bind = api.bind_shader_resource };
            var tex: ?*Com = null;
            if (device.slot(*const fn (*Com, *const api.Texture2DDesc, ?*const anyopaque, *?*Com) callconv(.winapi) HRESULT, api.CreateTexture2D)(device, &desc, null, &tex) < 0) return false;
            s.* = .{ .tex = tex, .format = format, .w = box.right, .h = box.bottom };
            const planes: [2]u32 = switch (format) {
                nv12 => .{ api.r8_unorm, r8g8_unorm },
                p010 => .{ r16_unorm, r16g16_unorm },
                else => .{ 0, 0 },
            };
            const n: usize = if (planes[0] == 0) 1 else 2;
            for (0..n) |k| {
                const sd: api.SrvDesc = .{ .format = planes[k], .dimension = srv_texture2d, .first = 0, .count = 1 };
                var v: ?*Com = null;
                if (device.slot(*const fn (*Com, *Com, ?*const api.SrvDesc, *?*Com) callconv(.winapi) HRESULT, api.CreateShaderResourceView)(device, tex.?, if (n == 1) null else &sd, &v) < 0) {
                    s.deinit();
                    return false;
                }
                s.views[k] = v;
            }
        }
        copy(ctx, s.tex.?, src, sub, &box);
        return true;
    }
};

const Texture3DDesc = extern struct {
    width: u32,
    height: u32,
    depth: u32,
    mips: u32 = 1,
    format: u32 = rgba16f,
    usage: u32 = 1, // D3D11_USAGE_IMMUTABLE
    bind: u32 = api.bind_shader_resource,
    cpu: u32 = 0,
    misc: u32 = 0,
};
const SubresourceData = extern struct { mem: *const anyopaque, pitch: u32, slice: u32 };

comptime {
    std.debug.assert(@sizeOf(Texture3DDesc) == 36);
    std.debug.assert(@sizeOf(color.Uniforms) % 16 == 0);
}

/// A LUT's GPU copy, made once per key.
const LutEntry = struct { key: u64 = 0, tex: ?*Com = null, srv: ?*Com = null };

/// The colour stage: `texture_post.hlsl` drawn over a slot's target, one
/// triangle covering it.
pub const Post = struct {
    vs: *Com,
    ps: *Com,
    cb: *Com,
    point: *Com,
    linear: *Com,
    rasterizer: *Com,
    luts: [4]LutEntry = @splat(.{}),
    next_lut: usize = 0,

    pub fn init(device: *Com) !Post {
        const vs = try api.shaderFrom(device, source, "texture_post.hlsl", "alc_post_vs", "vs_5_0", api.CreateVertexShader);
        errdefer vs.release();
        const ps = try api.shaderFrom(device, source, "texture_post.hlsl", "alc_post_ps", "ps_5_0", api.CreatePixelShader);
        errdefer ps.release();
        var cb: ?*Com = null;
        const bd: api.BufferDesc = .{ .byte_width = @sizeOf(color.Uniforms), .bind = api.bind_constant };
        try api.must(device.slot(*const fn (*Com, *const api.BufferDesc, ?*const anyopaque, *?*Com) callconv(.winapi) HRESULT, api.CreateBuffer)(device, &bd, null, &cb), "CreateBuffer(post)");
        errdefer cb.?.release();
        var point: ?*Com = null;
        const pd: api.SamplerDesc = .{ .filter = 0 }; // D3D11_FILTER_MIN_MAG_MIP_POINT
        try api.must(device.slot(*const fn (*Com, *const api.SamplerDesc, *?*Com) callconv(.winapi) HRESULT, api.CreateSamplerState)(device, &pd, &point), "CreateSamplerState(point)");
        errdefer point.?.release();
        var linear: ?*Com = null;
        const ld: api.SamplerDesc = .{};
        try api.must(device.slot(*const fn (*Com, *const api.SamplerDesc, *?*Com) callconv(.winapi) HRESULT, api.CreateSamplerState)(device, &ld, &linear), "CreateSamplerState(linear)");
        errdefer linear.?.release();
        var rs: ?*Com = null;
        const rd: api.RasterizerDesc = .{};
        try api.must(device.slot(*const fn (*Com, *const api.RasterizerDesc, *?*Com) callconv(.winapi) HRESULT, api.CreateRasterizerState)(device, &rd, &rs), "CreateRasterizerState(post)");
        return .{ .vs = vs, .ps = ps, .cb = cb.?, .point = point.?, .linear = linear.?, .rasterizer = rs.? };
    }

    pub fn deinit(p: *Post) void {
        for (&p.luts) |*l| releaseLut(l);
        for ([_]*Com{ p.vs, p.ps, p.cb, p.point, p.linear, p.rasterizer }) |c| c.release();
    }

    fn releaseLut(l: *LutEntry) void {
        if (l.srv) |v| v.release();
        if (l.tex) |t| t.release();
        l.* = .{};
    }

    /// The view of `l`'s 3D texture, made the first time its key is seen.
    fn lutView(p: *Post, device: *Com, l: gpu.Lut) ?*Com {
        if (!l.valid()) return null;
        for (p.luts) |e| if (e.key == l.key and e.srv != null) return e.srv;
        const slot = &p.luts[p.next_lut];
        p.next_lut = (p.next_lut + 1) % p.luts.len;
        releaseLut(slot);
        const n: u32 = l.size;
        const desc: Texture3DDesc = .{ .width = n, .height = n, .depth = n };
        const data: SubresourceData = .{ .mem = l.data.ptr, .pitch = n * 8, .slice = n * n * 8 };
        var tex: ?*Com = null;
        api.must(device.slot(*const fn (*Com, *const Texture3DDesc, ?*const SubresourceData, *?*Com) callconv(.winapi) HRESULT, CreateTexture3D)(device, &desc, &data, &tex), "CreateTexture3D(LUT)") catch return null;
        const srv = api.textureSrv(device, tex.?) orelse {
            tex.?.release();
            return null;
        };
        slot.* = .{ .key = l.key, .tex = tex, .srv = srv };
        return srv;
    }

    /// `t` (its effective format) from `src`'s views into `rtv`, `w` × `h`.
    pub fn run(p: *Post, device: *Com, ctx: *Com, t: gpu.Texture, src: *const Source, rtv: *Com, w: u32, h: u32) void {
        const u = color.uniforms(t, color.sourceMode(t.format));
        var mapped: api.Mapped = undefined;
        if (ctx.slot(*const fn (*Com, *Com, u32, u32, u32, *api.Mapped) callconv(.winapi) HRESULT, api.Map)(ctx, p.cb, 0, api.map_write_discard, 0, &mapped) < 0) return;
        @memcpy(mapped.data[0..@sizeOf(color.Uniforms)], std.mem.asBytes(&u));
        ctx.slot(*const fn (*Com, *Com, u32) callconv(.winapi) void, api.Unmap)(ctx, p.cb, 0);
        const lut = if (t.lut) |l| p.lutView(device, l) else null;
        const src_lut = if (t.source_lut) |l| p.lutView(device, l) else null;
        var vp = [1]api.Viewport{.{ .w = @floatFromInt(w), .h = @floatFromInt(h) }};
        ctx.slot(*const fn (*Com, u32, [*]const api.Viewport) callconv(.winapi) void, api.RSSetViewports)(ctx, 1, &vp);
        var rt = [1]?*Com{rtv};
        ctx.slot(*const fn (*Com, u32, [*]const ?*Com, ?*anyopaque) callconv(.winapi) void, api.OMSetRenderTargets)(ctx, 1, &rt, null);
        ctx.slot(*const fn (*Com, ?*Com, ?*const [4]f32, u32) callconv(.winapi) void, api.OMSetBlendState)(ctx, null, &[4]f32{ 0, 0, 0, 0 }, 0xffffffff);
        ctx.slot(*const fn (*Com, ?*Com) callconv(.winapi) void, api.RSSetState)(ctx, p.rasterizer);
        ctx.slot(*const fn (*Com, ?*Com) callconv(.winapi) void, api.IASetInputLayout)(ctx, null);
        ctx.slot(*const fn (*Com, u32) callconv(.winapi) void, api.IASetPrimitiveTopology)(ctx, topology_list);
        ctx.slot(*const fn (*Com, ?*Com, ?*const anyopaque, u32) callconv(.winapi) void, api.VSSetShader)(ctx, p.vs, null, 0);
        ctx.slot(*const fn (*Com, ?*Com, ?*const anyopaque, u32) callconv(.winapi) void, api.PSSetShader)(ctx, p.ps, null, 0);
        var cbs = [1]?*Com{p.cb};
        ctx.slot(*const fn (*Com, u32, u32, [*]const ?*Com) callconv(.winapi) void, api.PSSetConstantBuffers)(ctx, 0, 1, &cbs);
        var views = [4]?*Com{ src.views[0], src.views[1], lut, src_lut };
        ctx.slot(*const fn (*Com, u32, u32, [*]const ?*Com) callconv(.winapi) void, api.PSSetShaderResources)(ctx, 0, 4, &views);
        var samplers = [3]?*Com{ p.point, p.linear, p.linear };
        ctx.slot(*const fn (*Com, u32, u32, [*]const ?*Com) callconv(.winapi) void, api.PSSetSamplers)(ctx, 0, 3, &samplers);
        ctx.slot(*const fn (*Com, u32, u32) callconv(.winapi) void, api.Draw)(ctx, 3, 0);
        // Unbound again: next frame the copy writes the source, and the
        // frame samples the target.
        var none = [4]?*Com{ null, null, null, null };
        ctx.slot(*const fn (*Com, u32, u32, [*]const ?*Com) callconv(.winapi) void, api.PSSetShaderResources)(ctx, 0, 4, &none);
        var no_rt = [1]?*Com{null};
        ctx.slot(*const fn (*Com, u32, [*]const ?*Com, ?*anyopaque) callconv(.winapi) void, api.OMSetRenderTargets)(ctx, 1, &no_rt, null);
    }
};

/// A copy of `src`'s subresource into `dst` (BGRA, the slot's), `box` of it.
pub fn copyBgra(ctx: *Com, dst: *Com, src: *Com, sub: u32, box: api.Box) void {
    copy(ctx, dst, src, sub, &box);
}

pub const boxOf = copyBox;

test "a texture's DXGI format says what it holds" {
    try std.testing.expectEqual(gpu.Format.ycbcr420_8, formatOf(nv12).?);
    try std.testing.expectEqual(gpu.Format.ycbcr420_10, formatOf(p010).?);
    try std.testing.expectEqual(gpu.Format.bgra8, formatOf(api.bgra8).?);
    try std.testing.expect(formatOf(28) == null);
    const d: api.Texture2DDesc = .{ .width = 1920, .height = 1088, .format = nv12, .array = 8 };
    const e = effective(.{ .width = 1920, .height = 1080, .subresource = 3 }, d);
    try std.testing.expectEqual(gpu.Format.ycbcr420_8, e.format);
    try std.testing.expectEqual(@as(u32, 1080), e.height);
    try std.testing.expect(usable(.{ .width = 0, .height = 0, .subresource = 7 }, d));
    try std.testing.expect(!usable(.{ .width = 0, .height = 0, .subresource = 8 }, d));
    const odd = copyBox(.{ .width = 1279, .height = 719 }, d);
    try std.testing.expectEqual(@as(u32, 1280), odd.right);
    try std.testing.expectEqual(@as(u32, 720), odd.bottom);
}
