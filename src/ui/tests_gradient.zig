//! `Style.gradient`: a box's background fades from top to bottom, on the
//! GPU and in the CPU renderer alike.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");

const Scene = struct {
    fn view(_: *Scene, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull().bg(.black);
        defer root.end();
        ui.div(c).w(100).h(100).bg(.hex(0xff0000)).gradient(.hex(0x0000ff)).end();
    }
};

fn at(px: gpu.Pixels, x: usize, y: usize) [3]u8 {
    const i = (y * px.width + x) * 4;
    return .{ px.bytes[i + 2], px.bytes[i + 1], px.bytes[i] };
}

test "a gradient runs from the background at the top to its color at the bottom" {
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 120, .height = 120, .scale = 1 });
    defer t.deinit();
    t.settle(0.1);
    const px = try t.render(testing.allocator);
    defer px.deinit(testing.allocator);
    const top = at(px, 50, 1);
    const mid = at(px, 50, 50);
    const bottom = at(px, 50, 98);
    try testing.expect(top[0] > 240 and top[2] < 15);
    try testing.expect(bottom[2] > 240 and bottom[0] < 15);
    try testing.expect(mid[0] > 100 and mid[0] < 155 and mid[2] > 100 and mid[2] < 155);
    // The CPU renderer draws the same.
    const cpu: gpu.Pixels = .{ .bytes = try testing.allocator.alloc(u8, px.bytes.len), .width = px.width, .height = px.height };
    defer cpu.deinit(testing.allocator);
    const texels = try t.text.atlas.read(testing.allocator);
    defer testing.allocator.free(texels);
    raster.draw(cpu, t.instances.items, .{ .pixels = texels, .size = t.text.atlas.size }, t.text.images.pictures(), 1, .black);
    for ([_]usize{ 1, 50, 98 }) |y| {
        const a = at(px, 50, y);
        const b = at(cpu, 50, y);
        for (0..3) |k| try testing.expect(@abs(@as(i16, a[k]) - @as(i16, b[k])) <= 3);
    }
}

test "gradient colors pack into a quad's uv and back" {
    const uv = gpu.gradientUv(true, .{ .r = 0.2, .g = 0.4, .b = 0.6, .a = 1 });
    try testing.expectEqual(@as(f32, 1), uv[0]);
    const c = gpu.gradientBottom(uv);
    try testing.expectApproxEqAbs(@as(f32, 0.2), c[0], 0.003);
    try testing.expectApproxEqAbs(@as(f32, 0.4), c[1], 0.003);
    try testing.expectApproxEqAbs(@as(f32, 0.6), c[2], 0.003);
    try testing.expectApproxEqAbs(@as(f32, 1), c[3], 0.003);
}

/// Four stops whose colors change by two 8-bit steps a pixel, so every
/// pixel is a whole step: Metal and the CPU must agree exactly.
const stops = [_]ui.GradientStop{
    .{ .at = 0, .color = .hex(0x00ff14) },
    .{ .at = 0.3, .color = .hex(0x3cc350) },
    .{ .at = 0.6, .color = .hex(0x00ff8c) },
    .{ .at = 1, .color = .hex(0x50afdc) },
};

const Stops = struct {
    fn view(_: *Stops, c: *ui.Context) void {
        const root = ui.div(c).sizeFull().bg(.black);
        defer root.end();
        ui.div(c).absolute().offset(10, 0).w(20).h(100).bg(.white).gradientStops(&stops, null).end();
        // A meter's level: the lower half of a track, in the track's colors.
        ui.div(c).absolute().offset(40, 50).w(20).h(50).bg(.white).gradientStops(&stops, .{ .x = 0, .y = -50, .w = 20, .h = 100 }).end();
    }
};

test "a gradient of four stops is the same to the pixel on the GPU and the CPU" {
    const gpa = testing.allocator;
    var s: Stops = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Stops.view), .{ .width = 70, .height = 100, .scale = 1 });
    defer t.deinit();
    t.settle(0.1);
    const px = try t.render(gpa);
    defer px.deinit(gpa);
    const cpu: gpu.Pixels = .{ .bytes = try gpa.alloc(u8, px.bytes.len), .width = px.width, .height = px.height };
    defer cpu.deinit(gpa);
    var pictures = t.text.images.pictures();
    pictures.gradients = t.ctx.gradients.items;
    raster.draw(cpu, t.instances.items, .{ .pixels = &.{}, .size = 0 }, pictures, 1, .black);
    try testing.expectEqualSlices(u8, cpu.bytes, px.bytes);
    // Each stop's own color at its row, and two steps a pixel between.
    try testing.expectEqual([3]u8{ 1, 254, 21 }, at(px, 15, 0));
    try testing.expectEqual([3]u8{ 59, 196, 79 }, at(px, 15, 29));
    try testing.expectEqual([3]u8{ 79, 176, 219 }, at(px, 15, 99));
    // The anchored box shows the track's colors where it is.
    for (50..100) |y| try testing.expectEqual(at(px, 15, y), at(px, 45, y));
}
