//! No HWNDs or WebView2 runtime: deliver real handler vtables against fake COM.
const std = @import("std");
const testing = std.testing;
const Page = @import("../page_webview2.zig").Page;
const target = @import("../page_webview2_target.zig");
const handlers = @import("../page_webview2_handlers.zig");
const page = @import("../page.zig");
const window = @import("window.zig");
const Window = window.Window;
const App = @import("app.zig").App;
const ipc = @import("../ipc.zig").ipc(Window, App);
const wv = @import("webview2.zig");
const w = @import("win32.zig");
const Com = wv.Com;
const HRESULT = wv.HRESULT;
const gpa = testing.allocator;

const Host = struct {
    app: *App,
    win: *Window,

    fn init() !Host {
        const app = try gpa.create(App);
        errdefer gpa.destroy(app);
        app.* = .{ .gpa = gpa, .io = std.Io.Threaded.global_single_threaded.io(), .options = .{ .quit_on_last_window_closed = false } };
        const win = try gpa.create(Window);
        errdefer gpa.destroy(win);
        win.* = .{ .app = app };
        try app.windows.append(gpa, win);
        return .{ .app = app, .win = win };
    }

    fn makePage(self: Host, docked: bool, parent: ?*anyopaque) !*Page {
        const p = try gpa.create(Page);
        errdefer gpa.destroy(p);
        const data_dir = try gpa.dupeSentinel(u16, &.{}, 0);
        errdefer gpa.free(data_dir);
        // These handles are inspected only, never passed to Win32.
        const handles = try target.Handles.init(@ptrFromInt(0x1000), parent);
        p.* = .{
            .queue = page.Queue(Window).init(self.win, .{}),
            .hwnd = handles.parent,
            .owner_hwnd = handles.owner,
            .target = try Page.Target.create(gpa, p),
            .data_dir = data_dir,
            .docked = docked,
        };
        errdefer p.destroy();
        if (docked) try self.win.docked.append(gpa, p) else self.win.page = p;
        return p;
    }
};

fn completion(h: *Com, err: HRESULT, result: ?*Com) HRESULT {
    return h.slot(*const fn (*Com, HRESULT, ?*Com) callconv(.winapi) HRESULT, 3)(h, err, result);
}

fn event(h: *Com, args: ?*Com) HRESULT {
    return h.slot(*const fn (*Com, ?*Com, ?*Com) callconv(.winapi) HRESULT, 3)(h, null, args);
}

const Fake = struct {
    com: Com = .{ .vtable = &vtable },
    refs: u32 = 1,
    closes: usize = 0,
    visible_calls: usize = 0,
    removals: usize = 0,
    view: ?*Com = null,
    registered: ?*Com = null,
    close_on_view: ?*App = null,
    close_on_register: ?*App = null,

    const vtable = table();
    fn table() [58]*const anyopaque {
        var t: [58]*const anyopaque = @splat(&unexpected);
        t[1] = &addRef;
        t[2] = &release;
        t[3] = &settings;
        t[4] = &visible;
        t[6] = &bounds;
        t[24] = &close;
        t[25] = &webView;
        t[55] = &register;
        t[56] = &remove;
        t[35] = &remove;
        t[57] = &filter;
        return t;
    }
    fn self(c: *Com) *Fake {
        return @fieldParentPtr("com", c);
    }
    fn unexpected() callconv(.winapi) void {
        @panic("unexpected COM call after cancellation");
    }
    fn addRef(c: *Com) callconv(.winapi) u32 {
        self(c).refs += 1;
        return self(c).refs;
    }
    fn release(c: *Com) callconv(.winapi) u32 {
        self(c).refs -= 1;
        return self(c).refs;
    }
    fn close(c: *Com) callconv(.winapi) HRESULT {
        self(c).closes += 1;
        return wv.S_OK;
    }
    fn visible(c: *Com, _: i32) callconv(.winapi) HRESULT {
        self(c).visible_calls += 1;
        return wv.S_OK;
    }
    fn bounds(_: *Com, _: wv.Rect) callconv(.winapi) HRESULT {
        return wv.S_OK;
    }
    fn webView(c: *Com, out: *?*Com) callconv(.winapi) HRESULT {
        const f = self(c);
        out.* = f.view;
        if (out.*) |v| _ = v.addRef();
        if (f.close_on_view) |app| {
            f.close_on_view = null;
            app.destroy();
        }
        return wv.S_OK;
    }
    fn settings(_: *Com, out: *?*Com) callconv(.winapi) HRESULT {
        out.* = null;
        return wv.S_OK;
    }
    fn filter(_: *Com, _: [*:0]const u16, _: u32) callconv(.winapi) HRESULT {
        return wv.S_OK;
    }
    fn register(c: *Com, h: *Com, token: ?*i64) callconv(.winapi) HRESULT {
        const f = self(c);
        _ = h.addRef();
        f.registered = h;
        if (f.close_on_register) |app| {
            f.close_on_register = null;
            app.destroy();
        }
        // The token can arrive after a nested callback destroyed the page.
        if (token) |t| t.* = 1;
        return wv.S_OK;
    }
    fn remove(c: *Com, _: i64) callconv(.winapi) HRESULT {
        const f = self(c);
        f.removals += 1;
        if (f.registered) |h| {
            f.registered = null;
            // Deliver once more during teardown, before releasing it.
            _ = event(h, @ptrFromInt(0x10));
            h.release();
        }
        return wv.S_OK;
    }
};

test "WebView2: pending environment completion after page/window/app destruction" {
    const host = try Host.init();
    const p = try host.makePage(false, null);
    const h = try p.makeHandler(handlers.EnvCreated);
    defer h.release();
    const lifetime = p.target;
    host.app.destroy();
    try testing.expect(lifetime.page == null);
    try testing.expectEqual(@as(usize, 1), lifetime.refs);
    var env: Fake = .{};
    try testing.expectEqual(wv.S_OK, completion(h, 0, &env.com));
    try testing.expectEqual(wv.S_OK, completion(h, -1, null));
    try testing.expectEqual(@as(u32, 1), env.refs);
    try testing.expectEqual(@as(usize, 0), env.closes);
}

test "WebView2: pending controller closes its borrowed result after destruction" {
    const host = try Host.init();
    const p = try host.makePage(true, null);
    var env: Fake = .{};
    _ = env.com.addRef();
    p.environment = &env.com;
    const h = try p.makeHandler(handlers.CtlCreated);
    defer h.release();
    const lifetime = p.target;
    host.app.destroy();
    try testing.expect(lifetime.page == null);
    try testing.expectEqual(@as(u32, 1), env.refs);
    var ctl: Fake = .{};
    try testing.expectEqual(wv.S_OK, completion(h, 0, &ctl.com));
    try testing.expectEqual(wv.S_OK, completion(h, -1, null));
    try testing.expectEqual(@as(usize, 1), ctl.closes);
    try testing.expectEqual(@as(u32, 1), ctl.refs);
}

test "WebView2: script and all registered events ignore late poisoned arguments" {
    const host = try Host.init();
    const p = try host.makePage(true, null);
    const script = try p.makeHandler(handlers.ScriptDone);
    defer script.release();
    const events = [_]*Com{
        try p.makeHandler(handlers.NavigationCompleted),
        try p.makeHandler(handlers.MessageReceived),
        try p.makeHandler(handlers.ResourceRequested),
    };
    defer for (events) |h| h.release();
    host.app.destroy();
    try testing.expectEqual(wv.S_OK, completion(script, 0, @ptrFromInt(0x10)));
    for (events) |h| try testing.expectEqual(wv.S_OK, event(h, @ptrFromInt(0x10)));
}

test "WebView2: reentrant close while getting the controller's view stops setup" {
    const host = try Host.init();
    const p = try host.makePage(true, null);
    const h = try p.makeHandler(handlers.CtlCreated);
    defer h.release();
    var view: Fake = .{};
    var ctl: Fake = .{ .view = &view.com, .close_on_view = host.app };
    try testing.expectEqual(wv.S_OK, completion(h, 0, &ctl.com));
    try testing.expectEqual(@as(usize, 0), ctl.visible_calls);
    try testing.expectEqual(@as(usize, 1), ctl.closes);
    try testing.expectEqual(@as(u32, 1), ctl.refs);
    try testing.expectEqual(@as(u32, 1), view.refs);
}

test "WebView2: a registration completed after reentrant close is removed" {
    const host = try Host.init();
    const p = try host.makePage(true, null);
    const h = try p.makeHandler(handlers.CtlCreated);
    defer h.release();
    var view: Fake = .{ .close_on_register = host.app };
    var ctl: Fake = .{ .view = &view.com };
    try testing.expectEqual(wv.S_OK, completion(h, 0, &ctl.com));
    try testing.expectEqual(@as(usize, 1), view.removals);
    try testing.expect(view.registered == null);
    try testing.expectEqual(@as(u32, 1), ctl.refs);
    try testing.expectEqual(@as(u32, 1), view.refs);
}

extern "ole32" fn CoTaskMemAlloc(size: usize) callconv(.winapi) ?*anyopaque;

const Message = struct {
    com: Com = .{ .vtable = &vtable },
    close_on_source: ?*App = null,
    const vtable: [5]*const anyopaque = .{ &Fake.unexpected, &Fake.unexpected, &Fake.unexpected, &source, &json };

    fn json(_: *Com, out: *wv.PWSTR) callconv(.winapi) HRESULT {
        const text = wv.utf8LitZ("{\"t\":\"call\",\"id\":1,\"m\":\"Closing.close\",\"a\":[]}");
        const len = std.mem.span(text).len;
        const bytes = (len + 1) * @sizeOf(u16);
        const mem = CoTaskMemAlloc(bytes) orelse return -1;
        const wide: [*]u16 = @ptrCast(@alignCast(mem));
        @memcpy(wide[0 .. len + 1], text[0 .. len + 1]);
        out.* = @ptrCast(wide);
        return wv.S_OK;
    }
    fn source(c: *Com, out: *wv.PWSTR) callconv(.winapi) HRESULT {
        const m: *Message = @fieldParentPtr("com", c);
        out.* = null;
        if (m.close_on_source) |app| {
            m.close_on_source = null;
            app.destroy();
        }
        return wv.S_OK;
    }
};

const Closing = struct {
    called: bool = false,
    handler: *Com,

    pub fn close(self: *Closing, call: *ipc.Call) void {
        self.called = true;
        const p: *Page = @ptrCast(@alignCast(call.page.?));
        // Nested IPC resets its boolean dispatch flag before the outer call
        // finishes. The handler's stack pin must still protect this page.
        ipc.handlePageMessage(call.window, p, "{\"t\":\"log\"}", "");
        call.window.app.destroy();
        // The App and Window are gone, even though the outer call is live.
        _ = event(self.handler, @ptrFromInt(0x10));
    }
};

test "WebView2: nested IPC destroys the app and releases the executing handler" {
    const host = try Host.init();
    const p = try host.makePage(true, null);
    const h = try p.makeHandler(handlers.MessageReceived);
    var closing: Closing = .{ .handler = h };
    try host.app.bind(&closing);
    var view: Fake = .{ .registered = h };
    // Transfer the maker's handler reference and a view reference to Page.
    p.webview = &view.com;
    _ = view.com.addRef();
    p.token_message = 1;
    var args: Message = .{};
    try testing.expectEqual(wv.S_OK, event(h, &args.com));
    // Do not touch h: unregistering released its last reference on return.
    try testing.expect(closing.called);
    try testing.expectEqual(@as(usize, 1), view.removals);
    try testing.expectEqual(@as(u32, 1), view.refs);
    try testing.expect(view.registered == null);
}

test "WebView2: close while reading message source never dispatches into a freed app" {
    const host = try Host.init();
    const p = try host.makePage(true, null);
    const h = try p.makeHandler(handlers.MessageReceived);
    defer h.release();
    var args: Message = .{ .close_on_source = host.app };
    try testing.expectEqual(wv.S_OK, event(h, &args.com));
}

test "WebView2: destroying the main page detaches its route before the window closes" {
    const host = try Host.init();
    defer host.app.destroy();
    const p = try host.makePage(false, null);
    const id = p.target.id;
    p.destroy();
    try testing.expect(host.win.page == null);
    try testing.expect(host.win.pageFor(id) == null);
    const replacement = try host.makePage(false, null);
    try testing.expect(host.win.pageFor(id) == null);
    try testing.expectEqual(replacement, host.win.pageFor(replacement.target.id).?);
}

const Post = struct {
    var hwnd: ?w.HWND = null;
    var id: usize = 0;
    var kind: u32 = 0;
    fn send(h: w.HWND, msg: u32, wp: w.WPARAM, _: w.LPARAM) callconv(.winapi) w.BOOL {
        hwnd = h;
        id = wp;
        kind = msg;
        return 1;
    }
};

test "WebView2: custom parent keeps internal messages on the owner and drops stale ids" {
    const host = try Host.init();
    defer host.app.destroy();
    const p = try host.makePage(true, @ptrFromInt(0x2000));
    try testing.expect(p.hwnd != p.owner_hwnd);
    const old_id = p.target.id;
    for ([_]u32{ window.WM_NANOUI_FLUSH, window.WM_NANOUI_CONTROLLER }) |kind| {
        target.post(p, kind, Post.send);
        try testing.expectEqual(@as(?w.HWND, p.owner_hwnd), Post.hwnd);
        try testing.expectEqual(kind, Post.kind);
        try testing.expectEqual(old_id, Post.id);
        try testing.expectEqual(p, host.win.pageFor(Post.id).?);
    }
    p.destroy();
    try testing.expect(host.win.pageFor(old_id) == null);
    const replacement = try host.makePage(true, null);
    try testing.expect(replacement.target.id != old_id);
    try testing.expect(host.win.pageFor(old_id) == null);
    try testing.expect(host.win.pageFor(0) == null);
    try testing.expectEqual(replacement, host.win.pageFor(replacement.target.id).?);
    try testing.expectEqual(replacement.owner_hwnd, replacement.hwnd);
}
