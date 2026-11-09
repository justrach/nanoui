//! The Mac window's own tests: what `Options` asks of AppKit. Real windows,
//! never shown, and their style bits, collection behavior and alpha read
//! back from the NSWindow (as `windows/tests_window.zig` reads Win32's).

const std = @import("std");
const testing = std.testing;
const objc = @import("objc.zig");
const ui = @import("ui/ui.zig");
const App = @import("app.zig").App;
const Window = @import("window.zig").Window;

const Page = struct {
    fn view(_: *Page, c: *ui.Context) void {
        ui.text(c, "window", .{});
    }
};

/// An app that runs hidden: no Dock icon, no menus, no focus.
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
    while (app.windows.items.len > 0) app.windows.items[app.windows.items.len - 1].close();
    @import("ui/surface_wake.zig").sweep();
    app.windows.deinit(app.gpa);
    objc.release(app.delegate);
    app.gpa.destroy(app);
}

fn styleMask(w: *Window) objc.NSUInteger {
    return objc.msg(objc.NSUInteger, w.nswindow, "styleMask", .{});
}

fn yes(w: *Window, comptime selector: [:0]const u8) bool {
    return objc.msg(objc.BOOL, w.nswindow, selector, .{}) == objc.YES;
}

test "a window without decorations is borderless and still takes keys" {
    const app = try makeApp(testing.allocator);
    defer freeApp(app);
    var p: Page = .{};
    const plain = try app.newWindow(.{ .title = "plain", .width = 200, .height = 120, .visible = false, .content = .{ .view = .init(&p, Page.view) } });
    const bare = try app.newWindow(.{ .title = "bare", .width = 200, .height = 120, .visible = false, .decorations = false, .title_bar = .hidden, .content = .{ .view = .init(&p, Page.view) } });
    const panel = try app.newWindow(.{ .title = "panel", .width = 200, .height = 120, .visible = false, .decorations = false, .kind = .panel, .content = .{ .view = .init(&p, Page.view) } });

    // Titled (1) stays on a decorated window; a borderless one has no bits.
    try testing.expect(styleMask(plain) & 1 != 0);
    try testing.expectEqual(@as(objc.NSUInteger, 0), styleMask(bare));
    try testing.expectEqual(@as(objc.NSUInteger, 0), styleMask(panel));
    // AppKit says no for a borderless window unless its class says yes.
    try testing.expect(yes(bare, "canBecomeKeyWindow"));
    try testing.expect(yes(bare, "canBecomeMainWindow"));
    try testing.expect(yes(panel, "canBecomeKeyWindow"));
    try testing.expect(objc.msg(objc.BOOL, panel.nswindow, "isKindOfClass:", .{objc.class("NSPanel")}) == objc.YES);
}

test "skip_taskbar leaves Command-` and the Window menu, all_spaces still joins every Space" {
    const app = try makeApp(testing.allocator);
    defer freeApp(app);
    var p: Page = .{};
    const plain = try app.newWindow(.{ .title = "plain", .width = 200, .height = 120, .visible = false, .content = .{ .view = .init(&p, Page.view) } });
    const tool = try app.newWindow(.{ .title = "tool", .width = 200, .height = 120, .visible = false, .skip_taskbar = true, .all_spaces = true, .content = .{ .view = .init(&p, Page.view) } });

    const wanted: objc.NSUInteger = (1 << 0) | (1 << 6) | (1 << 8); // all Spaces, IgnoresCycle, full screen auxiliary
    try testing.expectEqual(wanted, objc.msg(objc.NSUInteger, tool.nswindow, "collectionBehavior", .{}) & wanted);
    try testing.expect(yes(tool, "isExcludedFromWindowsMenu"));
    try testing.expect(objc.msg(objc.NSUInteger, plain.nswindow, "collectionBehavior", .{}) & (1 << 6) == 0);
    try testing.expect(!yes(plain, "isExcludedFromWindowsMenu"));
}

test "opacity is the window's alpha, at creation and after" {
    const app = try makeApp(testing.allocator);
    defer freeApp(app);
    var p: Page = .{};
    const win = try app.newWindow(.{ .title = "glass", .width = 200, .height = 120, .visible = false, .opacity = 0.5, .content = .{ .view = .init(&p, Page.view) } });
    try testing.expectApproxEqAbs(@as(f64, 0.5), objc.msg(f64, win.nswindow, "alphaValue", .{}), 1e-6);
    win.setOpacity(0.25);
    try testing.expectApproxEqAbs(@as(f64, 0.25), objc.msg(f64, win.nswindow, "alphaValue", .{}), 1e-6);
    // Clamped, as on Windows.
    win.setOpacity(3);
    try testing.expectApproxEqAbs(@as(f64, 1), objc.msg(f64, win.nswindow, "alphaValue", .{}), 1e-6);

    // The room for a window beside it, where there is a screen at all.
    const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
    if (objc.msg(objc.NSUInteger, screens, "count", .{}) > 0) {
        const m = win.monitorSize();
        try testing.expect(m[0] > 0 and m[1] > 0);
    }
}

test "traffic_lights puts the buttons in a taller bar, and clicks beside them reach the view" {
    const app = try makeApp(testing.allocator);
    defer freeApp(app);
    var p: Page = .{};
    const win = try app.newWindow(.{ .title = "lights", .width = 600, .height = 400, .visible = false, .title_bar = .hidden, .traffic_lights = .{ .x = 26, .y = 26 }, .content = .{ .view = .init(&p, Page.view) } });

    const check = struct {
        fn at(w: *Window) !void {
            var last_x: f64 = 0;
            for (0..3) |i| {
                const b = objc.msg(objc.Object, w.nswindow, "standardWindowButton:", .{@as(objc.NSUInteger, i)});
                const f = objc.msg(objc.CGRect, b, "frame", .{});
                const bar = objc.msg(objc.Object, b, "superview", .{});
                const bar_h = objc.msg(objc.CGRect, bar, "bounds", .{}).size.height;
                try testing.expectApproxEqAbs(@as(f64, 26), bar_h - (f.origin.y + f.size.height / 2), 0.5);
                if (i == 0) try testing.expectApproxEqAbs(@as(f64, 26), f.origin.x + f.size.width / 2, 0.5) //
                else try testing.expect(f.origin.x - last_x >= 16);
                last_x = f.origin.x;
            }
        }
    }.at;
    try check(win);
    // AppKit lays the title bar out again on a resize: they are put back.
    win.setSize(720, 480);
    try check(win);

    // In the strip, past the buttons but inside the grown title bar: the
    // view takes it, or a tab row there could never be clicked.
    const content = objc.msg(objc.Object, win.nswindow, "contentView", .{});
    const theme_frame = objc.msg(objc.Object, content, "superview", .{});
    const h = objc.msg(objc.CGRect, theme_frame, "bounds", .{}).size.height;
    const hit = objc.msg(?objc.Object, theme_frame, "hitTest:", .{objc.CGPoint{ .x = 300, .y = h - 40 }}) orelse return error.NoHit;
    try testing.expect(objc.msg(objc.BOOL, hit, "isDescendantOf:", .{content}) == objc.YES);
}

test "traffic_lights repairs a layout that finishes after its frame notification" {
    const pool = objc.Pool.push();
    defer pool.pop();
    const app = try makeApp(testing.allocator);
    defer freeApp(app);
    var p: Page = .{};
    const win = try app.newWindow(.{ .title = "lights", .width = 600, .height = 400, .visible = false, .title_bar = .hidden, .traffic_lights = .{ .x = 26, .y = 26 }, .content = .{ .view = .init(&p, Page.view) } });
    const green = objc.msg(objc.Object, win.nswindow, "standardWindowButton:", .{@as(objc.NSUInteger, 2)});
    const center = objc.msg(objc.Object, objc.class("NSNotificationCenter"), "defaultCenter", .{});

    @import("platform.zig").runFor(0.02);
    // Model a reentrant AppKit layout: notification first, then its final
    // green-button write while our placement guard suppresses more callbacks.
    // Repeated notifications must coalesce, not create a self-sustaining loop.
    for (0..3) |_| objc.msg(void, center, "postNotificationName:object:", .{ NSViewFrameDidChangeNotification, green });
    var frame = objc.msg(objc.CGRect, green, "frame", .{});
    frame.origin.y += 20;
    win.lights.?.placing = true;
    objc.msg(void, green, "setFrame:", .{frame});
    win.lights.?.placing = false;
    try testing.expectApproxEqAbs(frame.origin.y, objc.msg(objc.CGRect, green, "frame", .{}).origin.y, 0.5);
    @import("platform.zig").runFor(0.02);

    for (0..3) |i| {
        const b = objc.msg(objc.Object, win.nswindow, "standardWindowButton:", .{@as(objc.NSUInteger, i)});
        const bounds = objc.msg(objc.CGRect, b, "bounds", .{});
        const at = objc.msg(objc.CGPoint, b, "convertPoint:toView:", .{ objc.CGPoint{ .x = bounds.size.width / 2, .y = bounds.size.height / 2 }, @as(?objc.Object, null) });
        const height = objc.msg(objc.CGRect, win.nswindow, "frame", .{}).size.height;
        try testing.expectApproxEqAbs(@as(f64, 26), height - at.y, 0.5);
        try testing.expectApproxEqAbs(26 + @as(f64, @floatFromInt(i)) * win.lights.?.spacing, at.x, 0.5);
    }
    try testing.expect(!win.lights.?.pending);
    try testing.expect(!yes(win, "isVisible"));

    // A queued repair must be harmless when its window closes first.
    objc.msg(void, center, "postNotificationName:object:", .{ NSViewFrameDidChangeNotification, green });
    try testing.expect(win.lights.?.pending);
    win.close();
    @import("platform.zig").runFor(0.02);
    try testing.expectEqual(@as(usize, 0), app.windows.items.len);
}

extern "c" const NSViewFrameDidChangeNotification: objc.Object;

test "traffic_lights is left alone without a hidden title bar" {
    const app = try makeApp(testing.allocator);
    defer freeApp(app);
    var p: Page = .{};
    const win = try app.newWindow(.{ .title = "plain", .width = 300, .height = 200, .visible = false, .traffic_lights = .{ .x = 26, .y = 26 }, .content = .{ .view = .init(&p, Page.view) } });
    try testing.expect(win.lights == null);
}

const wake = @import("ui/surface_wake.zig");

/// Closes a window whose surface has a wake queued `after` seconds out, as
/// the last window of a running app closes. Returns the wake's token. The
/// app is left running: `makeApp`'s `quit_on_last_window_closed = false`
/// keeps the close from quitting it (`stop:` and an event posted here).
fn closeWithWake(app: *App, p: *Page, after: f64) !?*anyopaque {
    const w = try app.newWindow(.{ .title = "closing", .width = 200, .height = 120, .visible = false, .content = .{ .view = .init(p, Page.view) } });
    const s = w.surface.?;
    wake.at(s, @import("ui/cf.zig").CACurrentMediaTime() + after);
    app.running = true;
    w.close();
    return wake.token(s);
}

test "a surface closed with a wake queued is freed when the app stops, though the wake never runs" {
    const app = try makeApp(testing.allocator);
    var p: Page = .{};
    // An hour off, so it never runs: the surface waits for it, and the
    // sweep (`freeApp`, as `App.destroy`) frees it.
    const id = try closeWithWake(app, &p, 3600);
    try testing.expect(wake.find(id) != null);
    app.running = false;
    freeApp(app);
    try testing.expect(wake.find(id) == null);
}

test "a wake that runs after its surface was freed finds nothing" {
    const app = try makeApp(testing.allocator);
    var p: Page = .{};
    const id = try closeWithWake(app, &p, 0);
    app.running = false;
    freeApp(app);
    try testing.expect(wake.find(id) == null);
    // The wake runs now, with no surface for its id.
    @import("platform.zig").runFor(0.05);
}

test "a surface closed with a wake queued is freed by the wake while the app runs" {
    const app = try makeApp(testing.allocator);
    var p: Page = .{};
    const id = try closeWithWake(app, &p, 0);
    // The wake is due now; a loaded machine may take a while to run it.
    var waited: f64 = 0;
    while (wake.find(id) != null and waited < 1) : (waited += 0.02) @import("platform.zig").runFor(0.02);
    try testing.expect(wake.find(id) == null);
    app.running = false;
    freeApp(app);
}

const Moves = struct {
    n: u32 = 0,
    fn onMove(ctx: *anyopaque, _: *Window) void {
        const m: *Moves = @ptrCast(@alignCast(ctx));
        m.n += 1;
    }
};

test "level and ignores_mouse are applied on a hidden window, on its screen, told when it moves" {
    const app = try makeApp(testing.allocator);
    defer freeApp(app);
    var p: Page = .{};
    var buf: [16]@import("screens.zig").Screen = undefined;
    const all = app.screens(&buf);
    const on: ?u32 = if (all.len > 0) all[0].id else null;
    var moves: Moves = .{};
    const feed = try app.newWindow(.{
        .title = "feed",
        .width = 320,
        .height = 180,
        .visible = false,
        .decorations = false,
        .level = .status,
        .ignores_mouse = true,
        .screen = on,
        .x = 40,
        .y = 30,
        .on_move = .{ .ctx = &moves, .func = Moves.onMove },
        .content = .{ .view = .init(&p, Page.view) },
    });
    try testing.expect(!feed.isVisible());
    try testing.expectEqual(@as(objc.NSInteger, 25), objc.msg(objc.NSInteger, feed.nswindow, "level", .{}));
    try testing.expectEqual(@import("window.zig").Level.status, feed.level());
    try testing.expect(yes(feed, "ignoresMouseEvents"));
    feed.setLevel(.screen_saver);
    try testing.expectEqual(@as(objc.NSInteger, 1000), objc.msg(objc.NSInteger, feed.nswindow, "level", .{}));
    feed.setIgnoresMouse(false);
    try testing.expect(!yes(feed, "ignoresMouseEvents"));
    // From the screen's top left.
    if (all.len > 0) {
        const f = feed.frame();
        try testing.expectApproxEqAbs(all[0].frame.x + 40, f.x, 0.5);
        try testing.expectApproxEqAbs(all[0].frame.y + 30, f.y, 0.5);
    }
    // Over a frame of its own, still hidden.
    feed.setFrame(.{ .x = 10, .y = 20, .width = 300, .height = 160 });
    const g = feed.frame();
    try testing.expectApproxEqAbs(@as(f64, 10), g.x, 0.5);
    try testing.expectApproxEqAbs(@as(f64, 160), g.height, 0.5);
    try testing.expect(moves.n > 0);
    try testing.expect(!feed.isVisible());
    // A plain window stacks normally and takes clicks.
    const plain = try app.newWindow(.{ .title = "plain", .width = 200, .height = 120, .visible = false, .content = .{ .view = .init(&p, Page.view) } });
    try testing.expectEqual(@import("window.zig").Level.normal, plain.level());
    try testing.expect(!yes(plain, "ignoresMouseEvents"));
}

const Counter = struct {
    frames: u32 = 0,
    fn view(k: *Counter, c: *ui.Context) void {
        k.frames += 1;
        ui.text(c, "wake", .{});
    }
};

fn asker(w: *Window) void {
    std.Io.sleep(testing.io, .fromMilliseconds(20), .awake) catch {};
    w.redrawFromAnyThread();
    w.redrawFromAnyThread();
}

test "a window redrawn from another thread draws on the main thread" {
    const app = try makeApp(testing.allocator);
    defer freeApp(app);
    var k: Counter = .{};
    const w = try app.newWindow(.{ .title = "wake", .width = 200, .height = 120, .visible = false, .content = .{ .view = .init(&k, Counter.view) } });
    const th = try std.Thread.spawn(.{}, asker, .{w});
    th.join();
    try testing.expect(w.surface.?.wake_pending.load(.acquire));
    const before = k.frames;
    @import("platform.zig").runFor(0.2);
    try testing.expect(!w.surface.?.wake_pending.load(.acquire));
    // Hidden, the frame waits until it shows; either way it was asked for.
    try testing.expect(k.frames > before or w.surface.?.pending or w.surface.?.full_pending);
}
