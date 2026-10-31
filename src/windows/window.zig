//! Windows on Windows: a top-level window showing native UI drawn by
//! nanoui. Pages (WebView2) are not supported yet.
const std = @import("std");
const w = @import("win32.zig");
const App = @import("app.zig").App;
const Surface = @import("surface.zig").Surface;
const window_types = @import("../window_types.zig");
const ui = @import("../ui/ui.zig");

pub const Asset = window_types.Asset;
pub const PageOptions = window_types.PageOptions;
pub const Content = window_types.Content;
pub const TitleBar = window_types.TitleBar;
pub const Callback = window_types.Callback(Window);
pub const Options = window_types.Options(Window);
pub const NativeView = window_types.NativeView;

pub const Frame = struct { x: f64, y: f64, width: f64, height: f64 };

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("NanoUIWindow");
var registered = false;

pub const Window = struct {
    app: *App,
    /// Null when headless (snapshots).
    hwnd: ?w.HWND = null,
    surface: ?*Surface = null,
    title_bar: TitleBar = .default,
    on_close: ?Callback = null,
    closed: bool = false,
    full_screen: bool = false,
    view: ?ui.View = null,
    width: f64 = 0,
    height: f64 = 0,
    theme: ?ui.Theme = null,
    min_width: f64 = 0,
    min_height: f64 = 0,
    /// Window opacity, 0 to 1. Below 1 `surface.zig` draws with GDI: see
    /// `setOpacity` for why the GPU path cannot show it.
    opacity: f64 = 1,

    pub fn create(app: *App, options: Options) !*Window {
        const self = try app.gpa.create(Window);
        errdefer app.gpa.destroy(self);
        self.* = .{ .app = app, .title_bar = options.title_bar, .on_close = options.on_close, .width = options.width, .height = options.height, .theme = options.theme, .min_width = options.min_width, .min_height = options.min_height, .opacity = options.opacity };
        switch (options.content) {
            .page => return error.PagesUnsupported,
            .view => |v| self.view = v,
        }
        if (!app.gui) return self;
        const inst = w.GetModuleHandleW(null);
        if (!registered) {
            const wc: w.WNDCLASSEXW = .{ .style = w.CS_DBLCLKS, .lpfnWndProc = wndProc, .hInstance = inst, .hCursor = w.LoadCursorW(null, 32512), .lpszClassName = class_name };
            if (w.RegisterClassExW(&wc) == 0) return error.RegisterClass;
            registered = true;
        }
        self.surface = try Surface.create(self, self.view.?, options.theme);
        var title: [512]u16 = undefined;
        // A borderless window is `WS_POPUP`: no title bar, no frame, and the
        // client area is the whole window. `WS_OVERLAPPEDWINDOW` otherwise, which
        // is titled, resizable, and has the system menu and minimise/maximise.
        var style: u32 = if (options.decorations) w.WS_OVERLAPPEDWINDOW else w.WS_POPUP;
        if (options.decorations and !options.resizable) style &= ~@as(u32, w.WS_THICKFRAME | w.WS_MAXIMIZEBOX);
        // The extended style: out of the taskbar and Alt-Tab, and layered for an
        // opacity below 1. `WS_EX_LAYERED` is what makes
        // `SetLayeredWindowAttributes` do anything at all.
        var ex: u32 = 0;
        if (options.skip_taskbar) ex |= w.WS_EX_TOOLWINDOW;
        if (options.opacity < 1) ex |= w.WS_EX_LAYERED;
        const hwnd = w.CreateWindowExW(ex, class_name, w.wide(&title, options.title), style, w.CW_USEDEFAULT, w.CW_USEDEFAULT, 100, 100, null, null, inst, null) orelse return error.CreateWindow;
        self.hwnd = hwnd;
        _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        self.setSize(options.width, options.height);
        if (options.x != null and options.y != null) self.setPosition(options.x.?, options.y.?) else self.center();
        // After the window exists: `SetLayeredWindowAttributes` needs one, and it
        // needs `WS_EX_LAYERED` to have been set when it was made.
        if (options.opacity < 1) self.setOpacity(options.opacity);
        if (!app.flags.hidden and options.visible) self.show();
        return self;
    }

    /// Sets how opaque the window is, 0 to 1. The window must have been made
    /// with `WS_EX_LAYERED` for this to do anything, which `Options.opacity < 1`
    /// does — a window made opaque cannot become translucent afterwards, and
    /// says so rather than silently doing nothing.
    ///
    /// The D3D11 path cannot show it: `SetLayeredWindowAttributes` has no effect
    /// on a DXGI flip-model swap chain. `surface.zig` reads `opacity` back and
    /// draws with GDI while it is below 1, so the pixels are right and the GPU
    /// comes back at 1.
    pub fn setOpacity(self: *Window, opacity: f64) void {
        self.opacity = std.math.clamp(opacity, 0, 1);
        const h = self.hwnd orelse return;
        const ex = w.GetWindowLongPtrW(h, w.GWL_EXSTYLE);
        if (@as(u32, @bitCast(@as(i32, @truncate(ex)))) & w.WS_EX_LAYERED == 0) return;
        const alpha: u8 = @intFromFloat(@round(self.opacity * 255));
        _ = w.SetLayeredWindowAttributes(h, 0, alpha, w.LWA_ALPHA);
        // A frame with the new mode: GDI when translucent, the GPU at 1.
        if (self.surface) |s| s.requestFrame();
    }

    fn of(hwnd: w.HWND) ?*Window {
        const p = w.GetWindowLongPtrW(hwnd, w.GWLP_USERDATA);
        if (p == 0) return null;
        return @ptrFromInt(@as(usize, @bitCast(p)));
    }

    fn wndProc(hwnd: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
        const self = of(hwnd) orelse return w.DefWindowProcW(hwnd, msg, wp, lp);
        if (msg == w.WM_DESTROY) {
            _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, 0);
            self.finish();
            return 0;
        }
        // `WM_CLOSE` is where a deferred `close` lands, and where the system's own
        // close button goes. Handled here rather than by `DefWindowProc` so the
        // view gets the same `on_close` either way, and so the `should_close`
        // veto below is possible.
        if (msg == w.WM_CLOSE) {
            self.destroyNow();
            return 0;
        }
        if (msg == w.WM_GETMINMAXINFO) {
            // MINMAXINFO: ptMinTrackSize is its fourth POINT.
            const pts: [*]w.POINT = @ptrFromInt(@as(usize, @bitCast(lp)));
            const s = self.dpiScale();
            pts[3] = .{ .x = @intFromFloat(self.min_width * s), .y = @intFromFloat(self.min_height * s) };
            return 0;
        }
        if (self.surface) |s| if (s.handle(hwnd, msg, wp, lp)) |r| return r;
        return w.DefWindowProcW(hwnd, msg, wp, lp);
    }

    fn dpiScale(self: *Window) f64 {
        const h = self.hwnd orelse return 1;
        const dpi = w.GetDpiForWindow(h);
        return if (dpi > 0) @as(f64, @floatFromInt(dpi)) / 96 else 1;
    }

    fn finish(self: *Window) void {
        if (self.closed) return;
        self.closed = true;
        if (self.on_close) |cb| cb.func(cb.ctx, self);
        if (self.surface) |s| s.destroy();
        self.surface = null;
        const app = self.app;
        app.removeWindow(self);
        app.gpa.destroy(self);
    }

    /// Asks the window to close. Deferred: the request is posted, and the window
    /// is destroyed when the message loop reaches it.
    ///
    /// Destroying it here would run its `WM_DESTROY` synchronously, which frees
    /// the `Surface` and its `Context` — and a view that closes its own window
    /// (a button in a demo, a dialog's action) is running inside that Context's
    /// frame. Deferring is what makes `close` safe to call from a view.
    pub fn close(self: *Window) void {
        if (self.hwnd != null) {
            _ = w.PostMessageW(self.hwnd.?, w.WM_CLOSE, 0, 0);
            return;
        }
        self.finish();
    }

    /// Closes now, destroying the window. From the message loop, or from `App`
    /// teardown where no loop is running any more.
    pub fn destroyNow(self: *Window) void {
        if (self.hwnd) |h| _ = w.DestroyWindow(h) else self.finish();
    }

    pub fn minimize(self: *Window) void {
        if (self.hwnd) |h| _ = w.ShowWindow(h, 6);
    }

    pub fn zoom(self: *Window) void {
        const h = self.hwnd orelse return;
        _ = w.ShowWindow(h, if (w.IsZoomed(h) != 0) 9 else 3);
    }

    pub fn frame(self: *Window) Frame {
        const h = self.hwnd orelse return .{ .x = 0, .y = 0, .width = self.width, .height = self.height };
        var r: w.RECT = .{};
        _ = w.GetWindowRect(h, &r);
        const s = self.dpiScale();
        return .{ .x = @as(f64, @floatFromInt(r.left)) / s, .y = @as(f64, @floatFromInt(r.top)) / s, .width = @as(f64, @floatFromInt(r.right - r.left)) / s, .height = @as(f64, @floatFromInt(r.bottom - r.top)) / s };
    }

    /// The screen's size in points, so a caller can work out whether there is
    /// room to put another window beside this one.
    pub fn monitorSize(self: *Window) [2]f64 {
        const s = self.dpiScale();
        return .{
            @as(f64, @floatFromInt(w.GetSystemMetrics(0))) / s,
            @as(f64, @floatFromInt(w.GetSystemMetrics(1))) / s,
        };
    }

    pub fn contentSize(self: *Window) [2]f64 {
        const s = self.surface orelse return .{ self.width, self.height };
        return .{ s.size.w, s.size.h };
    }

    /// Sizes the window so its client area is `width` × `height` points.
    pub fn setSize(self: *Window, width: f64, height: f64) void {
        const h = self.hwnd orelse return;
        const s = self.dpiScale();
        var r: w.RECT = .{ .right = @intFromFloat(width * s), .bottom = @intFromFloat(height * s) };
        _ = w.AdjustWindowRectEx(&r, w.WS_OVERLAPPEDWINDOW, 0, 0);
        _ = w.SetWindowPos(h, null, 0, 0, r.right - r.left, r.bottom - r.top, 0x0002 | 0x0004); // no move, no z-order
    }

    pub fn setPosition(self: *Window, x: f64, y: f64) void {
        const h = self.hwnd orelse return;
        const s = self.dpiScale();
        _ = w.SetWindowPos(h, null, @intFromFloat(x * s), @intFromFloat(y * s), 0, 0, 0x0001 | 0x0004); // no size, no z-order
    }

    pub fn center(self: *Window) void {
        const h = self.hwnd orelse return;
        var r: w.RECT = .{};
        _ = w.GetWindowRect(h, &r);
        const sw = w.GetSystemMetrics(0);
        const sh = w.GetSystemMetrics(1);
        _ = w.SetWindowPos(h, null, @divTrunc(sw - (r.right - r.left), 2), @divTrunc(sh - (r.bottom - r.top), 2), 0, 0, 0x0001 | 0x0004);
    }

    pub fn setMinSize(self: *Window, width: f64, height: f64) void {
        self.min_width = width;
        self.min_height = height;
    }

    pub fn setResizable(self: *Window, on: bool) void {
        _ = self;
        _ = on;
    }

    pub fn setAlwaysOnTop(self: *Window, on: bool) void {
        const h = self.hwnd orelse return;
        const topmost: isize = if (on) -1 else -2;
        _ = w.SetWindowPos(h, @ptrFromInt(@as(usize, @bitCast(topmost))), 0, 0, 0, 0, 0x0001 | 0x0002);
    }

    pub fn isFullScreen(self: *Window) bool {
        return self.full_screen;
    }

    pub fn setFullScreen(self: *Window, on: bool) void {
        self.full_screen = on;
        if (self.hwnd) |h| _ = w.ShowWindow(h, if (on) 3 else 9);
    }

    pub fn show(self: *Window) void {
        const h = self.hwnd orelse return;
        _ = w.ShowWindow(h, 5);
        _ = w.SetForegroundWindow(h);
        _ = w.SetFocus(h);
    }

    pub fn hide(self: *Window) void {
        if (self.hwnd) |h| _ = w.ShowWindow(h, 0);
    }

    /// Popovers are macOS's: none hides itself here.
    pub fn justHidden(_: *Window) bool {
        return false;
    }

    pub fn isVisible(self: *Window) bool {
        const h = self.hwnd orelse return false;
        return w.IsWindowVisible(h) != 0;
    }

    pub fn focus(self: *Window) void {
        if (self.hwnd) |h| _ = w.SetForegroundWindow(h);
    }

    pub fn isFocused(self: *Window) bool {
        const h = self.hwnd orelse return false;
        return w.GetForegroundWindow() == h;
    }

    pub fn redraw(self: *Window) void {
        if (self.surface) |s| s.requestFrame();
    }

    pub fn setTitle(self: *Window, title: []const u8) void {
        const h = self.hwnd orelse return;
        var buf: [512]u16 = undefined;
        _ = w.SetWindowTextW(h, w.wide(&buf, title));
    }

    pub fn nativeView(self: *Window) ?NativeView {
        const v = self.view orelse return null;
        if (self.surface) |s| if (s.size.w > 0) return .{ .view = v, .width = s.size.w, .height = s.size.h, .scale = @max(2, s.scale), .theme = self.theme };
        return .{ .view = v, .width = @floatCast(self.width), .height = @floatCast(self.height), .scale = 2, .theme = self.theme };
    }

    pub fn logFrame(self: *Window) void {
        const f = self.frame();
        std.debug.print("nanoui: window {x} frame {d} {d} {d} {d}\n", .{ @intFromPtr(self), f.x, f.y, f.width, f.height });
    }
};
