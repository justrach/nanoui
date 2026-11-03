//! `ui.svg` in a frame: an icon drawn at the screen's density, in the color
//! asked, on whole pixels; drawn again at another size; bad bytes drawing
//! nothing.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const chevron =
    \\<svg viewBox="0 0 24 24"><path fill="none" stroke="currentColor" stroke-linecap="round"
    \\ stroke-linejoin="round" stroke-width="2" d="m19 9l-7 6l-7-6"/></svg>
;
const square =
    \\<svg viewBox="0 0 10 10"><rect width="10" height="10" fill="#0000ff"/></svg>
;

const Icons = struct {
    size: f32 = 24,
    ok: bool = false,
    bad: bool = true,
    fn view(s: *Icons, c: *ui.Context) void {
        ui.row(c, .{ .padding = .all(10), .gap = 10 });
        defer ui.end(c);
        s.ok = ui.svg(c, .{ .key = "chevron", .bytes = chevron, .size = s.size, .color = .hex(0xff0000) });
        _ = ui.svg(c, .{ .key = "square", .bytes = square, .size = 10 });
        s.bad = ui.svg(c, .{ .key = "junk", .bytes = "not svg" });
    }
};

fn at(px: @import("gpu.zig").Pixels, x: usize, y: usize) [4]u8 {
    return px.bytes[(y * px.width + x) * 4 ..][0..4].*;
}

test "an SVG icon draws tinted at the screen's density, in its own colors untinted" {
    var s: Icons = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Icons.view), .{ .width = 120, .height = 60 });
    defer t.deinit();
    t.settle(1);
    try testing.expect(s.ok);
    try testing.expect(!s.bad);
    var sizes: [2][2]f32 = undefined;
    var k: usize = 0;
    for (t.ctx.nodes.items) |n| if (n.content == .image) {
        sizes[k] = .{ n.rect.w, n.rect.h };
        k += 1;
    };
    try testing.expectEqual(@as(usize, 2), k);
    try testing.expectEqual([2]f32{ 24, 24 }, sizes[0]);
    const px = try t.render(testing.allocator);
    defer px.deinit(testing.allocator);
    // At 2×: the chevron's tip at (12, 15) units in a box at (10, 10)
    // points is pixel (44, 50): red (BGRA). The square at (44, 10) points:
    // blue.
    const tip = at(px, 44, 49);
    try testing.expect(tip[2] > 180 and tip[1] < 80 and tip[0] < 80);
    const sq = at(px, 98, 30);
    try testing.expect(sq[0] > 200 and sq[2] < 60);
    // Another size is drawn again for it, not scaled.
    s.size = 48;
    t.frame();
    for (t.ctx.nodes.items) |n| if (n.content == .image) {
        try testing.expectEqual(@as(f32, 48), n.rect.w);
        break;
    };
}
