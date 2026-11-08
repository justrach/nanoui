//! WM_DROPFILES through a real, hidden window: a synthetic HDROP needs no
//! screen input, and Windows itself reads the paths and point back out.
const std = @import("std");
const testing = std.testing;
const w = @import("win32.zig");
const ui = @import("../ui/ui.zig");
const App = @import("app.zig").App;

const DROPFILES = extern struct {
    p_files: u32,
    pt: w.POINT,
    f_nc: w.BOOL,
    f_wide: w.BOOL,
};

/// The shell's HDROP layout: DROPFILES, then null-terminated UTF-16 paths,
/// with one more null to end the list. The receiver's DragFinish owns it next.
fn makeHDrop(paths: []const []const u8, point: w.POINT) !w.HDROP {
    var units: usize = 1;
    for (paths) |path| units += (try std.unicode.calcUtf16LeLen(path)) + 1;
    const mem = w.GlobalAlloc(w.GMEM_MOVEABLE, @sizeOf(DROPFILES) + units * 2) orelse return error.GlobalAlloc;
    errdefer _ = w.GlobalFree(mem);
    const raw: [*]u8 = @ptrCast(@alignCast(w.GlobalLock(mem) orelse return error.GlobalLock));
    const header: *DROPFILES = @ptrCast(@alignCast(raw));
    header.* = .{ .p_files = @sizeOf(DROPFILES), .pt = point, .f_nc = 0, .f_wide = 1 };
    var at: usize = @sizeOf(DROPFILES);
    for (paths) |path| {
        const n = std.unicode.calcUtf16LeLen(path) catch unreachable;
        const dst: [*]u16 = @ptrCast(@alignCast(raw + at));
        _ = std.unicode.utf8ToUtf16Le(dst[0..n], path) catch unreachable;
        dst[n] = 0;
        at += (n + 1) * 2;
    }
    const end: [*]u16 = @ptrCast(@alignCast(raw + at));
    end[0] = 0;
    _ = w.GlobalUnlock(mem);
    return @ptrCast(mem);
}

const Receiver = struct {
    expected: []const []const u8,
    accepts: bool = true,
    builds: u32 = 0,
    events: u32 = 0,
    paths: usize = 0,
    point: ui.Point = .{},
    urls_match: bool = false,

    fn view(r: *Receiver, c: *ui.Context) void {
        r.builds += 1;
        const box = ui.div(c).sizeFull();
        defer box.end();
        if (r.accepts) c.acceptDrop(box.index);
        if (c.dropAt(box.index)) |d| {
            r.events += 1;
            r.paths = d.urls.len;
            r.point = d.point;
            r.urls_match = d.urls.len == r.expected.len;
            if (r.urls_match) for (d.urls, r.expected) |actual, expected| {
                if (!std.mem.eql(u8, actual, expected)) {
                    r.urls_match = false;
                    break;
                }
            };
        }
    }
};

test "one WM_DROPFILES delivers one event with every path and its point" {
    const gpa = testing.allocator;
    const app = try gpa.create(App);
    app.* = .{
        .gpa = gpa,
        .io = std.Io.Threaded.global_single_threaded.io(),
        .options = .{ .quit_on_last_window_closed = false },
        .flags = .{ .hidden = true },
        .gui = true,
    };
    defer app.destroy();
    const expected = [_][]const u8{
        "file:///C:/one.txt",
        "file:///C:/Temp/%E4%B8%AD%E6%96%87%20%231.txt",
        "file://server/share/two.txt",
    };
    var receiver: Receiver = .{ .expected = &expected };
    const win = try app.newWindow(.{
        .title = "hidden drop test",
        .width = 320,
        .height = 200,
        .visible = false,
        .content = .{ .view = .init(&receiver, Receiver.view) },
    });
    const hwnd = win.hwnd orelse return error.SkipZigTest;
    const paths = [_][]const u8{ "C:\\one.txt", "C:\\Temp\\中文 #1.txt", "\\\\server\\share\\two.txt" };
    const hdrop = try makeHDrop(&paths, .{ .x = 48, .y = 32 });
    _ = w.SendMessageW(hwnd, w.WM_DROPFILES, @intFromPtr(hdrop), 0);

    try testing.expectEqual(@as(u32, 1), receiver.events);
    try testing.expectEqual(expected.len, receiver.paths);
    try testing.expect(receiver.urls_match);
    const scale = win.surface.?.scale;
    try testing.expectApproxEqAbs(@as(f32, 48) / scale, receiver.point.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 32) / scale, receiver.point.y, 0.001);
    try testing.expect(win.surface.?.ctx.input.drop == null);
}

test "WM_DROPFILES without a drop target keeps the view unchanged" {
    const gpa = testing.allocator;
    const app = try gpa.create(App);
    app.* = .{
        .gpa = gpa,
        .io = std.Io.Threaded.global_single_threaded.io(),
        .options = .{ .quit_on_last_window_closed = false },
        .flags = .{ .hidden = true },
        .gui = true,
    };
    defer app.destroy();
    var receiver: Receiver = .{ .expected = &.{}, .accepts = false };
    const win = try app.newWindow(.{
        .title = "hidden non-target drop test",
        .width = 320,
        .height = 200,
        .visible = false,
        .content = .{ .view = .init(&receiver, Receiver.view) },
    });
    const hwnd = win.hwnd orelse return error.SkipZigTest;
    const before = receiver.builds;
    const paths = [_][]const u8{"C:\\one.txt"};
    const hdrop = try makeHDrop(&paths, .{ .x = 48, .y = 32 });
    _ = w.SendMessageW(hwnd, w.WM_DROPFILES, @intFromPtr(hdrop), 0);

    try testing.expectEqual(before, receiver.builds);
    try testing.expectEqual(@as(u32, 0), receiver.events);
    try testing.expect(win.surface.?.ctx.input.drop == null);
}

test "WM_DROPFILES arriving while a frame builds is delivered between frames" {
    const gpa = testing.allocator;
    const app = try gpa.create(App);
    app.* = .{
        .gpa = gpa,
        .io = std.Io.Threaded.global_single_threaded.io(),
        .options = .{ .quit_on_last_window_closed = false },
        .flags = .{ .hidden = true },
        .gui = true,
    };
    defer app.destroy();
    const expected = [_][]const u8{"file:///C:/reentered.txt"};
    var receiver: Receiver = .{ .expected = &expected };
    const win = try app.newWindow(.{
        .title = "hidden reentrant drop test",
        .width = 320,
        .height = 200,
        .visible = false,
        .content = .{ .view = .init(&receiver, Receiver.view) },
    });
    const hwnd = win.hwnd orelse return error.SkipZigTest;
    const surface = win.surface.?;
    const paths = [_][]const u8{"C:\\reentered.txt"};
    const hdrop = try makeHDrop(&paths, .{ .x = 48, .y = 32 });

    surface.in_frame = true;
    _ = w.SendMessageW(hwnd, w.WM_DROPFILES, @intFromPtr(hdrop), 0);
    try testing.expectEqual(@as(u32, 0), receiver.events);
    try testing.expect(surface.ctx.input.drop == null);
    surface.in_frame = false;
    @import("loop.zig").runFor(0.1);

    try testing.expectEqual(@as(u32, 1), receiver.events);
    try testing.expectEqual(@as(usize, 1), receiver.paths);
    try testing.expect(receiver.urls_match);
    try testing.expect(surface.ctx.input.drop == null);
}
