//! Scripts' requests: what `fetch` and XHR are built on (`$.request`), the headers
//! every request of a page carries, and what comes back of cookies. A request
//! holds the page (`p.pending`), so its answer always finds it allocated.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const js = @import("../js/js.zig");
const http = nanoui.http;
const bind = @import("bind.zig");
const cookies = @import("cookies.zig");
const conv = @import("../js/conv.zig");
const typed = @import("../js/b_typed.zig");
const page_mod = @import("../page.zig");
const world_mod = @import("world.zig");
const Page = page_mod.Page;
const Value = js.Value;
const Vm = js.Vm;
const Error = js.Error;
const World = bind.World;

const apple = builtin.os.tag == .macos or builtin.os.tag == .ios;

fn now() f64 {
    return conv.realtimeMs();
}

pub fn cookiesForScript(gpa: std.mem.Allocator, url: []const u8) ![]u8 {
    return cookies.header(gpa, url, true, now());
}

pub fn setCookieFromScript(url: []const u8, line: []const u8) void {
    cookies.store(url, line, true, now());
}

/// `Set-Cookie` lines of a response, where the system didn't keep them.
pub fn storeCookies(res: http.Response, url: []const u8) void {
    const at = if (res.url.len > 0) res.url else url;
    for (res.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "set-cookie")) cookies.store(at, h.value, false, now());
    }
}

/// The `Cookie` line for a request, in `a`; null when none or on Apple's systems.
pub fn cookieLine(a: std.mem.Allocator, url: []const u8) ?[]const u8 {
    if (apple) return null;
    const s = cookies.header(a, url, false, now()) catch return null;
    return if (s.len > 0) s else null;
}

/// What our user agent string claims, as Chromium says it to servers.
pub const client_hints = [_]http.Header{
    .{ .name = "sec-ch-ua", .value = "\"Chromium\";v=\"" ++ page_mod.chrome_major ++ "\", \"Not_A Brand\";v=\"99\"" },
    .{ .name = "sec-ch-ua-mobile", .value = "?0" },
    .{ .name = "sec-ch-ua-platform", .value = switch (@import("builtin").os.tag) {
        .macos => "\"macOS\"",
        .windows => "\"Windows\"",
        .ios => "\"iOS\"",
        else => "\"Linux\"",
    } },
};

/// What every request of the page's own carries.
pub fn defaultHeaders(w: *World, url: []const u8, buf: *[4]http.Header) []const http.Header {
    buf[0] = .{ .name = "User-Agent", .value = page_mod.user_agent };
    buf[1] = .{ .name = "Accept", .value = "*/*" };
    buf[2] = .{ .name = "Accept-Language", .value = "en-US,en;q=0.9" };
    if (cookieLine(w.page.arena(), url)) |c| {
        buf[3] = .{ .name = "Cookie", .value = c };
        return buf[0..4];
    }
    return buf[0..3];
}

/// What `Referer` says of a request from `from` to `to`: browsers' default
/// (`strict-origin-when-cross-origin`). Some servers refuse a stylesheet or a font
/// without one. Null when nothing is to be said.
pub fn referrer(a: std.mem.Allocator, from: []const u8, to: []const u8) std.mem.Allocator.Error!?[]const u8 {
    const http_page = std.ascii.startsWithIgnoreCase(from, "http://") or std.ascii.startsWithIgnoreCase(from, "https://");
    if (!http_page) return null;
    const to_web = std.ascii.startsWithIgnoreCase(to, "http://") or std.ascii.startsWithIgnoreCase(to, "https://");
    if (!to_web) return null;
    if (std.ascii.startsWithIgnoreCase(from, "https://") and !std.ascii.startsWithIgnoreCase(to, "https://")) return null;
    if (sameOrigin(from, to)) return from[0 .. std.mem.indexOfScalar(u8, from, '#') orelse from.len];
    return try std.fmt.allocPrint(a, "{s}/", .{originOf(from)});
}

/// The address a page's requests speak for: for one with no address of its own
/// (`about:srcdoc`), that of the page that made it.
pub fn addressOf(p: *const Page) []const u8 {
    var at = p;
    while (std.mem.startsWith(u8, at.url(), "about:")) at = (at.frame orelse break).owner;
    return at.url();
}

const Req = struct { page: *Page, callback: Value, url: []u8 };

/// `scheme://host:port` of a URL; "" for one with no origin (`data:`, `file:`).
pub fn originOf(url: []const u8) []const u8 {
    const i = std.mem.indexOf(u8, url, "://") orelse return "";
    if (std.ascii.startsWithIgnoreCase(url, "file:")) return "";
    const rest = url[i + 3..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    return url[0 .. i + 3 + end];
}

fn sameOrigin(a: []const u8, b: []const u8) bool {
    const x = originOf(a);
    return x.len > 0 and std.ascii.eqlIgnoreCase(x, originOf(b));
}

/// Whether this page may ask for this address at all: the web can't read files.
pub fn allowed(page_url: []const u8, url: []const u8) bool {
    if (std.ascii.startsWithIgnoreCase(url, "http:") or std.ascii.startsWithIgnoreCase(url, "https:") or std.ascii.startsWithIgnoreCase(url, "data:")) return true;
    return std.ascii.startsWithIgnoreCase(url, "file:") and std.ascii.startsWithIgnoreCase(page_url, "file:");
}

/// Whether a cross-origin answer may be read: what CORS asks of its headers. The
/// request itself has been sent, as no preflight is made.
fn readable(p: *Page, asked: []const u8, res: http.Response) bool {
    const from = if (res.url.len > 0) res.url else asked;
    if (std.ascii.startsWithIgnoreCase(from, "data:")) return true;
    if (sameOrigin(p.url(), from)) return true;
    const allow = res.header("access-control-allow-origin") orelse return false;
    const here = originOf(p.url());
    const trimmed = std.mem.trim(u8, allow, " \t");
    if (std.mem.eql(u8, trimmed, "*")) return true;
    return std.ascii.eqlIgnoreCase(trimmed, if (here.len > 0) here else "null");
}

/// A request the page may not make fails the way a refused one does, a task later.
fn refuse(w: *World, cb: Value) Error!Value {
    const vm = w.vm;
    const out = [_]Value{ Value.fromInt(0), try vm.newString(""), (try vm.newArray(&.{})).value(), (try typed.newTyped(vm, .Uint8, 0)).value(), try vm.newString("not allowed") };
    _ = try w.timers.add(w, cb, 0, &out, false);
    return Value.undefined;
}

fn hasHeader(list: []const http.Header, name: []const u8) bool {
    for (list) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return true;
    return false;
}

/// `$.request(method, url, [name, value, …], body, callback, withCredentials)`. Answers
/// `callback(status, url, [name, value, …], bytes, error)` as a task of its own.
fn request(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    const p = w.page;
    if (w.stopped or p.dead) return Value.undefined;
    var arena = std.heap.ArenaAllocator.init(w.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const method = try a.dupe(u8, try bind.str(vm, args, 0));
    const url = try a.dupe(u8, try bind.str(vm, args, 1));
    if (!allowed(p.url(), url)) return refuse(w, bind.arg(args, 4));
    const cross = !sameOrigin(p.url(), url);
    var headers: std.ArrayList(http.Header) = .empty;
    if (bind.arg(args, 2).isObject()) {
        const list = args[2].asObject();
        const len = try vm.toNumber(try list.get(vm, "length"));
        var i: u32 = 0;
        while (@as(f64, @floatFromInt(i)) + 1 < len) : (i += 2) {
            try headers.append(a, .{
                .name = try a.dupe(u8, try vm.toStringSlice(try list.getIdx(vm, i))),
                .value = try a.dupe(u8, try vm.toStringSlice(try list.getIdx(vm, i + 1))),
            });
        }
    }
    if (!hasHeader(headers.items, "User-Agent")) try headers.append(a, .{ .name = "User-Agent", .value = page_mod.user_agent });
    if (!hasHeader(headers.items, "Accept")) try headers.append(a, .{ .name = "Accept", .value = "*/*" });
    if (!hasHeader(headers.items, "Accept-Language")) try headers.append(a, .{ .name = "Accept-Language", .value = "en-US,en;q=0.9" });
    if (try referrer(a, addressOf(p), url)) |r| try headers.append(a, .{ .name = "Referer", .value = r });
    if (cross and !std.ascii.startsWithIgnoreCase(url, "data:")) {
        const here = originOf(p.url());
        try headers.append(a, .{ .name = "Origin", .value = if (here.len > 0) here else "null" });
    }
    // The system's client on Apple's platforms decides this for itself.
    const credentials = vm.toBoolean(bind.arg(args, 5));
    if (!cross or credentials) if (cookieLine(a, url)) |c| try headers.append(a, .{ .name = "Cookie", .value = c });
    const body = bind.arg(args, 3);
    var bytes: []const u8 = "";
    if (body.isString()) {
        bytes = try vm.toStringSlice(body);
    } else if (body.isObject()) {
        if (body.asObject().class == .typedarray) {
            const o = body.asObject();
            const raw = typed.bytesOf(o);
            bytes = raw[0..@min(raw.len, typed.length(o) * typed.elemSize(o.payload.typed.kind))];
        }
    }
    if (world_mod.log_to_stderr) std.debug.print("[net] {s} {s} ({s})\n", .{ method, url[0..@min(url.len, 110)], if (p.worker != null) "worker" else "page" });
    const cb = bind.arg(args, 4);
    try vm.protect(cb);
    const r = try p.gpa.create(Req);
    r.* = .{ .page = p, .callback = cb, .url = try p.gpa.dupe(u8, url) };
    p.pending += 1;
    w.net_pending += 1;
    http.fetch(p.gpa, .{ .url = url, .method = method, .headers = headers.items, .body = bytes, .timeout = 60 }, r, answered);
    return Value.undefined;
}

fn answered(r: *Req, res: http.Response) void {
    const p = r.page;
    const cb = r.callback;
    const asked = r.url;
    p.gpa.destroy(r);
    defer p.gpa.free(asked);
    p.pending -= 1;
    p.busy += 1;
    defer {
        p.busy -= 1;
        p.maybeFree();
    }
    const w = p.js orelse return;
    w.net_pending -|= 1;
    w.vm.unprotect(cb);
    if (p.dead or w.stopped) return;
    storeCookies(res, res.url);
    if (world_mod.log_to_stderr) std.debug.print("[net] {d} {s} {s}\n", .{ res.status, asked[0..@min(asked.len, 90)], res.err });
    if (res.status != 0 and !readable(p, asked, res)) {
        var buf: [320]u8 = undefined;
        w.logLine(2, std.fmt.bufPrint(&buf, "Blocked by CORS: {s}", .{asked[0..@min(asked.len, 280)]}) catch "Blocked by CORS");
        w.enter();
        defer {
            w.leave();
            p.finishLoadCheck();
        }
        const blocked = http.Response{ .status = 0, .body = "", .err = "blocked by CORS" };
        const out = answer(w.vm, blocked, cb) catch |e| {
            w.report(e);
            return;
        };
        _ = w.callReported(cb, Value.undefined, &out);
        return;
    }
    w.enter();
    defer {
        w.leave();
        p.finishLoadCheck();
    }
    const vm = w.vm;
    const out = answer(vm, res, cb) catch |e| {
        w.report(e);
        return;
    };
    _ = w.callReported(cb, Value.undefined, &out);
}

fn answer(vm: *Vm, res: http.Response, _: Value) Error![5]Value {
    const list = try vm.newArray(&.{});
    var i: u32 = 0;
    for (res.headers) |h| {
        try list.setIdx(vm, i, try vm.newString(h.name));
        try list.setIdx(vm, i + 1, try vm.newString(h.value));
        i += 2;
    }
    const bytes = try typed.newTyped(vm, .Uint8, res.body.len);
    @memcpy(typed.bytesOf(bytes)[0..res.body.len], res.body);
    return .{ Value.fromInt(res.status), try vm.newString(res.url), list.value(), bytes.value(), try vm.newString(res.err) };
}

/// A view's bytes as text. The engine's strings are UTF-8 inside; what isn't is replaced.
fn decode(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const v = bind.arg(args, 0);
    if (!v.isObject()) return vm.newString("");
    const bytes = viewBytes(v.asObject()) orelse return vm.newString("");
    const stripped = if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF") and !vm.toBoolean(bind.arg(args, 1))) bytes[3..] else bytes;
    if (std.unicode.utf8ValidateSlice(stripped)) return vm.newString(stripped);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.gpa);
    var i: usize = 0;
    while (i < stripped.len) {
        const n = std.unicode.utf8ByteSequenceLength(stripped[i]) catch {
            try out.appendSlice(vm.gpa, "\u{FFFD}");
            i += 1;
            continue;
        };
        if (i + n > stripped.len or !std.unicode.utf8ValidateSlice(stripped[i .. i + n])) {
            try out.appendSlice(vm.gpa, "\u{FFFD}");
            i += 1;
            continue;
        }
        try out.appendSlice(vm.gpa, stripped[i .. i + n]);
        i += n;
    }
    return vm.newString(out.items);
}

fn viewBytes(o: *js.Object) ?[]const u8 {
    switch (o.class) {
        .typedarray, .dataview => {
            const d = o.payload.typed;
            const n = if (o.class == .dataview) d.len else typed.length(o) * typed.elemSize(d.kind);
            const raw = typed.bytesOf(o);
            return raw[0..@min(raw.len, n)];
        },
        .arraybuffer => return o.payload.buffer.bytes,
        else => return null,
    }
}

fn encode(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const s = if (args.len > 0 and !args[0].isUndefined()) try vm.toStringSlice(args[0]) else "";
    const bytes = try typed.newTyped(vm, .Uint8, s.len);
    @memcpy(typed.bytesOf(bytes)[0..s.len], s);
    return bytes.value();
}

const b64 = std.base64.standard;

/// A string's code points as bytes: `btoa`'s input, or null past Latin-1.
fn latin1(gpa: std.mem.Allocator, s: []const u8) ?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp > 0xFF) {
            out.deinit(gpa);
            return null;
        }
        out.append(gpa, @intCast(cp)) catch return null;
    }
    return out.toOwnedSlice(gpa) catch null;
}

fn btoa(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const s = try bind.str(vm, args, 0);
    const bytes = latin1(vm.gpa, s) orelse return bind.throwDom(vm, "InvalidCharacterError", "The string to be encoded contains characters outside of the Latin1 range.");
    defer vm.gpa.free(bytes);
    const out = try vm.gpa.alloc(u8, b64.Encoder.calcSize(bytes.len));
    defer vm.gpa.free(out);
    return vm.newString(b64.Encoder.encode(out, bytes));
}

fn atob(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const raw = try bind.str(vm, args, 0);
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(vm.gpa);
    for (raw) |c| if (!std.ascii.isWhitespace(c) and c != '=') try clean.append(vm.gpa, c);
    const no_pad = std.base64.standard_no_pad;
    const bad = "The string to be decoded is not correctly encoded.";
    const n = no_pad.Decoder.calcSizeForSlice(clean.items) catch return bind.throwDom(vm, "InvalidCharacterError", bad);
    const bytes = try vm.gpa.alloc(u8, n);
    defer vm.gpa.free(bytes);
    no_pad.Decoder.decode(bytes, clean.items) catch return bind.throwDom(vm, "InvalidCharacterError", bad);
    // Each byte becomes a character: two UTF-8 bytes past ASCII.
    const text = try vm.gpa.alloc(u8, n * 2);
    defer vm.gpa.free(text);
    var at: usize = 0;
    for (bytes) |b| at += std.unicode.utf8Encode(b, text[at..]) catch 0;
    return vm.newString(text[0..at]);
}

pub const internals = [_]bind.Method{
    .{ .name = "request", .arity = 6, .f = request },
    .{ .name = "decode", .arity = 1, .f = decode },
    .{ .name = "encode", .arity = 1, .f = encode },
};

pub const globals = [_]bind.Method{
    .{ .name = "btoa", .arity = 1, .f = btoa },
    .{ .name = "atob", .arity = 1, .f = atob },
};

test "a request's Referer, by browsers' default policy" {
    const a = std.testing.allocator;
    const same = (try referrer(a, "https://a.test/x/y?q=1#top", "https://a.test/s.css")).?;
    try std.testing.expectEqualStrings("https://a.test/x/y?q=1", same);
    const other = (try referrer(a, "https://a.test/x/y?q=1", "https://cdn.test/f.woff2")).?;
    defer a.free(other);
    try std.testing.expectEqualStrings("https://a.test/", other);
    try std.testing.expect(try referrer(a, "https://a.test/", "http://b.test/") == null);
    try std.testing.expect(try referrer(a, "file:///x.html", "https://b.test/") == null);
    try std.testing.expect(try referrer(a, "https://a.test/", "data:,x") == null);
}
