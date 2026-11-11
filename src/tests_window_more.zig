//! More of the Mac window, never shown: windows opened while the app runs
//! (a second window from a menu) and closed by the app with `on_close`
//! told; the frame; keys as the view gets them (Shift+1 as '1' with
//! Shift, a bare letter), keys let go (Command's too, which AppKit drops),
//! all of them when the window stops being key, and auto-repeat; the
//! menu's key equivalents held back for a view that captures chords.
const std = @import("std");
const testing = std.testing;
const objc = @import("objc.zig");
const ui = @import("ui/ui.zig");
const App = @import("app.zig").App;
const Window = @import("window.zig").Window;

const Keys = struct {
    got: ?ui.Shortcut = null,
    up: ?ui.Shortcut = null,
    repeated: bool = false,
    supported: bool = false,
    released: u32 = 0,
    take: bool = true,
    closed: u32 = 0,
    frames: u32 = 0,

    fn view(k: *Keys, c: *ui.Context) void {
        k.frames += 1;
        k.supported = c.key_up_supported;
        if (c.input.key_up) |u| k.up = u;
        if (c.input.keys_released) k.released += 1;
        if (c.input.shortcut) |s| {
            k.got = s;
            k.repeated = c.input.repeat;
            if (k.take) _ = c.shortcut(s);
        }
        ui.text(c, "keys", .{});
    }

    fn onClose(ctx: *anyopaque, _: *Window) void {
        const k: *Keys = @ptrCast(@alignCast(ctx));
        k.closed += 1;
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

/// A key press as AppKit makes it: `chars` typed, `ign` without modifiers.
fn keyEvent(code: u16, flags: objc.NSUInteger, chars: []const u8, ign: []const u8) objc.Object {
    return keyEventOf(10, code, flags, chars, ign, objc.NO);
}

/// NSEventTypeKeyDown (10) or NSEventTypeKeyUp (11), repeated or not.
fn keyEventOf(kind: objc.NSUInteger, code: u16, flags: objc.NSUInteger, chars: []const u8, ign: []const u8, repeat: objc.BOOL) objc.Object {
    return objc.msg(objc.Object, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{
        kind, objc.CGPoint{}, flags, @as(f64, 0), @as(objc.NSInteger, 0), @as(?objc.Object, null), objc.nsString(chars), objc.nsString(ign), repeat, code,
    });
}

const shift: objc.NSUInteger = 1 << 17;
const cmd: objc.NSUInteger = 1 << 20;

test "a window opened while the app runs, closed by the app, tells on_close" {
    const app = try makeApp(testing.allocator);
    defer freeApp(app);
    var k: Keys = .{};
    _ = try app.newWindow(.{ .title = "main", .width = 300, .height = 200, .visible = false, .content = .{ .view = .init(&k, Keys.view) } });
    // As after `run` began: a second window from a menu.
    app.running = true;
    const aux = try app.newWindow(.{ .title = "aux", .width = 240, .height = 160, .resizable = false, .visible = false, .on_close = .{ .ctx = &k, .func = Keys.onClose }, .content = .{ .view = .init(&k, Keys.view) } });
    try testing.expectEqual(@as(usize, 2), app.windows.items.len);
    const f = aux.frame();
    try testing.expectEqual(@as(f64, 240), f.width);
    try testing.expect(f.height >= 160);
    aux.close();
    try testing.expectEqual(@as(u32, 1), k.closed);
    try testing.expectEqual(@as(usize, 1), app.windows.items.len);
    try testing.expect(!app.stopping);
}

test "Shift+1 reaches the view as '1' with Shift, a bare letter as itself" {
    const pool = objc.Pool.push();
    defer pool.pop();
    const app = try makeApp(testing.allocator);
    defer freeApp(app);
    var k: Keys = .{};
    const w = try app.newWindow(.{ .title = "keys", .width = 200, .height = 120, .visible = false, .content = .{ .view = .init(&k, Keys.view) } });
    const view = w.surface.?.nsview;
    objc.msg(void, view, "keyDown:", .{keyEvent(18, shift, "!", "!")});
    const s = k.got orelse return error.NoShortcut;
    try testing.expectEqual(@as(u21, '1'), s.key);
    try testing.expect(s.shift and !s.cmd and !s.ctrl and !s.alt);
    k.got = null;
    objc.msg(void, view, "keyDown:", .{keyEvent(0, 0, "a", "a")});
    try testing.expectEqual(@as(u21, 'a'), k.got.?.key);
    try testing.expect(!k.got.?.shift);
    // Home, with no modifiers.
    k.got = null;
    objc.msg(void, view, "keyDown:", .{keyEvent(115, 0, "\u{F729}", "\u{F729}")});
    try testing.expectEqual(ui.Shortcut.home, k.got.?.key);
}

test "keyUp: the view sees the key let go, with its modifiers" {
    const pool = objc.Pool.push();
    defer pool.pop();
    const app = try makeApp(testing.allocator);
    defer freeApp(app);
    var k: Keys = .{};
    const w = try app.newWindow(.{ .title = "up", .width = 200, .height = 120, .visible = false, .content = .{ .view = .init(&k, Keys.view) } });
    const view = w.surface.?.nsview;
    try testing.expect(k.supported);
    // K, with Shift held: named as the shortcut names it, 'k' with Shift.
    objc.msg(void, view, "keyUp:", .{keyEventOf(11, 40, shift, "K", "K", objc.NO)});
    const u = k.up orelse return error.NoKeyUp;
    try testing.expectEqual(@as(u21, 'k'), u.key);
    try testing.expect(u.shift and !u.cmd and !u.alt);
    try testing.expect(w.surface.?.ctx.input.key_up == null);
    // An arrow: AppKit's code point.
    k.up = null;
    objc.msg(void, view, "keyUp:", .{keyEventOf(11, 123, 0, "\u{F702}", "\u{F702}", objc.NO)});
    try testing.expectEqual(ui.Shortcut.left, k.up.?.key);
}

test "a key let go with Command held reaches the view; resigning key lets every key go" {
    const pool = objc.Pool.push();
    defer pool.pop();
    const app = try makeApp(testing.allocator);
    defer freeApp(app);
    var k: Keys = .{};
    const w = try app.newWindow(.{ .title = "cmd-up", .width = 200, .height = 120, .visible = false, .content = .{ .view = .init(&k, Keys.view) } });
    const surface_keys = @import("ui/surface_keys.zig");
    // L held, then ⌘ pressed, then L let go: the key-up carries Command.
    try testing.expect(surface_keys.sendCommandKeyUp(w.nswindow, keyEventOf(11, 37, cmd, "l", "l", objc.NO)));
    const u = k.up orelse return error.NoKeyUp;
    try testing.expectEqual(@as(u21, 'l'), u.key);
    try testing.expect(u.cmd);
    // One without Command goes AppKit's own way.
    try testing.expect(!surface_keys.sendCommandKeyUp(w.nswindow, keyEventOf(11, 37, 0, "l", "l", objc.NO)));
    const s = w.surface.?;
    s.ctx.input.shift = true;
    surface_keys.keyWindowChanged(s, false);
    try testing.expectEqual(@as(u32, 1), k.released);
    try testing.expect(!s.ctx.input.shift and !s.ctx.input.keys_released);
}

test "a repeated keyDown: sets input.repeat" {
    const pool = objc.Pool.push();
    defer pool.pop();
    const app = try makeApp(testing.allocator);
    defer freeApp(app);
    var k: Keys = .{};
    const w = try app.newWindow(.{ .title = "repeat", .width = 200, .height = 120, .visible = false, .content = .{ .view = .init(&k, Keys.view) } });
    const view = w.surface.?.nsview;
    objc.msg(void, view, "keyDown:", .{keyEventOf(10, 38, 0, "j", "j", objc.NO)});
    try testing.expectEqual(@as(u21, 'j'), k.got.?.key);
    try testing.expect(!k.repeated);
    objc.msg(void, view, "keyDown:", .{keyEventOf(10, 38, 0, "j", "j", objc.YES)});
    try testing.expect(k.repeated);
    try testing.expect(!w.surface.?.ctx.input.repeat);
}

test "with menu key equivalents held back, a chord goes to the focused view" {
    const pool = objc.Pool.push();
    defer pool.pop();
    const app = try makeApp(testing.allocator);
    defer freeApp(app);
    var k: Keys = .{};
    const w = try app.newWindow(.{ .title = "capture", .width = 200, .height = 120, .visible = false, .content = .{ .view = .init(&k, Keys.view) } });
    const view = w.surface.?.nsview;
    _ = objc.msg(objc.BOOL, w.nswindow, "makeFirstResponder:", .{view});
    const ev = keyEvent(17, cmd, "t", "t");
    try testing.expect(objc.msg(objc.BOOL, view, "performKeyEquivalent:", .{ev}) == objc.NO);
    try testing.expect(k.got == null);
    ui.suspendMenuKeyEquivalents(true);
    defer ui.suspendMenuKeyEquivalents(false);
    try testing.expect(objc.msg(objc.BOOL, view, "performKeyEquivalent:", .{ev}) == objc.YES);
    try testing.expectEqual(@as(u21, 't'), k.got.?.key);
    try testing.expect(k.got.?.cmd);
    // The menu bar says no while held back.
    const m = try @import("menu.zig").Menu.create(testing.allocator, "Test", &.{
        .{ .label = "File", .submenu = &.{.{ .label = "New Tab", .id = "t", .accelerator = "Cmd+T" }} },
    });
    defer m.destroy();
    try testing.expect(objc.msg(objc.BOOL, m.ns, "performKeyEquivalent:", .{ev}) == objc.NO);
}

test "a view that closes its window inside an event frame does not touch the freed surface" {
    const pool = objc.Pool.push();
    defer pool.pop();
    const app = try makeApp(testing.allocator);
    defer freeApp(app);

    const Closer = struct {
        w: ?*Window = null,
        buf: ui.TextBuffer = .{},
        fn view(self: *@This(), c: *ui.Context) void {
            const tf = ui.textField(c, &self.buf, .{ .width = .{ .px = 160 } });
            if (c.focus == 0) c.focusCycle(false);
            if (tf.submitted or c.shortcut(.{ .key = 'w', .cmd = true }) or ui.button(c, "Close", .{}).clicked) {
                if (self.w) |win| {
                    self.w = null;
                    win.close();
                }
            }
        }
    };

    // 1. Closing on a shortcut inside keyDown:
    {
        var cl: Closer = .{};
        defer cl.buf.deinit();
        cl.w = try app.newWindow(.{ .title = "close-key", .width = 200, .height = 120, .visible = false, .content = .{ .view = .init(&cl, Closer.view) } });
        const nsview = cl.w.?.surface.?.nsview;
        objc.msg(void, nsview, "keyDown:", .{keyEvent(13, cmd, "w", "w")});
        try testing.expect(cl.w == null);
    }

    // 2. Closing on insertNewline: inside textinput.flush
    {
        var cl: Closer = .{};
        defer cl.buf.deinit();
        cl.w = try app.newWindow(.{ .title = "close-enter", .width = 200, .height = 120, .visible = false, .content = .{ .view = .init(&cl, Closer.view) } });
        const nsview = cl.w.?.surface.?.nsview;
        objc.msg(void, nsview, "doCommandBySelector:", .{objc.sel("insertNewline:")});
        try testing.expect(cl.w == null);
    }
}
