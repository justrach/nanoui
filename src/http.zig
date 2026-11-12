//! HTTP requests, answered on the main thread: the system's own client
//! on macOS and iOS (NSURLSession: its TLS, proxies, caches and
//! certificates), so an app need bring none; on Linux, Windows and
//! Android, http-zig's (HTTP/2 over TLS, HTTP/1.1 where a server has no h2), each
//! request on a thread of its own (`http_portable.zig`).
//!
//!     nanoui.http.fetch(gpa, .{ .url = "https://example.com/data.json" }, state, State.loaded);
//!
//!     fn loaded(s: *State, r: nanoui.http.Response) void {
//!         if (r.status == 200) s.parse(r.body);
//!         s.window.redraw();
//!     }
//!
//! Redirects are followed everywhere; `Response.url` says where they led and
//! `Response.headers` what the server said.
const std = @import("std");
const builtin = @import("builtin");
const apple = builtin.os.tag == .macos or builtin.os.tag == .ios;
const objc = if (apple) @import("objc.zig") else struct {};
const portable = @import("http_portable.zig");

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Request = struct {
    url: []const u8,
    method: []const u8 = "GET",
    headers: []const Header = &.{},
    body: []const u8 = "",
    /// Seconds without a byte before it gives up (on Linux, Windows and
    /// Android, for the whole answer).
    timeout: f64 = 30,
};

pub const Response = struct {
    /// The HTTP status: 0 when no answer came (`err` says why).
    status: u16,
    /// Valid until the callback returns: copy what is kept.
    body: []const u8,
    /// Why there was no answer (offline, a bad certificate, a timeout).
    err: []const u8 = "",
    /// The answer's headers, their names in lower case; as the body, valid
    /// until the callback returns. On Apple's systems repeated headers come
    /// folded into one, and cookies are the system's to keep.
    headers: []const Header = &.{},
    /// Where the answer came from: the URL asked for, or where its redirects
    /// led, which is what a page's relative links resolve against.
    url: []const u8 = "",

    /// The value of the first header called `name`, in any case.
    pub fn header(r: Response, name: []const u8) ?[]const u8 {
        for (r.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }
};

/// A `data:` URL's bytes, owned by `gpa`.
pub const decodeData = portable.decodeData;

/// Where a link leads from the URL it is on (`http_url.zig`).
pub const resolve = @import("http_url.zig").resolve;

/// An answer owned by `gpa`, returned synchronously by `send` (safe to call
/// from worker threads and headless processes without bouncing to the main queue).
pub const OwnedResponse = struct {
    gpa: std.mem.Allocator,
    answer: Answer = .{},

    pub fn status(r: *const OwnedResponse) u16 {
        return r.answer.status;
    }

    pub fn body(r: *const OwnedResponse) []const u8 {
        return r.answer.body;
    }

    pub fn err(r: *const OwnedResponse) []const u8 {
        return r.answer.err;
    }

    pub fn headers(r: *const OwnedResponse) []const Header {
        return r.answer.headers.items;
    }

    pub fn url(r: *const OwnedResponse) []const u8 {
        return r.answer.url;
    }

    pub fn header(r: *const OwnedResponse, name: []const u8) ?[]const u8 {
        for (r.answer.headers.items) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }

    pub fn deinit(r: *OwnedResponse) void {
        r.gpa.free(r.answer.body);
        r.answer.freeHead(r.gpa);
        if (r.answer.err_owned) r.gpa.free(r.answer.err);
        r.* = .{ .gpa = r.gpa };
    }
};

fn makeAppleRequest(req: Request) ?objc.Object {
    const url = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(req.url)}) orelse return null;
    const r = objc.msg(objc.Object, objc.class("NSMutableURLRequest"), "requestWithURL:", .{url});
    objc.msg(void, r, "setHTTPMethod:", .{objc.nsString(req.method)});
    objc.msg(void, r, "setTimeoutInterval:", .{req.timeout});
    for (req.headers) |h| objc.msg(void, r, "setValue:forHTTPHeaderField:", .{ objc.nsString(h.value), objc.nsString(h.name) });
    if (req.body.len > 0) {
        const data = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ req.body.ptr, @as(objc.NSUInteger, req.body.len) });
        objc.msg(void, r, "setHTTPBody:", .{data});
    }
    return r;
}

fn fillAppleAnswer(gpa: std.mem.Allocator, p: *Answer, data: ?objc.Object, response: ?objc.Object, err: ?objc.Object) void {
    if (response) |res| {
        if (objc.msg(objc.BOOL, res, "isKindOfClass:", .{objc.class("NSHTTPURLResponse")}) != objc.NO) {
            p.status = @intCast(std.math.clamp(objc.msg(objc.NSInteger, res, "statusCode", .{}), 0, 999));
            const fields = objc.msg(objc.Object, res, "allHeaderFields", .{});
            const names = objc.msg(objc.Object, fields, "allKeys", .{});
            for (0..objc.msg(objc.NSUInteger, names, "count", .{})) |i| {
                const name = objc.msg(objc.Object, names, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
                const value = objc.msg(?objc.Object, fields, "objectForKey:", .{name});
                p.addHeader(gpa, objc.fromNSString(name), objc.fromNSString(value)) catch break;
            }
        } else p.status = 200; // A `data:` address has no HTTP in it, as on the portable path.
        if (objc.msg(?objc.Object, res, "URL", .{})) |u|
            p.url = gpa.dupe(u8, objc.fromNSString(objc.msg(?objc.Object, u, "absoluteString", .{}))) catch "";
    }
    if (data) |d| {
        const len = objc.msg(objc.NSUInteger, d, "length", .{});
        if (len > 0) if (gpa.alloc(u8, len)) |body| {
            const bytes = objc.msg(?[*]const u8, d, "bytes", .{});
            if (bytes) |b| @memcpy(body, b[0..len]);
            p.body = body;
        } else |_| {
            p.err = "out of memory";
        };
    }
    if (err) |e| {
        const why = objc.fromNSString(objc.msg(?objc.Object, e, "localizedDescription", .{}));
        if (gpa.dupe(u8, why)) |copy| {
            p.err = copy;
            p.err_owned = true;
        } else |_| p.err = "failed";
        p.status = 0;
    }
}

/// Sends `req` synchronously on the calling thread and returns an `OwnedResponse`
/// whose buffers belong to `gpa` (call `deinit()` when done). Uses `NSURLSession`
/// on macOS and iOS so iOS sandbox TLS trust stores, proxies, and HTTP/2 work on
/// background worker threads without requiring `/etc/ssl/cert.pem` or the main queue.
pub fn send(gpa: std.mem.Allocator, req: Request) OwnedResponse {
    var out: OwnedResponse = .{ .gpa = gpa };
    if (!apple) {
        portable.sendSync(gpa, req, &out.answer);
        return out;
    }
    const Wait = struct {
        gpa: std.mem.Allocator,
        answer: *Answer,
        sem: objc.dispatch_semaphore_t,
        fn done(w: *@This(), data: ?objc.Object, response: ?objc.Object, err_obj: ?objc.Object) void {
            const pool = objc.Pool.push();
            defer pool.pop();
            fillAppleAnswer(w.gpa, w.answer, data, response, err_obj);
            _ = objc.dispatch_semaphore_signal(w.sem);
        }
    };
    const pool = objc.Pool.push();
    defer pool.pop();
    const r = makeAppleRequest(req) orelse {
        out.answer.err = "not a URL";
        return out;
    };
    const sem = objc.dispatch_semaphore_create(0);
    defer objc.dispatch_release(@ptrCast(sem));
    var wait_ctx: Wait = .{ .gpa = gpa, .answer = &out.answer, .sem = sem };
    const session = objc.msg(objc.Object, objc.class("NSURLSession"), "sharedSession", .{});
    var block = objc.Block(Wait, &.{ ?objc.Object, ?objc.Object, ?objc.Object }).init(&wait_ctx, Wait.done);
    const task = objc.msg(objc.Object, session, "dataTaskWithRequest:completionHandler:", .{ r, @as(*anyopaque, @ptrCast(&block)) });
    objc.msg(void, task, "resume", .{});
    _ = objc.dispatch_semaphore_wait(sem, objc.DISPATCH_TIME_FOREVER);
    return out;
}

/// Sends `req` and calls `done(ctx, response)` on the main thread when it
/// is answered or fails. `req`'s bytes are copied: they need not outlive
/// the call.
pub fn fetch(gpa: std.mem.Allocator, req: Request, ctx: anytype, comptime done: fn (@TypeOf(ctx), Response) void) void {
    const P = Pending(@TypeOf(ctx), done);
    const p = gpa.create(P) catch return done(ctx, .{ .status = 0, .body = "", .err = "out of memory" });
    p.* = .{ .gpa = gpa, .ctx = ctx };
    if (!apple) return portable.fetch(gpa, req, &p.answer, p, P.deliverC) catch {
        p.answer.err = "out of memory";
        P.deliver(p);
    };
    const pool = objc.Pool.push();
    defer pool.pop();
    const r = makeAppleRequest(req) orelse {
        p.answer.err = "not a URL";
        return P.deliver(p);
    };
    const session = objc.msg(objc.Object, objc.class("NSURLSession"), "sharedSession", .{});
    // The session copies the block (and with it `p`), and calls it on a
    // queue of its own.
    var block = objc.Block(P, &.{ ?objc.Object, ?objc.Object, ?objc.Object }).init(p, P.answered);
    const task = objc.msg(objc.Object, session, "dataTaskWithRequest:completionHandler:", .{ r, @as(*anyopaque, @ptrCast(&block)) });
    objc.msg(void, task, "resume", .{});
}

/// What came back, filled before it is taken to the main thread: the
/// body and an error's words owned (`err_owned`) by the allocator.
pub const Answer = struct {
    status: u16 = 0,
    body: []u8 = &.{},
    err: []const u8 = "",
    err_owned: bool = false,
    /// Names in lower case, and every string, owned by the allocator.
    headers: std.ArrayList(Header) = .empty,
    url: []const u8 = "",

    pub fn addHeader(a: *Answer, gpa: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        const n = try std.ascii.allocLowerString(gpa, name);
        errdefer gpa.free(n);
        const v = try gpa.dupe(u8, value);
        errdefer gpa.free(v);
        try a.headers.append(gpa, .{ .name = n, .value = v });
    }

    pub fn freeHead(a: *Answer, gpa: std.mem.Allocator) void {
        for (a.headers.items) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        a.headers.deinit(gpa);
        a.headers = .empty;
        gpa.free(a.url);
        a.url = "";
    }
};

fn Pending(comptime Ctx: type, comptime done: fn (Ctx, Response) void) type {
    return struct {
        gpa: std.mem.Allocator,
        ctx: Ctx,
        answer: Answer = .{},

        const Self = @This();

        /// On the session's queue: the answer copied, then taken to the main thread.
        fn answered(s: *Self, data: ?objc.Object, response: ?objc.Object, err: ?objc.Object) void {
            const pool = objc.Pool.push();
            defer pool.pop();
            fillAppleAnswer(s.gpa, &s.answer, data, response, err);
            objc.dispatchMain(s, deliverC);
        }

        fn deliverC(context: ?*anyopaque) callconv(.c) void {
            deliver(@ptrCast(@alignCast(context.?)));
        }

        fn deliver(s: *Self) void {
            const p = &s.answer;
            done(s.ctx, .{ .status = p.status, .body = p.body, .err = p.err, .headers = p.headers.items, .url = p.url });
            s.gpa.free(p.body);
            p.freeHead(s.gpa);
            if (p.err_owned) s.gpa.free(p.err);
            s.gpa.destroy(s);
        }
    };
}

test {
    _ = portable;
    _ = @import("http_url.zig");
}

test "a request is answered on the main thread, its body copied" {
    const State = struct {
        body: [16]u8 = undefined,
        len: usize = 0,
        answered: bool = false,
        on_main: bool = false,
        fn done(s: *@This(), r: Response) void {
            s.answered = true;
            s.on_main = if (apple) objc.isMainThread() else true;
            s.len = @min(r.body.len, s.body.len);
            @memcpy(s.body[0..s.len], r.body[0..s.len]);
        }
    };
    var s: State = .{};
    // A data URL: answered by the system's client without the network.
    fetch(std.testing.allocator, .{ .url = "data:text/plain,hello%20zig" }, &s, State.done);
    var waited: f64 = 0;
    while (!s.answered and waited < 5) : (waited += 0.01) @import("platform.zig").runFor(0.01);
    try std.testing.expect(s.answered);
    try std.testing.expect(s.on_main);
    try std.testing.expectEqualStrings("hello zig", s.body[0..s.len]);
}

test "an answer says where it came from" {
    const State = struct {
        answered: bool = false,
        url_ok: bool = false,
        fn done(s: *@This(), r: Response) void {
            s.answered = true;
            s.url_ok = r.status == 200 and std.mem.startsWith(u8, r.url, "data:text/plain");
        }
    };
    var s: State = .{};
    fetch(std.testing.allocator, .{ .url = "data:text/plain,x" }, &s, State.done);
    var waited: f64 = 0;
    while (!s.answered and waited < 5) : (waited += 0.01) @import("platform.zig").runFor(0.01);
    try std.testing.expect(s.answered and s.url_ok);
}

test "headers are found in any case" {
    const r: Response = .{ .status = 200, .body = "", .headers = &.{.{ .name = "content-type", .value = "text/html" }} };
    try std.testing.expectEqualStrings("text/html", r.header("Content-Type").?);
    try std.testing.expect(r.header("location") == null);
}

test "send answers synchronously on the calling thread and on a worker thread" {
    var r = send(std.testing.allocator, .{ .url = "data:text/plain,sync%20main" });
    defer r.deinit();
    try std.testing.expectEqual(@as(u16, 200), r.status());
    try std.testing.expectEqualStrings("sync main", r.body());
    try std.testing.expect(std.mem.startsWith(u8, r.url(), "data:text/plain"));

    const Worker = struct {
        ok: bool = false,
        fn run(w: *@This(), gpa: std.mem.Allocator) void {
            var res = send(gpa, .{ .url = "data:text/plain;base64,d29ya2VyIG9r" });
            defer res.deinit();
            w.ok = res.status() == 200 and std.mem.eql(u8, res.body(), "worker ok");
        }
    };
    var w: Worker = .{};
    const t = try std.Thread.spawn(.{}, Worker.run, .{ &w, std.testing.allocator });
    t.join();
    try std.testing.expect(w.ok);
}
