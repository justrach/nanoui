//! The page a Windows window shows: a WebView2 in the window, the bridge
//! injected at document start, and every request to the page's origin
//! answered from the asset table (`page.zig`).
//!
//! WebView2 makes a page in two asynchronous steps, each a COM callback:
//! the environment, then the controller inside it. The UI thread owns both;
//! until the controller arrives the page's queue holds messages, which is
//! what `page.Queue` already does for a DOM that is not ready yet.
const std = @import("std");
const wv = @import("windows/webview2.zig");
const profile = @import("page_webview2_profile.zig");
const handlers = @import("page_webview2_handlers.zig");
const target = @import("page_webview2_target.zig");
const dock = @import("page_webview2_dock.zig");
const page = @import("page.zig");
const window_mod = @import("windows/window.zig");
const w = @import("windows/win32.zig");
const Window = window_mod.Window;

const Com = wv.Com;
const bridge_js = page.bridge_js;

pub const Page = struct {
    pub const Target = target.Target(Page);

    queue: page.Queue(Window),
    /// The controller's parent may be a custom child HWND.
    hwnd: w.HWND,
    /// Internal messages always go to the owning nanoui window.
    owner_hwnd: w.HWND,
    target: *Target,
    active: usize = 0,
    /// The controller: the view's bounds and visibility.
    controller: ?*Com = null,
    webview: ?*Com = null,
    /// Kept for `CreateWebResourceResponse`, which the environment makes.
    environment: ?*Com = null,
    /// WebView2's profile folder for this app, kept for the environment's life.
    data_dir: [:0]u16,
    /// A flush was asked for before the controller existed.
    pending_flush: bool = false,
    /// The environment is asked for once the loop runs (`start`).
    pending_start: bool = true,
    /// `--nanoui-eval`, kept until the page has loaded.
    pending_eval: ?[]const u8 = null,
    /// A hidden run's window, shown off-screen while the controller is made
    /// (a parent never shown leaves the controller waiting), and hidden
    /// again once it answers — right or wrong.
    hidden_shown: bool = false,
    restore_rect: ?w.RECT = null,
    /// The registrations of the three event handlers, for `remove_*` at
    /// destroy: that is what releases them, now, not whenever the runtime
    /// gets round to it. 0: not registered.
    token_resource: i64 = 0,
    token_message: i64 = 0,
    token_nav: i64 = 0,
    /// Docked in a native-UI window (`Window.dockPage`): placed by the app
    /// (`setFrame`) rather than covering the client area.
    docked: bool = false,
    /// The docked page's bounds in pixels, once `setFrame` placed it.
    frame_px: ?wv.Rect = null,
    /// Shown (`show`, `hide`): kept for a controller that is not there yet.
    shown: bool = true,

    pub fn create(window: *Window, options: window_mod.PageOptions) !*Page {
        const gpa = window.app.gpa;
        // A custom controller parent need not run nanoui's window procedure.
        const handles = try target.Handles.init(window.hwnd, options.parent);
        const self = try gpa.create(Page);
        errdefer gpa.destroy(self);
        const data_dir = try profile.userDataDir(window, gpa, window.app.options.name);
        errdefer gpa.free(data_dir);
        self.* = .{
            .queue = page.Queue(Window).init(window, options),
            .hwnd = handles.parent,
            .owner_hwnd = handles.owner,
            .target = try Target.create(gpa, self),
            .docked = options.parent != null,
            .data_dir = data_dir,
        };
        errdefer self.target.release();
        self.queue.send = &sendJs;
        self.queue.ctx = self;
        // `--nanoui-eval` waits for the document: `dom-ready` from the bridge
        // comes before the DOM is there, and running it then sees `null`.
        self.pending_eval = window.app.flags.eval;

        // The folder is made inside `userDataDir` (empty when it cannot be,
        // which is WebView2's own default).

        const loader = (wv.Loader.get() orelse return error.WebView2Missing);
        // The version is only asked for with NANOUI_DEBUG: it is one more call
        // into WebView2 before anything else, and only a diagnostic one.
        if (window.app.debug) {
            if (loader.runtimeVersion(gpa)) |v| {
                defer gpa.free(v);
                std.log.info("nanoui: WebView2 {s}", .{v});
            }
        }

        // The environment is made against our profile folder, asynchronously.
        // It is asked for once the loop runs (`start`), not here: WebView2's
        // callbacks are posted to the thread's message queue, and a window
        // made before `run` would never hear back.
        self.pending_start = true;
        return self;
    }

    /// The environment and controller, asked for once the message loop runs.
    /// `Window.create` happens before `App.run` (an app makes its windows,
    /// then runs), and WebView2 posts every callback to that queue.
    pub fn start(self: *Page) void {
        if (!self.enter()) return;
        defer self.leave();
        if (!self.pending_start) return;
        self.pending_start = false;
        const loader = wv.Loader.get() orelse return;
        const handler = self.makeHandler(handlers.EnvCreated) catch return;
        const hr = loader.create_environment(null, self.data_dir.ptr, null, handler);
        // The handler's maker reference went with the call: the runtime
        // addref'd its own, and releases it after the callback.
        _ = wv.Com.release(handler);
        if (hr < 0) {
            std.log.warn("nanoui: CreateCoreWebView2EnvironmentWithOptions failed (0x{x})", .{@as(u32, @bitCast(hr))});
        }
    }

    /// A handler object: COM from here on. Its maker reference goes to the
    /// call that hands it over (released there, at once), and after that the
    /// box lives exactly as long as WebView2's own references — it frees
    /// itself when the last drops, which may be after the page (a window
    /// closed under a pending callback) is long gone.
    pub fn makeHandler(self: *Page, comptime T: type) !*Com {
        // The vtable has static storage: WebView2 keeps its address.
        const holder = try self.queue.gpa.create(handlers.Box(T));
        self.target.retain();
        holder.* = .{ .com = .{ .vtable = &handlers.Box(T).vtable_storage }, .target = self.target, .gpa = self.queue.gpa };
        return &holder.com;
    }

    /// Pins only an on-stack operation, never a pending COM callback.
    pub fn enter(self: *Page) bool {
        if (self.queue.dead) return false;
        self.active += 1;
        return true;
    }

    pub fn leave(self: *Page) void {
        self.active -= 1;
        if (self.queue.dead) self.freeClosed();
    }

    pub fn destroy(self: *Page) void {
        if (!self.enter()) return;
        defer self.leave();
        // Detach before any COM/Win32 calls: teardown itself can reenter.
        self.target.page = null;
        self.queue.dead = true;
        const window = self.queue.window;
        if (self.docked) window.undock(self);
        if (window.page == self) window.page = null;
        self.endHiddenShow();
        // The Window may disappear now. Only on-stack operations keep the
        // page and its COM references until they unwind; they check dead
        // after every potentially reentrant call before using the Window.
    }

    /// IPC may finish inside another callback/operation. Its boolean guard
    /// alone cannot protect that outer stack (or nested IPC dispatch).
    pub fn freeClosed(self: *Page) void {
        if (self.active != 0 or self.queue.dispatching) return;
        self.freeNow();
    }

    fn freeNow(self: *Page) void {
        const gpa = self.queue.gpa;
        self.queue.deinit();
        if (self.webview) |v| {
            if (self.token_resource != 0) _ = wv.WebView.removeWebResourceRequested(v, self.token_resource);
            if (self.token_message != 0) _ = wv.WebView.removeWebMessageReceived(v, self.token_message);
            if (self.token_nav != 0) _ = wv.WebView.removeNavigationCompleted(v, self.token_nav);
            v.release();
        }
        if (self.controller) |c| {
            _ = wv.Controller.close(c);
            c.release();
        }
        if (self.environment) |e| e.release();
        self.target.release();
        gpa.free(self.data_dir);
        gpa.destroy(self);
    }

    pub fn enqueue(self: *Page, msg: []const u8, hold: bool) void {
        if (!self.enter()) return;
        defer self.leave();
        // Closed by the call being answered: nobody is left to read it.
        if (self.queue.dead) return;
        self.queue.enqueue(msg, hold);
        // One post a turn: only the call that scheduled the flush asks for it.
        if (self.queue.schedule()) self.requestFlush();
    }

    pub fn domReady(self: *Page) void {
        if (!self.enter()) return;
        defer self.leave();
        self.queue.dom_ready = true;
        const gpa = self.queue.gpa;
        for (self.queue.held.items) |m| {
            self.queue.enqueue(m, false);
            gpa.free(m);
        }
        self.queue.held.clearRetainingCapacity();
        // The page bar: which pages this window can switch between, and which
        // one it is showing. Every document gets it, an app's page or the web.
        self.sendPageBar();
        if (self.queue.dead) return;
        if (self.queue.outbox.items.len > 0) self.requestFlush();
    }

    /// The bar's list, as JSON, run in the document's own context.
    fn sendPageBar(self: *Page) void {
        const entries = self.queue.options.pages;
        if (entries.len == 0) return;
        const gpa = self.queue.gpa;
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        const w_ = &aw.writer;
        w_.writeAll("window.__nanoui_setPages&&window.__nanoui_setPages([") catch return;
        for (entries, 0..) |e, i| {
            if (i > 0) w_.writeByte(',') catch return;
            w_.print("{{\"id\":{d},\"title\":", .{i}) catch return;
            std.json.Stringify.encodeJsonString(e.title, .{}, w_) catch return;
            w_.writeAll(",\"current\":") catch return;
            w_.writeAll(if (std.mem.eql(u8, e.url, self.queue.current_url)) "true" else "false") catch return;
            w_.writeByte('}') catch return;
        }
        w_.writeAll("])") catch return;
        self.runScript(aw.written());
    }
    /// Runs the queued messages once the loop turns: posting to the window
    /// keeps it to one evaluation a turn, as the Mac's `dispatchMain` does.
    fn requestFlush(self: *Page) void {
        if (self.webview == null) {
            self.pending_flush = true;
            return;
        }
        self.pending_flush = false;
        window_mod.postFlush(self);
    }

    pub fn startDrag(self: *Page) void {
        if (!self.enter()) return;
        defer self.leave();
        // The frame is the system's: one synthetic caption press makes the
        // window follow the mouse until the button goes up.
        _ = w.ReleaseCapture();
        if (self.queue.dead) return;
        _ = w.PostMessageW(self.owner_hwnd, w.WM_NCLBUTTONDOWN, @intCast(w.HTCAPTION), 0);
    }

    /// Runs `js` as a statement list, not as `__nanoui.receive(...)`: the
    /// app's own `--nanoui-eval`, once the document is there.
    pub fn runScript(self: *Page, js: []const u8) void {
        if (!self.enter()) return;
        defer self.leave();
        const view = self.webview orelse return;
        var wide: std.ArrayList(u16) = .empty;
        defer wide.deinit(self.queue.gpa);
        const n = std.unicode.calcUtf16LeLen(js) catch return;
        wide.ensureTotalCapacity(self.queue.gpa, n + 1) catch return;
        wide.items.len = n;
        _ = std.unicode.utf8ToUtf16Le(wide.items, js) catch return;
        wide.append(self.queue.gpa, 0) catch return;
        const handler = self.makeHandler(handlers.ScriptDone) catch return;
        _ = wv.WebView.executeScript(view, @ptrCast(wide.items.ptr), handler);
        _ = wv.Com.release(handler); // the maker's reference went with the call
    }

    /// The page's message loop has asked for the queued messages.
    pub fn flush(self: *Page) void {
        if (!self.enter()) return;
        defer self.leave();
        self.queue.flush();
    }

    pub fn load(self: *Page, url: []const u8) void {
        if (!self.enter()) return;
        defer self.leave();
        self.queue.dom_ready = false;
        const view = self.webview orelse return;
        var buf: [2048]u8 = undefined;
        // An absolute URL (`https://example.com`) loads as is, as WKWebView's
        // does; only a path is the app's own, served from its assets.
        const full = page.fullUrl(&buf, url);
        var wide: [2048]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&wide, full) catch return;
        if (n >= wide.len) return; // no room for the terminator either
        wide[n] = 0;
        // Kept for the page bar: which entry is the one showing.
        self.queue.setCurrent(url);
        if (self.queue.window.app.debug) std.debug.print("nanoui: navigating to {s}\n", .{full});
        _ = wv.WebView.navigate(view, wide[0..n :0]);
    }

    /// The environment is there. The controller is asked for on the loop's
    /// next turn, not inside this callback: WebView2 completes its own async
    /// work in order, and asking from within a completion of it comes back
    /// `ERROR_BUSY` (0x800700AA).
    pub fn environmentReady(self: *Page, env: *Com) void {
        if (!self.enter()) return;
        defer self.leave();
        // Ours for as long as the page is: the callback's reference is
        // released as soon as it returns, and `CreateWebResourceResponse`
        // (every request) needs one that outlives that.
        _ = env.addRef();
        self.environment = env;
        if (self.queue.dead) return;
        if (self.queue.window.app.debug) std.debug.print("nanoui: webview2 environment ready\n", .{});
        window_mod.postController(self);
    }

    /// Asks for the controller, when the loop reaches `WM_NANOUI_CONTROLLER`.
    pub fn makeController(self: *Page) void {
        if (!self.enter()) return;
        defer self.leave();
        const env = self.environment orelse return;
        // A parent that has never been shown leaves the controller waiting
        // (the samples show their window before they make the view). A
        // hidden run — `--nanoui-hidden`, `--nanoui-eval` — shows the window
        // off-screen instead, without activating it, and hides it again
        // when the controller answers, right or wrong (`endHiddenShow`).
        if (w.IsWindowVisible(self.hwnd) == 0) {
            self.hidden_shown = true;
            var rect: w.RECT = undefined;
            if (w.GetWindowRect(self.hwnd, &rect) != 0) self.restore_rect = rect;
            if (self.queue.dead) return;
            _ = w.SetWindowPos(self.hwnd, null, -32000, -32000, 0, 0, w.SWP_NOSIZE | w.SWP_NOZORDER | w.SWP_NOACTIVATE);
            if (self.queue.dead) return;
            _ = w.ShowWindow(self.hwnd, 8); // SW_SHOWNA
        }
        if (self.queue.dead) return;
        const handler = self.makeHandler(handlers.CtlCreated) catch {
            self.endHiddenShow();
            return;
        };
        const hr = wv.Environment.createController(env, self.hwnd, handler);
        _ = wv.Com.release(handler); // the maker's reference went with the call
        if (hr < 0) {
            self.endHiddenShow();
            std.log.warn("nanoui: CreateCoreWebView2Controller failed (0x{x})", .{@as(u32, @bitCast(hr))});
        }
    }

    /// The controller question is settled: a window shown for it goes back
    /// to being hidden, where it was.
    pub fn endHiddenShow(self: *Page) void {
        if (!self.hidden_shown) return;
        self.hidden_shown = false;
        const rect = self.restore_rect;
        self.restore_rect = null;
        // Hide and restore in one call: it may synchronously close the Window.
        if (rect) |r| {
            const swp_hidewindow = 0x0080;
            _ = w.SetWindowPos(self.hwnd, null, r.left, r.top, 0, 0, w.SWP_NOSIZE | w.SWP_NOZORDER | w.SWP_NOACTIVATE | swp_hidewindow);
        } else _ = w.ShowWindow(self.hwnd, 0); // SW_HIDE
    }

    /// The controller is there: the page's origin, the bridge, the handlers.
    pub fn controllerReady(self: *Page, ctl: *Com) void {
        if (!self.enter()) return;
        defer self.leave();
        if (self.queue.window.app.debug) std.debug.print("nanoui: webview2 controller ready\n", .{});
        const gpa = self.queue.gpa;
        self.controller = ctl;
        _ = ctl.addRef();
        if (self.queue.dead) return;
        var view: ?*Com = null;
        if (wv.Controller.webView(ctl, &view) < 0) return;
        const v = view orelse return;
        self.webview = v;
        if (self.queue.dead) return;

        if (self.docked) dock.ready(self, ctl) else {
            self.applyBounds();
            if (self.queue.dead) return;
            _ = wv.Controller.setIsVisible(ctl, 1);
        }

        // WebView2's own settings: the inspectable page keeps its menus and
        // developer tools, as WKWebView's does.
        if (self.queue.dead) return;
        var settings: ?*Com = null;
        if (wv.WebView.settings(v, &settings) >= 0) if (settings) |s| {
            defer s.release();
            if (self.queue.dead) return;
            _ = wv.Settings.setDevTools(s, if (self.queue.options.inspectable) 1 else 0);
            if (self.queue.dead) return;
            _ = wv.Settings.setContextMenus(s, if (self.queue.options.inspectable) 1 else 0);
            if (self.queue.dead) return;
            _ = wv.Settings.setZoomControl(s, 1);
        };
        if (self.queue.dead) return;

        // Every request to our origin is answered from the asset table.
        const filter = wv.utf8LitZ(page.origin ++ "/*");
        _ = wv.WebView.addResourceFilter(v, filter, wv.resource_context_all);
        if (self.queue.dead) return;
        // Three event handlers, each handed over with its maker reference
        // (released at once below): the runtime holds its own until the
        // `remove_*` in `destroy`.
        if (self.makeHandler(handlers.ResourceRequested)) |h| {
            if (wv.WebView.addWebResourceRequested(v, h, &self.token_resource) < 0) self.token_resource = 0;
            _ = wv.Com.release(h);
        } else |_| {}
        if (self.queue.dead) return;
        if (self.makeHandler(handlers.MessageReceived)) |h| {
            if (wv.WebView.addWebMessageReceived(v, h, &self.token_message) < 0) self.token_message = 0;
            _ = wv.Com.release(h);
        } else |_| {}
        if (self.queue.dead) return;
        // The page is there once its navigation completes: `--nanoui-eval`
        // runs then, when there is a document to run it in.
        if (self.makeHandler(handlers.NavigationCompleted)) |h| {
            if (wv.WebView.addNavigationCompleted(v, h, &self.token_nav) < 0) self.token_nav = 0;
            _ = wv.Com.release(h);
        } else |_| {}
        if (self.queue.dead) return;

        // The bridge, before the page's own scripts run. On the heap: the
        // file grows, and a fixed buffer would drop it on the floor silently.
        const n = std.unicode.calcUtf16LeLen(bridge_js) catch return;
        const wide = gpa.alloc(u16, n + 1) catch return;
        defer gpa.free(wide);
        _ = std.unicode.utf8ToUtf16Le(wide, bridge_js) catch return;
        wide[n] = 0;
        _ = wv.WebView.addScript(v, wide[0..n :0].ptr, null);
        if (self.queue.dead) return;

        self.load(self.queue.options.url);
        if (self.queue.dead) return;
        if (self.pending_flush) {
            self.pending_flush = false;
            window_mod.postFlush(self);
        }
    }

    /// Places a docked page (points, the window's client coordinates). Call
    /// from the surface's `after_frame` with the box's laid-out rect, as on
    /// macOS.
    pub fn setFrame(self: *Page, x: f64, y: f64, width: f64, height: f64) void {
        if (!self.enter()) return;
        defer self.leave();
        const r = dock.pixelRect(x, y, width, height, dock.scaleOf(self.hwnd));
        if (self.frame_px) |old| if (std.meta.eql(old, r)) return;
        self.frame_px = r;
        if (self.controller) |c| _ = wv.Controller.setBounds(c, r);
    }

    /// Shows or hides the page (a docked one's view; the window stays).
    pub fn setHidden(self: *Page, hidden: bool) void {
        if (!self.enter()) return;
        defer self.leave();
        if (self.shown == !hidden) return;
        self.shown = !hidden;
        if (self.controller) |c| _ = wv.Controller.setIsVisible(c, if (self.shown) 1 else 0);
    }

    pub fn show(self: *Page) void {
        self.setHidden(false);
    }

    pub fn hide(self: *Page) void {
        self.setHidden(true);
    }

    /// The view covers the client area; a docked one keeps its frame.
    pub fn applyBounds(self: *Page) void {
        if (!self.enter()) return;
        defer self.leave();
        if (self.docked) return;
        const c = self.controller orelse return;
        var rect: w.RECT = undefined;
        if (w.GetClientRect(self.hwnd, &rect) == 0) return;
        const width = rect.right - rect.left;
        const height = rect.bottom - rect.top;
        const hr = wv.Controller.setBounds(c, .{ .left = 0, .top = 0, .right = width, .bottom = height });
        if (hr < 0) std.log.warn("nanoui: put_Bounds failed (0x{x})", .{@as(u32, @bitCast(hr))});
    }
};

fn sendJs(ctx: *anyopaque, js: []const u8) void {
    const self: *Page = @ptrCast(@alignCast(ctx));
    if (!self.enter()) return;
    defer self.leave();
    const view = self.webview orelse return;
    // `__nanoui.receive([...])` is ASCII plus JSON, both UTF-16 safe.
    var wide: std.ArrayList(u16) = .empty;
    defer wide.deinit(self.queue.gpa);
    const n = std.unicode.calcUtf16LeLen(js) catch return;
    wide.ensureTotalCapacity(self.queue.gpa, n + 1) catch return;
    wide.items.len = n;
    _ = std.unicode.utf8ToUtf16Le(wide.items, js) catch return;
    wide.append(self.queue.gpa, 0) catch return;
    const hr = wv.WebView.executeScript(view, @ptrCast(wide.items.ptr), null);
    if (self.queue.dead) return;
    if (self.queue.window.app.debug) std.debug.print("nanoui: eval {d} bytes -> 0x{x}\n", .{ js.len, @as(u32, @bitCast(hr)) });
}
