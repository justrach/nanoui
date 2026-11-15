//! Tests for `View.after_frame`: invoked once after every completed CPU
//! frame (initial, multi-pass rebuild, and retained scroll frames), with
//! `null` as the default.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const State = struct {
    builds: usize = 0,
    after_calls: usize = 0,
    last_passes: u32 = 0,
    last_retained: bool = false,
    trigger_rebuild: bool = false,

    fn view(s: *State, c: *ui.Context) void {
        s.builds += 1;
        if (s.trigger_rebuild) {
            s.trigger_rebuild = false;
            c.changed = true;
        }
        ui.scroll(c, .{ .width = .fill, .height = .fill, .gap = 4 });
        defer ui.end(c);
        for (0..30) |i| {
            ui.keyInt(c, i);
            ui.row(c, .{ .width = .fill, .height = .{ .px = 24 } });
            defer ui.end(c);
            ui.textf(c, .{}, "Item {d}", .{i});
        }
    }

    fn afterFrame(ptr: *anyopaque, c: *ui.Context) void {
        const s: *State = @ptrCast(@alignCast(ptr));
        s.after_calls += 1;
        s.last_passes = c.stats.passes;
        s.last_retained = c.stats.retained;
    }
};

test "View.init defaults after_frame to null and invokes it once per completed frame" {
    var s: State = .{};
    var view: ui.View = .init(&s, State.view);
    try testing.expect(view.after_frame == null);

    view.after_frame = State.afterFrame;
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, view, .{ .width = 240, .height = 160 });
    defer t.deinit();

    // `Tester.init` runs the first frame.
    try testing.expectEqual(@as(usize, 1), s.after_calls);
    try testing.expectEqual(@as(usize, 1), s.builds);
    try testing.expectEqual(@as(u32, 1), s.last_passes);
    try testing.expect(!s.last_retained);

    // Multi-pass rebuild inside one frame still invokes after_frame once.
    s.trigger_rebuild = true;
    t.frame();
    try testing.expectEqual(@as(usize, 2), s.after_calls);
    try testing.expectEqual(@as(usize, 3), s.builds);
    try testing.expectEqual(@as(u32, 2), s.last_passes);
    try testing.expect(!s.last_retained);

    // Retained scroll frame bypasses view.build but still runs after_frame.
    t.scroll(100, 80, -28);
    try testing.expect(t.ctx.stats.retained);
    try testing.expectEqual(@as(usize, 3), s.after_calls);
    try testing.expectEqual(@as(usize, 3), s.builds);
    try testing.expect(s.last_retained);
}
