//! The Mac window's mouse buttons, never shown: the middle button
//! (`otherMouseDown:` with button number 2) as a press of its own, and
//! one press at a time, so another button's press while one is held is
//! ignored, and so is its release; a press whose release is still queued
//! is not stale.
const std = @import("std");
const testing = std.testing;
const objc = @import("objc.zig");
const ui = @import("ui/ui.zig");
const App = @import("app.zig").App;
const events = @import("ui/surface_events.zig");
const Button = @import("ui/input.zig").Button;
const cf = @import("ui/cf.zig");

const Seen = struct {
    presses: u32 = 0,
    releases: u32 = 0,
    button: Button = .left,

    fn view(s: *Seen, c: *ui.Context) void {
        if (c.input.pressed) {
            s.presses += 1;
            s.button = c.input.button;
        }
        if (c.input.released) s.releases += 1;
        ui.text(c, "mouse", .{});
    }
};

fn makeApp(gpa: std.mem.Allocator) !*App {
    const app = try gpa.create(App);
    app.* = .{
        .gpa = gpa,
        .io = testing.io,
        .options = .{ .quit_on_last_window_closed = false },
        .nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{}),
        .delegate = objc.msg(objc.Object, objc.class("NSObject"), "new", .{}),
        .flags = .{ .hidden = true },
    };
    return app;
}

fn freeApp(app: *App) void {
    app.running = false;
    while (app.windows.items.len > 0) app.windows.items[app.windows.items.len - 1].close();
    app.windows.deinit(app.gpa);
    objc.release(app.delegate);
    app.gpa.destroy(app);
}

/// Makes a mouse event without posting it (nothing reaches the screen).
extern "c" fn CGEventCreateMouseEvent(source: ?*anyopaque, kind: u32, at: objc.CGPoint, button: u32) ?*anyopaque;

/// kCGEventLeftMouseDown (1) / Up (2), kCGEventOtherMouseDown (25) / Up
/// (26), as an NSEvent: `+mouseEventWithType:` leaves an other-mouse
/// event's button number 0, a CGEvent carries it (2: the middle).
fn mouseEvent(kind: u32) !objc.Object {
    const button: u32 = if (kind >= 25) 2 else 0;
    const cg = CGEventCreateMouseEvent(null, kind, .{ .x = 30, .y = 30 }, button) orelse return error.NoEvent;
    defer cf.CFRelease(cg);
    return objc.msg(?objc.Object, objc.class("NSEvent"), "eventWithCGEvent:", .{cg}) orelse error.NoEvent;
}

test "mouse buttons: a middle press is its own, and a second button mid-press is ignored" {
    const pool = objc.Pool.push();
    defer pool.pop();
    const app = try makeApp(testing.allocator);
    defer freeApp(app);
    var seen: Seen = .{};
    const win = try app.newWindow(.{ .title = "mouse", .width = 200, .height = 120, .visible = false, .content = .{ .view = .init(&seen, Seen.view) } });
    const s = win.surface.?;
    const view = s.nsview;
    defer events.held_override = null;

    const other_down = try mouseEvent(25);
    // A made-up other-mouse event is the middle button's.
    try testing.expectEqual(@as(objc.NSInteger, 2), objc.msg(objc.NSInteger, other_down, "buttonNumber", .{}));

    // The middle button down: a press, and `button` says which.
    events.held_override = .{ .middle = true };
    objc.msg(void, view, "otherMouseDown:", .{other_down});
    try testing.expectEqual(@as(u32, 1), seen.presses);
    try testing.expect(seen.button == .middle and s.ctx.input.down);

    // The left button while it is held: no press, its release ends nothing.
    events.held_override = .{ .left = true, .middle = true };
    objc.msg(void, view, "mouseDown:", .{try mouseEvent(1)});
    try testing.expectEqual(@as(u32, 1), seen.presses);
    try testing.expect(s.ctx.input.button == .middle);
    objc.msg(void, view, "mouseUp:", .{try mouseEvent(2)});
    try testing.expect(s.ctx.input.down and seen.releases == 0);

    // The middle button let go: the release.
    events.held_override = .{};
    objc.msg(void, view, "otherMouseUp:", .{try mouseEvent(26)});
    try testing.expect(!s.ctx.input.down);
    try testing.expectEqual(@as(u32, 1), seen.releases);

    // A left press after the middle drag is the left's, and a middle press
    // during it is ignored too.
    events.held_override = .{ .left = true };
    objc.msg(void, view, "mouseDown:", .{try mouseEvent(1)});
    try testing.expect(seen.button == .left and s.ctx.input.down);
    events.held_override = .{ .left = true, .middle = true };
    objc.msg(void, view, "otherMouseDown:", .{other_down});
    try testing.expectEqual(@as(u32, 2), seen.presses);
    objc.msg(void, view, "otherMouseUp:", .{try mouseEvent(26)});
    try testing.expect(s.ctx.input.down and s.ctx.input.button == .left);
    events.held_override = .{};
    objc.msg(void, view, "mouseUp:", .{try mouseEvent(2)});
    try testing.expect(!s.ctx.input.down);
    try testing.expectEqual(@as(u32, 2), seen.releases);

    // A stale press (its release went elsewhere) gives way to the next.
    events.held_override = .{ .middle = true };
    objc.msg(void, view, "otherMouseDown:", .{other_down});
    events.held_override = .{ .left = true };
    objc.msg(void, view, "mouseDown:", .{try mouseEvent(1)});
    try testing.expect(s.ctx.input.button == .left and s.ctx.input.down);
    try testing.expectEqual(@as(u32, 4), seen.presses);
}

/// The app's next queued event of `mask`, taken off the queue.
fn takeQueued(mask: objc.NSUInteger) ?objc.Object {
    const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    const past = objc.msg(objc.Object, objc.class("NSDate"), "distantPast", .{});
    return objc.msg(?objc.Object, nsapp, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{ mask, past, objc.nsString(events.peek_mode), objc.YES });
}

fn drainLeftUps() void {
    while (takeQueued(1 << 2) != null) {}
}

test "mouse buttons: a press whose release is still queued is not stale" {
    const pool = objc.Pool.push();
    defer pool.pop();
    const app = try makeApp(testing.allocator);
    defer freeApp(app);
    var seen: Seen = .{};
    const win = try app.newWindow(.{ .title = "mouse", .width = 200, .height = 120, .visible = false, .content = .{ .view = .init(&seen, Seen.view) } });
    const s = win.surface.?;
    const view = s.nsview;
    defer events.held_override = null;
    const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    // Nothing of ours left in the queue, whatever happens.
    defer drainLeftUps();

    // A left drag in flight.
    events.held_override = .{ .left = true };
    objc.msg(void, view, "mouseDown:", .{try mouseEvent(1)});
    try testing.expect(seen.button == .left and s.ctx.input.down);

    // A slow frame: the middle button went down, then the left came up,
    // and both wait in the queue. As the middle press is handled the
    // mouse already says the left is up, but its release is behind it:
    // the middle press is ignored, the left drag goes on.
    objc.msg(void, nsapp, "postEvent:atStart:", .{ try mouseEvent(2), objc.NO });
    events.held_override = .{ .middle = true };
    objc.msg(void, view, "otherMouseDown:", .{try mouseEvent(25)});
    try testing.expectEqual(@as(u32, 1), seen.presses);
    try testing.expect(s.ctx.input.button == .left and s.ctx.input.down);

    // The queued release reaches the view and ends the left drag; the
    // middle button's release then ends nothing.
    const up = takeQueued(1 << 2) orelse return error.NotQueued;
    objc.msg(void, view, "mouseUp:", .{up});
    try testing.expect(!s.ctx.input.down);
    try testing.expectEqual(@as(u32, 1), seen.releases);
    events.held_override = .{};
    objc.msg(void, view, "otherMouseUp:", .{try mouseEvent(26)});
    try testing.expectEqual(@as(u32, 1), seen.releases);

    // With no release queued, the same press is stale and gives way.
    events.held_override = .{ .left = true };
    objc.msg(void, view, "mouseDown:", .{try mouseEvent(1)});
    events.held_override = .{ .middle = true };
    objc.msg(void, view, "otherMouseDown:", .{try mouseEvent(25)});
    try testing.expect(s.ctx.input.button == .middle and s.ctx.input.down);
    try testing.expectEqual(@as(u32, 3), seen.presses);
}
