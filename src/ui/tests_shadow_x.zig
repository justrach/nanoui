//! A shadow moved sideways (`Shadow.x`), drawn by the CPU renderer.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");

const Boxes = struct {
    fn view(_: *Boxes, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(40), .gap = 40 });
        defer ui.end(c);
        const white: ui.Color = .{ .r = 1, .g = 1, .b = 1 };
        _ = c.leaf(.{ .width = .{ .px = 80 }, .height = .{ .px = 60 }, .radius = 8, .background = white, .shadow = .{ .color = .{ .a = 0.6 }, .blur = 12, .x = 8, .y = 0 } }, .none, null);
        _ = c.leaf(.{ .width = .{ .px = 80 }, .height = .{ .px = 60 }, .radius = 8, .shadow = .{ .color = .{ .a = 0.6 }, .blur = 12, .x = 8, .y = 0, .knockout = true } }, .none, null);
    }
};

fn green(p: gpu.Pixels, scale: f32, x: f32, y: f32) u8 {
    const px: usize = @intFromFloat(x * scale);
    const py: usize = @intFromFloat(y * scale);
    return p.bytes[(py * p.width + px) * 4 + 1];
}

test "x-offset shadow is darker on the offset side" {
    const gpa = testing.allocator;
    var s: Boxes = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Boxes.view), .{ .width = 200, .height = 260 });
    defer t.deinit();
    const w: usize = @intFromFloat(t.size.w * t.scale);
    const h: usize = @intFromFloat(t.size.h * t.scale);
    const out: gpu.Pixels = .{ .bytes = try gpa.alloc(u8, w * h * 4), .width = w, .height = h };
    defer gpa.free(out.bytes);
    raster.draw(out, t.instances.items, .{ .pixels = &.{}, .size = 0 }, .{}, t.scale, t.theme.background);
    // Boxes at (40, 40) and (40, 140), 80 × 60: 4 pt right of each is
    // shaded more than 4 pt left of it; a knocked out one stays clear inside.
    try offsetSide(out, t.scale);
    // As the Tester renders it (Metal on macOS).
    const frame = try t.render(gpa);
    defer frame.deinit(gpa);
    try offsetSide(frame, t.scale);
}

fn offsetSide(p: gpu.Pixels, scale: f32) !void {
    for ([_]f32{ 70, 170 }) |y| try testing.expect(green(p, scale, 124, y) + 30 < green(p, scale, 36, y));
    try testing.expectEqual(green(p, scale, 2, 2), green(p, scale, 110, 170));
}
