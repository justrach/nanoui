//! A title bar the app draws (`chrome.zig`), the frame kept between
//! launches (`window_place.zig`) and the surface's `after_frame`, on real
//! hidden windows: `WM_NCCALCSIZE`'s client area, the codes
//! `WM_NCHITTEST` answers at the edges, the caption and the maximize
//! button, the pointer over that button reaching the view, and a
//! placement written and given back. The idioms are `tests_window.zig`'s.
const std = @import("std");
const testing = std.testing;
const ui = @import("../ui/ui.zig");
const App = @import("app.zig").App;
const Window = @import("window.zig").Window;
const Surface = @import("surface.zig").Surface;
const loop = @import("loop.zig");
const w = @import("win32.zig");
const chrome = @import("chrome.zig");
const place = @import("window_place.zig");
const TitleBar = @import("window.zig").TitleBar;

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

/// A title bar of the app's own: a drag handle (0 to 200 pt), the
/// maximize button (200 to 240) and a plain button (240 to 280) in a band
/// 40 pt tall, and the content under it.
const Bar = struct {
    max_hovered: bool = false,
    max_clicks: u32 = 0,
    content_id: u64 = 0,
    fn view(s: *Bar, c: *ui.Context) void {
        const root = c.open(.{ .direction = .column, .width = .fill, .height = .fill }, null);
        defer c.end();
        _ = root;
        {
            _ = c.open(.{ .direction = .row, .width = .fill, .height = .{ .px = 40 } }, null);
            defer c.end();
            const drag = c.open(.{ .width = .{ .px = 200 }, .height = .fill, .window_drag = true }, null);
            _ = c.interact(drag, .{});
            c.end();
            const max = c.open(.{ .width = .{ .px = 40 }, .height = .fill, .window_maximize = true }, "max");
            const it = c.interact(max, .{});
            if (it.hovered) s.max_hovered = true;
            if (it.clicked) s.max_clicks += 1;
            c.end();
            const plain = c.open(.{ .width = .{ .px = 40 }, .height = .fill }, null);
            _ = c.interact(plain, .{});
            c.end();
        }
        const content = c.open(.{ .width = .fill, .height = .fill }, "content");
        _ = c.interact(content, .{});
        s.content_id = c.node(content).id;
        c.end();
    }
};

fn lparam(x: i32, y: i32) w.LPARAM {
    const lo: u16 = @bitCast(@as(i16, @truncate(x)));
    const hi: u16 = @bitCast(@as(i16, @truncate(y)));
    return @bitCast(@as(usize, lo) | (@as(usize, hi) << 16));
}

/// The screen point `(x, y)` points into the client area.
fn screenAt(h: w.HWND, x: f32, y: f32) w.POINT {
    const dpi = w.GetDpiForWindow(h);
    const s: f32 = if (dpi > 0) @as(f32, @floatFromInt(dpi)) / 96 else 1;
    var p: w.POINT = .{ .x = @intFromFloat(@round(x * s)), .y = @intFromFloat(@round(y * s)) };
    _ = w.ClientToScreen(h, &p);
    return p;
}

fn hit(h: w.HWND, p: w.POINT) u32 {
    return @intCast(w.SendMessageW(h, chrome.WM_NCHITTEST, 0, lparam(p.x, p.y)));
}

fn chromeless(app: *App, bar: *Bar, title_bar: TitleBar) !*Window {
    return app.newWindow(.{
        .title = "chrome",
        .width = 400,
        .height = 260,
        .visible = false,
        .title_bar = title_bar,
        .content = .{ .view = .init(bar, Bar.view) },
    });
}

test "a hidden title bar's client area reaches the window's top and keeps its size" {
    const gpa = testing.allocator;
    const app = try makeApp(gpa);
    defer app.destroy();
    for ([_]TitleBar{.hidden}) |kind| {
        var bar: Bar = .{};
        const win = try chromeless(app, &bar, kind);
        const h = win.hwnd orelse return error.SkipZigTest;
        loop.runFor(0.05);
        var client: w.RECT = .{};
        _ = w.GetClientRect(h, &client);
        const dpi = w.GetDpiForWindow(h);
        const s: f64 = if (dpi > 0) @as(f64, @floatFromInt(dpi)) / 96 else 1;
        try testing.expectEqual(@as(i32, @intFromFloat(400 * s)), client.right);
        try testing.expectEqual(@as(i32, @intFromFloat(260 * s)), client.bottom);
        // WM_NCCALCSIZE gave the top band to the client: its first row is
        // the window's first row; the sides and bottom keep a frame.
        var outer: w.RECT = .{};
        _ = w.GetWindowRect(h, &outer);
        var origin: w.POINT = .{};
        _ = w.ClientToScreen(h, &origin);
        try testing.expectEqual(outer.top, origin.y);
        try testing.expect(origin.x >= outer.left);
        try testing.expectEqual(outer.bottom - origin.y - client.bottom, origin.x - outer.left);
        // The system caption's height, until the view sets its own.
        try testing.expectEqual(chrome.title_bar_height, win.surface.?.ctx.title_bar_height);
        win.destroyNow();
    }
}

test "WM_NCHITTEST: the edges' grips, the caption, the maximize button and the view" {
    const gpa = testing.allocator;
    const app = try makeApp(gpa);
    defer app.destroy();
    var bar: Bar = .{};
    const win = try chromeless(app, &bar, .hidden);
    defer win.destroyNow();
    const h = win.hwnd orelse return error.SkipZigTest;
    loop.runFor(0.05);
    const dpi = w.GetDpiForWindow(h);
    const s: f32 = if (dpi > 0) @as(f32, @floatFromInt(dpi)) / 96 else 1;
    const top_band: f32 = @as(f32, @floatFromInt(chrome.frameTop(dpi))) / s;
    // The reclaimed band's grips, over the drag handle and at the corners.
    try testing.expectEqual(chrome.HTTOP, hit(h, screenAt(h, 100, top_band * 0.5)));
    try testing.expectEqual(chrome.HTTOPLEFT, hit(h, screenAt(h, 0, 0)));
    try testing.expectEqual(chrome.HTTOPRIGHT, hit(h, screenAt(h, 399.5, 0)));
    // What the view drew: the drag handle is the caption, the maximize
    // button the system's, a plain button and the content the view's.
    try testing.expectEqual(chrome.HTCAPTION, hit(h, screenAt(h, 100, 20)));
    try testing.expectEqual(chrome.HTMAXBUTTON, hit(h, screenAt(h, 220, 20)));
    try testing.expectEqual(chrome.HTCLIENT, hit(h, screenAt(h, 260, 20)));
    try testing.expectEqual(chrome.HTCLIENT, hit(h, screenAt(h, 100, 120)));
    // The band's empty part: the caption above `title_bar_height`, the
    // view's below.
    try testing.expectEqual(chrome.HTCAPTION, hit(h, screenAt(h, 340, 20)));
    try testing.expectEqual(chrome.HTCLIENT, hit(h, screenAt(h, 340, 36)));
    // The sides and the bottom are still the system's frame.
    var outer: w.RECT = .{};
    _ = w.GetWindowRect(h, &outer);
    const mid = @divTrunc(outer.top + outer.bottom, 2);
    try testing.expectEqual(chrome.HTLEFT, hit(h, .{ .x = outer.left + 1, .y = mid }));
    try testing.expectEqual(chrome.HTRIGHT, hit(h, .{ .x = outer.right - 2, .y = mid }));
    try testing.expectEqual(chrome.HTBOTTOM, hit(h, .{ .x = @divTrunc(outer.left + outer.right, 2), .y = outer.bottom - 2 }));
    // A window that cannot maximize offers no snap layouts.
    win.setResizable(false);
    try testing.expectEqual(chrome.HTCLIENT, hit(h, screenAt(h, 220, 20)));
    // Not resizable: no top grip, the caption reaches the top.
    try testing.expectEqual(chrome.HTCAPTION, hit(h, screenAt(h, 100, top_band * 0.5)));
}

test "the pointer over the maximize button reaches the view: hover and click" {
    const gpa = testing.allocator;
    const app = try makeApp(gpa);
    defer app.destroy();
    var bar: Bar = .{};
    const win = try chromeless(app, &bar, .hidden);
    defer win.destroyNow();
    const h = win.hwnd orelse return error.SkipZigTest;
    loop.runFor(0.05);
    const p = screenAt(h, 220, 20);
    _ = w.SendMessageW(h, chrome.WM_NCMOUSEMOVE, chrome.HTMAXBUTTON, lparam(p.x, p.y));
    try testing.expect(bar.max_hovered);
    _ = w.SendMessageW(h, chrome.WM_NCLBUTTONDOWN, chrome.HTMAXBUTTON, lparam(p.x, p.y));
    _ = w.SendMessageW(h, chrome.WM_NCLBUTTONUP, chrome.HTMAXBUTTON, lparam(p.x, p.y));
    try testing.expectEqual(@as(u32, 1), bar.max_clicks);
    // Elsewhere in the frame the messages are the system's.
    _ = w.SendMessageW(h, chrome.WM_NCLBUTTONUP, chrome.HTCAPTION, lparam(p.x, p.y));
    try testing.expectEqual(@as(u32, 1), bar.max_clicks);
}

test "frame_autosave: a hidden window's placement is kept and given back" {
    const gpa = testing.allocator;
    const app = try makeApp(gpa);
    defer app.destroy();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [256]u8 = undefined;
    app.placement_dir = try std.fmt.bufPrint(&dir_buf, ".zig-cache\\tmp\\{s}", .{tmp.sub_path});
    var bar: Bar = .{};
    const options: @import("window.zig").Options = .{ .title = "kept", .width = 320, .height = 200, .visible = false, .frame_autosave = "TestMain", .content = .{ .view = .init(&bar, Bar.view) } };
    const first = try app.newWindow(options);
    const h1 = first.hwnd orelse return error.SkipZigTest;
    first.setPosition(140, 90);
    first.setSize(360, 240);
    var kept: w.RECT = .{};
    _ = w.GetWindowRect(h1, &kept);
    first.destroyNow();
    // Written as it closed.
    var buf: [128]u8 = undefined;
    const text = try tmp.dir.readFile(app.io, "TestMain.placement", &buf);
    try testing.expect(place.decode(text) != null);
    // A window made with the name opens where the first one was, at its
    // size, whatever its own options say — and stays hidden.
    var again = options;
    again.width = 200;
    again.height = 120;
    const second = try app.newWindow(again);
    defer second.destroyNow();
    const h2 = second.hwnd.?;
    var got: w.RECT = .{};
    _ = w.GetWindowRect(h2, &got);
    try testing.expectEqual(kept, got);
    try testing.expect(w.IsWindowVisible(h2) == 0);
    // Without a name, nothing is kept or read.
    var plain = options;
    plain.frame_autosave = null;
    const third = try app.newWindow(plain);
    defer third.destroyNow();
    var r3: w.RECT = .{};
    _ = w.GetWindowRect(third.hwnd.?, &r3);
    try testing.expect(!std.meta.eql(kept, r3));
}

const Hook = struct {
    bar: *Bar,
    calls: u32 = 0,
    content: ?ui.Rect = null,
    fn after(ctx: ?*anyopaque, s: *Surface) bool {
        const self: *Hook = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        self.content = s.ctx.rects.get(self.bar.content_id);
        return false;
    }
};

test "after_frame runs after each frame with its layout" {
    const gpa = testing.allocator;
    const app = try makeApp(gpa);
    defer app.destroy();
    var bar: Bar = .{};
    const win = try chromeless(app, &bar, .hidden);
    defer win.destroyNow();
    const h = win.hwnd orelse return error.SkipZigTest;
    const s = win.surface.?;
    var hook: Hook = .{ .bar = &bar };
    s.after_frame_ctx = &hook;
    s.after_frame = Hook.after;
    s.frame();
    try testing.expect(hook.calls >= 1);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(h)), s.nativeHandle());
    const r = hook.content orelse return error.NoContentRect;
    try testing.expectEqual(@as(f32, 40), r.y);
}
