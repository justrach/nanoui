//! Boxes that scroll sideways (`Style.scroll_x`): children at their own
//! widths, clipped, moved by the wheel's x or `setScroll`, and scroll
//! indicators that a box can do without (`Style.scroll_bar`).
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const Strip = struct {
    box: u32 = 0,
    items: [5]u32 = undefined,
    fn view(s: *Strip, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(10) });
        defer ui.end(c);
        s.box = c.open(.{ .direction = .row, .scroll_x = true, .width = .{ .px = 200 }, .height = .{ .px = 40 }, .scroll_bar = false }, null);
        defer c.end();
        for (&s.items, 0..) |*it, i| {
            const shade: f32 = @as(f32, @floatFromInt(i)) / 5;
            it.* = c.leaf(.{ .width = .{ .px = 100 }, .height = .{ .px = 40 }, .background = .{ .r = shade, .g = 0.5, .b = 0.2 } }, .none, null);
        }
    }
};

test "scroll_x clips and offsets children" {
    var s: Strip = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Strip.view), .{});
    defer t.deinit();
    const c = &t.ctx;
    // At their own widths, past the box.
    try testing.expectEqual(@as(f32, 10), c.node(s.items[0]).rect.x);
    try testing.expectEqual(@as(f32, 410), c.node(s.items[4]).rect.x);
    try testing.expectEqual(@as(f32, 100), c.node(s.items[4]).rect.w);
    // Clipped to the box.
    var clipped: u32 = 0;
    for (t.instances.items) |i| if (i.color[1] == 0.5) {
        clipped += 1;
        try testing.expectEqual([4]f32{ 10, 10, 210, 50 }, i.clip);
    };
    try testing.expectEqual(@as(u32, 2), clipped); // the rest is culled
    const id = c.node(s.box).id;
    c.setScroll(id, .x, 50);
    t.frame();
    try testing.expectEqual(@as(f32, -40), c.node(s.items[0]).rect.x);
    // Clamped to its content: 500 wide in 200.
    c.setScroll(id, .x, 10_000);
    t.frame();
    try testing.expectEqual(@as(f32, 300), c.scroll_x.get(id).?);
    try testing.expectEqual(@as(f32, 110), c.node(s.items[4]).rect.x);
    // The wheel's x, over the box: a swipe left goes right.
    c.setScroll(id, .x, 0);
    t.frame();
    c.input.mouse = .{ .x = 100, .y = 30 };
    c.input.scroll.x = -30;
    t.frame();
    try testing.expectEqual(@as(f32, -20), c.node(s.items[0]).rect.x);
    // Not over it: nothing moves.
    c.input.mouse = .{ .x = 300, .y = 200 };
    c.input.scroll.x = -30;
    t.frame();
    try testing.expectEqual(@as(f32, -20), c.node(s.items[0]).rect.x);
}

const Both = struct {
    bars: bool = true,
    fn view(s: *Both, c: *ui.Context) void {
        ui.row(c, .{ .gap = 10 });
        defer ui.end(c);
        {
            _ = c.open(.{ .scroll = true, .width = .{ .px = 100 }, .height = .{ .px = 100 }, .scroll_bar = s.bars }, null);
            defer c.end();
            for (0..5) |_| _ = c.leaf(.{ .width = .{ .px = 80 }, .height = .{ .px = 50 }, .background = .{ .g = 1 } }, .none, null);
        }
        _ = c.open(.{ .direction = .row, .scroll_x = true, .width = .{ .px = 100 }, .height = .{ .px = 40 }, .scroll_bar = s.bars }, null);
        defer c.end();
        for (0..5) |_| _ = c.leaf(.{ .width = .{ .px = 50 }, .height = .{ .px = 40 }, .background = .{ .b = 1 } }, .none, null);
    }
};

fn bars(t: *ui.Tester) u32 {
    var n: u32 = 0;
    for (t.instances.items) |i| if (i.radius == 2 and (i.rect[2] == 4 or i.rect[3] == 4)) {
        n += 1;
    };
    return n;
}

test "scroll_bar false paints no bar" {
    var s: Both = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Both.view), .{});
    defer t.deinit();
    try testing.expectEqual(@as(u32, 2), bars(&t));
    s.bars = false;
    t.frame();
    try testing.expectEqual(@as(u32, 0), bars(&t));
}
