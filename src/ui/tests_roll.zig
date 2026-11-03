//! Rolling digits and pull to refresh, through the Tester.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const motion = ui.motion;

const Board = struct {
    value: u32 = 5,

    fn view(s: *Board, c: *ui.Context) void {
        const col = ui.div(c).column().p(10);
        defer col.end();
        motion.roll(c, "eta", c.print("{d} min", .{s.value}), .{ .size = 20 }, .{});
    }
};

/// The strip's offset: the one box moved up.
fn stripY(t: *ui.Tester) f32 {
    for (t.ctx.nodes.items) |n| if (n.style.offset.y != 0) return n.style.offset.y;
    return 0;
}

test "a changed digit rolls its strip to the new one" {
    var s: Board = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Board.view), .{ .width = 200, .height = 100 });
    defer t.deinit();
    t.settle(0.5);
    const lh: f32 = 25;
    try testing.expectApproxEqAbs(-5 * lh, stripY(&t), 0.1);
    s.value = 2;
    t.frame();
    t.advance(0.05);
    const mid = stripY(&t);
    try testing.expect(mid < -2 * lh and mid > -5 * lh);
    t.settle(2);
    try testing.expectApproxEqAbs(-2 * lh, stripY(&t), 0.1);
    try testing.expect(t.hasText(" min"));
}

const List = struct {
    pull: motion.Pull = .{},
    refreshed: u32 = 0,

    fn view(s: *List, c: *ui.Context) void {
        const list = ui.div(c).column().sizeFull().scrollY();
        defer list.end();
        if (s.pull.update(c, list.id())) s.refreshed += 1;
        for (0..30) |i| {
            ui.keyInt(c, i);
            ui.text(c, c.print("row {d}", .{i}), .{ .size = 16 });
        }
    }
};

test "let go past the threshold refreshes once; short of it, not" {
    var s: List = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, List.view), .{ .width = 200, .height = 200 });
    defer t.deinit();
    t.settle(0.2);
    t.ctx.input.mouse = .{ .x = 50, .y = 50 };
    t.ctx.scroll_holding = true;
    _ = t.ctx.applyScroll(100); // 35 points of rubber band: short
    t.frame();
    try testing.expect(!s.pull.armed);
    t.ctx.scroll_holding = false;
    t.settle(1.5);
    try testing.expectEqual(@as(u32, 0), s.refreshed);
    t.ctx.input.mouse = .{ .x = 50, .y = 50 };
    t.ctx.scroll_holding = true;
    _ = t.ctx.applyScroll(240); // 84 points: past 64
    t.frame();
    try testing.expect(s.pull.armed);
    try testing.expect(s.pull.progress() == 1);
    t.ctx.scroll_holding = false;
    t.settle(1.5);
    try testing.expectEqual(@as(u32, 1), s.refreshed);
}
