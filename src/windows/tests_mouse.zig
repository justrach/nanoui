//! A hidden Windows surface's mouse buttons: the middle button's press,
//! drag and release as the left's, the second-button guard, a left press
//! after a middle drag being the left's, the capture lost mid-press, and
//! the right button's press asking for a context menu.
const std = @import("std");
const testing = std.testing;
const ui = @import("../ui/ui.zig");
const w = @import("win32.zig");
const App = @import("app.zig").App;
const Button = @import("../ui/input.zig").Button;

const Seen = struct {
    presses: u32 = 0,
    releases: u32 = 0,
    middle_clicks: u32 = 0,
    right_clicks: u32 = 0,
    secondary_clicks: u32 = 0,
    clicks: u32 = 0,
    button: Button = .left,
    down: bool = false,

    fn view(s: *Seen, c: *ui.Context) void {
        if (c.input.pressed) {
            s.presses += 1;
            s.button = c.input.button;
        }
        if (c.input.released) s.releases += 1;
        s.down = c.input.down;
        const i = c.open(.{ .width = .{ .px = 160 }, .height = .{ .px = 80 } }, null);
        defer c.end();
        const it = c.interact(i, .{});
        if (it.middle_clicked) s.middle_clicks += 1;
        if (it.right_clicked) s.right_clicks += 1;
        if (it.secondary_clicked) s.secondary_clicks += 1;
        if (it.clicked) s.clicks += 1;
    }
};

/// A mouse message's lParam: client pixels, x low, y high.
fn at(x: i16, y: i16) w.LPARAM {
    return @as(w.LPARAM, @as(u16, @bitCast(x))) | (@as(w.LPARAM, @as(u16, @bitCast(y))) << 16);
}

fn hiddenApp(gpa: std.mem.Allocator) !*App {
    const app = try gpa.create(App);
    app.* = .{
        .gpa = gpa,
        .io = std.Io.Threaded.global_single_threaded.io(),
        .options = .{ .quit_on_last_window_closed = false },
        .flags = .{ .hidden = true },
        .gui = true,
    };
    return app;
}

test "mouse buttons: a middle press drags and lets go as the left does, one press at a time" {
    const gpa = testing.allocator;
    const app = try hiddenApp(gpa);
    defer app.destroy();
    var seen: Seen = .{};
    const win = try app.newWindow(.{ .title = "mouse", .width = 200, .height = 120, .visible = false, .content = .{ .view = .init(&seen, Seen.view) } });
    const h = win.hwnd orelse return error.SkipZigTest;
    const s = win.surface.?;
    const in = &s.ctx.input;

    // The middle button: a press of its own, held through moves.
    try testing.expectEqual(@as(?w.LRESULT, 0), s.handle(h, w.WM_MBUTTONDOWN, w.MK_MBUTTON, at(20, 20)));
    try testing.expectEqual(@as(u32, 1), seen.presses);
    try testing.expect(seen.button == .middle and seen.down and in.down);
    _ = s.handle(h, w.WM_MOUSEMOVE, w.MK_MBUTTON, at(60, 30));
    try testing.expect(in.down and in.mouse.x > 20);

    // The left button while it is held: no second press, and its release
    // does not end the middle one's.
    _ = s.handle(h, w.WM_LBUTTONDOWN, w.MK_LBUTTON | w.MK_MBUTTON, at(60, 30));
    try testing.expectEqual(@as(u32, 1), seen.presses);
    try testing.expect(in.button == .middle and in.down);
    _ = s.handle(h, w.WM_LBUTTONUP, w.MK_MBUTTON, at(60, 30));
    try testing.expect(in.down and seen.releases == 0);

    // The middle button let go: a release, a middle click on the box.
    _ = s.handle(h, w.WM_MBUTTONUP, 0, at(60, 30));
    try testing.expect(!in.down and !seen.down);
    try testing.expectEqual(@as(u32, 1), seen.releases);
    try testing.expectEqual(@as(u32, 1), seen.middle_clicks);

    // A left press after the middle drag is the left's.
    _ = s.handle(h, w.WM_LBUTTONDOWN, w.MK_LBUTTON, at(30, 30));
    try testing.expect(seen.button == .left and in.button == .left and in.down);
    _ = s.handle(h, w.WM_MBUTTONDOWN, w.MK_LBUTTON | w.MK_MBUTTON, at(30, 30));
    try testing.expect(in.button == .left);
    _ = s.handle(h, w.WM_MBUTTONUP, w.MK_LBUTTON, at(30, 30));
    try testing.expect(in.down);
    _ = s.handle(h, w.WM_LBUTTONUP, 0, at(30, 30));
    try testing.expect(!in.down);
    try testing.expectEqual(@as(u32, 1), seen.middle_clicks);

    // A double click of the middle button counts two.
    _ = s.handle(h, w.WM_MBUTTONDBLCLK, w.MK_MBUTTON, at(30, 30));
    try testing.expect(in.button == .middle and in.click_count == 2 and in.down);
    _ = s.handle(h, w.WM_MBUTTONUP, 0, at(30, 30));

    // The capture lost mid-drag (Alt+Tab): the press ends, with no
    // release and no click. Our own capture taken again is not that.
    _ = s.handle(h, w.WM_MBUTTONDOWN, w.MK_MBUTTON, at(30, 30));
    const releases = seen.releases;
    const clicks = seen.middle_clicks;
    _ = s.handle(h, w.WM_CAPTURECHANGED, 0, @bitCast(@intFromPtr(h)));
    try testing.expect(in.down);
    try testing.expectEqual(@as(?w.LRESULT, 0), s.handle(h, w.WM_CAPTURECHANGED, 0, 0));
    try testing.expect(!in.down and !seen.down);
    try testing.expectEqual(releases, seen.releases);
    try testing.expectEqual(clicks, seen.middle_clicks);
    // Its late release, if one comes, ends nothing.
    _ = s.handle(h, w.WM_MBUTTONUP, 0, at(30, 30));
    try testing.expectEqual(releases, seen.releases);

    // A stale press (its button no longer held) gives way to the next.
    _ = s.handle(h, w.WM_MBUTTONDOWN, w.MK_MBUTTON, at(30, 30));
    _ = s.handle(h, w.WM_LBUTTONDOWN, w.MK_LBUTTON, at(30, 30));
    try testing.expect(in.button == .left and in.down);
    _ = s.handle(h, w.WM_LBUTTONUP, 0, at(30, 30));
    try testing.expect(!in.down);
}

test "mouse buttons: a right press is a secondary click, not a left one" {
    const gpa = testing.allocator;
    const app = try hiddenApp(gpa);
    defer app.destroy();
    var seen: Seen = .{};
    const win = try app.newWindow(.{ .title = "mouse", .width = 200, .height = 120, .visible = false, .content = .{ .view = .init(&seen, Seen.view) } });
    const h = win.hwnd orelse return error.SkipZigTest;
    const s = win.surface.?;
    const in = &s.ctx.input;

    // The press reaches the view as the right button's and asks the box
    // under it for its context menu. It ends with that frame, as on the
    // Mac, so the window keeps no capture.
    try testing.expectEqual(@as(?w.LRESULT, 0), s.handle(h, w.WM_RBUTTONDOWN, w.MK_RBUTTON, at(20, 20)));
    try testing.expect(seen.button == .right and seen.down and !in.down);
    try testing.expectEqual(@as(u32, 1), seen.right_clicks);
    try testing.expectEqual(@as(u32, 1), seen.secondary_clicks);
    try testing.expect(w.GetCapture() != h);

    // Its release is answered (no WM_CONTEXTMENU follows) and is no click.
    try testing.expectEqual(@as(?w.LRESULT, 0), s.handle(h, w.WM_RBUTTONUP, 0, at(20, 20)));
    try testing.expectEqual(@as(u32, 0), seen.clicks);

    // A double click of the right button counts two.
    _ = s.handle(h, w.WM_RBUTTONDBLCLK, w.MK_RBUTTON, at(20, 20));
    try testing.expect(in.button == .right and in.click_count == 2);
    try testing.expectEqual(@as(u32, 2), seen.right_clicks);
    _ = s.handle(h, w.WM_RBUTTONUP, 0, at(20, 20));

    // A left click afterwards is the left's, and asks for no menu.
    _ = s.handle(h, w.WM_LBUTTONDOWN, w.MK_LBUTTON, at(20, 20));
    try testing.expect(w.GetCapture() == h);
    _ = s.handle(h, w.WM_LBUTTONUP, 0, at(20, 20));
    try testing.expect(w.GetCapture() != h);
    try testing.expectEqual(@as(u32, 1), seen.clicks);
    try testing.expectEqual(@as(u32, 2), seen.right_clicks);
    try testing.expectEqual(@as(u32, 2), seen.secondary_clicks);
}
