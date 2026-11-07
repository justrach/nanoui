//! Regressions runnable against main's existing APIs, without catalog helpers.
const std = @import("std");
const ui = @import("../ui.zig");
const motion = @import("motion.zig");
const testing = std.testing;

test "instant retarget cancels a moving channel even at the same destination" {
    var ch: motion.Channel = .at(0);
    ch.retarget(1, .{ .tween = .{ .duration = 0.5 } }, 0, 0);
    ch.sample(0.1);
    try testing.expect(ch.moving and ch.value < 1);
    ch.retarget(1, .instant, 0, 0.1);
    try testing.expectEqual(@as(f64, 1), ch.value);
    try testing.expect(!ch.moving);
}

const Delayed = struct {
    legacy_flag: bool = false,
    last: motion.Frame = .{},
    fn view(s: *Delayed, c: *ui.Context) void {
        c.reduced_motion = !s.legacy_flag;
        c.reduce_motion = s.legacy_flag;
        s.last = motion.frame(c, .{
            .initial = .{ .opacity = 0, .y = 8 },
            .target = .{ .opacity = 1, .y = 0 },
            .delay = 2,
            .transition = .{ .tween = .{ .duration = 0.3 } },
        });
        const box = ui.div(c).size(40, 20).motion(s.last);
        box.end();
    }
};

test "either reduced motion flag skips a declarative entrance delay immediately" {
    for ([_]bool{ false, true }) |legacy| {
        var s: Delayed = .{ .legacy_flag = legacy };
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&s, Delayed.view), .{});
        defer t.deinit();
        try testing.expectEqual(@as(f32, 1), s.last.opacity);
        try testing.expectEqual(@as(f32, 0), s.last.y);
        try testing.expect(!s.last.animating and !t.ctx.animating);
    }
}
