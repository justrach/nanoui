//! Windows on Windows: a top-level window showing native UI drawn by
//! nanoui, or a page drawn by WebView2 (`page_webview2.zig`).
const std = @import("std");
const w = @import("win32.zig");
const App = @import("app.zig").App;
const Surface = @import("surface.zig").Surface;
const window_types = @import("../window_types.zig");
const Page = @import("../page_webview2.zig").Page;
const drop_files = @import("drop_files.zig");
const iconFrame = @import("icon.zig").iconFrame;
const chrome = @import("chrome.zig");
const place = @import("window_place.zig");

/// The window message a page's queued messages go out on (`Page.flush`):
/// after the app's own (`WM_APP` onwards, as `fdwatch.zig` allocates them).
pub const WM_NANOUI_FLUSH: u32 = w.WM_APP + 0x4000;
/// The menu that asks a page for its controller once its environment is up.
pub const WM_NANOUI_CONTROLLER: u32 = w.WM_APP + 0x4001;
/// An encoded event from any thread (`sendOwned`), the message on board.
pub const WM_NANOUI_JOB: u32 = w.WM_APP + 0x4002;

/// Asks the window to run its page's queued messages once the loop turns.
pub fn postFlush(hwnd: w.HWND) void {
    _ = w.PostMessageW(hwnd, WM_NANOUI_FLUSH, 0, 0);
}

/// Asks the window to make its page's controller on the loop's next turn.
pub fn postController(hwnd: w.HWND) void {
    _ = w.PostMessageW(hwnd, WM_NANOUI_CONTROLLER, 0, 0);
}
const ui = @import("../ui/ui.zig");

pub const Asset = window_types.Asset;
pub const PageOptions = window_types.PageOptions;
pub const Content = window_types.Content;
pub const TitleBar = window_types.TitleBar;
pub const Callback = window_types.Callback(Window);
pub const ShouldClose = window_types.ShouldClose(Window);
pub const Options = window_types.Options(Window);
pub const NativeView = window_types.NativeView;

pub const Frame = place.Frame;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("NanoUIWindow");
var registered = false;

pub const Window = struct {
    app: *App,
    /// Null when headless (snapshots).
    hwnd: ?w.HWND = null,
    /// `Options.icon`'s frames, owned by the window and freed in `finish`.
    icon_big: ?w.HICON = null,
    icon_small: ?w.HICON = null,
    surface: ?*Surface = null,
    title_bar: TitleBar = .default,
    on_close: ?Callback = null,
    should_close: ?ShouldClose = null,
    on_resize: ?Callback = null,
    on_key: ?Callback = null,
    on_fullscreen: ?Callback = null,
    closed: bool = false,
    full_screen: bool = false,
    view: ?ui.View = null,
    /// The page, when the window shows one instead of native UI.
    page: ?*Page = null,
    width: f64 = 0,
    height: f64 = 0,
    theme: ?ui.Theme = null,
    min_width: f64 = 0,
    min_height: f64 = 0,
    /// Window opacity, 0 to 1. Below 1 the surface draws with GDI: see
    /// `setOpacity` for why the GPU path cannot show it.
    opacity: f64 = 1,
    /// `Options.transparent`: the frame is the window, alpha and all
    /// (`layered.zig`).
    transparent: bool = false,
    /// Whether the title bar was last made dark; null until it is set.
    title_bar_dark: ?bool = null,
    /// `Options.decorations`: false is a `WS_POPUP`.
    decorations: bool = true,
    /// `Options.frame_autosave`, the app's copy (`window_place.zig`).
    autosave: ?[]const u8 = null,
    /// The kept placement was maximized: the first `show` maximizes.
    restore_maximized: bool = false,
    /// The pointer is over the app's maximize button (`chrome.zig`), with
    /// the non-client leave asked for.
    max_hover: bool = false,

    /// Resizing changes geometry only, never the foreground window.
    pub const set_size_flags: u32 = w.SWP_NOMOVE | w.SWP_NOZORDER | w.SWP_NOACTIVATE;

    pub fn create(app: *App, options: Options) !*Window {
        const self = try app.gpa.create(Window);
        errdefer app.gpa.destroy(self);
        self.* = .{ .app = app, .title_bar = options.title_bar, .on_close = options.on_close, .should_close = options.should_close, .on_resize = options.on_resize, .on_key = options.on_key, .on_fullscreen = options.on_fullscreen, .width = options.width, .height = options.height, .theme = options.theme, .min_width = options.min_width, .min_height = options.min_height, .opacity = options.opacity, .transparent = options.transparent and !options.decorations, .decorations = options.decorations };
        // A page is made once the window it fills exists, below.
        var page_options: ?PageOptions = null;
        switch (options.content) {
            .page => |p| page_options = p,
            .view => |v| self.view = v,
        }
        if (!app.gui) return self;
        if (options.frame_autosave) |n| self.autosave = try app.gpa.dupe(u8, n);
        errdefer if (self.autosave) |n| app.gpa.free(n);
        const inst = w.GetModuleHandleW(null);
        if (!registered) {
            const wc: w.WNDCLASSEXW = .{ .style = w.CS_DBLCLKS, .lpfnWndProc = wndProc, .hInstance = inst, .hCursor = w.LoadCursorW(null, 32512), .lpszClassName = class_name };
            if (w.RegisterClassExW(&wc) == 0) return error.RegisterClass;
            registered = true;
        }
        if (self.view) |view| {
            self.surface = try Surface.create(self, view, options.theme);
            errdefer if (self.surface) |s| s.destroy();
            // The system caption's height, until the view sets its own band.
            if (chrome.chromeless(self)) self.surface.?.ctx.title_bar_height = chrome.title_bar_height;
        }
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
        if (options.opacity < 1 or self.transparent) ex |= w.WS_EX_LAYERED;
        const hwnd = w.CreateWindowExW(ex, class_name, w.wide(&title, options.title), style, w.CW_USEDEFAULT, w.CW_USEDEFAULT, 100, 100, null, null, inst, null) orelse return error.CreateWindow;
        self.hwnd = hwnd;
        // The title bar matches the theme before the window is first shown; a
        // surface keeps it matching the theme each frame is drawn with.
        self.setTitleBarDark(if (options.theme) |t| t.dark else @import("desktop.zig").isDark());
        _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        self.setIcon(options.icon);
        w.DragAcceptFiles(hwnd, 1);
        // A title bar the app draws: the band reclaimed before the first size.
        if (chrome.chromeless(self)) chrome.apply(hwnd);
        self.setSize(options.width, options.height);
        if (options.x != null and options.y != null) self.setPosition(options.x.?, options.y.?) else self.center();
        // A frame kept under the name wins over the one asked for.
        if (self.autosave != null) _ = place.restore(self);
        if (options.always_on_top) self.setAlwaysOnTop(true);
        // After the window exists: `SetLayeredWindowAttributes` needs one, and it
        // needs `WS_EX_LAYERED` to have been set when it was made — or set just
        // now, which `setOpacity` does for a window that was made opaque.
        if (options.opacity < 1) self.setOpacity(options.opacity);
        // The page is WebView2's, in the client area the window now has.
        if (page_options) |p| {
            if (Page.create(self, p)) |made| {
                self.page = made;
            } else |err| switch (err) {
                // No runtime on this machine: the app still opens, and says
                // what is missing where the page would have been.
                error.WebView2Missing => {
                    std.log.warn("nanoui: no WebView2 for this window: showing a notice instead", .{});
                    self.view = @import("window_notice.zig").fallbackView(p.url);
                    self.surface = Surface.create(self, self.view.?, options.theme) catch null;
                },
                else => return err,
            }
        }
        if (!app.flags.hidden and options.visible) self.show();
        return self;
    }

    /// Sets how opaque the window is, 0 to 1. A window that was made opaque
    /// gains `WS_EX_LAYERED` here (Windows 8 and later let a window take the
    /// style at runtime), so an opacity slider works on any window.
    ///
    /// The D3D11 path cannot show it: `SetLayeredWindowAttributes` has no effect
    /// on a DXGI flip-model swap chain. `surface.zig` reads `opacity` back and
    /// draws with GDI while it is below 1, so the pixels are right and the GPU
    /// comes back at 1 (`surface_gpu.zig` has the gate).
    pub fn setOpacity(self: *Window, opacity: f64) void {
        self.opacity = std.math.clamp(opacity, 0, 1);
        // A transparent window's frames carry the opacity themselves:
        // `SetLayeredWindowAttributes` would stop `UpdateLayeredWindow`.
        if (self.transparent) {
            if (self.surface) |s| s.requestFrame();
            return;
        }
        const h = self.hwnd orelse return;
        if (self.opacity < 1) {
            const ex = w.GetWindowLongPtrW(h, w.GWL_EXSTYLE);
            if (@as(u32, @bitCast(@as(i32, @truncate(ex)))) & w.WS_EX_LAYERED == 0) {
                // Layering is what makes the alpha below do anything at all.
                _ = w.SetWindowLongPtrW(h, w.GWL_EXSTYLE, ex | w.WS_EX_LAYERED);
            }
        }
        const alpha: u8 = @intFromFloat(@round(self.opacity * 255));
        _ = w.SetLayeredWindowAttributes(h, 0, alpha, w.LWA_ALPHA);
        // A frame with the new mode: GDI when translucent, the GPU at 1.
        if (self.surface) |s| s.requestFrame();
    }

    /// A dark title bar for a dark theme, as the system draws its own windows
    /// in dark mode. Versions of Windows without it keep a light one.
    pub fn setTitleBarDark(self: *Window, dark: bool) void {
        if (self.title_bar_dark == dark) return;
        const h = self.hwnd orelse return;
        const value: w.BOOL = @intFromBool(dark);
        _ = w.DwmSetWindowAttribute(h, w.DWMWA_USE_IMMERSIVE_DARK_MODE, &value, @sizeOf(w.BOOL));
        self.title_bar_dark = dark;
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
        // view gets the same `on_close` either way, and `should_close` can keep
        // the window open — an unsaved-document question, or a window that only
        // hides.
        if (msg == w.WM_CLOSE) {
            if (self.should_close) |sc| {
                if (!sc.func(sc.ctx, self)) return 0;
            }
            self.destroyNow();
            return 0;
        }
        // A title bar the app draws: the frame's messages (`chrome.zig`).
        if (chrome.chromeless(self)) if (chrome.handle(self, hwnd, msg, wp, lp)) |r| return r;
        // A move or resize ended: the frame is kept (`frame_autosave`).
        if (msg == w.WM_EXITSIZEMOVE) place.save(self);
        if (msg == w.WM_DROPFILES) {
            // Dropping does not activate the window: nothing here takes focus.
            if (wp != 0) drop_files.handle(self.surface, hwnd, @ptrFromInt(wp));
            return 0;
        }
        if (msg == w.WM_GETMINMAXINFO) {
            const mm: *w.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lp)));
            const s = self.dpiScale();
            mm.pt_min_track_size = .{ .x = @intFromFloat(@max(0, self.min_width) * s), .y = @intFromFloat(@max(0, self.min_height) * s) };
            // A borderless window maximises over the whole monitor, taskbar
            // and all: capped to the work area like a decorated one instead.
            // `ptMaxPosition` is *monitor-relative* — the window manager
            // remaps it onto whichever monitor the window maximises on — so
            // the work area goes in as an offset from that monitor's origin,
            // not as a screen position (which would be right only where the
            // primary monitor's origin is the screen's). `ptMaxSize` is used
            // as-is unless it covers the primary monitor, in which case the
            // size difference between the monitors is added on — a maximise
            // on a secondary bigger than the primary can overshoot the work
            // area by that much. (Raymond Chen, "How does the window manager
            // adjust ptMaxSize and ptMaxPosition for multiple monitors?")
            const style: u32 = @bitCast(@as(i32, @truncate(w.GetWindowLongPtrW(hwnd, w.GWL_STYLE))));
            if (style & w.WS_CAPTION == 0) if (self.monitor()) |m| {
                mm.pt_max_size = .{ .x = m.work.right - m.work.left, .y = m.work.bottom - m.work.top };
                mm.pt_max_position = .{ .x = m.work.left - m.whole.left, .y = m.work.top - m.whole.top };
            };
            return 0;
        }
        if (self.surface) |s| {
            const handled = s.handle(hwnd, msg, wp, lp);
            if (handled) |r| {
                // After the surface has taken the size: the app hears about a
                // resize once, when it is done — a drag reports at its end
                // (`WM_EXITSIZEMOVE`, where `dragging` is already false), and
                // everything else at the WM_SIZE that made it. A minimising
                // size (wParam 1) is not a resize worth reporting.
                if (self.on_resize != null and ((msg == w.WM_SIZE and wp != 1 and !s.dragging) or msg == w.WM_EXITSIZEMOVE)) self.onResize();
                return r;
            }
        }
        // A page's queued messages go out on the turn this message lands on.
        if (msg == WM_NANOUI_FLUSH) {
            if (self.page) |p| p.flush();
            return 0;
        }
        if (msg == WM_NANOUI_CONTROLLER) {
            if (self.page) |p| p.makeController();
            return 0;
        }
        if (msg == WM_NANOUI_JOB) {
            // An event some thread encoded: into the page's outbox, and the
            // message with it.
            const job: *SendJob = @ptrFromInt(wp);
            defer self.app.gpa.destroy(job);
            defer self.app.gpa.free(job.msg);
            if (self.page) |p| p.enqueue(job.msg, true);
            return 0;
        }
        // A page has no surface to follow the system's appearance: its title bar does here.
        if (msg == w.WM_SETTINGCHANGE and self.surface == null and self.theme == null) self.setTitleBarDark(@import("desktop.zig").isDark());
        if (self.page) |p| {
            // The window moved or changed size, or the monitor's scale did:
            // the webview covers the client area as it now is.
            if (msg == w.WM_SIZE or msg == w.WM_EXITSIZEMOVE or msg == w.WM_DPICHANGED) p.applyBounds();
        }
        if ((msg == w.WM_SETFOCUS or msg == w.WM_KILLFOCUS) and self.on_key != null) self.onKey();
        return w.DefWindowProcW(hwnd, msg, wp, lp);
    }

    fn onResize(self: *Window) void {
        if (self.on_resize) |cb| cb.func(cb.ctx, self);
    }

    fn onKey(self: *Window) void {
        if (self.on_key) |cb| cb.func(cb.ctx, self);
    }

    fn onFullscreen(self: *Window) void {
        if (self.on_fullscreen) |cb| cb.func(cb.ctx, self);
    }

    pub const dpiScale = place.dpiScale;
    const monitor = place.monitor;
    const workArea = place.workArea;
    pub const frame = place.frame;
    pub const monitorSize = place.monitorSize;
    /// Sizes the window so its client area is `width` × `height` points.
    pub const setSize = place.setSize;
    pub const setPosition = place.setPosition;
    pub const center = place.center;

    /// The title-bar and taskbar icons, from an ICO's bytes: the frame
    /// nearest the size the system asks for.
    fn setIcon(self: *Window, icon: ?[]const u8) void {
        const ico = icon orelse return;
        const hwnd = self.hwnd orelse return;
        self.icon_big = iconFrame(ico, w.GetSystemMetrics(w.SM_CXICON), w.GetSystemMetrics(w.SM_CYICON));
        self.icon_small = iconFrame(ico, w.GetSystemMetrics(w.SM_CXSMICON), w.GetSystemMetrics(w.SM_CYSMICON));
        if (self.icon_big) |h| _ = w.SendMessageW(hwnd, w.WM_SETICON, w.ICON_BIG, @bitCast(@as(usize, @intFromPtr(h))));
        if (self.icon_small) |h| _ = w.SendMessageW(hwnd, w.WM_SETICON, w.ICON_SMALL, @bitCast(@as(usize, @intFromPtr(h))));
    }

    fn finish(self: *Window) void {
        if (self.closed) return;
        self.closed = true;
        // Where it was, for the next window made with its name.
        place.save(self);
        if (self.autosave) |n| self.app.gpa.free(n);
        self.autosave = null;
        if (self.on_close) |cb| cb.func(cb.ctx, self);
        // The page first: WebView2's view is a child window, gone with its
        // controller before the window that holds it.
        if (self.page) |p| p.destroy();
        self.page = null;
        if (self.surface) |s| s.destroy();
        self.surface = null;
        if (self.icon_big) |h| _ = w.DestroyIcon(h);
        self.icon_big = null;
        if (self.icon_small) |h| _ = w.DestroyIcon(h);
        self.icon_small = null;
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
        self.onFullscreen();
    }

    pub fn contentSize(self: *Window) [2]f64 {
        const s = self.surface orelse return .{ self.width, self.height };
        return .{ s.size.w, s.size.h };
    }

    pub fn setMinSize(self: *Window, width: f64, height: f64) void {
        self.min_width = width;
        self.min_height = height;
    }

    pub fn setResizable(self: *Window, on: bool) void {
        const h = self.hwnd orelse return;
        const style = w.GetWindowLongPtrW(h, w.GWL_STYLE);
        const bits: isize = w.WS_THICKFRAME | w.WS_MAXIMIZEBOX;
        const next = if (on) style | bits else style & ~bits;
        if (next == style) return;
        _ = w.SetWindowLongPtrW(h, w.GWL_STYLE, next);
        // The frame is recomputed from the style: without this the border a
        // resizable frame needs only appears at the next resize.
        _ = w.SetWindowPos(h, null, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0020); // no move, no size, frame changed
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
        self.onFullscreen();
    }

    pub fn show(self: *Window) void {
        const h = self.hwnd orelse return;
        // Maximized, if the kept placement was (`window_place.restore`).
        _ = w.ShowWindow(h, if (self.restore_maximized) 3 else 5);
        self.restore_maximized = false;
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

    /// Points a page's window at `url`: a path from the app's assets, or an
    /// absolute `http(s)://` one. No effect on a native-UI window.
    pub fn setPageUrl(self: *Window, url: []const u8) void {
        if (self.page) |p| p.load(url);
    }

    /// Shows entry `i` of `PageOptions.pages` (the bar's buttons).
    pub fn showPage(self: *Window, i: usize) void {
        const p = self.page orelse return;
        if (i >= p.queue.options.pages.len) return;
        p.load(p.queue.options.pages[i].url);
    }

    const SendJob = struct { msg: []u8 };

    /// Queues an encoded message for the page and takes ownership of it.
    /// Safe from any thread: the message is posted to the window's own
    /// queue, so the outbox is only ever touched on the UI thread, where
    /// the page lives.
    pub fn sendOwned(self: *Window, msg: []u8) void {
        const hwnd = self.hwnd orelse return self.app.gpa.free(msg);
        const job = self.app.gpa.create(SendJob) catch return self.app.gpa.free(msg);
        job.* = .{ .msg = msg };
        if (w.PostMessageW(hwnd, WM_NANOUI_JOB, @intFromPtr(job), 0) == 0) {
            self.app.gpa.free(msg);
            self.app.gpa.destroy(job);
        }
    }

    pub fn nativeView(self: *Window) ?NativeView {
        const v = self.view orelse return null;
        if (self.surface) |s| if (s.size.w > 0) return .{ .view = v, .width = s.size.w, .height = s.size.h, .scale = s.scale, .theme = self.theme };
        return .{ .view = v, .width = @floatCast(self.width), .height = @floatCast(self.height), .scale = @floatCast(self.dpiScale()), .theme = self.theme };
    }

    pub fn logFrame(self: *Window) void {
        const f = self.frame();
        std.debug.print("nanoui: window {x} frame {d} {d} {d} {d}\n", .{ @intFromPtr(self), f.x, f.y, f.width, f.height });
    }
};
