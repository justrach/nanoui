//! WebView2 request navigation, origin scoping across redirects, and failure reporting.
//!
//! Note on WebView2 limitations: `NavigateWithWebResourceRequest` restricts certain
//! header/method semantics (including special runtime `Cookie` handling); it is
//! intended for HTTP(S) GET navigations with application headers such as `Authorization`.
const std = @import("std");
const wv = @import("windows/webview2.zig");
const page_request = @import("page_request.zig");

const Com = wv.Com;
const operation_aborted_status: u32 = 14;

pub fn loadUrl(comptime PageType: type, self: *PageType, url: []const u8) void {
    self.scope.clear(self.queue.gpa);
    self.queue.dom_ready = false;
    const view = self.webview orelse return;
    var buf: [2048]u8 = undefined;
    const full = page_request.resolveUrl(&buf, url);
    var wide: [2048]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, full) catch return;
    if (n >= wide.len) return;
    wide[n] = 0;
    self.queue.setCurrent(url);
    if (self.queue.window.app.debug) std.debug.print("nanoui: navigating to {s}\n", .{full});
    _ = wv.WebView.navigate(view, wide[0..n :0]);
}

pub fn loadNow(comptime PageType: type, self: *PageType, req: page_request.PageRequest) page_request.Error!void {
    try page_request.validate(req);
    if (req.headers.len == 0) {
        loadUrl(PageType, self, req.url);
        return;
    }
    const env = self.environment orelse return error.NoPage;
    const view = self.webview orelse return error.NoPage;
    const env2 = wv.query(env, &wv.iid_environment2) orelse return error.Unsupported;
    defer env2.release();
    const v2 = wv.query(view, &wv.iid_webview2_2) orelse return error.Unsupported;
    defer v2.release();

    const gpa = self.queue.gpa;
    var url_buf: [2048]u8 = undefined;
    const full = page_request.resolveUrl(&url_buf, req.url);
    var wide_url: [2048]u16 = undefined;
    const n_url = std.unicode.utf8ToUtf16Le(&wide_url, full) catch return error.InvalidUrl;
    if (n_url >= wide_url.len) return error.InvalidUrl;
    wide_url[n_url] = 0;

    var owned = try page_request.OwnedRequest.clone(gpa, req);
    defer owned.deinit(gpa);
    const crlf = try owned.formatCrlfHeaders(gpa);
    defer gpa.free(crlf);
    const n_hdr = std.unicode.calcUtf16LeLen(crlf) catch return error.InvalidHeaderValue;
    const wide_hdr = try gpa.alloc(u16, n_hdr + 1);
    defer gpa.free(wide_hdr);
    _ = std.unicode.utf8ToUtf16Le(wide_hdr[0..n_hdr], crlf) catch return error.InvalidHeaderValue;
    wide_hdr[n_hdr] = 0;

    var com_req: ?*Com = null;
    if (wv.Environment2.createWebResourceRequest(env2, wide_url[0..n_url :0], wv.utf8LitZ("GET"), null, wide_hdr[0..n_hdr :0], &com_req) < 0)
        return error.Unsupported;
    const r = com_req orelse return error.Unsupported;
    defer r.release();

    self.scope.set(gpa, full, req.headers);
    self.queue.setCurrent(req.url);
    self.queue.dom_ready = false;
    if (wv.WebView2.navigateWithWebResourceRequest(v2, r) < 0) {
        self.scope.clear(gpa);
        return error.Unsupported;
    }
}

pub fn drainPending(comptime PageType: type, self: *PageType) void {
    const gpa = self.queue.gpa;
    switch (self.pending_req.takeReadyAction(gpa, self.queue.options.url)) {
        .none => {},
        .default_url => |url| loadUrl(PageType, self, url),
        .request => |owned_init| {
            var owned = owned_init;
            defer owned.deinit(gpa);
            const hdrs = owned.asRequest(gpa) catch |err| {
                reportError(self, owned.url, @errorName(err));
                return;
            };
            defer gpa.free(hdrs);
            loadNow(PageType, self, .{ .url = owned.url, .headers = hdrs }) catch |err| {
                reportError(self, owned.url, @errorName(err));
            };
        },
    }
}

pub fn onNavigationStarting(comptime PageType: type, self: *PageType, args: ?*Com) void {
    const a = args orelse return;
    if (self.queue.dead or self.scope.origin_url == null) return;
    var redir: wv.BOOL = 0;
    if (wv.NavigationStartingArgs.isRedirected(a, &redir) < 0 or redir == 0) return;

    var raw: wv.PWSTR = null;
    if (wv.NavigationStartingArgs.uri(a, &raw) < 0) return;
    defer wv.coTaskMemFree(raw);
    const wide = raw orelse return;
    const gpa = self.queue.gpa;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const units = std.mem.span(wide);
    buf.ensureTotalCapacity(gpa, units.len * 3) catch return;
    const n = std.unicode.utf16LeToUtf8(buf.allocatedSlice(), units) catch return;
    const target_url = buf.allocatedSlice()[0..n];
    if (target_url.len == 0 or self.scope.allowsHeadersFor(target_url)) return;

    // Cross-origin redirect while scoped headers were supplied: cancel the
    // runtime redirect and re-navigate cleanly without custom headers.
    _ = wv.NavigationStartingArgs.setCancel(a, 1);
    self.scope.clear(gpa);
    loadUrl(PageType, self, target_url);
}

pub fn onNavigationCompleted(comptime PageType: type, self: *PageType, args: ?*Com) void {
    self.scope.clear(self.queue.gpa);
    const a = args orelse return;
    var ok: wv.BOOL = 1;
    if (wv.NavigationCompletedArgs.isSuccess(a, &ok) < 0 or ok != 0) return;
    var status: u32 = 0;
    _ = wv.NavigationCompletedArgs.webErrorStatus(a, &status);
    if (status == operation_aborted_status) return;
    reportError(self, self.queue.current_url, "Navigation failed");
}

pub fn reportError(self: anytype, url: []const u8, msg: []const u8) void {
    if (self.queue.dead) return;
    const cb = self.queue.options.on_load_error orelse return;
    cb(self.queue.options.on_load_error_ctx, url, msg);
}
