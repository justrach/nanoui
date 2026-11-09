//! The page a window shows on macOS and iOS: a WKWebView with the bridge
//! injected and assets served from the `nanoui://` scheme by a
//! `WKURLSchemeHandler`. The queue of messages and the asset table are
//! `page.zig`'s; this is the view, its two handlers, and the calls that reach
//! them. On iOS, WebKit loads with the first page: linked, every app would pay
//! for it at launch, and nothing here but its classes, by name, needs it.
const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc.zig");
const ios = builtin.os.tag == .ios;
const app_mod = if (ios) @import("ios/app.zig") else @import("app.zig");
const window_mod = if (ios) @import("ios/window.zig") else @import("window.zig");
const ipc = @import("ipc.zig").ipc(window_mod.Window, app_mod.App);
const page = @import("page.zig");

const Window = window_mod.Window;
const bridge_js = page.bridge_js;

extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;

pub const Page = struct {
    queue: page.Queue(Window),
    webview: objc.Object,
    handler: objc.Object,
    last_mouse_down: ?objc.Object = null,

    pub fn create(window: *Window, options: window_mod.PageOptions) !*Page {
        const gpa = window.app.gpa;
        const self = try gpa.create(Page);
        errdefer gpa.destroy(self);
        self.* = .{ .queue = page.Queue(Window).init(window, options), .webview = undefined, .handler = undefined };
        self.queue.send = &sendJs;
        self.queue.ctx = self;
        if (ios and dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", 1) == null) return error.NoWebKit;

        const handler_class = objc.defineClass(.{
            .name = "NanoUIPageHandler",
            .protocols = &.{ "WKScriptMessageHandler", "WKURLSchemeHandler" },
            .methods = &.{
                .{ .name = "userContentController:didReceiveScriptMessage:", .imp = &didReceiveScriptMessage, .types = "v@:@@" },
                .{ .name = "webView:startURLSchemeTask:", .imp = &startURLSchemeTask, .types = "v@:@@" },
                .{ .name = "webView:stopURLSchemeTask:", .imp = &stopURLSchemeTask, .types = "v@:@@" },
            },
        });
        const webview_class = objc.defineClass(.{
            .name = "NanoUIWebView",
            .superclass = "WKWebView",
            .methods = if (ios) &.{} else &.{
                .{ .name = "mouseDown:", .imp = &webViewMouseDown, .types = "v@:@" },
            },
        });

        const handler = objc.msg(objc.Object, handler_class, "new", .{});
        errdefer objc.release(handler);
        objc.setZig(handler, self);

        const config = objc.msg(objc.Object, objc.alloc("WKWebViewConfiguration"), "init", .{});
        defer objc.release(config);
        const ucc = objc.msg(objc.Object, config, "userContentController", .{});
        const script = objc.msg(objc.Object, objc.class("WKUserScript"), "alloc", .{});
        defer objc.release(script);
        const script_src = objc.nsString(bridge_js);
        const script_init = objc.msg(objc.Object, script, "initWithSource:injectionTime:forMainFrameOnly:", .{ script_src, @as(objc.NSInteger, 0), objc.YES });
        objc.msg(void, ucc, "addUserScript:", .{script_init});
        objc.msg(void, ucc, "addScriptMessageHandler:name:", .{ handler, objc.nsString("nanoui") });
        objc.msg(void, config, "setURLSchemeHandler:forURLScheme:", .{ handler, objc.nsString("nanoui") });
        if (options.inspectable and !ios) {
            const prefs = objc.msg(objc.Object, config, "preferences", .{});
            const yes = objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{objc.YES});
            objc.msg(void, prefs, "setValue:forKey:", .{ yes, objc.nsString("developerExtrasEnabled") });
        }
        if (options.configure) |f| f(options.configure_ctx, @ptrCast(config));

        // Docked: in the app's view, placed by `setFrame`; else the window's.
        const docked: ?objc.Object = if (options.parent) |p| @ptrCast(p) else null;
        const content_view = docked orelse if (ios) window.page_host.? else objc.msg(objc.Object, window.nswindow, "contentView", .{});
        const bounds: objc.CGRect = if (docked != null) .{} else objc.msg(objc.CGRect, content_view, "bounds", .{});
        const webview = objc.msg(objc.Object, objc.msg(objc.Object, webview_class, "alloc", .{}), "initWithFrame:configuration:", .{ bounds, config });
        objc.setZig(webview, self);
        if (docked == null) objc.msg(void, webview, "setAutoresizingMask:", .{@as(objc.NSUInteger, 2 | 16)}); // width | height sizable
        if (options.inspectable and objc.msg(objc.BOOL, webview, "respondsToSelector:", .{objc.sel("setInspectable:")}))
            objc.msg(void, webview, "setInspectable:", .{objc.YES});
        if (ios) objc.msg(void, webview, "setAllowsBackForwardNavigationGestures:", .{objc.YES});
        // The web view is not the content view: WebKit docks the inspector in its superview.
        objc.msg(void, content_view, "addSubview:", .{webview});

        self.webview = webview;
        self.handler = handler;
        self.loadUrl(options.url);
        return self;
    }

    pub fn destroy(self: *Page) void {
        const ucc = objc.msg(objc.Object, objc.msg(objc.Object, self.webview, "configuration", .{}), "userContentController", .{});
        objc.msg(void, ucc, "removeScriptMessageHandlerForName:", .{objc.nsString("nanoui")});
        objc.setZig(self.handler, null);
        objc.setZig(self.webview, null);
        objc.msg(void, self.webview, "removeFromSuperview", .{});
        objc.release(self.webview);
        objc.release(self.handler);
        if (self.last_mouse_down) |e| objc.release(e);
        self.queue.deinit();
        // A scheduled flush frees the page when it runs, a message being
        // handled when it returns; without either, now.
        if (self.queue.flush_scheduled or self.queue.dispatching) return;
        self.queue.gpa.destroy(self);
    }

    pub fn enqueue(self: *Page, msg: []const u8, hold: bool) void {
        // Closed by the call being answered: nobody is left to read it.
        if (self.queue.dead) return;
        self.queue.enqueue(msg, hold);
        // One block a turn: only the call that scheduled the flush dispatches.
        if (self.queue.schedule()) objc.dispatchMain(self, flushJob);
    }

    pub fn domReady(self: *Page) void {
        // Held messages go out, and the app's `--nanoui-eval` runs: the
        // document is there, as it was when this ran inside `Page`.
        self.queue.domReady();
        // The bar of the app's pages: every document gets it, an app's own
        // page and the web's alike.
        self.sendPageBar();
        if (self.queue.outbox.items.len > 0) self.enqueue("", true);
    }

    /// The bar's list, as JSON, run in the document's own context.
    fn sendPageBar(self: *Page) void {
        const entries = self.queue.options.pages;
        if (entries.len == 0) return;
        const gpa = self.queue.gpa;
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        const wr = &aw.writer;
        wr.writeAll("window.__nanoui_setPages&&window.__nanoui_setPages([") catch return;
        for (entries, 0..) |e, i| {
            if (i > 0) wr.writeByte(',') catch return;
            wr.print("{{\"id\":{d},\"title\":", .{i}) catch return;
            std.json.Stringify.encodeJsonString(e.title, .{}, wr) catch return;
            wr.writeAll(",\"current\":") catch return;
            wr.writeAll(if (std.mem.eql(u8, e.url, self.queue.current_url)) "true" else "false") catch return;
            wr.writeByte('}') catch return;
        }
        wr.writeAll("])") catch return;
        sendJs(self, aw.written());
    }

    pub fn startDrag(self: *Page) void {
        // A screen isn't dragged.
        if (ios) return;
        const ev = self.last_mouse_down orelse return;
        objc.msg(void, self.queue.window.nswindow, "performWindowDragWithEvent:", .{ev});
    }

    fn loadUrl(self: *Page, url: []const u8) void {
        self.queue.setCurrent(url);
        // An absolute `http(s)://` URL loads as it is, as WebView2's does;
        // only a path is the app's own, served from its assets.
        const full = page.fullUrl(&stackBuf, url);
        const nsurl = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(full)}) orelse return;
        const req = objc.msg(objc.Object, objc.class("NSURLRequest"), "requestWithURL:", .{nsurl});
        self.queue.dom_ready = false;
        _ = objc.msg(?objc.Object, self.webview, "loadRequest:", .{req});
    }

    /// `Page.load`, for the window's `.page` content.
    pub fn load(self: *Page, url: []const u8) void {
        self.loadUrl(url);
    }

    /// Places a docked page in its parent view (points, the parent's
    /// coordinates). Call from the surface's `after_frame` with the box's
    /// laid-out rect, returning true, so the move presents with the frame.
    pub fn setFrame(self: *Page, x: f64, y: f64, w: f64, h: f64) void {
        objc.msg(void, self.webview, "setFrame:", .{objc.CGRect{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } }});
    }

    /// Queues an encoded message for this page (any thread: main only here).
    pub fn sendOwned(self: *Page, msg: []u8) void {
        defer self.queue.gpa.free(msg);
        self.enqueue(msg, true);
    }
};

var stackBuf: [2048]u8 = undefined;
fn sendJs(ctx: *anyopaque, js: []const u8) void {
    const self: *Page = @ptrCast(@alignCast(ctx));
    const pool = objc.Pool.push();
    defer pool.pop();
    objc.msg(void, self.webview, "evaluateJavaScript:completionHandler:", .{ objc.nsString(js), @as(?*anyopaque, null) });
}

fn flushJob(ctx: ?*anyopaque) callconv(.c) void {
    const self: *Page = @ptrCast(@alignCast(ctx));
    if (self.queue.dead) {
        self.queue.gpa.destroy(self);
        return;
    }
    self.queue.flush();
}

fn didReceiveScriptMessage(self_obj: objc.Object, _: objc.SEL, _: objc.Object, message: objc.Object) callconv(.c) void {
    const self = objc.getZig(Page, self_obj) orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const body = objc.msg(objc.Object, message, "body", .{});
    // The page that sent it, which need not be the window's `page`, and the
    // document in it that did: where the frame is now, not where it was sent.
    ipc.handlePageMessage(self.queue.window, self, objc.fromNSString(body), messageSource(message));
}

/// The absolute URL of the frame a script message came from
/// (`message.frameInfo.request.URL`), or "" when WebKit gives none.
fn messageSource(message: objc.Object) []const u8 {
    const frame = objc.msg(?objc.Object, message, "frameInfo", .{}) orelse return "";
    const req = objc.msg(?objc.Object, frame, "request", .{}) orelse return "";
    const url = objc.msg(?objc.Object, req, "URL", .{}) orelse return "";
    return objc.fromNSString(objc.msg(?objc.Object, url, "absoluteString", .{}));
}

fn startURLSchemeTask(self_obj: objc.Object, _: objc.SEL, _: objc.Object, task: objc.Object) callconv(.c) void {
    const self = objc.getZig(Page, self_obj) orelse return;
    serve(self, task);
}

fn stopURLSchemeTask(_: objc.Object, _: objc.SEL, _: objc.Object, _: objc.Object) callconv(.c) void {}

fn serve(self: *Page, task: objc.Object) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const req = objc.msg(objc.Object, task, "request", .{});
    const url = objc.msg(objc.Object, req, "URL", .{});
    const path = objc.fromNSString(objc.msg(?objc.Object, url, "path", .{}));
    const served = self.queue.serve(path);

    const keys = [_]objc.Object{ objc.nsString("Content-Type"), objc.nsString("Cache-Control") };
    const values = [_]objc.Object{ objc.nsString(served.mime), objc.nsString("no-cache") };
    const headers = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObjects:forKeys:count:", .{ &values, &keys, @as(objc.NSUInteger, keys.len) });
    const res = objc.msg(objc.Object, objc.alloc("NSHTTPURLResponse"), "initWithURL:statusCode:HTTPVersion:headerFields:", .{
        url, @as(objc.NSInteger, served.status), objc.nsString("HTTP/1.1"), headers,
    });
    defer objc.release(res);
    const nsdata = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ served.data.ptr, served.data.len });
    objc.msg(void, task, "didReceiveResponse:", .{res});
    objc.msg(void, task, "didReceiveData:", .{nsdata});
    objc.msg(void, task, "didFinish", .{});
}

fn webViewMouseDown(self_obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const self = objc.getZig(Page, self_obj) orelse return;
    // Kept for `startDrag` after the callback returns: owned, the old one
    // let go, and WebKit's own press still runs.
    if (self.last_mouse_down) |old| objc.release(old);
    self.last_mouse_down = objc.retain(event);
    objc.msgSuper(void, self_obj, objc.class("WKWebView"), "mouseDown:", .{event});
}
