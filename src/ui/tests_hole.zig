//! Holes (`ui.hole`): a rounded box cut out of the frame, so a native view
//! under it (a map) shows there, cut the same by Metal and the CPU, and
//! what's drawn after it lies over the cut.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const raster = @import("raster.zig");
const text = @import("text.zig");

const Scene = struct {
    id: u64 = 0,
    fn view(s: *Scene, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull().p(10).bg(.hex(0x336699));
        defer root.end();
        const box = ui.div(c).w(120).h(80);
        defer box.end();
        s.id = ui.hole(c, "map", 16);
        // A chip over the map, drawn after the cut.
        const chip = ui.div(c).absolute().offset(8, 8).w(24).h(16).bg(.hex(0xFFD100));
        chip.end();
    }
};

fn at(p: @import("gpu.zig").Pixels, scale: f32, x: f32, y: f32) [4]u8 {
    const px: usize = @intFromFloat(x * scale);
    const py: usize = @intFromFloat(y * scale);
    return p.bytes[(py * p.width + px) * 4 ..][0..4].*;
}

test "a hole cuts the frame clear, corners rounded; what follows draws over it" {
    const gpa = testing.allocator;
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = 160, .height = 120 });
    defer t.deinit();
    t.settle(0.1);
    const shown = try t.render(gpa);
    defer shown.deinit(gpa);
    // Inside the hole: nothing.
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, at(shown, t.scale, 70, 60));
    // Its corner is rounded: the background stays.
    try testing.expectEqual(@as(u8, 255), at(shown, t.scale, 11, 11)[3]);
    // Outside it: the background.
    try testing.expectEqual(@as(u8, 255), at(shown, t.scale, 150, 110)[3]);
    // The chip over it.
    try testing.expectEqual([4]u8{ 0x00, 0xD1, 0xFF, 255 }, at(shown, t.scale, 30, 26));
    // The hole takes touches: it is a box the pointer can be over.
    try testing.expect(s.id != 0);
    if (!text.portable) {
        const cpu = try gpa.alloc(u8, shown.bytes.len);
        defer gpa.free(cpu);
        raster.draw(.{ .bytes = cpu, .width = shown.width, .height = shown.height }, t.instances.items, .{ .pixels = &.{}, .size = 0 }, t.text.images.pictures(), t.scale, t.theme.background);
        try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, cpu[(@as(usize, @intFromFloat(60 * t.scale)) * shown.width + @as(usize, @intFromFloat(70 * t.scale))) * 4 ..][0..4].*);
    }
}
