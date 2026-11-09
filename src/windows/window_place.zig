//! Where a Windows window is and how big: its frame and the monitor's work
//! area in points, sizing the client area, centering — and the frame kept
//! between launches (`Options.frame_autosave`), as macOS keeps it in the
//! defaults under the name: `GetWindowPlacement` (the restored rect and
//! whether it was maximized) written to the app's data folder when a move
//! or resize ends (`WM_EXITSIZEMOVE`) and as the window closes, and given
//! back with `SetWindowPlacement` when one is made with the same name —
//! unless no monitor shows it any more.
const std = @import("std");
const w = @import("win32.zig");
const chrome = @import("chrome.zig");
const Window = @import("window.zig").Window;

pub const Frame = struct { x: f64, y: f64, width: f64, height: f64 };

pub const WINDOWPLACEMENT = extern struct {
    length: u32 = @sizeOf(WINDOWPLACEMENT),
    flags: u32 = 0,
    show_cmd: u32 = 0,
    min_position: w.POINT = .{},
    max_position: w.POINT = .{},
    normal: w.RECT = .{},
};
comptime {
    std.debug.assert(@sizeOf(WINDOWPLACEMENT) == 44);
}

extern "user32" fn GetWindowPlacement(hwnd: w.HWND, wp: *WINDOWPLACEMENT) callconv(.winapi) w.BOOL;
extern "user32" fn SetWindowPlacement(hwnd: w.HWND, wp: *const WINDOWPLACEMENT) callconv(.winapi) w.BOOL;
extern "user32" fn MonitorFromRect(rect: *const w.RECT, flags: u32) callconv(.winapi) ?*anyopaque;

const SW_SHOWMAXIMIZED: u32 = 3;

pub fn dpiScale(self: *Window) f64 {
    const h = self.hwnd orelse return 1;
    const dpi = w.GetDpiForWindow(h);
    return if (dpi > 0) @as(f64, @floatFromInt(dpi)) / 96 else 1;
}

/// The monitor the window is mostly on: its whole rect and its work area
/// (the monitor minus the taskbar and the docked bars). Null when the
/// system will not say.
pub fn monitor(self: *Window) ?struct { whole: w.RECT, work: w.RECT } {
    const h = self.hwnd orelse return null;
    const m = w.MonitorFromWindow(h, 2) orelse return null;
    var info: w.MONITORINFO = .{};
    if (w.GetMonitorInfoW(m, &info) == 0) return null;
    return .{ .whole = info.rc_monitor, .work = info.rc_work };
}

/// The work area of the monitor the window is mostly on.
pub fn workArea(self: *Window) ?w.RECT {
    const m = monitor(self) orelse return null;
    return m.work;
}

pub fn frame(self: *Window) Frame {
    const h = self.hwnd orelse return .{ .x = 0, .y = 0, .width = self.width, .height = self.height };
    var r: w.RECT = .{};
    _ = w.GetWindowRect(h, &r);
    const s = dpiScale(self);
    return .{ .x = @as(f64, @floatFromInt(r.left)) / s, .y = @as(f64, @floatFromInt(r.top)) / s, .width = @as(f64, @floatFromInt(r.right - r.left)) / s, .height = @as(f64, @floatFromInt(r.bottom - r.top)) / s };
}

/// The work area of the monitor the window is on, in points, so a caller
/// can work out whether there is room to put another window beside this
/// one. (The taskbar is left out: room means room for a window.)
pub fn monitorSize(self: *Window) [2]f64 {
    const s = dpiScale(self);
    if (workArea(self)) |a| {
        return .{ @as(f64, @floatFromInt(a.right - a.left)) / s, @as(f64, @floatFromInt(a.bottom - a.top)) / s };
    }
    return .{ @as(f64, @floatFromInt(w.GetSystemMetrics(0))) / s, @as(f64, @floatFromInt(w.GetSystemMetrics(1))) / s };
}

/// Sizes the window so its client area is `width` × `height` points.
pub fn setSize(self: *Window, width: f64, height: f64) void {
    const h = self.hwnd orelse return;
    const s = dpiScale(self);
    const cw: i32 = @intFromFloat(width * s);
    const ch: i32 = @intFromFloat(height * s);
    // The window's own style decides the non-client border a client area
    // of this size needs: a `WS_POPUP` has none, and a chromeless window
    // has no top one (`chrome.zig` reclaims it).
    const style: u32 = @bitCast(@as(i32, @truncate(w.GetWindowLongPtrW(h, w.GWL_STYLE))));
    if (chrome.chromeless(self)) {
        const outer = chrome.outerSize(style, cw, ch);
        _ = w.SetWindowPos(h, null, 0, 0, outer[0], outer[1], Window.set_size_flags);
        return;
    }
    var r: w.RECT = .{ .right = cw, .bottom = ch };
    _ = w.AdjustWindowRectEx(&r, style, 0, 0);
    _ = w.SetWindowPos(h, null, 0, 0, r.right - r.left, r.bottom - r.top, Window.set_size_flags);
}

pub fn setPosition(self: *Window, x: f64, y: f64) void {
    const h = self.hwnd orelse return;
    const s = dpiScale(self);
    _ = w.SetWindowPos(h, null, @intFromFloat(x * s), @intFromFloat(y * s), 0, 0, 0x0001 | 0x0004 | w.SWP_NOACTIVATE); // no size, no z-order
}

pub fn center(self: *Window) void {
    const h = self.hwnd orelse return;
    var r: w.RECT = .{};
    _ = w.GetWindowRect(h, &r);
    const area = workArea(self) orelse w.RECT{ .right = w.GetSystemMetrics(0), .bottom = w.GetSystemMetrics(1) };
    _ = w.SetWindowPos(h, null, area.left + @divTrunc(area.right - area.left - (r.right - r.left), 2), area.top + @divTrunc(area.bottom - area.top - (r.bottom - r.top), 2), 0, 0, 0x0001 | 0x0004 | w.SWP_NOACTIVATE);
}

/// A placement as the file keeps it: one line, `show left top right bottom`.
pub fn encode(buf: []u8, p: WINDOWPLACEMENT) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d} {d} {d} {d} {d}\n", .{ p.show_cmd, p.normal.left, p.normal.top, p.normal.right, p.normal.bottom });
}

/// `encode` read back; null for anything that is not five numbers making
/// a rect with an area.
pub fn decode(text: []const u8) ?WINDOWPLACEMENT {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    var v: [5]i32 = undefined;
    for (&v) |*x| x.* = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    if (it.next() != null) return null;
    if (v[3] <= v[1] or v[4] <= v[2] or v[0] < 0) return null;
    return .{ .show_cmd = @intCast(v[0]), .normal = .{ .left = v[1], .top = v[2], .right = v[3], .bottom = v[4] } };
}

/// The file a window's placement is kept in: `<folder>/<name>.placement`,
/// the folder the app's data one (or `App.placement_dir`). Null where
/// nothing is kept: a hidden run (tests, snapshots) that named no folder.
fn filePath(self: *Window, buf: []u8) ?[]const u8 {
    const name = self.autosave orelse return null;
    const app = self.app;
    for (name) |ch| if (ch == '/' or ch == '\\' or ch == ':') return null;
    if (app.placement_dir) |dir| return std.fmt.bufPrint(buf, "{s}\\{s}.placement", .{ dir, name }) catch null;
    if (app.flags.hidden) return null;
    const dir = @import("desktop.zig").path(app.gpa, .data, app.options.name) catch return null;
    defer app.gpa.free(dir);
    return std.fmt.bufPrint(buf, "{s}\\{s}.placement", .{ dir, name }) catch null;
}

/// Writes the window's placement, when it has an autosave name.
pub fn save(self: *Window) void {
    const h = self.hwnd orelse return;
    var path_buf: [1024]u8 = undefined;
    const path = filePath(self, &path_buf) orelse return;
    var p: WINDOWPLACEMENT = .{};
    if (GetWindowPlacement(h, &p) == 0) return;
    var line: [96]u8 = undefined;
    const text = encode(&line, p) catch return;
    std.Io.Dir.cwd().writeFile(self.app.io, .{ .sub_path = path, .data = text }) catch |e| {
        std.log.warn("nanoui: the window's frame could not be kept: {t}", .{e});
    };
}

/// Gives the window the placement kept under its name: true when there was
/// one a monitor still shows. A maximized one is restored at its normal
/// rect and maximized when the window is shown (`restore_maximized`), so a
/// window made hidden stays hidden.
pub fn restore(self: *Window) bool {
    const h = self.hwnd orelse return false;
    var path_buf: [1024]u8 = undefined;
    const path = filePath(self, &path_buf) orelse return false;
    var text_buf: [128]u8 = undefined;
    const text = std.Io.Dir.cwd().readFile(self.app.io, path, &text_buf) catch return false;
    var p = decode(text) orelse return false;
    if (!onAMonitor(p.normal)) return false;
    self.restore_maximized = p.show_cmd == SW_SHOWMAXIMIZED;
    p.show_cmd = if (w.IsWindowVisible(h) != 0) (if (self.restore_maximized) SW_SHOWMAXIMIZED else 1) else 0;
    if (w.IsWindowVisible(h) != 0) self.restore_maximized = false;
    return SetWindowPlacement(h, &p) != 0;
}

/// `rect` in workspace coordinates (`WINDOWPLACEMENT.rcNormalPosition`'s,
/// offset by a taskbar on the top or left) in screen coordinates, as the
/// monitor `whole`, with its work area `work`, places it.
pub fn workspaceToScreen(rect: w.RECT, whole: w.RECT, work: w.RECT) w.RECT {
    const dx = work.left - whole.left;
    const dy = work.top - whole.top;
    return .{ .left = rect.left + dx, .top = rect.top + dy, .right = rect.right + dx, .bottom = rect.bottom + dy };
}

/// Whether a monitor shows the placement's rect (workspace coordinates):
/// it is made screen coordinates on the monitor nearest it first, which
/// `MonitorFromRect` wants.
fn onAMonitor(normal: w.RECT) bool {
    const near = MonitorFromRect(&normal, 2) orelse return false; // MONITOR_DEFAULTTONEAREST
    var info: w.MONITORINFO = .{};
    if (w.GetMonitorInfoW(near, &info) == 0) return MonitorFromRect(&normal, 0) != null;
    const screen = workspaceToScreen(normal, info.rc_monitor, info.rc_work);
    return MonitorFromRect(&screen, 0) != null; // MONITOR_DEFAULTTONULL
}

test "a taskbar on the left moves a workspace rect right into screen coordinates" {
    const whole: w.RECT = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 };
    const work: w.RECT = .{ .left = 48, .top = 0, .right = 1920, .bottom = 1080 };
    const r = workspaceToScreen(.{ .left = 10, .top = 20, .right = 110, .bottom = 220 }, whole, work);
    try std.testing.expectEqual(w.RECT{ .left = 58, .top = 20, .right = 158, .bottom = 220 }, r);
    // A taskbar at the bottom changes nothing.
    const bottom: w.RECT = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1032 };
    try std.testing.expectEqual(w.RECT{ .left = 10, .top = 20, .right = 110, .bottom = 220 }, workspaceToScreen(.{ .left = 10, .top = 20, .right = 110, .bottom = 220 }, whole, bottom));
}

test "a placement's line reads back as it was written" {
    var buf: [96]u8 = undefined;
    const p: WINDOWPLACEMENT = .{ .show_cmd = 3, .normal = .{ .left = -1200, .top = 40, .right = -200, .bottom = 740 } };
    const text = try encode(&buf, p);
    try std.testing.expectEqualStrings("3 -1200 40 -200 740\n", text);
    const back = decode(text).?;
    try std.testing.expectEqual(p.show_cmd, back.show_cmd);
    try std.testing.expectEqual(p.normal, back.normal);
    try std.testing.expect(decode("1 2 3") == null);
    try std.testing.expect(decode("1 10 10 5 20") == null);
    try std.testing.expect(decode("1 0 0 10 10 7") == null);
}
