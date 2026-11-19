//! An extended (EDR) Metal surface (`Surface.setColour(.extended_linear)`):
//! the UI drawn in 8-bit sRGB and decoded, a `.surface_linear` texture in
//! the plane under it, composed into RGBA16Float by `fs_hdr_compose`:
//!   out = k · srgbEOTF(ui.rgb / ui.a) · ui.a + (1 − ui.a) · plane,
//! the plane holding each texture's own (un-premultiplied) colour and the
//! hole cut for it its coverage and alpha.
//! Frames are drawn offscreen into half floats (`drawOffscreenLinear`) and
//! checked against that formula on the CPU; an SDR snapshot of the same
//! frame is unchanged whatever the surface shows.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");
const text = @import("text.zig");
const objc = @import("../objc.zig");
const metal_hdr = struct {
    /// What `fs_hdr_compose` decodes the UI with (metal_hdr.zig's).
    fn srgbEotf(c: f32) f32 {
        return if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
    }
};

const W = 40;
const H = 24;

/// An instance of `kind` over `rect`, straight-alpha `color`.
fn inst(kind: f32, rect: [4]f32, color: [4]f32) gpu.Instance {
    return .{ .rect = rect, .color = color, .kind = kind };
}

/// A texture instance of slot 0 over `rect`.
fn textureAt(rect: [4]f32, radius: f32) gpu.Instance {
    return .{ .rect = rect, .color = .{ 1, 1, 1, 1 }, .uv = .{ 0, 0, 1, 1 }, .kind = gpu.Kind.texture, .radius = radius };
}

/// A shared RGBA16Float MTLTexture of `w` × `h` texels of `v` (premultiplied).
fn halfTexture(w: usize, h: usize, v: [4]f32) !objc.Object {
    if (comptime text.portable) return error.SkipZigTest;
    const device: objc.Object = @ptrCast(ui.metalDevice() orelse return error.SkipZigTest);
    const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ @as(objc.NSUInteger, 115), @as(objc.NSUInteger, w), @as(objc.NSUInteger, h), objc.NO });
    objc.msg(void, desc, "setUsage:", .{@as(objc.NSUInteger, 1)});
    objc.msg(void, desc, "setStorageMode:", .{@as(objc.NSUInteger, 0)});
    const tex = objc.msg(?objc.Object, device, "newTextureWithDescriptor:", .{desc}) orelse return error.SkipZigTest;
    const px = try testing.allocator.alloc(f16, w * h * 4);
    defer testing.allocator.free(px);
    for (0..w * h) |i| for (0..4) |k| {
        px[i * 4 + k] = @floatCast(v[k]);
    };
    const Region = extern struct { x: usize, y: usize, z: usize, w: usize, h: usize, d: usize };
    objc.msg(void, tex, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{ Region{ .x = 0, .y = 0, .z = 0, .w = w, .h = h, .d = 1 }, @as(objc.NSUInteger, 0), @as(*const anyopaque, px.ptr), @as(objc.NSUInteger, w * 8) });
    return tex;
}

const Empty = struct {
    fn view(_: *Empty, c: *ui.Context) void {
        ui.div(c).sizeFull().end();
    }
};

/// A tester whose renderer draws `instances` (its textures `textures`).
const Rig = struct {
    t: ui.Tester = undefined,
    e: Empty = .{},

    fn init(r: *Rig) !void {
        if (text.portable) return error.SkipZigTest;
        try r.t.init(testing.allocator, .init(&r.e, Empty.view), .{ .width = W, .height = H, .scale = 1 });
    }

    fn deinit(r: *Rig) void {
        r.t.deinit();
    }

    fn sdr(r: *Rig, instances: []const gpu.Instance, textures: []const gpu.Texture) !gpu.Pixels {
        if (comptime text.portable) return error.SkipZigTest;
        r.t.renderer.textures = textures;
        return r.t.renderer.drawOffscreen(testing.allocator, instances, r.t.text.texture(), .{ .w = W, .h = H }, 1, clear);
    }

    fn linear(r: *Rig, instances: []const gpu.Instance, textures: []const gpu.Texture, k: f32) ![]f32 {
        if (comptime text.portable) return error.SkipZigTest;
        r.t.renderer.textures = textures;
        r.t.renderer.sdr_white_scale = k;
        defer r.t.renderer.sdr_white_scale = 1;
        const px = try r.t.renderer.drawOffscreenLinear(testing.allocator, instances, r.t.text.texture(), .{ .w = W, .h = H }, 1, clear);
        try testing.expectEqual(@as(usize, W), px.width);
        return px.rgba;
    }
};

const clear: ui.Color = .{ .r = 0.1, .g = 0.2, .b = 0.3, .a = 1 };

/// `want` ≈ `got`, to what a half float and the GPU's `pow` keep.
fn near(want: f32, got: f32) bool {
    return @abs(want - got) <= 2e-3 + 2e-3 * @abs(want);
}

fn expectNear(want: f32, got: f32) !void {
    if (!near(want, got)) {
        std.debug.print("want {d:.5}, got {d:.5}\n", .{ want, got });
        return error.TestExpectedApproxEqAbs;
    }
}

test "HDR surface: opaque UI pixels compose to the EOTF of their 8-bit codes, times the white scale" {
    if (comptime text.portable) return error.SkipZigTest;
    var r: Rig = .{};
    try r.init();
    defer r.deinit();
    const quads = [_]gpu.Instance{
        inst(gpu.Kind.quad, .{ 0, 0, 20, 24 }, .{ 0.9, 0.5, 0.05, 1 }),
        inst(gpu.Kind.quad, .{ 20, 0, 20, 12 }, .{ 0.2, 0.7, 1, 1 }),
        // Half transparent over the clear: still an opaque pixel.
        inst(gpu.Kind.quad, .{ 20, 12, 20, 12 }, .{ 1, 1, 1, 0.5 }),
    };
    const codes = try r.sdr(&quads, &.{});
    defer codes.deinit(testing.allocator);
    inline for (.{ 1.0, 2.5 }) |k| {
        const lin = try r.linear(&quads, &.{}, k);
        defer testing.allocator.free(lin);
        for (0..W * H) |i| {
            try testing.expectEqual(@as(u8, 255), codes.bytes[i * 4 + 3]);
            for (0..3) |c| {
                const code = @as(f32, @floatFromInt(codes.bytes[i * 4 + 2 - c])) / 255;
                try expectNear(k * metal_hdr.srgbEotf(code), lin[i * 4 + c]);
            }
            try expectNear(1, lin[i * 4 + 3]);
        }
    }
}

test "HDR surface: a .surface_linear texture lands in the plane, values above white kept, under a later overlay" {
    if (comptime text.portable) return error.SkipZigTest;
    var r: Rig = .{};
    try r.init();
    defer r.deinit();
    const v: [4]f32 = .{ 4.0, 0.5, 12.0, 1 };
    const tex = try halfTexture(8, 8, v);
    defer objc.release(tex);
    const textures = [_]gpu.Texture{.{ .width = 8, .height = 8, .mtl_texture = @ptrCast(tex), .encoding = .surface_linear }};
    const overlay = [4]f32{ 0.2, 0.8, 0.4, 0.5 };
    const frame = [_]gpu.Instance{
        inst(gpu.Kind.quad, .{ 0, 0, 40, 24 }, .{ 0.5, 0.5, 0.5, 1 }),
        textureAt(.{ 4, 4, 24, 16 }, 0),
        // Drawn after the video: over it, half transparent, on its right.
        inst(gpu.Kind.quad, .{ 20, 4, 16, 16 }, overlay),
    };
    const lin = try r.linear(&frame, &textures, 1);
    defer testing.allocator.free(lin);
    const at = struct {
        fn f(px: []const f32, x: usize, y: usize) []const f32 {
            return px[(y * W + x) * 4 ..][0..4];
        }
    }.f;
    // Inside the texture, before the overlay: the plane as it is (> 1).
    for (0..4) |c| try expectNear(v[c], at(lin, 10, 10)[c]);
    // Under the overlay: k · ui_lin + (1 − a) · plane, the UI decoded.
    const a = overlay[3];
    for (0..3) |c| {
        // The overlay's premultiplied 8-bit code, decoded un-premultiplied.
        const code = @round(overlay[c] * a * 255) / 255 / a;
        const want = metal_hdr.srgbEotf(code) * a + (1 - a) * v[c];
        try testing.expect(@abs(want - at(lin, 24, 10)[c]) <= 0.01 + 0.01 * want);
    }
    // Outside both: the background's EOTF, the plane unread.
    try expectNear(metal_hdr.srgbEotf(128.0 / 255.0), at(lin, 1, 1)[0]);
    try expectNear(metal_hdr.srgbEotf(128.0 / 255.0), at(lin, 38, 22)[1]);
}

test "HDR surface: a rounded texture's antialiased edge sums to one with the UI around it" {
    if (comptime text.portable) return error.SkipZigTest;
    var r: Rig = .{};
    try r.init();
    defer r.deinit();
    // The texture is the background's own linear light: wherever the edge
    // is, UI and plane together give that light back.
    const code: f32 = 0.6;
    const bg_lin = metal_hdr.srgbEotf(@round(code * 255) / 255);
    const tex = try halfTexture(4, 4, .{ bg_lin, bg_lin, bg_lin, 1 });
    defer objc.release(tex);
    const textures = [_]gpu.Texture{.{ .width = 4, .height = 4, .mtl_texture = @ptrCast(tex), .encoding = .surface_linear }};
    const frame = [_]gpu.Instance{
        inst(gpu.Kind.quad, .{ 0, 0, 40, 24 }, .{ code, code, code, 1 }),
        textureAt(.{ 3.5, 2.25, 30, 19 }, 7),
    };
    const lin = try r.linear(&frame, &textures, 1);
    defer testing.allocator.free(lin);
    var worst: f32 = 0;
    for (0..W * H) |i| for (0..3) |c| {
        worst = @max(worst, @abs(lin[i * 4 + c] - bg_lin));
    };
    // 8-bit premultiplied UI at the edge: within a couple of code steps.
    if (worst > 0.01) std.debug.print("worst edge error {d:.5}\n", .{worst});
    try testing.expect(worst <= 0.01);
}

test "HDR surface: SDR snapshots are unchanged with the surface extended" {
    if (comptime text.portable) return error.SkipZigTest;
    var r: Rig = .{};
    try r.init();
    defer r.deinit();
    const tex = try halfTexture(8, 8, .{ 2.0, 0.25, 0.1, 1 });
    defer objc.release(tex);
    const textures = [_]gpu.Texture{.{ .width = 8, .height = 8, .mtl_texture = @ptrCast(tex), .encoding = .surface_linear }};
    const frame = [_]gpu.Instance{
        inst(gpu.Kind.quad, .{ 0, 0, 40, 24 }, .{ 0.3, 0.6, 0.9, 1 }),
        textureAt(.{ 4, 4, 24, 16 }, 3),
        inst(gpu.Kind.quad, .{ 20, 4, 16, 16 }, .{ 1, 0, 0, 0.25 }),
    };
    const before = try r.sdr(&frame, &textures);
    defer before.deinit(testing.allocator);
    try testing.expectEqual(gpu.SurfaceColour.sdr_srgb, r.t.renderer.colour);
    try r.t.renderer.setColour(.extended_linear);
    try testing.expectEqual(gpu.SurfaceColour.extended_linear, r.t.renderer.colour);
    try testing.expectEqual(@as(objc.NSUInteger, 115), objc.msg(objc.NSUInteger, r.t.renderer.layer, "pixelFormat", .{}));
    const during = try r.sdr(&frame, &textures);
    defer during.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, before.bytes, during.bytes);
    try r.t.renderer.setColour(.sdr_srgb);
    try testing.expectEqual(@as(objc.NSUInteger, 80), objc.msg(objc.NSUInteger, r.t.renderer.layer, "pixelFormat", .{}));
    const after = try r.sdr(&frame, &textures);
    defer after.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, before.bytes, after.bytes);
}

test "HDR surface: an SDR display by default; the Tester's display is the view's, and passing through needs no stage" {
    const lin: gpu.Texture = .{ .width = 1, .height = 1, .format = .rgba16f, .encoding = .surface_linear };
    try testing.expect(lin.needsPostOn(.sdr_srgb));
    try testing.expect(!lin.needsPostOn(.extended_linear));
    const auto: gpu.Texture = .{ .width = 1, .height = 1, .format = .rgba16f };
    try testing.expectEqual(auto.needsPost(), auto.needsPostOn(.extended_linear));
    const d: gpu.DisplayInfo = .{};
    try testing.expect(!d.hasHeadroom());
    try testing.expectEqual(@as(f32, 1), d.sdr_white_scale);
    if (text.portable) return;
    const Seen = struct {
        info: gpu.DisplayInfo = .{},
        colour: gpu.SurfaceColour = .sdr_srgb,
        fn view(s: *@This(), c: *ui.Context) void {
            s.info = c.display_info;
            s.colour = c.surface_colour;
            ui.div(c).sizeFull().end();
        }
    };
    var seen: Seen = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&seen, Seen.view), .{ .width = 16, .height = 16, .scale = 1 });
    defer t.deinit();
    try testing.expect(!seen.info.hasHeadroom());
    t.display_info = .{ .headroom_now = 4, .headroom_potential = 16, .max_nits = 1600, .hdr_output = true, .wide_gamut = true };
    t.surface_colour = .extended_linear;
    t.frame();
    try testing.expectEqual(@as(f32, 16), seen.info.headroom_potential);
    try testing.expect(seen.info.hasHeadroom());
    try testing.expectEqual(gpu.SurfaceColour.extended_linear, seen.colour);
}
