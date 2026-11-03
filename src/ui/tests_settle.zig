//! Rows that spring to a new place when a row above them goes
//! (`Style.settle_y`), but not when their box scrolls; and the overlay
//! scroller that shows only while it scrolls (`scroll_bar_fades`).
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const spring: ui.Spring = .{ .response = 0.3, .damping = 0.86 };

const Rows = struct {
    first: bool = true,
    fn view(r: *Rows, c: *ui.Context) void {
        _ = c.open(.{ .scroll = true, .direction = .column, .height = .{ .px = 50 }, .width = .{ .px = 100 }, .scroll_bar_fades = true }, "rows");
        defer c.end();
        if (r.first) _ = c.leaf(.{ .height = .{ .px = 20 }, .width = .fill, .settle_y = spring }, .none, "a");
        _ = c.leaf(.{ .height = .{ .px = 20 }, .width = .fill, .settle_y = spring }, .none, "b");
        for (0..4) |_| _ = c.leaf(.{ .height = .{ .px = 20 }, .width = .fill }, .none, null);
    }
};

/// Row "b": the last that settles.
fn bY(t: *ui.Tester) f32 {
    var y: ?f32 = null;
    for (t.ctx.nodes.items) |n| if (n.style.settle_y != null) {
        y = n.rect.y;
    };
    return y.?;
}

fn scrolled(t: *ui.Tester) f32 {
    var it = t.ctx.scroll.valueIterator();
    while (it.next()) |v| return v.*;
    return 0;
}

test "settle_y: a row above gone, the next springs up from where it was" {
    var r: Rows = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&r, Rows.view), .{});
    defer t.deinit();
    t.frame();
    try testing.expectApproxEqAbs(@as(f32, 20), bY(&t), 0.01);
    r.first = false;
    t.frame();
    // Where it was, all but a frame's step of the spring.
    try testing.expect(bY(&t) > 15);
    t.settle(2);
    try testing.expectApproxEqAbs(@as(f32, 0), bY(&t), 0.01);
}

test "settle_y: scrolling moves the rows at once" {
    var r: Rows = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&r, Rows.view), .{});
    defer t.deinit();
    t.frame();
    t.scroll(50, 25, -30);
    t.frame();
    const off = scrolled(&t);
    try testing.expect(off > 0);
    try testing.expectApproxEqAbs(20 - off, bY(&t), 0.01);
}

fn barShown(t: *ui.Tester) bool {
    for (t.instances.items) |i| if (i.rect[2] == 4 and i.radius == 2 and i.color[3] > 0) return true;
    return false;
}

test "scroll_bar_fades: the indicator shows while scrolling, then goes" {
    var r: Rows = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&r, Rows.view), .{});
    defer t.deinit();
    t.frame();
    try testing.expect(!barShown(&t));
    t.scroll(50, 25, -30);
    t.frame();
    try testing.expect(barShown(&t));
    t.advance(0.5);
    t.frame();
    try testing.expect(barShown(&t));
    t.advance(1.0);
    t.frame();
    try testing.expect(!barShown(&t));
}
