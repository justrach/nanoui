//! An extended (scRGB) Direct3D 11 frame (`Surface.setColour`,
//! `d3d.zig`'s FP16 swap chain), as `metal_hdr.zig` draws one on Metal: the
//! UI is drawn as ever into the renderer's own BGRA8 frame, a hole cut in it
//! for each `.surface_linear` texture; those textures go into a half-float
//! plane (`plane_ps`); then `hdr_compose_ps` (hdr.hlsl) writes the back
//! buffer: the UI decoded to linear light and scaled to SDR white
//! (`Renderer.sdr_white_scale`, SDRWhiteLevel / 1000), the plane under it.
//! Made the first time a frame is drawn extended.
const std = @import("std");
const gpu = @import("gpu.zig");
const types = @import("types.zig");
const api = @import("d3d11_glue.zig");
const d3d11 = @import("d3d11.zig");
const Renderer = d3d11.Renderer;
const Com = api.Com;
const HRESULT = api.HRESULT;

/// DXGI_FORMAT_R16G16B16A16_FLOAT: the plane and an extended back buffer.
pub const rgba16f: u32 = 10;

/// hdr.hlsl's `Hdr` cbuffer (b1).
const Constants = extern struct { scale: f32, plane: f32, pad: [2]f32 = .{ 0, 0 } };

pub const Hdr = struct {
    plane_ps: ?*Com = null,
    compose_ps: ?*Com = null,
    /// Cuts a texture's shape out of the UI: zero over, the UI kept by the
    /// inverse of its coverage.
    hole_blend: ?*Com = null,
    constants: ?*Com = null,
    plane: api.Target = .{ .format = rgba16f },

    pub fn deinit(h: *Hdr) void {
        if (h.plane_ps) |x| x.release();
        if (h.compose_ps) |x| x.release();
        if (h.hole_blend) |x| x.release();
        if (h.constants) |x| x.release();
        h.plane.deinit();
        h.* = .{};
    }

    /// The shaders and states, made once (their bytecode cached where the
    /// renderer's other shaders are).
    pub fn ensure(h: *Hdr, r: *Renderer) !void {
        if (h.compose_ps != null) return;
        const dev = r.device;
        const cache_root: ?[]const u8 = if (r.cache_root_len > 0) r.cache_root_buf[0..r.cache_root_len] else null;
        const plane = try api.shaderFrom(dev, d3d11.source, "shader.hlsl", "plane_ps", "ps_5_0", api.CreatePixelShader, cache_root);
        errdefer plane.release();
        const compose = try api.shaderFrom(dev, d3d11.source, "shader.hlsl", "hdr_compose_ps", "ps_5_0", api.CreatePixelShader, cache_root);
        errdefer compose.release();
        var bd: api.BlendDesc = .{};
        bd.targets[0].src = api.blend_zero;
        bd.targets[0].src_alpha = api.blend_zero;
        var blend: ?*Com = null;
        try api.check(dev.slot(*const fn (*Com, *const api.BlendDesc, *?*Com) callconv(.winapi) HRESULT, api.CreateBlendState)(dev, &bd, &blend));
        errdefer blend.?.release();
        const cb: api.BufferDesc = .{ .byte_width = @sizeOf(Constants), .bind = api.bind_constant };
        var constants: ?*Com = null;
        try api.check(dev.slot(*const fn (*Com, *const api.BufferDesc, ?*const anyopaque, *?*Com) callconv(.winapi) HRESULT, api.CreateBuffer)(dev, &cb, null, &constants));
        h.* = .{ .plane_ps = plane, .compose_ps = compose, .hole_blend = blend, .constants = constants, .plane = h.plane };
    }
};

/// Whether slot `slot`'s texture goes to the plane this frame.
pub fn inPlane(r: *const Renderer, slot: usize) bool {
    return r.extended and r.hdr.compose_ps != null and r.slots.isLinear(slot);
}

/// After the UI (`Renderer.draw`): the plane, then the compose into
/// `target`, an RGBA16F texture (the back buffer, or a test's), `w` × `h`.
pub fn finish(r: *Renderer, instances: []const gpu.Instance, size: types.Size, scale: f32, target: *Com, w: usize, h: usize) void {
    const g = r.context;
    const hdr = &r.hdr;
    // The plane: every `.surface_linear` texture, its own clip and corners.
    var planes: u32 = 0;
    hdr.plane.reserveAs(r.device, w, h, false, rgba16f);
    if (hdr.plane.rtv) |rtv| {
        var empty = [1]?*Com{null};
        g.slot(*const fn (*Com, u32, u32, [*]const ?*Com) callconv(.winapi) void, api.PSSetShaderResources)(g, 5, 1, &empty);
        d3d11.bindTarget(g, rtv);
        g.slot(*const fn (*Com, *Com, *const [4]f32) callconv(.winapi) void, api.ClearRenderTargetView)(g, rtv, &[4]f32{ 0, 0, 0, 0 });
        r.setBlend(false);
        for (instances, 0..) |inst, i| {
            if (inst.kind != gpu.Kind.texture) continue;
            const slot: usize = @intFromFloat(@max(0, inst.border_width));
            if (!inPlane(r, slot)) continue;
            r.bound_texture = r.slots.get(slot) orelse continue;
            defer r.bound_texture = null;
            r.drawWith(hdr.plane_ps.?, size, scale, i, 1);
            planes += 1;
        }
        r.setBlend(true);
    }
    // The compose, into the target.
    var rtv: ?*Com = null;
    api.check(r.device.slot(*const fn (*Com, *Com, ?*const anyopaque, *?*Com) callconv(.winapi) HRESULT, api.CreateRenderTargetView)(r.device, target, null, &rtv)) catch return;
    defer rtv.?.release();
    var none = [2]?*Com{ null, null };
    g.slot(*const fn (*Com, u32, u32, [*]const ?*Com) callconv(.winapi) void, api.PSSetShaderResources)(g, 0, 2, &none);
    d3d11.bindTarget(g, rtv.?);
    d3d11.setViewport(g, @floatFromInt(w), @floatFromInt(h));
    r.setBlend(false);
    defer r.setBlend(true);
    const k: Constants = .{ .scale = r.sdr_white_scale, .plane = if (planes > 0) 1 else 0 };
    var mapped: api.Mapped = undefined;
    if (g.slot(*const fn (*Com, *Com, u32, u32, u32, *api.Mapped) callconv(.winapi) HRESULT, api.Map)(g, hdr.constants.?, 0, api.map_write_discard, 0, &mapped) >= 0) {
        @memcpy(mapped.data[0..@sizeOf(Constants)], std.mem.asBytes(&k));
        g.slot(*const fn (*Com, *Com, u32) callconv(.winapi) void, api.Unmap)(g, hdr.constants.?, 0);
    }
    var cb = [1]?*Com{hdr.constants};
    g.slot(*const fn (*Com, u32, u32, [*]const ?*Com) callconv(.winapi) void, api.PSSetConstantBuffers)(g, 1, 1, &cb);
    var views = [2]?*Com{ r.frame.srv, if (planes > 0) hdr.plane.srv else r.frame.srv };
    g.slot(*const fn (*Com, u32, u32, [*]const ?*Com) callconv(.winapi) void, api.PSSetShaderResources)(g, 0, 2, &views);
    g.slot(*const fn (*Com, ?*Com, ?*const anyopaque, u32) callconv(.winapi) void, api.VSSetShader)(g, r.pass_vs, null, 0);
    g.slot(*const fn (*Com, ?*Com, ?*const anyopaque, u32) callconv(.winapi) void, api.PSSetShader)(g, hdr.compose_ps.?, null, 0);
    g.slot(*const fn (*Com, u32, u32) callconv(.winapi) void, api.Draw)(g, 3, 0);
    g.slot(*const fn (*Com, u32, u32, [*]const ?*Com) callconv(.winapi) void, api.PSSetShaderResources)(g, 0, 2, &none);
}

/// The scRGB value of SDR white for a display whose SDR white level is
/// `level` (DISPLAYCONFIG_SDR_WHITE_LEVEL: 1000 is 80 nits, scRGB's 1.0).
pub fn whiteScale(level: u32) f32 {
    return @as(f32, @floatFromInt(level)) / 1000.0;
}

test "scRGB: SDR white's value from the display's SDR white level" {
    // 80 nits (the default level, 1000): scRGB's 1.0.
    try std.testing.expectEqual(@as(f32, 1), whiteScale(1000));
    // The Windows slider at 200 nits: 2500, k = 2.5.
    try std.testing.expectEqual(@as(f32, 2.5), whiteScale(2500));
}
