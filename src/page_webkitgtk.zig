//! The page a Linux window shows: a WebKitWebView with the bridge injected
//! and assets served from the `nanoui://` scheme, as WKWebView's are. The
//! queue of messages and the asset table are `page.zig`'s; this is the view,
//! its two handlers, and the calls that reach them.
const std = @import("std");
const gtk = @import("linux/gtk.zig");
const wk = @import("linux/webkit.zig");
const page = @import("page.zig");
const page_request = @import("page_request.zig");
const window_mod = @import("linux/window.zig");
const app_mod = @import("linux/app.zig");
const ipc = @import("ipc.zig").ipc(window_mod.Window, app_mod.App);

const Window = window_mod.Window;
const App = app_mod.App;

pub const Page = struct {
    queue: page.Queue(Window),
    /// Our own reference: the window holds another while it shows the view.
    view: *gtk.Widget,
    manager: *anyopaque,
    message_signal: c_ulong = 0,
    crash_signal: c_ulong = 0,
    policy_signal: c_ulong = 0,
    load_changed_signal: c_ulong = 0,
    load_failed_signal: c_ulong = 0,
    scope: page_request.ActiveScope = .{},
    /// The turn's flush, while one is waiting; a page closed under it
    /// cancels it, so it never fires into freed memory.
    flush_source: c_uint = 0,

    pub fn create(window: *Window, options: window_mod.PageOptions) !*Page {
        if (!wk.load()) return error.WebKitMissing;
        const app = window.app;
        const gpa = app.gpa;
        const self = try gpa.create(Page);
        errdefer gpa.destroy(self);

        const view = try newView(app);
        const manager = wk.api.webkit_web_view_get_user_content_manager(view);
        self.* = .{ .queue = page.Queue(Window).init(window, options), .view = view, .manager = manager };
        self.queue.send = &sendJs;
        self.queue.ctx = self;

        wk.api.webkit_settings_set_enable_developer_extras(wk.api.webkit_web_view_get_settings(view), @intFromBool(options.inspectable));
        const script = wk.api.webkit_user_script_new(page.bridge_js, wk.top_frame, wk.document_start, null, null);
        defer wk.api.webkit_user_script_unref(script);
        wk.api.webkit_user_content_manager_add_script(manager, script);
        _ = wk.api.webkit_user_content_manager_register_script_message_handler(manager, "nanoui", null);
        self.message_signal = gtk.api.g_signal_connect_data(manager, "script-message-received::nanoui", @ptrCast(&onMessage), self, null, 0);
        self.crash_signal = gtk.api.g_signal_connect_data(view, "web-process-terminated", @ptrCast(&onTerminated), self, null, 0);
        self.policy_signal = gtk.api.g_signal_connect_data(view, "decide-policy", @ptrCast(&onDecidePolicy), self, null, 0);
        self.load_changed_signal = gtk.api.g_signal_connect_data(view, "load-changed", @ptrCast(&onLoadChanged), self, null, 0);
        self.load_failed_signal = gtk.api.g_signal_connect_data(view, "load-failed", @ptrCast(&onLoadFailed), self, null, 0);

        if (!options.defer_initial_load) self.load(options.url);
        return self;
    }

    pub fn destroy(self: *Page) void {
        if (self.flush_source != 0) _ = gtk.api.g_source_remove(self.flush_source);
        // The manager can outlive the view for a moment: it must not call
        // into a page that is gone.
        gtk.api.g_signal_handler_disconnect(self.manager, self.message_signal);
        gtk.api.g_signal_handler_disconnect(self.view, self.crash_signal);
        gtk.api.g_signal_handler_disconnect(self.view, self.policy_signal);
        gtk.api.g_signal_handler_disconnect(self.view, self.load_changed_signal);
        gtk.api.g_signal_handler_disconnect(self.view, self.load_failed_signal);
        gtk.api.g_object_unref(self.view);
        self.scope.clear(self.queue.gpa);
        self.queue.deinit();
        // Closed by a call it is still answering: `ipc` frees it when the
        // call returns (`freeClosed`).
        if (self.queue.dispatching) return;
        self.queue.gpa.destroy(self);
    }

    /// After `destroy`, once the call that closed the page has returned
    /// (its flush source is already gone).
    pub fn freeClosed(self: *Page) void {
        self.queue.gpa.destroy(self);
    }

    pub fn enqueue(self: *Page, msg: []const u8, hold: bool) void {
        // Closed by the call being answered: nobody is left to read it.
        if (self.queue.dead) return;
        self.queue.enqueue(msg, hold);
        // One source a turn: only the call that scheduled the flush adds it.
        if (self.queue.schedule()) self.flush_source = gtk.api.g_timeout_add(0, onFlush, self);
    }

    pub fn domReady(self: *Page) void {
        self.queue.domReady();
        self.queue.sendPageBar();
        if (self.queue.outbox.items.len > 0 and self.queue.schedule())
            self.flush_source = gtk.api.g_timeout_add(0, onFlush, self);
    }

    /// `--app-region: drag`: the window follows the pointer. The press was
    /// seen by the web process, so where it is comes from the pointer now.
    pub fn startDrag(self: *Page) void {
        const win = self.queue.window.gtkwindow orelse return;
        const display = gtk.api.gdk_display_get_default() orelse return;
        const pointer = gtk.api.gdk_seat_get_pointer(gtk.api.gdk_display_get_default_seat(display)) orelse return;
        if (gtk.v4) {
            const surface = gtk.v4api.gtk_native_get_surface(win) orelse return;
            var x: f64 = 0;
            var y: f64 = 0;
            _ = gtk.v4api.gdk_surface_get_device_position(surface, pointer, &x, &y, null);
            gtk.v4api.gdk_toplevel_begin_move(surface, pointer, 1, x, y, 0);
        } else {
            var x: c_int = 0;
            var y: c_int = 0;
            gtk.v3.gdk_device_get_position(pointer, null, &x, &y);
            gtk.v3.gtk_window_begin_move_drag(win, 1, x, y, 0);
        }
    }

    /// Points the view at `url`: a path from the assets, or an absolute one.
    pub fn load(self: *Page, url: []const u8) void {
        self.scope.clear(self.queue.gpa);
        var buf: [2048]u8 = undefined;
        const full = page_request.resolveUrl(&buf, url);
        const gpa = self.queue.gpa;
        const z = gpa.dupeSentinel(u8, full, 0) catch return;
        defer gpa.free(z);
        self.queue.setCurrent(url);
        self.queue.dom_ready = false;
        wk.api.webkit_web_view_load_uri(self.view, z);
    }

    /// Starts a GET navigation with per-request HTTP headers scoped to `req.url`'s origin.
    pub fn loadRequest(self: *Page, req: window_mod.PageRequest) page_request.Error!void {
        try page_request.validate(req);
        if (req.headers.len == 0) {
            self.load(req.url);
            return;
        }
        if (!wk.has_request_api) return error.Unsupported;
        var buf: [2048]u8 = undefined;
        const full = page_request.resolveUrl(&buf, req.url);
        const gpa = self.queue.gpa;
        const z_url = try gpa.dupeSentinel(u8, full, 0);
        defer gpa.free(z_url);
        const uri_req = wk.req_api.webkit_uri_request_new(z_url);
        defer gtk.api.g_object_unref(uri_req);
        const hdrs = wk.req_api.webkit_uri_request_get_http_headers(uri_req) orelse return error.Unsupported;
        for (req.headers) |h| {
            const z_name = try gpa.dupeSentinel(u8, h.name, 0);
            defer gpa.free(z_name);
            const z_val = try gpa.dupeSentinel(u8, h.value, 0);
            defer gpa.free(z_val);
            wk.req_api.soup_message_headers_replace(hdrs, z_name, z_val);
        }
        self.scope.set(gpa, full, req.headers);
        self.queue.setCurrent(req.url);
        self.queue.dom_ready = false;
        wk.req_api.webkit_web_view_load_request(self.view, uri_req);
    }
};

/// A view in the app's one context, its reference ours.
fn newView(app: *App) !*gtk.Widget {
    const g = &gtk.api;
    const context = try contextOf(app);
    const kind = wk.api.webkit_web_view_get_type();
    const made = if (wk.six)
        g.g_object_new(kind, "web-context", context, "network-session", app.web_session.?, @as(?[*:0]const u8, null))
    else
        g.g_object_new(kind, "web-context", context, @as(?[*:0]const u8, null));
    return g.g_object_ref_sink(made orelse return error.WebViewFailed);
}

/// The app's context: its profile and its scheme, once. Without a profile
/// of its own, every nanoui app would share one origin's storage, since each
/// is `nanoui://localhost`. A hidden run keeps nothing, on any machine.
fn contextOf(app: *App) !*anyopaque {
    if (app.web_context) |c| return c;
    const gpa = app.gpa;
    const desktop = @import("linux/desktop.zig");
    const name = app.options.name;
    const hidden = app.flags.hidden;
    var data: ?[:0]u8 = null;
    var cache: ?[:0]u8 = null;
    defer if (data) |d| gpa.free(d);
    defer if (cache) |d| gpa.free(d);
    if (!hidden) {
        const d = try desktop.path(gpa, .data, name);
        defer gpa.free(d);
        data = try std.fmt.allocPrintSentinel(gpa, "{s}/webkit", .{d}, 0);
        const c = try desktop.path(gpa, .cache, name);
        defer gpa.free(c);
        cache = try std.fmt.allocPrintSentinel(gpa, "{s}/webkit", .{c}, 0);
    }
    const context = if (wk.six) blk: {
        app.web_session = if (hidden) wk.v6.webkit_network_session_new_ephemeral() else wk.v6.webkit_network_session_new(data.?, cache.?);
        break :blk wk.v6.webkit_web_context_new();
    } else blk: {
        const manager = if (hidden)
            wk.v4x.webkit_website_data_manager_new_ephemeral()
        else
            gtk.api.g_object_new(wk.v4x.webkit_website_data_manager_get_type(), "base-data-directory", data.?.ptr, "base-cache-directory", cache.?.ptr, @as(?[*:0]const u8, null)) orelse return error.WebViewFailed;
        defer gtk.api.g_object_unref(manager);
        break :blk wk.v4x.webkit_web_context_new_with_website_data_manager(manager);
    };
    wk.api.webkit_web_context_register_uri_scheme(context, "nanoui", onRequest, app, null);
    // Secure, so pages have what https gives them (crypto.subtle, service
    // APIs); CORS-enabled, or `<script type=module>` and fetch refuse it.
    const security = wk.api.webkit_web_context_get_security_manager(context);
    wk.api.webkit_security_manager_register_uri_scheme_as_secure(security, "nanoui");
    wk.api.webkit_security_manager_register_uri_scheme_as_cors_enabled(security, "nanoui");
    app.web_context = context;
    return context;
}

fn sendJs(ctx: *anyopaque, js: []const u8) void {
    const self: *Page = @ptrCast(@alignCast(ctx));
    wk.api.webkit_web_view_evaluate_javascript(self.view, js.ptr, @intCast(js.len), null, null, null, null, null);
}

fn onFlush(data: ?*anyopaque) callconv(.c) c_int {
    const self: *Page = @ptrCast(@alignCast(data));
    self.flush_source = 0;
    self.queue.flush();
    return 0;
}

/// 4.x wraps the value in a WebKitJavascriptResult; 6.0 sends the value.
fn onMessage(_: *anyopaque, value: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self: *Page = @ptrCast(@alignCast(data));
    const js_value = if (wk.six) value else wk.v4x.webkit_javascript_result_get_js_value(value);
    const text = wk.api.jsc_value_to_string(js_value) orelse return;
    defer gtk.api.g_free(text);
    // The page may close its window here: `self` is not used after this.
    ipc.handleMessage(self.queue.window, std.mem.span(text));
}

/// The web process died, by a crash (0) or out of memory (1), and the window
/// is blank: say so, where nothing else would. 2 is us, closing the view.
fn onTerminated(_: *anyopaque, reason: c_int, _: ?*anyopaque) callconv(.c) void {
    if (reason != 2) std.log.warn("nanoui: the page's web process stopped ({s})", .{if (reason == 1) "out of memory" else "crashed"});
}

const GError = extern struct { domain: u32, code: c_int, message: ?[*:0]const u8 };

fn onDecidePolicy(_: *anyopaque, decision: *anyopaque, decision_type: c_int, data: ?*anyopaque) callconv(.c) c_int {
    if (decision_type != 0 or !wk.has_request_api) return 0;
    const self: *Page = @ptrCast(@alignCast(data));
    if (self.queue.dead or self.scope.origin_url == null) return 0;
    const action = wk.req_api.webkit_navigation_policy_decision_get_navigation_action(decision) orelse return 0;
    const req = wk.req_api.webkit_navigation_action_get_request(action) orelse return 0;
    const uri_z = wk.req_api.webkit_uri_request_get_uri(req) orelse return 0;
    const uri = std.mem.span(uri_z);
    if (self.scope.allowsHeadersFor(uri)) return 0;
    const gpa = self.queue.gpa;
    const copy = gpa.dupe(u8, uri) catch uri;
    defer if (copy.ptr != uri.ptr) gpa.free(copy);
    wk.req_api.webkit_policy_decision_ignore(decision);
    self.scope.clear(gpa);
    self.load(copy);
    return 1;
}

fn onLoadChanged(_: *anyopaque, load_event: c_int, data: ?*anyopaque) callconv(.c) void {
    if (load_event != 3) return;
    const self: *Page = @ptrCast(@alignCast(data));
    self.scope.clear(self.queue.gpa);
}

fn onLoadFailed(_: *anyopaque, _: c_int, failing_uri: ?[*:0]const u8, gerr: ?*const GError, data: ?*anyopaque) callconv(.c) c_int {
    const self: *Page = @ptrCast(@alignCast(data));
    if (gerr) |e| if (e.code == 102 or e.code == 302) return 0;
    self.scope.clear(self.queue.gpa);
    if (self.queue.dead) return 0;
    const cb = self.queue.options.on_load_error orelse return 0;
    const url = if (failing_uri) |u| std.mem.span(u) else self.queue.current_url;
    const msg = if (gerr) |e| if (e.message) |m| std.mem.span(m) else "Navigation failed" else "Navigation failed";
    cb(self.queue.options.on_load_error_ctx, url, msg);
    return 0;
}

/// One context serves every window, so the view says whose page it is.
fn onRequest(request: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(data));
    const view = wk.api.webkit_uri_scheme_request_get_web_view(request);
    const path = std.mem.span(wk.api.webkit_uri_scheme_request_get_path(request));
    for (app.windows.items) |w| {
        const p = w.page orelse continue;
        if (@as(*anyopaque, p.view) != view) continue;
        return respond(request, p.queue.serve(path));
    }
    // No window has this view: its page is closing. WebKit waits for an answer.
    respond(request, .{ .data = "Not Found", .mime = "text/plain", .status = 404 });
}

fn respond(request: *anyopaque, served: page.Served) void {
    const g = &gtk.api;
    // The body outlives the stream, as `Served` promises: nothing is copied.
    const stream = g.g_memory_input_stream_new_from_data(served.data.ptr, @intCast(served.data.len), null);
    defer g.g_object_unref(stream);
    const response = wk.api.webkit_uri_scheme_response_new(stream, @intCast(served.data.len));
    defer g.g_object_unref(response);
    var buf: [128]u8 = undefined;
    const mime = std.fmt.bufPrintSentinel(&buf, "{s}", .{served.mime}, 0) catch "application/octet-stream";
    wk.api.webkit_uri_scheme_response_set_content_type(response, mime);
    wk.api.webkit_uri_scheme_response_set_status(response, served.status, null);
    wk.api.webkit_uri_scheme_request_finish_with_response(request, response);
}
