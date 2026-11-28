//! WKNavigationDelegate & authenticated `NSMutableURLRequest` helpers for
//! `page_webkit.zig` (macOS and iOS): scopes request headers to the target
//! origin on main-frame navigation, strips them on cross-origin redirects,
//! and routes load errors to `PageOptions.on_load_error`.
const std = @import("std");
const objc = @import("objc.zig");
const page_request = @import("page_request.zig");

const DecisionBlock = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*const anyopaque, objc.NSInteger) callconv(.c) void,
};

const wk_policy_cancel: objc.NSInteger = 0;
const wk_policy_allow: objc.NSInteger = 1;
const ns_url_error_cancelled: objc.NSInteger = -999;

pub fn delegateClass() objc.Class {
    return objc.defineClass(.{
        .name = "NanoUINavDelegate",
        .superclass = "NSObject",
        .protocols = &.{"WKNavigationDelegate"},
        .methods = &.{
            .{ .name = "webView:decidePolicyForNavigationAction:decisionHandler:", .imp = &decidePolicy, .types = "v@:@@@" },
            .{ .name = "webView:didStartProvisionalNavigation:", .imp = &didStart, .types = "v@:@@" },
            .{ .name = "webView:didFinishNavigation:", .imp = &didFinish, .types = "v@:@@" },
            .{ .name = "webView:didFailProvisionalNavigation:withError:", .imp = &didFail, .types = "v@:@@@" },
            .{ .name = "webView:didFailNavigation:withError:", .imp = &didFail, .types = "v@:@@@" },
        },
    });
}

/// Builds and submits a GET `NSMutableURLRequest` with custom headers on
/// `PageType`, scoping the headers to `url`'s origin.
pub fn load(comptime PageType: type, self: *PageType, req: page_request.PageRequest) page_request.Error!void {
    try page_request.validate(req);
    const pool = objc.Pool.push();
    defer pool.pop();
    var buf: [2048]u8 = undefined;
    const full = page_request.resolveUrl(&buf, req.url);
    const nsurl = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(full)}) orelse return error.InvalidUrl;
    const mreq = objc.msg(objc.Object, objc.class("NSMutableURLRequest"), "requestWithURL:", .{nsurl});
    for (req.headers) |h| {
        objc.msg(void, mreq, "setValue:forHTTPHeaderField:", .{ objc.nsString(h.value), objc.nsString(h.name) });
    }
    self.clearScope();
    self.scope.set(self.queue.gpa, full, req.headers);
    self.queue.setCurrent(req.url);
    self.queue.dom_ready = false;
    if (objc.msg(?objc.Object, self.webview, "loadRequest:", .{mreq})) |nav_obj| {
        self.scope_nav = objc.retain(nav_obj);
    }
}

fn callDecision(handler: objc.Object, policy: objc.NSInteger) void {
    const b: *const DecisionBlock = @ptrCast(@alignCast(handler));
    b.invoke(b, policy);
}

fn pageFromDelegate(self_obj: objc.Object) ?*@import("page_webkit.zig").Page {
    const Page = @import("page_webkit.zig").Page;
    const p = objc.getZig(Page, self_obj) orelse return null;
    return if (p.queue.dead) null else p;
}

fn decidePolicy(self_obj: objc.Object, _: objc.SEL, _: objc.Object, action: objc.Object, handler: objc.Object) callconv(.c) void {
    const p = pageFromDelegate(self_obj) orelse return callDecision(handler, wk_policy_cancel);
    if (p.scope.origin_url != null) {
        const pool = objc.Pool.push();
        defer pool.pop();
        const tf = objc.msg(?objc.Object, action, "targetFrame", .{});
        const is_main = if (tf) |f| objc.msg(objc.BOOL, f, "isMainFrame", .{}) else true;
        if (is_main) {
            if (objc.msg(?objc.Object, action, "request", .{})) |nsreq| {
                if (objc.msg(?objc.Object, nsreq, "URL", .{})) |nsurl| {
                    const url_str = objc.fromNSString(objc.msg(?objc.Object, nsurl, "absoluteString", .{}));
                    if (url_str.len > 0 and !p.scope.allowsHeadersFor(url_str)) {
                        // Cross-origin redirect: cancel the request carrying custom headers
                        // and re-issue a clean URL-only request to avoid forwarding creds.
                        const plain = objc.msg(objc.Object, objc.class("NSURLRequest"), "requestWithURL:", .{nsurl});
                        p.clearScope();
                        callDecision(handler, wk_policy_cancel);
                        _ = objc.msg(?objc.Object, p.webview, "loadRequest:", .{plain});
                        return;
                    }
                }
            }
        }
    }
    callDecision(handler, wk_policy_allow);
}

fn sameNav(p: anytype, nav_obj: ?objc.Object) bool {
    const active = p.scope_nav orelse return false;
    const cur = nav_obj orelse return false;
    return @intFromPtr(cur) == @intFromPtr(active);
}

fn didStart(self_obj: objc.Object, _: objc.SEL, _: objc.Object, _: objc.Object) callconv(.c) void {
    const p = pageFromDelegate(self_obj) orelse return;
    p.invalidateFileDragGesture();
}

fn didFinish(self_obj: objc.Object, _: objc.SEL, _: objc.Object, nav_obj: ?objc.Object) callconv(.c) void {
    const p = pageFromDelegate(self_obj) orelse return;
    if (sameNav(p, nav_obj)) p.clearScope();
}

fn didFail(self_obj: objc.Object, _: objc.SEL, _: objc.Object, nav_obj: ?objc.Object, err_obj: objc.Object) callconv(.c) void {
    const p = pageFromDelegate(self_obj) orelse return;
    const code = objc.msg(objc.NSInteger, err_obj, "code", .{});
    if (code == ns_url_error_cancelled) return;
    if (sameNav(p, nav_obj)) p.clearScope();
    const cb = p.queue.options.on_load_error orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const desc = objc.fromNSString(objc.msg(?objc.Object, err_obj, "localizedDescription", .{}));
    cb(p.queue.options.on_load_error_ctx, p.queue.current_url, if (desc.len > 0) desc else "Navigation failed");
}
