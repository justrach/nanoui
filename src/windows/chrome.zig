//! A window whose title bar the app draws (`TitleBar.hidden`): the view
//! reaches the window's top edge, and the system still owns everything a
//! frame does — resizing from every edge, the caption's drag, double-click
//! and system menu, the shadow, Windows 11's rounded corners and its snap
//! layouts.
//!
//! The window keeps `WS_OVERLAPPEDWINDOW` (its resize frame, its verbs and
//! the DWM's border and shadow come with it). `WM_NCCALCSIZE` gives the top
//! band — caption and top frame — to the client, keeping the other three
//! borders at the system's own metrics, so DefWindowProc still answers their
//! resize grips; `WM_NCHITTEST` hands the reclaimed band's grips back, names
//! the view's `window_drag` boxes the caption and its maximize button
//! (`Style.window_maximize`) HTMAXBUTTON. That last answer diverts the
//! pointer over the button into non-client messages, which are projected
//! back onto the view as ordinary mouse input, so the button still hovers
//! and clicks like its neighbours.
//!
//! The frame is never extended into the client (`DwmExtendFrameIntoClientArea`):
//! the real app measured the DWM then painting its own caption material over
//! the app's band on the glass. `WM_NCACTIVATE` is told not to repaint, or
//! the inactive caption lands on the view's top rows. `WM_NCPAINT` goes to
//! DefWindowProc: answering it turns the DWM's non-client rendering off
//! (`DWMWA_NCRENDERING_ENABLED` false), and then nothing paints the side and
//! bottom borders, which show white instead of the DWM's invisible resize
//! frame. That also brings the classic caption back over the top rows of an
//! inactive window.
const std = @import("std");
const w = @import("win32.zig");
const Window = @import("window.zig").Window;

pub const WM_NCCALCSIZE: u32 = 0x0083;
pub const WM_NCHITTEST: u32 = 0x0084;
pub const WM_NCPAINT: u32 = 0x0085;
pub const WM_NCACTIVATE: u32 = 0x0086;
pub const WM_NCMOUSEMOVE: u32 = 0x00A0;
pub const WM_NCLBUTTONDOWN: u32 = 0x00A1;
pub const WM_NCLBUTTONUP: u32 = 0x00A2;
pub const WM_NCLBUTTONDBLCLK: u32 = 0x00A3;
pub const WM_NCMOUSELEAVE: u32 = 0x02A2;

pub const HTCLIENT: u32 = 1;
pub const HTCAPTION: u32 = 2;
pub const HTMAXBUTTON: u32 = 9;
pub const HTLEFT: u32 = 10;
pub const HTRIGHT: u32 = 11;
pub const HTTOP: u32 = 12;
pub const HTTOPLEFT: u32 = 13;
pub const HTTOPRIGHT: u32 = 14;
pub const HTBOTTOM: u32 = 15;
pub const HTBOTTOMLEFT: u32 = 16;
pub const HTBOTTOMRIGHT: u32 = 17;

const SM_CXSIZEFRAME: i32 = 32;
const SM_CYSIZEFRAME: i32 = 33;
const SM_CXPADDEDBORDER: i32 = 92;
const TME_LEAVE: u32 = 0x2;
const TME_NONCLIENT: u32 = 0x10;
const DWMWA_WINDOW_CORNER_PREFERENCE: u32 = 33;
const DWMWCP_ROUND: u32 = 2;

pub const NCCALCSIZE_PARAMS = extern struct { rgrc: [3]w.RECT, pos: ?*anyopaque };

extern "user32" fn GetSystemMetricsForDpi(index: i32, dpi: u32) callconv(.winapi) i32;
extern "dwmapi" fn DwmSetWindowAttribute(hwnd: w.HWND, attr: u32, value: *const anyopaque, size: u32) callconv(.winapi) i32;

/// The title bar's height a view under a hidden one starts with on
/// Windows: the system caption's (the real app's `window_chrome_height`).
pub const title_bar_height: f32 = 32;

/// Whether `win` draws its own title bar here.
pub fn chromeless(win: *const Window) bool {
    return win.decorations and win.title_bar == .hidden;
}

/// The frame's thickness at the top, in pixels at `dpi`: what a maximized
/// window's outer rect overhangs the monitor by, and the reclaimed band's
/// resize grip.
pub fn frameTop(dpi: u32) i32 {
    const d = if (dpi > 0) dpi else 96;
    return GetSystemMetricsForDpi(SM_CYSIZEFRAME, d) + GetSystemMetricsForDpi(SM_CXPADDEDBORDER, d);
}

/// The diagonal grips' reach along the top: the side frame's width.
fn cornerWidth(dpi: u32) i32 {
    const d = if (dpi > 0) dpi else 96;
    return GetSystemMetricsForDpi(SM_CXSIZEFRAME, d) + GetSystemMetricsForDpi(SM_CXPADDEDBORDER, d);
}

/// The client's top once DefWindowProc has taken its borders: back at the
/// window's own top, except that a maximized window's rect overhangs the
/// monitor by one frame thickness, which would push the view's first rows
/// off the screen.
pub fn reclaimedTop(original_top: i32, zoomed: bool, frame_top: i32) i32 {
    return if (zoomed) original_top + frame_top else original_top;
}

/// What the view's part of the window is to the system, at a client point
/// (pixels): the reclaimed band's resize grips first (an app caption that
/// starts at the top overlaps them, and a window that cannot be resized
/// from its top is the worse failure), then what the view says is there.
pub const Probe = struct {
    x: i32,
    y: i32,
    client_width: i32,
    resizable: bool,
    zoomed: bool,
    maximizable: bool,
    frame_top: i32,
    corner: i32,
    part: @import("../ui/context_hooks.zig").FramePart,
};

pub fn hitCode(p: Probe) u32 {
    if (p.resizable and !p.zoomed and p.y >= 0 and p.y < p.frame_top) {
        if (p.x < p.corner) return HTTOPLEFT;
        if (p.x >= p.client_width - p.corner) return HTTOPRIGHT;
        return HTTOP;
    }
    return switch (p.part) {
        .maximize => if (p.maximizable) HTMAXBUTTON else HTCLIENT,
        .caption => HTCAPTION,
        .client => HTCLIENT,
    };
}

/// Made chromeless: Windows 11's rounded corners, and the frame worked out
/// again, so the first `WM_NCCALCSIZE` reclaims the band.
pub fn apply(hwnd: w.HWND) void {
    const round: u32 = DWMWCP_ROUND;
    _ = DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &round, 4);
    _ = w.SetWindowPos(hwnd, null, 0, 0, 0, 0, w.SWP_NOMOVE | w.SWP_NOSIZE | w.SWP_NOZORDER | w.SWP_NOACTIVATE | w.SWP_FRAMECHANGED);
}

/// The outer size whose client is `cw` × `ch` pixels once the band is
/// reclaimed: the side and bottom borders the style gives, no top.
pub fn outerSize(style: u32, cw: i32, ch: i32) [2]i32 {
    var r: w.RECT = .{ .right = cw, .bottom = ch };
    _ = w.AdjustWindowRectEx(&r, style, 0, 0);
    return .{ r.right - r.left, r.bottom };
}

/// The window procedure's part for a chromeless window; null for messages
/// it leaves to the rest.
pub fn handle(win: *Window, hwnd: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) ?w.LRESULT {
    switch (msg) {
        WM_NCCALCSIZE => {
            if (wp == 0) return null;
            const params: *NCCALCSIZE_PARAMS = @ptrFromInt(@as(usize, @bitCast(lp)));
            const original_top = params.rgrc[0].top;
            const def = w.DefWindowProcW(hwnd, msg, wp, lp);
            if (def != 0) return def;
            params.rgrc[0].top = reclaimedTop(original_top, w.IsZoomed(hwnd) != 0, frameTop(w.GetDpiForWindow(hwnd)));
            return 0;
        },
        // lParam -1 is WM_NCACTIVATE's "do not repaint the non-client area".
        // WM_NCPAINT is left to DefWindowProc: see the top of this file.
        WM_NCACTIVATE => return w.DefWindowProcW(hwnd, msg, wp, -1),
        WM_NCHITTEST => {
            // The side and bottom borders are still the system's.
            const def = w.DefWindowProcW(hwnd, msg, wp, lp);
            if (def != HTCLIENT) return def;
            return @intCast(hitAt(win, hwnd, screenPoint(lp)));
        },
        WM_NCMOUSEMOVE, WM_NCLBUTTONDOWN, WM_NCLBUTTONDBLCLK, WM_NCLBUTTONUP => {
            if (wp != HTMAXBUTTON) return null;
            forward(win, hwnd, msg, lp);
            return 0;
        },
        WM_NCMOUSELEAVE => {
            if (win.max_hover) {
                win.max_hover = false;
                if (win.surface) |s| {
                    s.tracking = false;
                    _ = s.handle(hwnd, w.WM_MOUSELEAVE, 0, 0);
                }
            }
            return null;
        },
        else => return null,
    }
}

fn screenPoint(lp: w.LPARAM) w.POINT {
    return .{ .x = @as(i16, @truncate(lp)), .y = @as(i16, @truncate(lp >> 16)) };
}

/// The hit code at screen point `sp`, for the part DefWindowProc called
/// client.
pub fn hitAt(win: *Window, hwnd: w.HWND, sp: w.POINT) u32 {
    var p = sp;
    _ = w.ScreenToClient(hwnd, &p);
    var rect: w.RECT = .{};
    _ = w.GetClientRect(hwnd, &rect);
    const dpi = w.GetDpiForWindow(hwnd);
    const style: u32 = @bitCast(@as(i32, @truncate(w.GetWindowLongPtrW(hwnd, w.GWL_STYLE))));
    var part: @import("../ui/context_hooks.zig").FramePart = .client;
    if (win.surface) |s| {
        const pt: @import("../ui/types.zig").Point = .{ .x = @as(f32, @floatFromInt(p.x)) / s.scale, .y = @as(f32, @floatFromInt(p.y)) / s.scale };
        part = s.ctx.framePartAt(pt, true);
    }
    return hitCode(.{
        .x = p.x,
        .y = p.y,
        .client_width = rect.right - rect.left,
        .resizable = style & w.WS_THICKFRAME != 0,
        .zoomed = w.IsZoomed(hwnd) != 0,
        .maximizable = style & w.WS_MAXIMIZEBOX != 0,
        .frame_top = frameTop(dpi),
        .corner = cornerWidth(dpi),
        .part = part,
    });
}

/// The pointer over the maximize button, as the view's own mouse input.
fn forward(win: *Window, hwnd: w.HWND, msg: u32, lp: w.LPARAM) void {
    const s = win.surface orelse return;
    var p = screenPoint(lp);
    _ = w.ScreenToClient(hwnd, &p);
    const client: w.LPARAM = @bitCast(@as(usize, @as(u16, @bitCast(@as(i16, @truncate(p.x))))) | (@as(usize, @as(u16, @bitCast(@as(i16, @truncate(p.y))))) << 16));
    if (msg == WM_NCMOUSEMOVE and !win.max_hover) {
        // The leave edge, once a hover: TME_NONCLIENT is what makes it a
        // WM_NCMOUSELEAVE.
        var t: w.TRACKMOUSEEVENT = .{ .dwFlags = TME_LEAVE | TME_NONCLIENT, .hwndTrack = hwnd };
        if (w.TrackMouseEvent(&t) != 0) win.max_hover = true;
    }
    // The client's own leave tracking would fire at once: the pointer is
    // outside the client as Windows counts it.
    s.tracking = true;
    const as: u32 = switch (msg) {
        WM_NCMOUSEMOVE => w.WM_MOUSEMOVE,
        WM_NCLBUTTONDOWN, WM_NCLBUTTONDBLCLK => w.WM_LBUTTONDOWN,
        else => w.WM_LBUTTONUP,
    };
    _ = s.handle(hwnd, as, 0, client);
}

test "the reclaimed top: the window's own, a frame lower when maximized" {
    try std.testing.expectEqual(@as(i32, 100), reclaimedTop(100, false, 8));
    try std.testing.expectEqual(@as(i32, 108), reclaimedTop(100, true, 8));
}

test "hit codes: the top band's grips, then the caption and the maximize button" {
    var p: Probe = .{ .x = 300, .y = 2, .client_width = 800, .resizable = true, .zoomed = false, .maximizable = true, .frame_top = 8, .corner = 8, .part = .caption };
    try std.testing.expectEqual(HTTOP, hitCode(p));
    p.x = 3;
    try std.testing.expectEqual(HTTOPLEFT, hitCode(p));
    p.x = 795;
    try std.testing.expectEqual(HTTOPRIGHT, hitCode(p));
    // Below the band: what the view says.
    p.y = 20;
    try std.testing.expectEqual(HTCAPTION, hitCode(p));
    p.part = .maximize;
    try std.testing.expectEqual(HTMAXBUTTON, hitCode(p));
    p.maximizable = false;
    try std.testing.expectEqual(HTCLIENT, hitCode(p));
    p.part = .client;
    try std.testing.expectEqual(HTCLIENT, hitCode(p));
    // Maximized, or not resizable: no top grip, the caption reaches the top.
    p.y = 2;
    p.part = .caption;
    p.zoomed = true;
    try std.testing.expectEqual(HTCAPTION, hitCode(p));
    p.zoomed = false;
    p.resizable = false;
    try std.testing.expectEqual(HTCAPTION, hitCode(p));
}
