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
