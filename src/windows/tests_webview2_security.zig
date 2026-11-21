//! No HWNDs or WebView2 runtime: verify WebView2 `allow_request` fail-closed guards.
const std = @import("std");
const testing = std.testing;
const Page = @import("../page_webview2.zig").Page;
const target = @import("../page_webview2_target.zig");
const handlers = @import("../page_webview2_handlers.zig");
const page = @import("../page.zig");
const window = @import("window.zig");
const Window = window.Window;
const App = @import("app.zig").App;
const wv = @import("webview2.zig");
const Com = wv.Com;
const HRESULT = wv.HRESULT;
const gpa = testing.allocator;

extern "ole32" fn CoTaskMemAlloc(cb: usize) callconv(.winapi) ?*anyopaque;

const Host = struct {
    app: *App,
    win: *Window,
    errors: usize = 0,
    last_url: [128]u8 = undefined,
    last_url_len: usize = 0,
    allow_calls: usize = 0,
    allow_result: bool = false,

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

    fn onError(ctx: ?*anyopaque, url: []const u8, _: []const u8) void {
        const self: *Host = @ptrCast(@alignCast(ctx.?));
        self.errors += 1;
        const n = @min(url.len, self.last_url.len);
        @memcpy(self.last_url[0..n], url[0..n]);
        self.last_url_len = n;
    }

    fn allowRequest(ctx: ?*anyopaque, _: []const u8) bool {
        const self: *Host = @ptrCast(@alignCast(ctx.?));
        self.allow_calls += 1;
        return self.allow_result;
    }

    fn makePage(self: *Host, with_filter: bool) !*Page {
        const p = try gpa.create(Page);
        errdefer gpa.destroy(p);
        const data_dir = try gpa.dupeSentinel(u16, &.{}, 0);
        errdefer gpa.free(data_dir);
        const handles = try target.Handles.init(@ptrFromInt(0x1000), null);
        p.* = .{
            .queue = page.Queue(Window).init(self.win, .{
                .url = "https://app.example/start",
                .allow_request = if (with_filter) allowRequest else null,
                .allow_request_ctx = self,
                .on_load_error = onError,
                .on_load_error_ctx = self,
            }),
            .hwnd = handles.parent,
            .owner_hwnd = handles.owner,
            .target = try Page.Target.create(gpa, p),
            .data_dir = data_dir,
        };
        self.win.page = p;
        return p;
    }
};

fn allocCoWideUnits(units: []const u16) !wv.PWSTR {
    const raw = CoTaskMemAlloc((units.len + 1) * @sizeOf(u16)) orelse return error.OutOfMemory;
    const wide: [*]u16 = @ptrCast(@alignCast(raw));
    @memcpy(wide[0..units.len], units);
    wide[units.len] = 0;
    return @ptrCast(wide);
}

fn unexpected() callconv(.winapi) void {
    @panic("unexpected COM slot call");
}

fn baseAddRef(refs: *u32) u32 {
    refs.* += 1;
    return refs.*;
}

fn baseRelease(refs: *u32) u32 {
    refs.* -= 1;
    return refs.*;
}

const FakeResponse = struct {
    com: Com = .{ .vtable = &vtable },
    refs: u32 = 1,
    const vtable = table();
    fn table() [3]*const anyopaque {
        var t: [3]*const anyopaque = @splat(&unexpected);
        t[1] = &addRef;
        t[2] = &release;
        return t;
    }
    fn self(c: *Com) *FakeResponse {
        return @fieldParentPtr("com", c);
    }
    fn addRef(c: *Com) callconv(.winapi) u32 {
        return baseAddRef(&self(c).refs);
    }
    fn release(c: *Com) callconv(.winapi) u32 {
        return baseRelease(&self(c).refs);
    }
};

const FakeEnv = struct {
    com: Com = .{ .vtable = &vtable },
    refs: u32 = 1,
    response: *FakeResponse,
    response_status: i32 = 0,
    const vtable = table();
    fn table() [5]*const anyopaque {
        var t: [5]*const anyopaque = @splat(&unexpected);
        t[1] = &addRef;
        t[2] = &release;
        t[4] = &createResponse;
        return t;
    }
    fn self(c: *Com) *FakeEnv {
        return @fieldParentPtr("com", c);
    }
    fn addRef(c: *Com) callconv(.winapi) u32 {
        return baseAddRef(&self(c).refs);
    }
    fn release(c: *Com) callconv(.winapi) u32 {
        return baseRelease(&self(c).refs);
    }
    fn createResponse(c: *Com, _: ?*Com, status: i32, _: [*:0]const u16, _: [*:0]const u16, out: *?*Com) callconv(.winapi) HRESULT {
        const f = self(c);
        f.response_status = status;
        _ = f.response.com.addRef();
        out.* = &f.response.com;
        return wv.S_OK;
    }
};

const FakeView = struct {
    com: Com = .{ .vtable = &vtable },
    refs: u32 = 1,
    has_v22: bool = true,
    filter_kinds_hr: HRESULT = wv.S_OK,
    add_resource_hr: HRESULT = wv.S_OK,
    navigates: usize = 0,
    const vtable = table();
    fn table() [124]*const anyopaque {
        var t: [124]*const anyopaque = @splat(&unexpected);
        t[0] = &qi;
        t[1] = &addRef;
        t[2] = &release;
        t[3] = &settings;
        t[5] = &navigate;
        t[55] = &addResource;
        t[56] = &remove;
        t[57] = &filter;
        t[123] = &filterKinds;
        return t;
    }
    fn self(c: *Com) *FakeView {
        return @fieldParentPtr("com", c);
    }
    fn qi(c: *Com, iid: *const wv.Guid, out: *?*anyopaque) callconv(.winapi) HRESULT {
        const f = self(c);
        if (std.meta.eql(iid.*, wv.iid_webview2_22) and f.has_v22) {
            f.refs += 1;
            out.* = c;
            return wv.S_OK;
        }
        out.* = null;
        return -1;
    }
    fn addRef(c: *Com) callconv(.winapi) u32 {
        return baseAddRef(&self(c).refs);
    }
    fn release(c: *Com) callconv(.winapi) u32 {
        return baseRelease(&self(c).refs);
    }
    fn settings(_: *Com, out: *?*Com) callconv(.winapi) HRESULT {
        out.* = null;
        return wv.S_OK;
    }
    fn navigate(c: *Com, _: [*:0]const u16) callconv(.winapi) HRESULT {
        self(c).navigates += 1;
        return wv.S_OK;
    }
    fn filter(_: *Com, _: [*:0]const u16, _: u32) callconv(.winapi) HRESULT {
        return wv.S_OK;
    }
    fn filterKinds(c: *Com, _: [*:0]const u16, _: u32, _: u32) callconv(.winapi) HRESULT {
        return self(c).filter_kinds_hr;
    }
    fn addResource(c: *Com, _: *Com, token: ?*i64) callconv(.winapi) HRESULT {
        const f = self(c);
        if (f.add_resource_hr < 0) return f.add_resource_hr;
        if (token) |t| t.* = 1;
        return wv.S_OK;
    }
    fn remove(_: *Com, _: i64) callconv(.winapi) HRESULT {
        return wv.S_OK;
    }
};

const FakeCtl = struct {
    com: Com = .{ .vtable = &vtable },
    refs: u32 = 1,
    view: *FakeView,
    closes: usize = 0,
    hidden_calls: usize = 0,
    const vtable = table();
    fn table() [26]*const anyopaque {
        var t: [26]*const anyopaque = @splat(&unexpected);
        t[1] = &addRef;
        t[2] = &release;
        t[4] = &setIsVisible;
        t[6] = &bounds;
        t[24] = &close;
        t[25] = &webView;
        return t;
    }
    fn self(c: *Com) *FakeCtl {
        return @fieldParentPtr("com", c);
    }
    fn addRef(c: *Com) callconv(.winapi) u32 {
        return baseAddRef(&self(c).refs);
    }
    fn release(c: *Com) callconv(.winapi) u32 {
        return baseRelease(&self(c).refs);
    }
    fn setIsVisible(c: *Com, visible: wv.BOOL) callconv(.winapi) HRESULT {
        if (visible == 0) self(c).hidden_calls += 1;
        return wv.S_OK;
    }
    fn bounds(_: *Com, _: wv.Rect) callconv(.winapi) HRESULT {
        return wv.S_OK;
    }
    fn close(c: *Com) callconv(.winapi) HRESULT {
        self(c).closes += 1;
        return wv.S_OK;
    }
    fn webView(c: *Com, out: *?*Com) callconv(.winapi) HRESULT {
        const f = self(c);
        _ = f.view.com.addRef();
        out.* = &f.view.com;
        return wv.S_OK;
    }
};

const FakeReq = struct {
    com: Com = .{ .vtable = &vtable },
    refs: u32 = 1,
    uri_hr: HRESULT = wv.S_OK,
    uri_units: []const u16 = &.{ 'h', 't', 't', 'p', 's', ':', '/', '/', 'e', 'v', 'i', 'l', '.', 't', 'e', 's', 't', '/' },
    const vtable = table();
    fn table() [4]*const anyopaque {
        var t: [4]*const anyopaque = @splat(&unexpected);
        t[1] = &addRef;
        t[2] = &release;
        t[3] = &uri;
        return t;
    }
    fn self(c: *Com) *FakeReq {
        return @fieldParentPtr("com", c);
    }
    fn addRef(c: *Com) callconv(.winapi) u32 {
        return baseAddRef(&self(c).refs);
    }
    fn release(c: *Com) callconv(.winapi) u32 {
        return baseRelease(&self(c).refs);
    }
    fn uri(c: *Com, out: *wv.PWSTR) callconv(.winapi) HRESULT {
        const f = self(c);
        if (f.uri_hr < 0) {
            out.* = null;
            return f.uri_hr;
        }
        out.* = allocCoWideUnits(f.uri_units) catch return -1;
        return wv.S_OK;
    }
};

const FakeArgs = struct {
    com: Com = .{ .vtable = &vtable },
    refs: u32 = 1,
    request_hr: HRESULT = wv.S_OK,
    req: ?*FakeReq = null,
    set_response_calls: usize = 0,
    const vtable = table();
    fn table() [6]*const anyopaque {
        var t: [6]*const anyopaque = @splat(&unexpected);
        t[1] = &addRef;
        t[2] = &release;
        t[3] = &request;
        t[5] = &setResponse;
        return t;
    }
    fn self(c: *Com) *FakeArgs {
        return @fieldParentPtr("com", c);
    }
    fn addRef(c: *Com) callconv(.winapi) u32 {
        return baseAddRef(&self(c).refs);
    }
    fn release(c: *Com) callconv(.winapi) u32 {
        return baseRelease(&self(c).refs);
    }
    fn request(c: *Com, out: *?*Com) callconv(.winapi) HRESULT {
        const f = self(c);
        if (f.request_hr < 0) {
            out.* = null;
            return f.request_hr;
        }
        if (f.req) |r| {
            _ = r.com.addRef();
            out.* = &r.com;
            return wv.S_OK;
        }
        out.* = null;
        return wv.S_OK;
    }
    fn setResponse(c: *Com, _: *Com) callconv(.winapi) HRESULT {
        self(c).set_response_calls += 1;
        return wv.S_OK;
    }
};

test "WebView2: controllerReady blocks page when ICoreWebView2_22 is absent" {
    var host = try Host.init();
    const p = try host.makePage(true);
    defer host.app.destroy();
    var view: FakeView = .{ .has_v22 = false };
    var ctl: FakeCtl = .{ .view = &view };
    p.controllerReady(&ctl.com);
    try testing.expect(p.filter_blocked);
    try testing.expect(p.webview == null);
    try testing.expect(p.controller == null);
    try testing.expectEqual(@as(usize, 1), ctl.closes);
    try testing.expectEqual(@as(usize, 1), ctl.hidden_calls);
    try testing.expectEqual(@as(usize, 1), host.errors);
    try testing.expectEqualStrings("https://app.example/start", host.last_url[0..host.last_url_len]);
    try testing.expectEqual(@as(u32, 1), ctl.refs);
    try testing.expectEqual(@as(u32, 1), view.refs);
    p.load("https://later.example/");
    try testing.expectError(error.NoPage, p.loadRequest(.{ .url = "https://later.example/" }));
    try testing.expectEqual(@as(usize, 0), view.navigates);
}

test "WebView2: controllerReady blocks page when AddWebResourceRequestedFilterWithRequestSourceKinds fails" {
    var host = try Host.init();
    const p = try host.makePage(true);
    defer host.app.destroy();
    try p.loadRequest(.{ .url = "https://queued.example/app" });
    var view: FakeView = .{ .filter_kinds_hr = -1 };
    var ctl: FakeCtl = .{ .view = &view };
    p.controllerReady(&ctl.com);
    try testing.expect(p.filter_blocked);
    try testing.expect(p.webview == null);
    try testing.expectEqual(@as(usize, 1), ctl.closes);
    try testing.expectEqual(@as(usize, 1), host.errors);
    try testing.expectEqualStrings("https://queued.example/app", host.last_url[0..host.last_url_len]);
    try testing.expectEqual(@as(u32, 1), ctl.refs);
    try testing.expectEqual(@as(u32, 1), view.refs);
}

test "WebView2: controllerReady blocks page when add_WebResourceRequested fails" {
    var host = try Host.init();
    const p = try host.makePage(true);
    defer host.app.destroy();
    var view: FakeView = .{ .add_resource_hr = -1 };
    var ctl: FakeCtl = .{ .view = &view };
    p.controllerReady(&ctl.com);
    try testing.expect(p.filter_blocked);
    try testing.expect(p.webview == null);
    try testing.expectEqual(@as(usize, 1), ctl.closes);
    try testing.expectEqual(@as(usize, 1), host.errors);
    try testing.expectEqual(@as(u32, 1), ctl.refs);
    try testing.expectEqual(@as(u32, 1), view.refs);
}

test "WebView2: ResourceRequested fails closed with 403 on COM/UTF-16/OOM failures" {
    var host = try Host.init();
    const p = try host.makePage(true);
    defer host.app.destroy();
    var resp: FakeResponse = .{};
    var env: FakeEnv = .{ .response = &resp };
    _ = env.com.addRef();
    p.environment = &env.com;

    var bad_args: FakeArgs = .{ .request_hr = -1 };
    _ = handlers.ResourceRequested.invoke(p, null, &bad_args.com);
    try testing.expectEqual(@as(usize, 1), bad_args.set_response_calls);
    try testing.expectEqual(@as(i32, 403), env.response_status);
    try testing.expectEqual(@as(usize, 0), host.allow_calls);

    var bad_req: FakeReq = .{ .uri_units = &.{0xD800} };
    var args_bad_utf16: FakeArgs = .{ .req = &bad_req };
    env.response_status = 0;
    _ = handlers.ResourceRequested.invoke(p, null, &args_bad_utf16.com);
    try testing.expectEqual(@as(usize, 1), args_bad_utf16.set_response_calls);
    try testing.expectEqual(@as(i32, 403), env.response_status);
    try testing.expectEqual(@as(usize, 0), host.allow_calls);
    try testing.expectEqual(@as(u32, 1), bad_req.refs);

    var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    p.queue.gpa = failing.allocator();
    var ok_req: FakeReq = .{};
    var args_oom: FakeArgs = .{ .req = &ok_req };
    env.response_status = 0;
    _ = handlers.ResourceRequested.invoke(p, null, &args_oom.com);
    p.queue.gpa = gpa;
    try testing.expectEqual(@as(usize, 1), args_oom.set_response_calls);
    try testing.expectEqual(@as(i32, 403), env.response_status);
    try testing.expectEqual(@as(usize, 0), host.allow_calls);
    try testing.expectEqual(@as(u32, 1), ok_req.refs);
    try testing.expectEqual(@as(u32, 1), resp.refs);

    p.queue.options.allow_request = null;
    var unfiltered_args: FakeArgs = .{ .request_hr = -1 };
    _ = handlers.ResourceRequested.invoke(p, null, &unfiltered_args.com);
    try testing.expectEqual(@as(usize, 0), unfiltered_args.set_response_calls);
}
