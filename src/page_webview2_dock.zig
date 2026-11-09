//! A WebView2 page docked in a native-UI window (`Window.dockPage`): the
//! controller is a child of the window's own HWND, placed by the app
//! (`Page.setFrame`, in points from the window's client top left, as
//! macOS's docked WKWebView is placed in its parent view), shown and hidden
//! with `put_IsVisible`, and see-through where `PageOptions.transparent`
//! asks (`ICoreWebView2Controller2::put_DefaultBackgroundColor`, alpha 0).
//! Nothing here runs until the controller exists: what the app asked for
//! before is kept, and given to the controller the moment it arrives.
const std = @import("std");
const wv = @import("windows/webview2.zig");
const w = @import("windows/win32.zig");
const Page = @import("page_webview2.zig").Page;

const Com = wv.Com;
const HRESULT = wv.HRESULT;

/// ICoreWebView2Controller2: the controller with a default background.
pub const iid_controller2: wv.Guid = .{ .a = 0xc979903e, .b = 0xd4ca, .c = 0x4228, .d = .{ 0x92, 0xeb, 0x47, 0xee, 0x3f, 0xa9, 0x6e, 0xab } };

/// COREWEBVIEW2_COLOR: four bytes, alpha first.
pub const Color = extern struct { a: u8, r: u8, g: u8, b: u8 };

/// 27: `ICoreWebView2Controller2::put_DefaultBackgroundColor`, on the
/// interface `QueryInterface` (slot 0) gives.
pub fn setDefaultBackground(controller: *Com, color: Color) HRESULT {
    var c2: ?*anyopaque = null;
    const qi = controller.slot(*const fn (*Com, *const wv.Guid, *?*anyopaque) callconv(.winapi) HRESULT, 0)(controller, &iid_controller2, &c2);
    if (qi < 0) return qi;
    const ctl2: *Com = @ptrCast(@alignCast(c2 orelse return -1));
    defer ctl2.release();
    return ctl2.slot(*const fn (*Com, Color) callconv(.winapi) HRESULT, 27)(ctl2, color);
}

/// A rect in points (the window's client coordinates) as the controller's
/// bounds take it: pixels at `scale`, rounded outward to whole pixels so
/// the page covers the box it was placed over.
pub fn pixelRect(x: f64, y: f64, width: f64, height: f64, scale: f64) wv.Rect {
    return .{
        .left = @intFromFloat(@floor(x * scale)),
        .top = @intFromFloat(@floor(y * scale)),
        .right = @intFromFloat(@ceil((x + @max(0, width)) * scale)),
        .bottom = @intFromFloat(@ceil((y + @max(0, height)) * scale)),
    };
}

/// The window's scale: its DPI over 96.
pub fn scaleOf(hwnd: w.HWND) f64 {
    const dpi = w.GetDpiForWindow(hwnd);
    return if (dpi > 0) @as(f64, @floatFromInt(dpi)) / 96 else 1;
}

/// What a docked controller is given once it exists: where it is, whether
/// it shows, and its background.
pub fn ready(p: *Page, controller: *Com) void {
    if (p.queue.options.transparent) {
        const hr = setDefaultBackground(controller, .{ .a = 0, .r = 0, .g = 0, .b = 0 });
        if (hr < 0) std.log.warn("nanoui: put_DefaultBackgroundColor failed (0x{x}): the page is opaque", .{@as(u32, @bitCast(hr))});
    }
    if (p.frame_px) |r| _ = wv.Controller.setBounds(controller, r);
    _ = wv.Controller.setIsVisible(controller, if (p.shown) 1 else 0);
}

test "a frame in points covers its box in pixels" {
    const r = pixelRect(10.25, 20, 100.5, 50, 1.5);
    try std.testing.expectEqual(@as(i32, 15), r.left);
    try std.testing.expectEqual(@as(i32, 30), r.top);
    try std.testing.expectEqual(@as(i32, 167), r.right);
    try std.testing.expectEqual(@as(i32, 105), r.bottom);
    const empty = pixelRect(5, 5, -3, 0, 2);
    try std.testing.expectEqual(empty.left, empty.right);
}

test "COREWEBVIEW2_COLOR is four bytes" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Color));
}
