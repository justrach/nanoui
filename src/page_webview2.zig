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
const page = @import("page.zig");
const window_mod = @import("windows/window.zig");
const app_mod = @import("windows/app.zig");
const ipc = @import("ipc.zig").ipc(window_mod.Window, app_mod.App);
const w = @import("windows/win32.zig");
const Window = window_mod.Window;

const Com = wv.Com;
const HRESULT = wv.HRESULT;
const bridge_js = page.bridge_js;

pub const Page = struct {
    queue: page.Queue(Window),
    hwnd: w.HWND,
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

    pub fn create(window: *Window, options: window_mod.PageOptions) !*Page {
        const gpa = window.app.gpa;
        const hwnd = window.hwnd orelse return error.NoWindow;
        const self = try gpa.create(Page);
        errdefer gpa.destroy(self);
        self.* = .{
            .queue = page.Queue(Window).init(window, options),
            .hwnd = hwnd,
            .data_dir = try profile.userDataDir(window, gpa, window.app.options.name),
        };
        errdefer gpa.free(self.data_dir);
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
        if (!self.pending_start) return;
        self.pending_start = false;
        const loader = wv.Loader.get() orelse return;
        const handler = self.makeHandler(EnvCreated) catch return;
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
    fn makeHandler(self: *Page, comptime T: type) !*Com {
        // `T.vtable` is a comptime constant: `&T.vtable` points at static
        // storage, where a local's address would dangle the moment this
        // returns (WebView2 keeps the vtable it is given).
        const holder = try self.queue.gpa.create(Box(T));
        holder.* = .{ .com = .{ .vtable = &Box(T).vtable_storage }, .page = self, .gpa = self.queue.gpa };
        return &holder.com;
    }

    pub fn destroy(self: *Page) void {
        self.queue.deinit();
        // Close the controller first, and give back the reference
        // `controllerReady` took: the view goes with it.
        if (self.controller) |c| {
            _ = wv.Controller.close(c);
            _ = wv.Com.release(c);
        }
        if (self.webview) |v| {
            // The three registrations let go here: each remove releases the
            // handler's own reference now. Whatever WebView2 still holds
            // after this — a callback already in flight — frees itself.
            if (self.token_resource != 0) _ = wv.WebView.removeWebResourceRequested(v, self.token_resource);
            if (self.token_message != 0) _ = wv.WebView.removeWebMessageReceived(v, self.token_message);
            if (self.token_nav != 0) _ = wv.WebView.removeNavigationCompleted(v, self.token_nav);
            v.release();
        }
        if (self.environment) |e| e.release();
        self.controller = null;
        self.webview = null;
        self.environment = null;
        self.freeNow();
    }

    /// Frees the page and its profile path. The handlers need nothing from
    /// it any more: each is alive until WebView2's own references drop.
    pub fn freeNow(self: *Page) void {
        const gpa = self.queue.gpa;
        gpa.free(self.data_dir);
        gpa.destroy(self);
    }

    pub fn enqueue(self: *Page, msg: []const u8, hold: bool) void {
        self.queue.enqueue(msg, hold);
        // One post a turn: only the call that scheduled the flush asks for it.
        if (self.queue.schedule()) self.requestFlush();
    }

    pub fn domReady(self: *Page) void {
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
        window_mod.postFlush(self.hwnd);
    }

    pub fn startDrag(self: *Page) void {
        // The frame is the system's: one synthetic caption press makes the
        // window follow the mouse until the button goes up.
        _ = w.ReleaseCapture();
        _ = w.PostMessageW(self.hwnd, w.WM_NCLBUTTONDOWN, @intCast(w.HTCAPTION), 0);
    }

    /// Runs `js` as a statement list, not as `__nanoui.receive(...)`: the
    /// app's own `--nanoui-eval`, once the document is there.
    pub fn runScript(self: *Page, js: []const u8) void {
        const view = self.webview orelse return;
        var wide: std.ArrayList(u16) = .empty;
        defer wide.deinit(self.queue.gpa);
        const n = std.unicode.calcUtf16LeLen(js) catch return;
        wide.ensureTotalCapacity(self.queue.gpa, n + 1) catch return;
        wide.items.len = n;
        _ = std.unicode.utf8ToUtf16Le(wide.items, js) catch return;
        wide.append(self.queue.gpa, 0) catch return;
        const handler = self.makeHandler(ScriptDone) catch return;
        _ = wv.WebView.executeScript(view, @ptrCast(wide.items.ptr), handler);
        _ = wv.Com.release(handler); // the maker's reference went with the call
    }

    /// The page's message loop has asked for the queued messages.
    pub fn flush(self: *Page) void {
        self.queue.flush();
    }

    pub fn load(self: *Page, url: []const u8) void {
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
    fn environmentReady(self: *Page, env: *Com) void {
        // Ours for as long as the page is: the callback's reference is
        // released as soon as it returns, and `CreateWebResourceResponse`
        // (every request) needs one that outlives that.
        _ = env.addRef();
        self.environment = env;
        if (self.queue.window.app.debug) std.debug.print("nanoui: webview2 environment ready\n", .{});
        window_mod.postController(self.hwnd);
    }

    /// Asks for the controller, when the loop reaches `WM_NANOUI_CONTROLLER`.
    pub fn makeController(self: *Page) void {
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
            _ = w.SetWindowPos(self.hwnd, null, -32000, -32000, 0, 0, w.SWP_NOSIZE | w.SWP_NOZORDER | w.SWP_NOACTIVATE);
            _ = w.ShowWindow(self.hwnd, 8); // SW_SHOWNA
        }
        const handler = self.makeHandler(CtlCreated) catch return;
        const hr = wv.Environment.createController(env, self.hwnd, handler);
        _ = wv.Com.release(handler); // the maker's reference went with the call
        if (hr < 0) {
            self.endHiddenShow();
            std.log.warn("nanoui: CreateCoreWebView2Controller failed (0x{x})", .{@as(u32, @bitCast(hr))});
        }
    }

    /// The controller question is settled: a window shown for it goes back
    /// to being hidden, where it was.
    fn endHiddenShow(self: *Page) void {
        if (!self.hidden_shown) return;
        self.hidden_shown = false;
        _ = w.ShowWindow(self.hwnd, 0); // SW_HIDE
        if (self.restore_rect) |r| {
            self.restore_rect = null;
            _ = w.SetWindowPos(self.hwnd, null, r.left, r.top, 0, 0, w.SWP_NOSIZE | w.SWP_NOZORDER | w.SWP_NOACTIVATE);
        }
    }

    /// The controller is there: the page's origin, the bridge, the handlers.
    fn controllerReady(self: *Page, ctl: *Com) void {
        if (self.queue.window.app.debug) std.debug.print("nanoui: webview2 controller ready\n", .{});
        const gpa = self.queue.gpa;
        self.controller = ctl;
        _ = ctl.addRef();
        var view: ?*Com = null;
        if (wv.Controller.webView(ctl, &view) < 0) return;
        const v = view orelse return;
        self.webview = v;

        self.applyBounds();
        _ = wv.Controller.setIsVisible(ctl, 1);

        // WebView2's own settings: the inspectable page keeps its menus and
        // developer tools, as WKWebView's does.
        var settings: ?*Com = null;
        if (wv.WebView.settings(v, &settings) >= 0) if (settings) |s| {
            _ = wv.Settings.setDevTools(s, if (self.queue.options.inspectable) 1 else 0);
            _ = wv.Settings.setContextMenus(s, if (self.queue.options.inspectable) 1 else 0);
            _ = wv.Settings.setZoomControl(s, 1);
            s.release();
        };

        // Every request to our origin is answered from the asset table.
        const filter = wv.utf8LitZ(page.origin ++ "/*");
        _ = wv.WebView.addResourceFilter(v, filter, wv.resource_context_all);
        // Three event handlers, each handed over with its maker reference
        // (released at once below): the runtime holds its own until the
        // `remove_*` in `destroy`.
        if (self.makeHandler(ResourceRequested)) |h| {
            if (wv.WebView.addWebResourceRequested(v, h, &self.token_resource) < 0) self.token_resource = 0;
            _ = wv.Com.release(h);
        } else |_| {}
        if (self.makeHandler(MessageReceived)) |h| {
            if (wv.WebView.addWebMessageReceived(v, h, &self.token_message) < 0) self.token_message = 0;
            _ = wv.Com.release(h);
        } else |_| {}
        // The page is there once its navigation completes: `--nanoui-eval`
        // runs then, when there is a document to run it in.
        if (self.makeHandler(NavigationCompleted)) |h| {
            if (wv.WebView.addNavigationCompleted(v, h, &self.token_nav) < 0) self.token_nav = 0;
            _ = wv.Com.release(h);
        } else |_| {}

        // The bridge, before the page's own scripts run. On the heap: the
        // file grows, and a fixed buffer would drop it on the floor silently.
        const n = std.unicode.calcUtf16LeLen(bridge_js) catch return;
        const wide = gpa.alloc(u16, n + 1) catch return;
        defer gpa.free(wide);
        _ = std.unicode.utf8ToUtf16Le(wide, bridge_js) catch return;
        wide[n] = 0;
        _ = wv.WebView.addScript(v, wide[0..n :0].ptr, null);

        self.load(self.queue.options.url);
        if (self.pending_flush) {
            self.pending_flush = false;
            window_mod.postFlush(self.hwnd);
        }
    }

    /// The view covers the window's client area.
    pub fn applyBounds(self: *Page) void {
        const c = self.controller orelse return;
        var rect: w.RECT = undefined;
        if (w.GetClientRect(self.hwnd, &rect) == 0) return;
        const width = rect.right - rect.left;
        const height = rect.bottom - rect.top;
        const hr = wv.Controller.setBounds(c, .{ .left = 0, .top = 0, .right = width, .bottom = height });
        if (hr < 0) std.log.warn("nanoui: put_Bounds failed (0x{x})", .{@as(u32, @bitCast(hr))});
    }
};

/// One handler object: the COM vtable first, so `Invoke` can find its page.
fn Box(comptime T: type) type {
    return struct {
        com: Com,
        page: *Page,
        /// The references alive: 1 at birth (the maker's, released the
        /// moment the call that takes the handler returns), then WebView2's
        /// own. All calls on it are the UI thread's, where the runtime runs
        /// its callbacks.
        refs: u32 = 1,
        gpa: std.mem.Allocator,

        /// The vtable WebView2 keeps: `vtable_storage` is a container whose
        /// address is the compile-time constant itself, not a copy.
        const vtable_storage: [wv.handler_slots + 1]*const anyopaque = wv.HandlerVtable(@This(), T.invoke);

        /// The last reference gone: free. Nothing of the page is touched —
        /// the page may already be gone (a window closed under a callback).
        pub fn release_free(self: *@This()) void {
            self.gpa.destroy(self);
        }
    };
}

fn sendJs(ctx: *anyopaque, js: []const u8) void {
    const self: *Page = @ptrCast(@alignCast(ctx));
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
    if (self.queue.window.app.debug) std.debug.print("nanoui: eval {d} bytes -> 0x{x}\n", .{ js.len, @as(u32, @bitCast(hr)) });
}

/// `ICoreWebView2ExecuteScriptCompletedHandler`: `Invoke(HRESULT errorCode,
/// LPCWSTR result)` — the result is the JSON text itself, not an object.
const ScriptDone = struct {
    fn invoke(box: *Box(ScriptDone), _: ?*Com, result: ?*Com) callconv(.winapi) HRESULT {
        // The second argument is the wide string, passed where a pointer goes.
        const wide: [*:0]const u16 = @ptrCast(@alignCast(result orelse return wv.S_OK));
        if (!box.page.queue.window.app.debug) return wv.S_OK;
        const units = std.mem.span(wide);
        var buf: [4096]u8 = undefined;
        const m = std.unicode.utf16LeToUtf8(&buf, units) catch 0;
        std.debug.print("nanoui: eval returned {s}\n", .{buf[0..m]});
        return wv.S_OK;
    }
};

// ---------------------------------------------------------------------------
// The three callbacks. Each is `Invoke` at slot 3 of its own interface.
// ---------------------------------------------------------------------------

const EnvCreated = struct {
    fn invoke(box: *Box(EnvCreated), err: HRESULT, result: ?*Com) callconv(.winapi) HRESULT {
        if (box.page.queue.window.app.debug) std.debug.print("nanoui: webview2 environment callback 0x{x}\n", .{@as(u32, @bitCast(err))});
        if (err >= 0) if (result) |env| box.page.environmentReady(env);
        // `result` is WebView2's only for the length of this call: the page
        // took its own reference (`environmentReady`), so none is released here.
        return wv.S_OK;
    }
};

test "the environment handler takes an HRESULT and a result" {
    // `invoke(box, errorCode, result)`: the three the shim calls it with.
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(@TypeOf(EnvCreated.invoke)).@"fn".param_types.len);
}

const CtlCreated = struct {
    fn invoke(box: *Box(CtlCreated), err: HRESULT, result: ?*Com) callconv(.winapi) HRESULT {
        box.page.endHiddenShow();
        if (err >= 0) if (result) |ctl| box.page.controllerReady(ctl);
        return wv.S_OK;
    }
};

const NavigationCompleted = struct {
    fn invoke(box: *Box(NavigationCompleted), sender: ?*Com, args: ?*Com) callconv(.winapi) HRESULT {
        _ = sender;
        _ = args;
        const p = box.page;
        if (p.queue.window.app.debug) {
            // What the view is showing, and what is in it: a document that
            // is not the app's page shows here as `about:blank` or an error.
            var src: wv.PWSTR = null;
            if (p.webview) |v| if (wv.WebView.source(v, &src) >= 0) {
                defer wv.coTaskMemFree(src);
                if (src) |s| {
                    var buf: [1024]u8 = undefined;
                    const units = std.mem.span(s);
                    buf[0] = 0;
                    const n = std.unicode.utf16LeToUtf8(&buf, units) catch 0;
                    std.debug.print("nanoui: navigation completed, source={s}\n", .{buf[0..n]});
                }
            };
        }
        // With a document to run in, the app's `--nanoui-eval` goes now:
        // `dom-ready` (the bridge's) comes before the document is there.
        if (p.pending_eval) |js| {
            p.pending_eval = null;
            p.queue.eval(js);
        }
        return wv.S_OK;
    }
};

const MessageReceived = struct {
    fn invoke(box: *Box(MessageReceived), sender: ?*Com, args: ?*Com) callconv(.winapi) HRESULT {
        _ = sender;
        const a = args orelse return wv.S_OK;
        var raw: wv.PWSTR = null;
        if (wv.MessageArgs.getWebMessageAsJson(a, &raw) < 0) return wv.S_OK;
        defer wv.coTaskMemFree(raw);
        const wide = raw orelse return wv.S_OK;
        const gpa = box.page.queue.gpa;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        // UTF-16 is at most as long as UTF-8 in bytes, never longer.
        const units = std.mem.span(wide);
        buf.ensureTotalCapacity(gpa, units.len * 3) catch return wv.S_OK;
        const n = std.unicode.utf16LeToUtf8(buf.allocatedSlice(), units) catch return wv.S_OK;
        ipc.handleMessage(box.page.queue.window, buf.allocatedSlice()[0..n]);
        if (box.page.queue.window.app.debug)
            std.debug.print("nanoui: page said: {s}\n", .{buf.allocatedSlice()[0..n]});
        return wv.S_OK;
    }
};

const ResourceRequested = struct {
    fn invoke(box: *Box(ResourceRequested), sender: ?*Com, args: ?*Com) callconv(.winapi) HRESULT {
        _ = sender;
        const a = args orelse return wv.S_OK;
        const page_self = box.page;

        var req: ?*Com = null;
        if (wv.ResourceArgs.request(a, &req) < 0) return wv.S_OK;
        const r = req orelse return wv.S_OK;
        defer r.release();

        var uri: wv.PWSTR = null;
        if (wv.ResourceRequest.uri(r, &uri) < 0) return wv.S_OK;
        defer wv.coTaskMemFree(uri);
        const wide = uri orelse return wv.S_OK;

        const gpa = page_self.queue.gpa;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        const units = std.mem.span(wide);
        buf.ensureTotalCapacity(gpa, units.len * 3) catch return wv.S_OK;
        const n = std.unicode.utf16LeToUtf8(buf.allocatedSlice(), units) catch return wv.S_OK;

        const served = page_self.queue.serve(page.pathOf(buf.allocatedSlice()[0..n]));
        if (box.page.queue.window.app.debug)
            std.debug.print("nanoui: resource {s} -> {d} {s} ({d} bytes)\n", .{ buf.allocatedSlice()[0..n], served.status, served.mime, served.data.len });
        const env = page_self.environment orelse return wv.S_OK;
        var resp: ?*Com = null;
        const cr = makeResponse(env, served, gpa, &resp);
        if (cr < 0 or resp == null) {
            if (cr < 0) std.log.warn("nanoui: CreateWebResourceResponse failed (0x{x})", .{@as(u32, @bitCast(cr))});
            return wv.S_OK;
        }
        defer resp.?.release();
        const pr = wv.ResourceArgs.setResponse(a, resp.?);
        if (pr < 0) std.log.warn("nanoui: put_Response failed (0x{x})", .{@as(u32, @bitCast(pr))});
        return wv.S_OK;
    }
};

/// `env.CreateWebResourceResponse(stream, status, reason, headers)`.
fn makeResponse(env: *Com, served: page.Served, gpa: std.mem.Allocator, out: *?*Com) HRESULT {
    const headers = headersZ(gpa, served.mime) orelse return -1;
    defer gpa.free(headers);
    var stream: ?*Com = null;
    if (served.data.len > 0) stream = shMemStream(served.data.ptr, served.data.len);
    // WebView2 takes the stream: it owns the reference it was given, so the
    // one made here is not released by us.
    return wv.Environment.createResponse(env, stream, @intCast(served.status), reasonZ(served.status), headers.ptr, out);
}

/// An `IStream` over a copy of `bytes`.
///
/// `CreateStreamOnHGlobal`: the stream owns the memory (WebView2 reads it
/// after this returns, and asks its size), so the bytes go into an HGLOBAL
/// the stream takes.
fn shMemStream(bytes: [*]const u8, len: usize) ?*Com {
    const h = w.GlobalAlloc(w.GMEM_MOVEABLE, len) orelse return null;
    const dest = w.GlobalLock(h) orelse {
        _ = w.GlobalFree(h);
        return null;
    };
    @memcpy(@as([*]u8, @ptrCast(dest))[0..len], bytes[0..len]);
    _ = w.GlobalUnlock(h);
    var stream: ?*Com = null;
    const hr = CreateStreamOnHGlobal(h, 1, &stream); // fDeleteOnRelease
    if (hr < 0) {
        _ = w.GlobalFree(h);
        return null;
    }
    return stream;
}

extern "ole32" fn CreateStreamOnHGlobal(mem: ?*anyopaque, delete_on_release: i32, out: *?*Com) callconv(.winapi) HRESULT;

/// The reason phrase WebView2 takes, by status.
fn reasonZ(status: u16) [*:0]const u16 {
    return switch (status) {
        200 => std.unicode.utf8ToUtf16LeStringLiteral("OK"),
        else => std.unicode.utf8ToUtf16LeStringLiteral("Not Found"),
    };
}

/// `Content-Type: <mime>\r\nCache-Control: no-cache\r\n`, as WebView2 takes
/// its headers. `mime` is one of ours or an asset's, so it is built here.
fn headersZ(gpa: std.mem.Allocator, mime: []const u8) ?[:0]u16 {
    const text = std.fmt.allocPrint(gpa, "Content-Type: {s}\r\nCache-Control: no-cache\r\n", .{mime}) catch return null;
    defer gpa.free(text);
    const n = std.unicode.calcUtf16LeLen(text) catch return null;
    const buf = gpa.alloc(u16, n + 1) catch return null;
    _ = std.unicode.utf8ToUtf16Le(buf, text) catch {
        gpa.free(buf);
        return null;
    };
    buf[n] = 0;
    return buf[0..n :0];
}
