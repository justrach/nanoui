//! An extended (scRGB) Direct3D 11 frame (`d3d11_hdr.zig`): drawn into a
//! half-float target as an HDR swap chain's back buffer is, the UI decoded
//! and scaled to SDR white, a `.surface_linear` texture in the plane under
//! it, values above white kept. Links everywhere; runs on Windows (and skips
//! where there is no Direct3D 11 renderer, as `tests_d3d11.zig`'s do).
const std = @import("std");
const testing = std.testing;
const gpu = @import("gpu.zig");
const api = @import("d3d11_glue.zig");
const d3d11 = @import("d3d11.zig");
const d3d11_hdr = @import("d3d11_hdr.zig");
const base = @import("tests_d3d11.zig");

const Com = api.Com;
const HRESULT = api.HRESULT;
const W = 32;
const H = 16;

fn srgbEotf(c: f32) f32 {
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

/// An RGBA16F texture of `w` × `h` texels of `v`, or a render target.
fn halfTexture(device: *Com, w: u32, h: u32, v: [4]f32, bind: u32) !*Com {
    var px: [W * H * 4]f16 = undefined;
    for (0..w * h) |i| for (0..4) |k| {
        px[i * 4 + k] = @floatCast(v[k]);
    };
    const Data = extern struct { mem: *const anyopaque, pitch: u32, slice: u32 = 0 };
    const data: Data = .{ .mem = &px, .pitch = w * 8 };
    const desc: api.Texture2DDesc = .{ .width = w, .height = h, .format = d3d11_hdr.rgba16f, .bind = bind };
    var tex: ?*Com = null;
    try api.must(device.slot(*const fn (*Com, *const api.Texture2DDesc, ?*const Data, *?*Com) callconv(.winapi) HRESULT, api.CreateTexture2D)(device, &desc, &data, &tex), "CreateTexture2D(test half)");
    return tex.?;
}

/// `tex`'s `W` × `H` half floats, read back as floats.
fn readHalf(r: *d3d11.Renderer, tex: *Com) ![W * H * 4]f32 {
    const sd: api.Texture2DDesc = .{ .width = W, .height = H, .format = d3d11_hdr.rgba16f, .usage = api.usage_staging, .cpu = api.cpu_read };
    var staging: ?*Com = null;
    try api.must(r.device.slot(*const fn (*Com, *const api.Texture2DDesc, ?*const anyopaque, *?*Com) callconv(.winapi) HRESULT, api.CreateTexture2D)(r.device, &sd, null, &staging), "CreateTexture2D(staging)");
    defer staging.?.release();
    const g = r.context;
    g.slot(*const fn (*Com, *Com, *Com) callconv(.winapi) void, api.CopyResource)(g, staging.?, tex);
    var mapped: api.Mapped = undefined;
    try api.must(g.slot(*const fn (*Com, *Com, u32, u32, u32, *api.Mapped) callconv(.winapi) HRESULT, api.Map)(g, staging.?, 0, api.map_read, 0, &mapped), "Map(staging)");
    defer g.slot(*const fn (*Com, *Com, u32) callconv(.winapi) void, api.Unmap)(g, staging.?, 0);
    var out: [W * H * 4]f32 = undefined;
    for (0..H) |y| {
        const row: [*]const f16 = @ptrCast(@alignCast(mapped.data + y * mapped.row_pitch));
        for (0..W * 4) |i| out[y * W * 4 + i] = row[i];
    }
    return out;
}

test "d3d11 HDR: opaque UI composes to its codes' EOTF times SDR white, a linear texture keeps values above white" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var maybe = try base.renderer();
    if (maybe == null) return error.SkipZigTest;
    const r = &maybe.?;
    defer r.deinit();
    const v: [4]f32 = .{ 4.0, 0.5, 9.0, 1 };
    const src = try halfTexture(r.device, 8, 8, v, api.bind_shader_resource);
    defer src.release();
    const target = try halfTexture(r.device, W, H, .{ 0, 0, 0, 0 }, api.bind_render_target | api.bind_shader_resource);
    defer target.release();
    const textures = [_]gpu.Texture{.{ .width = 8, .height = 8, .d3d11_texture = @ptrCast(src), .format = .rgba16f, .encoding = .surface_linear }};
    r.textures = &textures;
    const frame = [_]gpu.Instance{
        .{ .rect = .{ 0, 0, W, H }, .color = .{ 0.6, 0.6, 0.6, 1 } },
        .{ .rect = .{ 16, 0, 16, 16 }, .color = .{ 1, 1, 1, 1 }, .uv = .{ 0, 0, 1, 1 }, .kind = gpu.Kind.texture },
    };
    r.extended = true;
    r.sdr_white_scale = 2.5;
    r.draw(&frame, .{ .w = W, .h = H }, 1, .{ .r = 0, .g = 0, .b = 0, .a = 1 }, target);
    const out = try readHalf(r, target);
    const ui_lin = 2.5 * srgbEotf(153.0 / 255.0);
    // The UI: decoded, times k.
    try testing.expectApproxEqAbs(ui_lin, out[(4 * W + 4) * 4], 4e-3 * ui_lin);
    // The texture, in the plane: as it is, above white.
    for (0..3) |c| try testing.expectApproxEqAbs(v[c], out[(8 * W + 24) * 4 + c], 4e-3 * v[c]);
}
