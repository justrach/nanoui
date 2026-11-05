//! A message through `handlePageMessage`, the way a webview hands one over:
//! what the method sees in `Call` (the page, its label, the sending
//! document's URL and origin) and the reply the page gets.
const std = @import("std");
const page_mod = @import("page.zig");
const window_types = @import("window_types.zig");

const testing = std.testing;

const FakeApp = struct {
    gpa: std.mem.Allocator,
    services: std.StringHashMapUnmanaged(I.Service) = .empty,
};

const FakePage = struct {
    queue: struct {
        gpa: std.mem.Allocator,
        options: window_types.PageOptions = .{},
        current_url: []const u8 = "",
        dispatching: bool = false,
        dead: bool = false,
        flush_scheduled: bool = false,
    },
    sent: std.ArrayList(u8) = .empty,

    pub fn enqueue(self: *FakePage, msg: []const u8, hold: bool) void {
        _ = hold;
        self.sent.appendSlice(self.queue.gpa, msg) catch {};
    }
    pub fn domReady(_: *FakePage) void {}
    pub fn startDrag(_: *FakePage) void {}
};

const FakeWindow = struct {
    app: *FakeApp,
    page: ?*FakePage = null,

    pub fn showPage(_: *FakeWindow, _: usize) void {}
    pub fn zoom(_: *FakeWindow) void {}
    pub fn close(_: *FakeWindow) void {}
    pub fn minimize(_: *FakeWindow) void {}
    pub fn setTitle(_: *FakeWindow, _: []const u8) void {}
};

const I = @import("ipc.zig").ipc(FakeWindow, FakeApp);

/// What the method saw, copied out of the call's arena.
const Seen = struct {
    page: ?*anyopaque = null,
    label: [64]u8 = undefined,
    label_len: usize = 0,
    url: [128]u8 = undefined,
    url_len: usize = 0,
    origin: [64]u8 = undefined,
    origin_len: usize = 0,
};

const Code = struct {
    seen: Seen = .{},

    pub fn who(self: *Code, call: *I.Call) []const u8 {
        self.seen.page = call.page;
        self.seen.label_len = copy(&self.seen.label, call.label);
        self.seen.url_len = copy(&self.seen.url, call.url);
        self.seen.origin_len = copy(&self.seen.origin, call.origin());
        return call.origin();
    }

    fn copy(dst: []u8, src: []const u8) usize {
        const n = @min(dst.len, src.len);
        @memcpy(dst[0..n], src[0..n]);
        return n;
    }
};

const Rig = struct {
    app: FakeApp,
    window: FakeWindow,
    page: FakePage,
    code: Code = .{},

    fn init(self: *Rig, label: []const u8, current: []const u8) !void {
        self.* = .{
            .app = .{ .gpa = testing.allocator },
            .window = undefined,
            .page = .{ .queue = .{ .gpa = testing.allocator, .options = .{ .label = label }, .current_url = current } },
        };
        self.window = .{ .app = &self.app, .page = &self.page };
        const svc = I.service(Code, &self.code);
        try self.app.services.put(testing.allocator, svc.name, svc);
    }

    fn deinit(self: *Rig) void {
        self.app.services.deinit(testing.allocator);
        self.page.sent.deinit(testing.allocator);
    }
};

const call_body = "{\"t\":\"call\",\"id\":7,\"m\":\"Code.who\",\"a\":[]}";

test "a call carries its page, label and the sending document's origin" {
    var r: Rig = undefined;
    try r.init("motion-code", "/code.html");
    defer r.deinit();
    I.handlePageMessage(&r.window, &r.page, call_body, page_mod.origin ++ "/code.html?x=1");
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&r.page)), r.code.seen.page);
    try testing.expectEqualStrings("motion-code", r.code.seen.label[0..r.code.seen.label_len]);
    try testing.expectEqualStrings(page_mod.origin ++ "/code.html?x=1", r.code.seen.url[0..r.code.seen.url_len]);
    try testing.expectEqualStrings(page_mod.origin, r.code.seen.origin[0..r.code.seen.origin_len]);
    try testing.expectEqualStrings("{\"t\":\"reply\",\"id\":7,\"ok\":true,\"v\":\"" ++ page_mod.origin ++ "\"}", r.page.sent.items);
}

test "a page that navigated itself is seen where it went" {
    var r: Rig = undefined;
    try r.init("motion-code", "/code.html");
    defer r.deinit();
    I.handlePageMessage(&r.window, &r.page, call_body, "https://evil.example/x");
    try testing.expectEqualStrings("https://evil.example", r.code.seen.origin[0..r.code.seen.origin_len]);
}

test "without a source the app's path resolves onto its origin" {
    var r: Rig = undefined;
    try r.init("", "/code.html");
    defer r.deinit();
    // `handleMessage` is the window's own page, with no source to give.
    I.handleMessage(&r.window, call_body);
    try testing.expectEqualStrings(page_mod.origin ++ "/code.html", r.code.seen.url[0..r.code.seen.url_len]);
    try testing.expectEqualStrings(page_mod.origin, r.code.seen.origin[0..r.code.seen.origin_len]);
    // A remote page's URL stays as it is.
    r.page.queue.current_url = "http://localhost:5173/";
    I.handleMessage(&r.window, call_body);
    try testing.expectEqualStrings("http://localhost:5173", r.code.seen.origin[0..r.code.seen.origin_len]);
}

test "a URL too long to keep clears the current one" {
    const Q = page_mod.Queue(FakeWindow);
    var q: Q = .{ .window = undefined, .gpa = testing.allocator, .options = .{} };
    q.setCurrent("/a.html");
    try testing.expectEqualStrings("/a.html", q.current_url);
    const long: [@typeInfo(@FieldType(Q, "current_buf")).array.len + 1]u8 = @splat('a');
    q.setCurrent(&long);
    try testing.expectEqualStrings("", q.current_url);
}
