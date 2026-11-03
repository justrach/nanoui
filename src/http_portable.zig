//! HTTP where nanoui uses no system client (Linux, Windows, Android): each request
//! on a thread of its own through http-zig (HTTP/2 over TLS with ALPN,
//! HTTP/1.1 where a server has no h2; plain `http://` by std's client),
//! raced against its timeout, its answer then taken to the main thread.
//! `data:` URLs are answered without the network.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const http = @import("http.zig");

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
        if (raw[i] == '%' and i + 2 < raw.len) {
            const byte = std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch return error.NotAUrl;
            try text.append(gpa, byte);
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
            if (@import("android/activity.zig").looper != null) return @import("android/calls.zig").after(0, ctx, deliver);
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
}

fn fail(job: *Job, e: anyerror) void {
    freeAnswer(job);
    if (job.answer.err.len == 0) job.answer.err = @errorName(e);
}

/// The request itself: http-zig over https, std's client over http.
fn send(io: Io, job: *Job) anyerror!void {
    const gpa = job.gpa;
    const u = try parseUrl(job.url);
    var path_buf: [2048]u8 = undefined;
    const path = target(u, &path_buf);
    if (std.mem.eql(u8, u.scheme, "http")) return sendPlain(io, job);
    const h2 = @import("http_zig");
    const headers = try gpa.alloc(h2.Header, job.names.len);
    defer gpa.free(headers);
    for (headers, job.names, job.values) |*h, n, v| h.* = .{ .name = n, .value = v };
    const authority = if (u.port == 443) u.host else try std.fmt.allocPrint(gpa, "{s}:{d}", .{ u.host, u.port });
    defer if (u.port != 443) gpa.free(authority);
    const s = try h2.Session.open(gpa, io, u.host, u.port);
    defer s.close();
    var res = try s.request(.{ .method = job.method, .scheme = "https", .authority = authority, .path = path, .extra = headers, .body = job.body });
    defer res.deinit();
    job.answer.body = try gpa.dupe(u8, res.body);
    job.answer.status = res.status;
}

fn sendPlain(io: Io, job: *Job) anyerror!void {
    const gpa = job.gpa;
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const extra = try gpa.alloc(std.http.Header, job.names.len);
    defer gpa.free(extra);
    for (extra, job.names, job.values) |*h, n, v| h.* = .{ .name = n, .value = v };
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const method = std.meta.stringToEnum(std.http.Method, job.method) orelse return error.UnsupportedMethod;
    const result = try client.fetch(.{
        .location = .{ .url = job.url },
        .method = method,
        .payload = if (job.body.len == 0) null else job.body,
        .extra_headers = extra,
        .response_writer = &aw.writer,
    });
    job.answer.body = try aw.toOwnedSlice();
    job.answer.status = @intFromEnum(result.status);
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
    const b = try decodeData(gpa, "data:text/plain;base64,aGVsbG8gemln");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("hello zig", b);
}
