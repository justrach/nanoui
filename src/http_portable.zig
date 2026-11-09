//! HTTP where nanoui uses no system client (Linux, Windows, Android): each request
//! on a thread of its own through http-zig (HTTP/2 over TLS with ALPN,
//! HTTP/1.1 where a server has no h2; plain `http://` by std's client),
//! raced against its timeout, its answer then taken to the main thread.
//! `data:` URLs are answered without the network.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const http = @import("http.zig");
const resolveUrl = @import("http_url.zig").resolve;

/// A URL split for a request: "https://host:8443/path?q" → https, host,
/// 8443, "/path?q".
pub const Url = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,
    path: []const u8,
};

pub fn parseUrl(url: []const u8) !Url {
    const sep = std.mem.indexOf(u8, url, "://") orelse return error.NotAUrl;
    const scheme = url[0..sep];
    const secure = std.ascii.eqlIgnoreCase(scheme, "https");
    if (!secure and !std.ascii.eqlIgnoreCase(scheme, "http")) return error.UnsupportedScheme;
    const rest = url[sep + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..end];
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return error.NotAUrl;
    var host = authority;
    var port: u16 = if (secure) 443 else 80;
    // "[::1]:8080", "host:8080".
    const close = if (authority[0] == '[') std.mem.indexOfScalar(u8, authority, ']') else null;
    const colon_from = if (close) |c| c else 0;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| if (colon > colon_from) {
        host = authority[0..colon];
        port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return error.NotAUrl;
    };
    if (close != null) host = host[1 .. host.len - 1];
    var path = rest[end..];
    if (std.mem.indexOfScalar(u8, path, '#')) |h| path = path[0..h];
    return .{ .scheme = if (secure) "https" else "http", .host = host, .port = port, .path = path };
}

/// The path to ask for: "/" for none, "/?q" for a bare query.
fn target(u: Url, buf: []u8) []const u8 {
    if (u.path.len == 0) return "/";
    if (u.path[0] == '?') return std.fmt.bufPrint(buf, "/{s}", .{u.path}) catch "/";
    return u.path;
}

/// A `data:` URL's bytes: percent-escaped, or base64 after ";base64".
pub fn decodeData(gpa: std.mem.Allocator, url: []const u8) ![]u8 {
    if (!std.ascii.startsWithIgnoreCase(url, "data:")) return error.NotAUrl;
    const comma = std.mem.indexOfScalar(u8, url, ',') orelse return error.NotAUrl;
    const meta = url[5..comma];
    const raw = url[comma + 1 ..];
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        // A `%` that isn't an escape is itself, as URLs have it: pages write
        // `width='100%'` straight into their addresses.
        const byte = if (raw[i] == '%' and i + 2 < raw.len) std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch null else null;
        if (byte) |b| {
            try text.append(gpa, b);
            i += 2;
        } else try text.append(gpa, raw[i]);
    }
    if (!std.mem.endsWith(u8, meta, ";base64")) return text.toOwnedSlice(gpa);
    defer text.deinit(gpa);
    const d = std.base64.standard.Decoder;
    const out = try gpa.alloc(u8, d.calcSizeForSlice(text.items) catch return error.NotAUrl);
    errdefer gpa.free(out);
    d.decode(out, text.items) catch return error.NotAUrl;
    return out;
}

/// The request, copied for its thread, and where its answer goes.
const Job = struct {
    gpa: std.mem.Allocator,
    url: []u8,
    method: []u8,
    names: [][]u8,
    values: [][]u8,
    body: []u8,
    timeout_ms: u64,
    answer: *http.Answer,
    ctx: *anyopaque,
    deliver: *const fn (?*anyopaque) callconv(.c) void,

    fn deinit(j: *Job) void {
        const gpa = j.gpa;
        for (j.names, j.values) |n, v| {
            gpa.free(n);
            gpa.free(v);
        }
        gpa.free(j.names);
        gpa.free(j.values);
        gpa.free(j.url);
        gpa.free(j.method);
        gpa.free(j.body);
        gpa.destroy(j);
    }
};

/// Starts `req` on a thread of its own; `deliver(ctx)` runs on the main
/// thread once `answer` is filled. Called on the main thread. An error
/// here (out of memory) means nothing was started.
pub fn fetch(gpa: std.mem.Allocator, req: http.Request, answer: *http.Answer, ctx: *anyopaque, deliver: *const fn (?*anyopaque) callconv(.c) void) !void {
    if (std.ascii.startsWithIgnoreCase(req.url, "data:")) {
        // No network: answered now, still by way of the main thread's queue.
        if (decodeData(gpa, req.url)) |bytes| {
            answer.status = 200;
            answer.body = bytes;
            answer.url = gpa.dupe(u8, req.url) catch "";
        } else |_| answer.err = "not a URL";
        return post(ctx, deliver);
    }
    const job = try gpa.create(Job);
    errdefer gpa.destroy(job);
    job.* = .{
        .gpa = gpa,
        .url = try gpa.dupe(u8, req.url),
        .method = undefined,
        .names = &.{},
        .values = &.{},
        .body = &.{},
        .timeout_ms = @intFromFloat(@max(1, req.timeout) * 1000),
        .answer = answer,
        .ctx = ctx,
        .deliver = deliver,
    };
    errdefer gpa.free(job.url);
    job.method = try gpa.dupe(u8, req.method);
    errdefer gpa.free(job.method);
    job.body = try gpa.dupe(u8, req.body);
    errdefer gpa.free(job.body);
    job.names = try gpa.alloc([]u8, req.headers.len);
    job.values = try gpa.alloc([]u8, req.headers.len);
    var copied: usize = 0;
    errdefer for (job.names[0..copied], job.values[0..copied]) |n, v| {
        gpa.free(n);
        gpa.free(v);
    };
    for (req.headers, 0..) |h, k| {
        // HTTP/2 wants header names in lower case.
        job.names[k] = try std.ascii.allocLowerString(gpa, h.name);
        job.values[k] = gpa.dupe(u8, h.value) catch |e| {
            gpa.free(job.names[k]);
            return e;
        };
        copied += 1;
    }
    if (!canPost()) {
        job.deinit();
        answer.err = "nanoui.http: no main loop to answer on";
        return post(ctx, deliver);
    }
    const t = std.Thread.spawn(.{}, work, .{job}) catch {
        job.deinit();
        answer.err = "nanoui.http: no thread for the request";
        return post(ctx, deliver);
    };
    t.detach();
}

/// The main thread's queue is there (GLib loaded; Windows' message window).
fn canPost() bool {
    return switch (builtin.os.tag) {
        .linux => if (builtin.abi.isAndroid()) @import("android/activity.zig").looper != null else @import("linux/gtk.zig").load(),
        .windows => if (@import("windows/fdwatch.zig").prepare()) true else |_| false,
        else => false,
    };
}

/// `deliver(ctx)` on the main thread soon; at once where there is no queue
/// (tests on a platform without one), which is the main thread then.
fn post(ctx: *anyopaque, deliver: *const fn (?*anyopaque) callconv(.c) void) void {
    switch (builtin.os.tag) {
        .linux => if (builtin.abi.isAndroid()) {
            if (@import("android/activity.zig").looper != null) {
                _ = @import("android/calls.zig").after(0, ctx, deliver);
                return;
            }
        } else if (@import("linux/gtk.zig").load()) return @import("linux/app.zig").App.after(0, ctx, deliver),
        .windows => if (@import("windows/fdwatch.zig").post(ctx, deliver)) return,
        else => {},
    }
    deliver(ctx);
}

fn work(job: *Job) void {
    const gpa = job.gpa;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    // Android's resolver is its C library's (Zig's own asks /etc/resolv.conf's servers).
    const io = if (builtin.abi.isAndroid()) @import("android/lookup.zig").io(&threaded) else threaded.io();
    race(io, job);
    const ctx = job.ctx;
    const deliver = job.deliver;
    job.deinit();
    post(ctx, deliver);
}

const Done = union(enum) { answered: anyerror!void, late: void };

/// The request against its timeout: whichever ends first.
fn race(io: Io, job: *Job) void {
    var buf: [2]Done = undefined;
    var sel: Io.Select(Done) = .init(io, &buf);
    sel.concurrent(.answered, send, .{ io, job }) catch {
        // No thread for the race: the request alone, unbounded.
        send(io, job) catch |e| fail(job, e);
        return;
    };
    sel.concurrent(.late, wait, .{ io, job.timeout_ms }) catch {};
    const first = sel.await() catch |e| {
        sel.cancelDiscard();
        return fail(job, e);
    };
    sel.cancelDiscard();
    switch (first) {
        .late => {
            freeAnswer(job);
            job.answer.err = "timed out";
        },
        .answered => |r| r catch |e| fail(job, e),
    }
}

fn wait(io: Io, ms: u64) void {
    io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

fn freeAnswer(job: *Job) void {
    job.gpa.free(job.answer.body);
    job.answer.body = &.{};
    job.answer.status = 0;
    job.answer.freeHead(job.gpa);
}

fn fail(job: *Job, e: anyerror) void {
    freeAnswer(job);
    if (job.answer.err.len == 0) job.answer.err = @errorName(e);
}

/// Redirects followed before giving up, as Chrome and Firefox do.
const max_redirects = 20;

/// The request and its redirects. A 303, and a 301 or 302 after a POST, goes
/// on as a GET without its body, as browsers do; what proves who is asking
/// doesn't go on to another host.
fn send(io: Io, job: *Job) anyerror!void {
    const gpa = job.gpa;
    var url = try gpa.dupe(u8, job.url);
    defer gpa.free(url);
    var method: []const u8 = job.method;
    var body: []const u8 = job.body;
    var private = true;
    var hops: usize = 0;
    while (true) : (hops += 1) {
        const u = try parseUrl(url);
        const hop: Hop = .{ .url = url, .u = u, .method = method, .body = body, .private = private };
        if (std.mem.eql(u8, u.scheme, "http")) try sendPlain(io, job, hop) else try sendTls(io, job, hop);
        const location = redirectTo(job.answer.*) orelse break;
        if (hops == max_redirects) return error.TooManyRedirects;
        const next = try resolveUrl(gpa, url, location);
        errdefer gpa.free(next);
        const n = try parseUrl(next);
        private = private and std.ascii.eqlIgnoreCase(n.host, u.host) and n.port == u.port;
        const status = job.answer.status;
        if (status == 303 or ((status == 301 or status == 302) and std.mem.eql(u8, method, "POST"))) {
            if (!std.mem.eql(u8, method, "HEAD")) method = "GET";
            body = "";
        }
        gpa.free(url);
        url = next;
        freeAnswer(job);
    }
    job.answer.url = try gpa.dupe(u8, url);
}

/// One request of a chain.
const Hop = struct { url: []const u8, u: Url, method: []const u8, body: []const u8, private: bool };

fn redirectTo(a: http.Answer) ?[]const u8 {
    if (a.status != 301 and a.status != 302 and a.status != 303 and a.status != 307 and a.status != 308) return null;
    for (a.headers.items) |h| if (std.mem.eql(u8, h.name, "location")) return h.value;
    return null;
}

/// Whether the request's header `i` goes on this hop.
fn sent(job: *const Job, i: usize, hop: Hop) bool {
    if (hop.private) return true;
    return !std.mem.eql(u8, job.names[i], "authorization") and !std.mem.eql(u8, job.names[i], "cookie");
}

/// Linux, Windows and Android: Apple's systems come here only in this file's tests.
const has_tls = builtin.os.tag != .macos and builtin.os.tag != .ios;

fn sendTls(io: Io, job: *Job, hop: Hop) anyerror!void {
    if (!has_tls) return error.UnsupportedScheme;
    const gpa = job.gpa;
    var path_buf: [2048]u8 = undefined;
    const path = target(hop.u, &path_buf);
    const h2 = @import("http_zig");
    var headers: std.ArrayList(h2.Header) = .empty;
    defer headers.deinit(gpa);
    for (job.names, job.values, 0..) |n, v, i| if (sent(job, i, hop)) try headers.append(gpa, .{ .name = n, .value = v });
    const authority = if (hop.u.port == 443) hop.u.host else try std.fmt.allocPrint(gpa, "{s}:{d}", .{ hop.u.host, hop.u.port });
    defer if (hop.u.port != 443) gpa.free(authority);
    const s = try h2.Session.open(gpa, io, hop.u.host, hop.u.port);
    defer s.close();
    var res = try s.request(.{ .method = hop.method, .scheme = "https", .authority = authority, .path = path, .extra = headers.items, .body = hop.body });
    defer res.deinit();
    for (res.headers) |h| if (h.name.len > 0 and h.name[0] != ':') try job.answer.addHeader(gpa, h.name, h.value);
    job.answer.body = try gpa.dupe(u8, res.body);
    job.answer.status = res.status;
}

fn sendPlain(io: Io, job: *Job, hop: Hop) anyerror!void {
    const gpa = job.gpa;
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var extra: std.ArrayList(std.http.Header) = .empty;
    defer extra.deinit(gpa);
    for (job.names, job.values, 0..) |n, v, i| if (sent(job, i, hop)) try extra.append(gpa, .{ .name = n, .value = v });
    const method = std.meta.stringToEnum(std.http.Method, hop.method) orelse return error.UnsupportedMethod;
    var req = try client.request(method, try std.Uri.parse(hop.url), .{ .redirect_behavior = .unhandled, .extra_headers = extra.items, .keep_alive = false });
    defer req.deinit();
    if (hop.body.len > 0) {
        req.transfer_encoding = .{ .content_length = hop.body.len };
        var w = try req.sendBodyUnflushed(&.{});
        try w.writer.writeAll(hop.body);
        try w.end();
        try req.connection.?.flush();
    } else try req.sendBodiless();
    var response = try req.receiveHead(&.{});
    // The head's bytes don't outlive reading the body.
    var it = response.head.iterateHeaders();
    while (it.next()) |h| try job.answer.addHeader(gpa, h.name, h.value);
    const status = response.head.status;
    const window: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try gpa.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try gpa.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer gpa.free(window);
    var transfer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer, &decompress, window);
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    _ = reader.streamRemaining(&aw.writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };
    job.answer.body = try aw.toOwnedSlice();
    job.answer.status = @intFromEnum(status);
}

test "URLs split for a request; data URLs read" {
    const u = try parseUrl("https://api.adsb.lol/v2/point/35.1/139.8/250");
    try std.testing.expectEqualStrings("api.adsb.lol", u.host);
    try std.testing.expectEqual(@as(u16, 443), u.port);
    try std.testing.expectEqualStrings("/v2/point/35.1/139.8/250", u.path);
    const p = try parseUrl("http://localhost:8080?x=1#top");
    try std.testing.expectEqualStrings("http", p.scheme);
    try std.testing.expectEqual(@as(u16, 8080), p.port);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/?x=1", target(p, &buf));
    try std.testing.expectEqualStrings("/", target(try parseUrl("https://example.com"), &buf));
    const v6 = try parseUrl("https://[::1]:8443/a");
    try std.testing.expectEqualStrings("::1", v6.host);
    try std.testing.expectEqual(@as(u16, 8443), v6.port);
    try std.testing.expectError(error.UnsupportedScheme, parseUrl("ftp://x/"));
    try std.testing.expectError(error.NotAUrl, parseUrl("https:///nohost"));

    const gpa = std.testing.allocator;
    const a = try decodeData(gpa, "data:text/plain,hello%20zig");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("hello zig", a);
    const stray = try decodeData(gpa, "data:text/plain,50%' %zz 100%");
    defer gpa.free(stray);
    try std.testing.expectEqualStrings("50%' %zz 100%", stray);
    const b = try decodeData(gpa, "data:text/plain;base64,aGVsbG8gemln");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("hello zig", b);
}

/// A server on a loopback port answering by path, one connection per request.
const TestServer = struct {
    server: Io.net.Server,
    io: Io,
    requests: usize,
    port: u16,

    fn run(s: *TestServer) void {
        for (0..s.requests) |_| {
            var stream = s.server.accept(s.io) catch return;
            defer stream.close(s.io);
            var in_buf: [2048]u8 = undefined;
            var reader = stream.reader(s.io, &in_buf);
            var at: usize = 0;
            var head: [2048]u8 = undefined;
            while (std.mem.indexOf(u8, head[0..at], "\r\n\r\n") == null and at < head.len) {
                const byte = reader.interface.takeByte() catch break;
                head[at] = byte;
                at += 1;
            }
            const req = head[0..at];
            var out_buf: [512]u8 = undefined;
            var writer = stream.writer(s.io, &out_buf);
            const w = &writer.interface;
            const method = req[0 .. std.mem.indexOfScalar(u8, req, ' ') orelse 0];
            const has_auth = std.mem.indexOf(u8, req, "authorization:") != null;
            if (std.mem.indexOf(u8, req, " /start ") != null) {
                w.print("HTTP/1.1 302 Found\r\nLocation: /a/../end\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{}) catch return;
            } else if (std.mem.indexOf(u8, req, " /post ") != null) {
                w.print("HTTP/1.1 303 See Other\r\nLocation: /end\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{}) catch return;
            } else if (std.mem.indexOf(u8, req, " /away ") != null) {
                w.print("HTTP/1.1 302 Found\r\nLocation: http://localhost:{d}/end\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{s.port}) catch return;
            } else if (std.mem.indexOf(u8, req, " /loop ") != null) {
                w.print("HTTP/1.1 302 Found\r\nLocation: /loop\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{}) catch return;
            } else {
                var body_buf: [32]u8 = undefined;
                const body = std.fmt.bufPrint(&body_buf, "{s} {s}", .{ method, if (has_auth) "auth" else "open" }) catch return;
                w.print("HTTP/1.1 200 OK\r\nX-Thing: Yes\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch return;
            }
            w.flush() catch return;
        }
    }
};

test "plain HTTP follows redirects and keeps the last answer's headers" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const any = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var ts: TestServer = .{ .server = try any.listen(io, .{ .reuse_address = true }), .io = io, .requests = 2 + 2 + 2 + 21, .port = 0 };
    ts.port = ts.server.socket.address.getPort();
    defer ts.server.deinit(io);
    const thread = try std.Thread.spawn(.{}, TestServer.run, .{&ts});
    defer thread.join();

    const Try = struct {
        fn go(i: Io, a: std.mem.Allocator, port: u16, path: []const u8, method: []const u8, body: []const u8, answer: *http.Answer) !void {
            var names = [_][]u8{try a.dupe(u8, "authorization")};
            defer a.free(names[0]);
            var values = [_][]u8{try a.dupe(u8, "secret")};
            defer a.free(values[0]);
            const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}{s}", .{ port, path });
            defer a.free(url);
            var job: Job = .{ .gpa = a, .url = url, .method = @constCast(method), .names = &names, .values = &values, .body = @constCast(body), .timeout_ms = 5000, .answer = answer, .ctx = undefined, .deliver = undefined };
            return send(i, &job);
        }
    };

    var a: http.Answer = .{};
    defer {
        gpa.free(a.body);
        a.freeHead(gpa);
    }
    try Try.go(io, gpa, ts.port, "/start", "GET", "", &a);
    try std.testing.expectEqual(@as(u16, 200), a.status);
    try std.testing.expectEqualStrings("GET auth", a.body);
    try std.testing.expect(std.mem.endsWith(u8, a.url, "/end"));
    var found = false;
    for (a.headers.items) |h| {
        if (std.mem.eql(u8, h.name, "x-thing")) found = std.mem.eql(u8, h.value, "Yes");
    }
    try std.testing.expect(found);

    var b: http.Answer = .{};
    defer {
        gpa.free(b.body);
        b.freeHead(gpa);
    }
    try Try.go(io, gpa, ts.port, "/post", "POST", "form", &b);
    try std.testing.expectEqualStrings("GET auth", b.body);

    // Another host: what proves who is asking stays behind.
    var c: http.Answer = .{};
    defer {
        gpa.free(c.body);
        c.freeHead(gpa);
    }
    try Try.go(io, gpa, ts.port, "/away", "GET", "", &c);
    try std.testing.expectEqualStrings("GET open", c.body);

    var d: http.Answer = .{};
    defer {
        gpa.free(d.body);
        d.freeHead(gpa);
    }
    try std.testing.expectError(error.TooManyRedirects, Try.go(io, gpa, ts.port, "/loop", "GET", "", &d));
}
