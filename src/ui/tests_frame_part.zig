//! What a point of the view is to the window's frame (`framePartAt`, what
//! Windows' WM_NCHITTEST asks a chromeless window): a `window_drag` box is
//! the caption, `window_maximize` the maximize button, any other box the
//! view's, and under a hidden title bar the empty top strip the caption.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const Bar = struct {
    fn view(_: *Bar, c: *ui.Context) void {
        c.title_bar_height = 32;
        _ = c.open(.{ .direction = .column, .width = .fill, .height = .fill }, null);
        defer c.end();
        {
            _ = c.open(.{ .direction = .row, .width = .fill, .height = .{ .px = 40 } }, null);
            defer c.end();
            const drag = c.open(.{ .width = .{ .px = 200 }, .height = .fill, .window_drag = true }, null);
            _ = c.interact(drag, .{});
            c.end();
            const max = c.open(.{ .width = .{ .px = 40 }, .height = .fill, .window_maximize = true }, null);
            _ = c.interact(max, .{});
            c.end();
            const plain = c.open(.{ .width = .{ .px = 40 }, .height = .fill }, null);
            _ = c.interact(plain, .{});
            c.end();
        }
        const content = c.open(.{ .width = .fill, .height = .fill }, null);
        _ = c.interact(content, .{});
        c.end();
    }
};

test "framePartAt: the caption, the maximize button and the view's own" {
    var b: Bar = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&b, Bar.view), .{ .width = 400, .height = 200 });
    defer t.deinit();
    t.settle(0.05);
    const c = &t.ctx;
    try testing.expectEqual(.caption, c.framePartAt(.{ .x = 100, .y = 20 }, true));
    try testing.expectEqual(.maximize, c.framePartAt(.{ .x = 220, .y = 20 }, true));
    try testing.expectEqual(.client, c.framePartAt(.{ .x = 260, .y = 20 }, true));
    try testing.expectEqual(.client, c.framePartAt(.{ .x = 100, .y = 120 }, true));
    // The band's empty part: the caption above `title_bar_height` under a
    // hidden title bar, the view's below it and without one.
    try testing.expectEqual(.caption, c.framePartAt(.{ .x = 340, .y = 20 }, true));
    try testing.expectEqual(.client, c.framePartAt(.{ .x = 340, .y = 36 }, true));
    try testing.expectEqual(.client, c.framePartAt(.{ .x = 340, .y = 20 }, false));
    // A drag handle is the caption with or without a hidden title bar.
    try testing.expectEqual(.caption, c.framePartAt(.{ .x = 100, .y = 20 }, false));
}
