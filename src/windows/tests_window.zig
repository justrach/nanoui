//! The window's own tests: what `Options` asks of Win32 — the size a client
//! area comes out at, topmost, the `should_close` veto, resizability, the
//! opacity a window that was made opaque can still take, where a borderless
//! window maximises — and the timers. The idioms are `tests_surface.zig`'s:
//! real hidden windows, real style bits, and messages pumped by `runFor`.

const std = @import("std");
const testing = std.testing;
const ui = @import("../ui/ui.zig");
const App = @import("app.zig").App;
const Window = @import("window.zig").Window;
const loop = @import("loop.zig");
const w = @import("win32.zig");

const Page = struct {
    fn view(_: *Page, c: *ui.Context) void {
        const root = ui.div(c).p(10);
        defer root.end();
        ui.text(c, "window", .{});
    }
};

fn makeApp(gpa: std.mem.Allocator) !*App {
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

fn styleOf(h: w.HWND) u32 {
    return @bitCast(@as(i32, @truncate(w.GetWindowLongPtrW(h, w.GWL_STYLE))));
}

fn exStyleOf(h: w.HWND) u32 {
    return @bitCast(@as(i32, @truncate(w.GetWindowLongPtrW(h, w.GWL_EXSTYLE))));
}

test "a window's client area is the size that was asked, borderless or not" {
    const gpa = testing.allocator;
    const app = try makeApp(gpa);
    defer app.destroy();
    var p: Page = .{};
    // A borderless window used to be sized with the decorated style's border
    // added on: 200 points of client came out as ~216.
    for ([_]bool{ true, false }) |decorated| {
        const win = try app.newWindow(.{
            .title = "size",
            .width = 200,
            .height = 120,
            .visible = false,
            .decorations = decorated,
            .content = .{ .view = .init(&p, Page.view) },
        });
        const h = win.hwnd orelse return error.SkipZigTest;
        var r: w.RECT = .{};
        _ = w.GetClientRect(h, &r);
        const dpi = w.GetDpiForWindow(h);
        const s: f64 = if (dpi > 0) @as(f64, @floatFromInt(dpi)) / 96 else 1;
        try testing.expectEqual(@as(i32, @intFromFloat(200 * s)), r.right - r.left);
        try testing.expectEqual(@as(i32, @intFromFloat(120 * s)), r.bottom - r.top);
    }
}

test "a window that asks to be above the others is WS_EX_TOPMOST" {
    const gpa = testing.allocator;
    const app = try makeApp(gpa);
    defer app.destroy();
    var p: Page = .{};
    const win = try app.newWindow(.{
        .title = "topmost",
        .width = 160,
        .height = 100,
        .visible = false,
        .always_on_top = true,
        .content = .{ .view = .init(&p, Page.view) },
    });
    const h = win.hwnd orelse return error.SkipZigTest;
    try testing.expect(exStyleOf(h) & w.WS_EX_TOPMOST != 0);
}

const Veto = struct {
    allow: bool = false,
    asked: u32 = 0,
    closed: bool = false,

    fn shouldClose(ctx: *anyopaque, _: *Window) bool {
        const self: *Veto = @ptrCast(@alignCast(ctx));
        self.asked += 1;
        return self.allow;
    }

    fn onClose(ctx: *anyopaque, _: *Window) void {
        const self: *Veto = @ptrCast(@alignCast(ctx));
        self.closed = true;
    }
};

test "should_close keeps the window up until it says yes" {
    const gpa = testing.allocator;
    const app = try makeApp(gpa);
    defer app.destroy();
    var p: Page = .{};
    var v: Veto = .{};
    const win = try app.newWindow(.{
        .title = "veto",
        .width = 160,
        .height = 100,
        .visible = false,
        .should_close = .{ .ctx = &v, .func = Veto.shouldClose },
        .on_close = .{ .ctx = &v, .func = Veto.onClose },
        .content = .{ .view = .init(&p, Page.view) },
    });
    // The system's close button, and a deferred `close`, land as WM_CLOSE.
    _ = w.PostMessageW(win.hwnd.?, w.WM_CLOSE, 0, 0);
    loop.runFor(0.1);
    try testing.expectEqual(@as(u32, 1), v.asked);
    try testing.expect(!v.closed);
    try testing.expectEqual(@as(usize, 1), app.windows.items.len);
    // The veto withdrawn: the next one destroys it for real.
    v.allow = true;
    win.close();
    loop.runFor(0.1);
    try testing.expectEqual(@as(u32, 2), v.asked);
    try testing.expect(v.closed);
    try testing.expectEqual(@as(usize, 0), app.windows.items.len);
}

test "resizability is the frame bits, and it comes back" {
    const gpa = testing.allocator;
    const app = try makeApp(gpa);
    defer app.destroy();
    var p: Page = .{};
    const win = try app.newWindow(.{
        .title = "resize",
        .width = 160,
        .height = 100,
        .visible = false,
        .content = .{ .view = .init(&p, Page.view) },
    });
    const h = win.hwnd orelse return error.SkipZigTest;
    try testing.expect(styleOf(h) & w.WS_THICKFRAME != 0);
    win.setResizable(false);
    try testing.expect(styleOf(h) & w.WS_THICKFRAME == 0);
    try testing.expect(styleOf(h) & w.WS_MAXIMIZEBOX == 0);
    win.setResizable(true);
    try testing.expect(styleOf(h) & w.WS_THICKFRAME != 0);
    try testing.expect(styleOf(h) & w.WS_MAXIMIZEBOX != 0);
}

test "a window that was made opaque can still fade" {
    const gpa = testing.allocator;
    const app = try makeApp(gpa);
    defer app.destroy();
    var p: Page = .{};
    const win = try app.newWindow(.{
        .title = "fade",
        .width = 160,
        .height = 100,
        .visible = false,
        .content = .{ .view = .init(&p, Page.view) },
    });
    const h = win.hwnd orelse return error.SkipZigTest;
    try testing.expect(exStyleOf(h) & w.WS_EX_LAYERED == 0);
    // An opacity slider on a window that was made opaque used to change the
    // surface's mind about the GPU and nothing else.
    win.setOpacity(0.5);
    try testing.expectEqual(@as(f64, 0.5), win.opacity);
    try testing.expect(exStyleOf(h) & w.WS_EX_LAYERED != 0);
    win.setOpacity(1);
    try testing.expectEqual(@as(f64, 1), win.opacity);
}

test "a borderless window's maximize is capped to the work area, monitor-relative" {
    const gpa = testing.allocator;
    const app = try makeApp(gpa);
    defer app.destroy();
    var p: Page = .{};
    // Asked headlessly: `WM_GETMINMAXINFO` straight to the window procedure,
    // the message the system sends when it is about to maximize. (Maximizing
    // for real would show and focus a window — never done in tests.)
    const win = try app.newWindow(.{
        .title = "maximize",
        .width = 160,
        .height = 100,
        .visible = false,
        .decorations = false,
        .content = .{ .view = .init(&p, Page.view) },
    });
    const h = win.hwnd orelse return error.SkipZigTest;
    var mm: w.MINMAXINFO = .{};
    _ = w.SendMessageW(h, w.WM_GETMINMAXINFO, 0, @bitCast(@intFromPtr(&mm)));
    const mon = w.MonitorFromWindow(h, 2) orelse return error.SkipZigTest;
    var info: w.MONITORINFO = .{};
    if (w.GetMonitorInfoW(mon, &info) == 0) return error.SkipZigTest;
    // A WS_POPUP left alone covers the whole monitor, taskbar and all: the
    // maximize size is the work area instead...
    try testing.expectEqual(@as(i32, info.rc_work.right - info.rc_work.left), mm.pt_max_size.x);
    try testing.expectEqual(@as(i32, info.rc_work.bottom - info.rc_work.top), mm.pt_max_size.y);
    // ...and the place is the work area as an offset from the monitor's own
    // origin, because `ptMaxPosition` is monitor-relative.
    try testing.expectEqual(@as(i32, info.rc_work.left - info.rc_monitor.left), mm.pt_max_position.x);
    try testing.expectEqual(@as(i32, info.rc_work.top - info.rc_monitor.top), mm.pt_max_position.y);
    // The tracking minimum is the options', scaled to the window's DPI.
    const dpi = w.GetDpiForWindow(h);
    const s: f64 = if (dpi > 0) @as(f64, @floatFromInt(dpi)) / 96 else 1;
    try testing.expectEqual(@as(i32, @intFromFloat(200 * s)), mm.pt_min_track_size.x);
    try testing.expectEqual(@as(i32, @intFromFloat(150 * s)), mm.pt_min_track_size.y);

    // A decorated window's maximize stays the system's business: nothing
    // written into the size or the place.
    const plain = try app.newWindow(.{
        .title = "maximize plain",
        .width = 160,
        .height = 100,
        .visible = false,
        .content = .{ .view = .init(&p, Page.view) },
    });
    var mm2: w.MINMAXINFO = .{};
    _ = w.SendMessageW(plain.hwnd orelse return error.SkipZigTest, w.WM_GETMINMAXINFO, 0, @bitCast(@intFromPtr(&mm2)));
    try testing.expectEqual(@as(i32, 0), mm2.pt_max_size.x);
    try testing.expectEqual(@as(i32, 0), mm2.pt_max_position.x);
}

const Counter = struct { n: u32 = 0 };
fn bump(ctx: ?*anyopaque) callconv(.c) void {
    const c: *Counter = @ptrCast(@alignCast(ctx.?));
    c.n += 1;
}

test "a timer fires once, through the message loop" {
    const gpa = testing.allocator;
    const app = try makeApp(gpa);
    defer app.destroy();
    var c: Counter = .{};
    App.after(1, &c, bump);
    try testing.expectEqual(@as(u32, 0), c.n);
    loop.runFor(0.2);
    try testing.expectEqual(@as(u32, 1), c.n);
}

test "a timer still pending when the app is destroyed never fires" {
    const gpa = testing.allocator;
    const app = try makeApp(gpa);
    var c: Counter = .{};
    // Short enough that the pump below would run it, were it still there.
    App.after(50, &c, bump);
    // A timer that outlived the app used to call into a freed context.
    app.destroy();
    loop.runFor(0.2);
    try testing.expectEqual(@as(u32, 0), c.n);
}

const Wheel = struct {
    got_x: f32 = 0,

    fn view(r: *Wheel, c: *ui.Context) void {
        const root = ui.div(c).p(10);
        defer root.end();
        ui.text(c, "wheel", .{});
        // Recorded in the build the message drove: the scroll is an edge,
        // gone by the next frame.
        if (c.input.scroll.x != 0) r.got_x = c.input.scroll.x;
    }
};

test "the sideways wheel reaches the view along x" {
    const gpa = testing.allocator;
    const app = try makeApp(gpa);
    defer app.destroy();
    var p: Wheel = .{};
    const win = try app.newWindow(.{
        .title = "wheel",
        .width = 160,
        .height = 100,
        .visible = false,
        .content = .{ .view = .init(&p, Wheel.view) },
    });
    const h = win.hwnd orelse return error.SkipZigTest;
    // One notch right: 120 in the high word of wParam. There was no handler
    // at all before, so a tilt or a sideways trackpad slide did nothing.
    _ = w.PostMessageW(h, w.WM_MOUSEHWHEEL, 120 << 16, 0);
    loop.runFor(0.1);
    try testing.expectEqual(@as(f32, 48), p.got_x);
}

test "onMain lands the call on the thread that pumps" {
    const gpa = testing.allocator;
    const app = try makeApp(gpa);
    defer app.destroy();
    // The hand-built app skipped the fdwatch window `onMain` posts through.
    _ = @import("fdwatch.zig").prepare() catch return error.SkipZigTest;
    var c: Counter = .{};
    App.onMain(&c, bump);
    try testing.expectEqual(@as(u32, 0), c.n);
    loop.runFor(0.2);
    try testing.expectEqual(@as(u32, 1), c.n);
}
