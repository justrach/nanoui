//! Direct3D 11's vocabulary as Zig sees it: the COM calls, the constants
//! and the descriptors, each laid out as `d3d11.h` declares it, with the
//! sizes checked at compile time. `d3d11.zig` draws the frame with them.
const std = @import("std");

pub const HRESULT = i32;
pub const Guid = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
pub const iid_texture2d: Guid = .{ .a = 0x6f15aaf2, .b = 0xd208, .c = 0x4e89, .d = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c } };

/// DXGI_FORMAT_B8G8R8A8_UNORM: what the frame and the pictures are in.
pub const bgra8: u32 = 87;
/// DXGI_FORMAT_R8_UNORM: the glyph atlas' coverage.
pub const r8_unorm: u32 = 61;

// D3D11_BIND_*, D3D11_USAGE_*, D3D11_CPU_ACCESS_*, D3D11_MAP_*.
pub const bind_constant: u32 = 0x4;
pub const bind_shader_resource: u32 = 0x8;
pub const bind_render_target: u32 = 0x20;
pub const usage_default: u32 = 0;
pub const usage_dynamic: u32 = 2;
pub const usage_staging: u32 = 3;
pub const cpu_write: u32 = 0x10000;
pub const cpu_read: u32 = 0x20000;
pub const map_read: u32 = 1;
pub const map_write_discard: u32 = 4;
pub const misc_structured: u32 = 0x40;
pub const srv_buffer: u32 = 1;

// D3D11_FILL_SOLID, D3D11_CULL_NONE, D3D11_BLEND_*, D3D11_BLEND_OP_ADD,
// D3D11_FILTER_MIN_MAG_MIP_LINEAR, D3D11_TEXTURE_ADDRESS_CLAMP,
// D3D11_COMPARISON_ALWAYS, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP.
pub const fill_solid: u32 = 3;
pub const cull_none: u32 = 1;
pub const blend_one: u32 = 2;
pub const blend_inv_src_alpha: u32 = 6;
pub const blend_op_add: u32 = 1;
pub const filter_linear: u32 = 0x15;
pub const address_clamp: u32 = 3;
pub const comparison_always: u32 = 8;
pub const topology_strip: u32 = 5;
pub const sdk_version: u32 = 7;
pub const bgra_support: u32 = 0x20;

// ID3D11DeviceContext's slots, in the header's declaration order.
pub const VSSetConstantBuffers = 7;
pub const PSSetShaderResources = 8;
pub const PSSetShader = 9;
pub const PSSetSamplers = 10;
pub const VSSetShader = 11;
pub const Draw = 13;
pub const Map = 14;
pub const Unmap = 15;
pub const PSSetConstantBuffers = 16;
pub const IASetInputLayout = 17;
pub const DrawInstanced = 21;
pub const IASetPrimitiveTopology = 24;
pub const VSSetShaderResources = 25;
pub const OMSetRenderTargets = 33;
pub const OMSetBlendState = 35;
pub const RSSetState = 43;
pub const RSSetViewports = 44;
pub const CopySubresourceRegion = 46;
pub const CopyResource = 47;
pub const UpdateSubresource = 48;
pub const ClearRenderTargetView = 50;
// ID3D11Device's.
pub const CreateBuffer = 3;
pub const CreateTexture2D = 5;
pub const CreateShaderResourceView = 7;
pub const CreateRenderTargetView = 9;
pub const CreateVertexShader = 12;
pub const CreatePixelShader = 15;
pub const CreateBlendState = 20;
pub const CreateRasterizerState = 22;
pub const CreateSamplerState = 23;

/// A COM object: its first field points at its vtable.
pub const Com = extern struct {
    vtable: [*]const *const anyopaque,

    pub fn slot(c: *Com, comptime T: type, i: usize) T {
        return @ptrCast(@alignCast(c.vtable[i]));
    }

    pub fn release(c: *Com) void {
        _ = c.slot(*const fn (*Com) callconv(.winapi) u32, 2)(c);
    }
};

pub extern "d3d11" fn D3D11CreateDevice(adapter: ?*anyopaque, driver: u32, software: ?*anyopaque, flags: u32, levels: ?[*]const u32, n_levels: u32, sdk: u32, device: *?*Com, level: ?*u32, context: *?*Com) callconv(.winapi) HRESULT;
pub extern "d3dcompiler_47" fn D3DCompile(src: [*]const u8, len: usize, name: ?[*:0]const u8, defines: ?*const anyopaque, include: ?*anyopaque, entry: [*:0]const u8, target: [*:0]const u8, flags1: u32, flags2: u32, code: *?*Blob, errors: *?*Blob) callconv(.winapi) HRESULT;

/// A compiled shader, as `D3DCompile` gives it.
pub const Blob = extern struct {
    vtable: [*]const *const anyopaque,

    pub fn bytes(b: *Blob) [*]const u8 {
        return @as(*const fn (*Blob) callconv(.winapi) [*]const u8, @ptrCast(@alignCast(b.vtable[3])))(b);
    }

    pub fn size(b: *Blob) usize {
        return @as(*const fn (*Blob) callconv(.winapi) usize, @ptrCast(@alignCast(b.vtable[4])))(b);
    }

    pub fn release(b: *Blob) void {
        _ = @as(*const fn (*Blob) callconv(.winapi) u32, @ptrCast(@alignCast(b.vtable[2])))(b);
    }
};

comptime {
    // The SDK's sizes, so a wrong field or a short union fails the build
    // rather than reading past the end of a struct at run time.
    std.debug.assert(@sizeOf(Texture2DDesc) == 44);
    std.debug.assert(@sizeOf(BufferDesc) == 24);
    std.debug.assert(@sizeOf(SrvDesc) == 24);
    std.debug.assert(@sizeOf(Mapped) == 16);
    std.debug.assert(@sizeOf(Viewport) == 24);
    std.debug.assert(@sizeOf(BlendDesc) == 264);
    std.debug.assert(@sizeOf(RasterizerDesc) == 40);
    std.debug.assert(@sizeOf(SamplerDesc) == 52);
    std.debug.assert(@sizeOf(Params) == 80);
}

pub fn check(hr: HRESULT) !void {
    if (hr < 0) {
        std.log.err("nanoui: Direct3D failed: 0x{x:0>8}", .{@as(u32, @bitCast(hr))});
        return error.Direct3D;
    }
}

/// `check`, naming the call that failed.
pub fn must(hr: HRESULT, comptime what: []const u8) !void {
    if (hr < 0) {
        std.log.err("nanoui: Direct3D {s} failed: 0x{x:0>8}", .{ what, @as(u32, @bitCast(hr)) });
        return error.Direct3D;
    }
}

pub const Texture2DDesc = extern struct {
    width: u32,
    height: u32,
    mips: u32 = 1,
    array: u32 = 1,
    format: u32 = bgra8,
    sample_count: u32 = 1,
    sample_quality: u32 = 0,
    usage: u32 = 0,
    bind: u32 = 0,
    cpu: u32 = 0,
    misc: u32 = 0,
};

pub const BufferDesc = extern struct {
    byte_width: u32,
    usage: u32 = usage_dynamic,
    bind: u32,
    cpu: u32 = cpu_write,
    misc: u32 = 0,
    stride: u32 = 0,
};

/// D3D11_SHADER_RESOURCE_VIEW_DESC. Its union is as wide as
/// D3D11_TEXCUBE_ARRAY_SRV's four UINTs, so the struct is 24 bytes, not the
/// 16 a buffer view alone needs: a short one is read past its end.
pub const SrvDesc = extern struct {
    format: u32 = 0,
    dimension: u32,
    first: u32 = 0,
    count: u32,
    pad: [2]u32 = .{ 0, 0 },
};

pub const Mapped = extern struct { data: [*]u8, row_pitch: u32, depth_pitch: u32 };

pub const Viewport = extern struct { x: f32 = 0, y: f32 = 0, w: f32, h: f32, min_z: f32 = 0, max_z: f32 = 1 };

/// D3D11_BOX: the texels a subresource copy moves, right and bottom exclusive.
pub const Box = extern struct { left: u32 = 0, top: u32 = 0, front: u32 = 0, right: u32, bottom: u32, back: u32 = 1 };

pub const RenderTargetBlend = extern struct {
    enable: i32 = 1,
    src: u32 = blend_one,
    dst: u32 = blend_inv_src_alpha,
    op: u32 = blend_op_add,
    src_alpha: u32 = blend_one,
    dst_alpha: u32 = blend_inv_src_alpha,
    op_alpha: u32 = blend_op_add,
    write_mask: u8 = 0xf,
    pad: [3]u8 = .{ 0, 0, 0 },
};

pub const BlendDesc = extern struct {
    alpha_to_coverage: i32 = 0,
    independent: i32 = 0,
    targets: [8]RenderTargetBlend = @splat(.{}),
};

pub const RasterizerDesc = extern struct {
    fill: u32 = fill_solid,
    cull: u32 = cull_none,
    front_ccw: i32 = 0,
    depth_bias: i32 = 0,
    depth_bias_clamp: f32 = 0,
    slope_scaled_depth_bias: f32 = 0,
    depth_clip: i32 = 1,
    scissor: i32 = 0,
    multisample: i32 = 0,
    antialiased_line: i32 = 0,
};

pub const SamplerDesc = extern struct {
    filter: u32 = filter_linear,
    address_u: u32 = address_clamp,
    address_v: u32 = address_clamp,
    address_w: u32 = address_clamp,
    mip_lod_bias: f32 = 0,
    max_anisotropy: u32 = 1,
    comparison: u32 = comparison_always,
    border: [4]f32 = .{ 0, 0, 0, 0 },
    min_lod: f32 = 0,
    max_lod: f32 = std.math.inf(f32),
};

/// The constants every shader reads, as `shader.hlsl`'s one cbuffer: the
/// viewport in points, the scale, and the glass and pass parameters. The
/// members are laid out so that none straddles a 16-byte boundary.
pub const Params = extern struct {
    viewport: [2]f32 = .{ 0, 0 },
    scale: f32 = 1,
    down: f32 = 1,
    origin: [2]f32 = .{ 0, 0 },
    size: [2]f32 = .{ 0, 0 },
    area: [4]i32 = .{ 0, 0, 0, 0 },
    frame_height: i32 = 0,
    radius: i32 = 0,
    sigma: f32 = 0,
    pad0: f32 = 0,
    dir: [2]i32 = .{ 0, 0 },
    /// The first instance this draw reads: `SV_InstanceID` starts at 0, and
    /// DrawInstanced's StartInstanceLocation only offsets vertex-buffer reads,
    /// so the offset is added here, in the shader.
    start_instance: i32 = 0,
    pad1: i32 = 0,
};

/// The size a texture is made at to hold a `want`-tall or -wide frame that the
/// last one of `had` did not: a quarter more, so a drag-resize passes many
/// sizes before the texture is remade again. Stepping by a fixed number of
/// pixels would remake it at every step of a drag; stepping by a share of it
/// keeps the number of remakes logarithmic.
fn stepSize(want: usize, had: usize) usize {
    const grown = want + want / 4 + 64;
    return if (grown > had) grown else had;
}

/// A texture with the views that draw into it and read it.
pub const Target = struct {
    texture: ?*Com = null,
    rtv: ?*Com = null,
    srv: ?*Com = null,
    w: usize = 0,
    h: usize = 0,

    /// At least `w` × `h` (exactly, when `exact`); a no-op when it already
    /// fits. On failure it stays unusable (`rtv` null, `w` and `h` zero).
    pub fn reserve(t: *Target, device: *Com, w: usize, h: usize, exact: bool) void {
        if (t.texture != null) {
            const fits = if (exact) w == t.w and h == t.h else w <= t.w and h <= t.h;
            // A texture well past what the frame needs is let go: a window
            // dragged huge and then made small would otherwise keep that much
            // video memory for as long as it lives.
            const oversized = !exact and w * 4 < t.w and h * 4 < t.h;
            if (fits and !oversized) return;
        }
        t.deinit();
        // Grown in steps, not to the exact size: a drag resize asks for a few
        // more pixels a frame, and reallocating the texture (with its two views)
        // for each of them is what made a resize stutter. A quarter more than
        // is needed leaves room for the frames that follow. (An oversized
        // texture above was let go on purpose: the next one grows from the
        // need, not from what was just released, or a window held small after
        // being big would remake the big texture every frame.)
        const want_w = if (exact) w else @max(w, t.w);
        const want_h = if (exact) h else @max(h, t.h);
        const tw: u32 = @intCast(if (exact) want_w else stepSize(want_w, t.w));
        const th: u32 = @intCast(if (exact) want_h else stepSize(want_h, t.h));
        if (tw == 0 or th == 0) return;
        const tex = texture2D(device, bgra8, tw, th, bind_render_target | bind_shader_resource) orelse return;
        var rtv: ?*Com = null;
        check(device.slot(*const fn (*Com, *Com, ?*const anyopaque, *?*Com) callconv(.winapi) HRESULT, CreateRenderTargetView)(device, tex, null, &rtv)) catch {
            tex.release();
            return;
        };
        var srv: ?*Com = null;
        check(device.slot(*const fn (*Com, *Com, ?*const anyopaque, *?*Com) callconv(.winapi) HRESULT, CreateShaderResourceView)(device, tex, null, &srv)) catch {
            rtv.?.release();
            tex.release();
            return;
        };
        t.* = .{ .texture = tex, .rtv = rtv, .srv = srv, .w = tw, .h = th };
    }

    pub fn deinit(t: *Target) void {
        if (t.srv) |v| v.release();
        if (t.rtv) |v| v.release();
        if (t.texture) |v| v.release();
        t.* = .{};
    }
};

/// A BGRA8 2D texture of `w` × `h` with `bind`.
pub fn texture2D(device: *Com, format: u32, w: u32, h: u32, bind: u32) ?*Com {
    const desc: Texture2DDesc = .{ .width = w, .height = h, .format = format, .bind = bind };
    var tex: ?*Com = null;
    must(device.slot(*const fn (*Com, *const Texture2DDesc, ?*const anyopaque, *?*Com) callconv(.winapi) HRESULT, CreateTexture2D)(device, &desc, null, &tex), "CreateTexture2D") catch return null;
    return tex;
}

/// Copies `pixels` into a texture, `bpp` bytes a texel, `size` × `size`.
pub fn uploadAtlas(context: *Com, texture: *Com, pixels: []const u8, size: u32, bpp: usize) void {
    const s: usize = size;
    const row = s * bpp;
    if (pixels.len < row * s) return;
    context.slot(*const fn (*Com, *Com, u32, ?*const anyopaque, [*]const u8, u32, u32) callconv(.winapi) void, UpdateSubresource)(context, texture, 0, null, pixels.ptr, @intCast(row), 0);
}

/// A whole-texture shader resource view of `texture`.
pub fn textureSrv(device: *Com, texture: *Com) ?*Com {
    var srv: ?*Com = null;
    must(device.slot(*const fn (*Com, *Com, ?*const anyopaque, *?*Com) callconv(.winapi) HRESULT, CreateShaderResourceView)(device, texture, null, &srv), "textureSrv") catch return null;
    return srv;
}
