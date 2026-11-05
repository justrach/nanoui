//! A texture mapped by a 2×2 matrix (`ui.textureAffine`): a shear moves
//! its texels where the map says, in the GPU's frame and the CPU's alike,
//! after the box's rotation, and the identity is no map at all.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const text = @import("text.zig");

const w = 64;
const h = 48;

/// A gradient with a white square at texels 4 to 20 (the box's 8 to 40).
fn card() [w * h * 4]u8 {
    var px: [w * h * 4]u8 = undefined;
    for (0..h) |y| for (0..w) |x| {
        const i = (y * w + x) * 4;
        const white = x >= 4 and x < 20 and y >= 4 and y < 20;
        px[i + 0] = if (white) 255 else @intCast(x * 4);
        px[i + 1] = if (white) 255 else @intCast(y * 5);
        px[i + 2] = if (white) 255 else 200;
        px[i + 3] = 255;
    };
    return px;
}

const Scene = struct {
    source: ui.Texture,
    m: [4]f32 = .{ 1, 0, 0, 1 },
    rotation: f32 = 0,
    fn view(s: *Scene, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull().p(10);
        defer root.end();
        ui.textureAffine(c, .{ .width = .{ .px = 128 }, .height = .{ .px = 96 }, .rotation = s.rotation }, s.source, .{ 0, 0, 1, 1 }, 1, s.m);
    }
};

fn at(p: gpu.Pixels, scale: f32, x: f32, y: f32) [4]u8 {
    const px: usize = @intFromFloat(x * scale);
    const py: usize = @intFromFloat(y * scale);
    return p.bytes[(py * p.width + px) * 4 ..][0..4].*;
}

fn textureInstance(t: *ui.Tester) ?gpu.Instance {
    for (t.instances.items) |i| if (i.kind == gpu.Kind.texture) return i;
    return null;
}

test "a sheared texture's texels land where the map puts them, on the GPU and the CPU" {
    const gpa = testing.allocator;
    const px = card();
    var s: Scene = .{ .source = .{ .width = w, .height = h, .bgra = &px } };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = 160, .height = 120 });
    defer t.deinit();
    t.settle(0.1);
    // The identity is no map.
    try testing.expectEqual([4]f32{ 0, 0, 0, 0 }, textureInstance(&t).?.border_color);
    const plain = try t.render(gpa);
    defer plain.deinit(gpa);
    // The box is 128 × 96 at (10, 10), about its middle (74, 58). Unmapped,
    // (58, 46) is the box's (48, 36): texel 24, past the white square.
    try testing.expect(at(plain, t.scale, 58, 46)[2] == 200);
    // (150, 18) is past the box's right edge (138).
    try testing.expect(at(plain, t.scale, 150, 18)[2] != 200);
    // x' = x - y about the middle: the box's (36, 36), in the square, moves
    // from (46, 46) to (58, 46).
    s.m = .{ 1, -1, 0, 1 };
    t.settle(0.1);
    const inst = textureInstance(&t).?;
    try testing.expectEqual([4]f32{ 1, -1, 0, 1 }, inst.border_color);
    try testing.expectEqual(@as(f32, 74), inst.xf[2]);
    const sheared = try t.render(gpa);
    defer sheared.deinit(gpa);
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(sheared, t.scale, 58, 46));
    // Past the box's own right edge the shear shows the card: its top rows
    // move right (40 points at y = 18), so (150, 18) is the box's (100, 8).
    try testing.expect(at(sheared, t.scale, 150, 18)[2] == 200);
    if (!text.portable) {
        // The GPU's frame (Metal here) and the CPU's agree.
        var pictures = t.text.images.pictures();
        pictures.textures = t.ctx.textures.items;
        const cpu = try gpa.alloc(u8, sheared.bytes.len);
        defer gpa.free(cpu);
        raster.draw(.{ .bytes = cpu, .width = sheared.width, .height = sheared.height }, t.instances.items, .{ .pixels = &.{}, .size = 0 }, pictures, t.scale, t.theme.background);
        var total: u64 = 0;
        for (cpu, sheared.bytes) |a, b| total += if (a > b) a - b else b - a;
        const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(cpu.len));
        try testing.expect(mean < 1.5);
        const c = (@as(usize, @intFromFloat(46 * t.scale)) * sheared.width + @as(usize, @intFromFloat(58 * t.scale))) * 4;
        try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, cpu[c..][0..4]);
    }
}

test "a map goes after the box's rotation" {
    const gpa = testing.allocator;
    const px = card();
    // A quarter turn, then a mirror across the vertical: (x, y) → (y, x)
    // about the middle, overall.
    var s: Scene = .{ .source = .{ .width = w, .height = h, .bgra = &px }, .m = .{ -1, 0, 0, 1 }, .rotation = std.math.pi / 2.0 };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = 160, .height = 120 });
    defer t.deinit();
    t.settle(0.1);
    const inst = textureInstance(&t).?;
    const m = gpu.affine(&inst).?;
    try testing.expectApproxEqAbs(@as(f32, 0), m[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), m[1], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), m[2], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), m[3], 1e-5);
    const shown = try t.render(gpa);
    defer shown.deinit(gpa);
    // A swap of x and y about the middle (74, 58): the square's (24, 24),
    // 40 and 24 points up and left of it, lands 24 left and 40 up: (50, 18).
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(shown, t.scale, 50, 18));
}
