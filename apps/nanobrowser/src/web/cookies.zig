//! The cookie jar: in memory, one for the process, honoring domain, path, expiry
//! and `Secure` simply. On Linux and Windows, `Set-Cookie` from any response comes
//! here and requests carry what matches. On Apple's systems the URL session keeps
//! its own cookies for requests; this jar only answers `document.cookie`.
const std = @import("std");

const Cookie = struct {
    name: []u8,
    value: []u8,
    domain: []u8,
    host_only: bool,
    path: []u8,
    secure: bool,
    http_only: bool,
    /// Milliseconds since the epoch; null for a session cookie.
    expires: ?f64,
};

const gpa = std.heap.smp_allocator;
var jar: std.ArrayList(Cookie) = .empty;

pub const Url = struct { scheme: []const u8, host: []const u8, path: []const u8 };

/// The parts of `url` a cookie cares about.
pub fn parts(url: []const u8) ?Url {
    const i = std.mem.indexOf(u8, url, "://") orelse return null;
    const rest = url[i + 3..];
    const slash = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    var host = rest[0..slash];
    if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..];
    if (std.mem.indexOfScalar(u8, host, ':')) |c| host = host[0..c];
    var path = rest[slash..];
    if (std.mem.indexOfAny(u8, path, "?#")) |q| path = path[0..q];
    if (path.len == 0) path = "/";
    return .{ .scheme = url[0..i], .host = host, .path = path };
}

fn defaultPath(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "/";
    return if (i == 0) "/" else path[0..i];
}

fn domainMatches(c: *const Cookie, host: []const u8) bool {
    if (c.host_only) return std.ascii.eqlIgnoreCase(c.domain, host);
    if (std.ascii.eqlIgnoreCase(c.domain, host)) return true;
    if (host.len <= c.domain.len) return false;
    const tail = host[host.len - c.domain.len..];
    return host[host.len - c.domain.len - 1] == '.' and std.ascii.eqlIgnoreCase(tail, c.domain);
}

fn pathMatches(c: *const Cookie, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, c.path)) return false;
    return path.len == c.path.len or c.path[c.path.len - 1] == '/' or path[c.path.len] == '/';
}

fn free(c: *const Cookie) void {
    gpa.free(c.name);
    gpa.free(c.value);
    gpa.free(c.domain);
    gpa.free(c.path);
}

/// Stores what a `Set-Cookie` line or `document.cookie = …` says.
pub fn store(url: []const u8, line: []const u8, from_script: bool, now_ms: f64) void {
    const u = parts(url) orelse return;
    var it = std.mem.splitScalar(u8, line, ';');
    const pair = it.next() orelse return;
    const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return;
    const name = std.mem.trim(u8, pair[0..eq], " \t");
    const value = std.mem.trim(u8, pair[eq + 1 ..], " \t");
    var domain: []const u8 = u.host;
    var host_only = true;
    var path: []const u8 = defaultPath(u.path);
    var secure = false;
    var http_only = false;
    var expires: ?f64 = null;
    while (it.next()) |raw| {
        const attr = std.mem.trim(u8, raw, " \t");
        const e = std.mem.indexOfScalar(u8, attr, '=');
        const key = if (e) |x| attr[0..x] else attr;
        const val = if (e) |x| std.mem.trim(u8, attr[x + 1 ..], " \t") else "";
        if (std.ascii.eqlIgnoreCase(key, "domain") and val.len > 0) {
            const d = if (val[0] == '.') val[1..] else val;
            // A cookie may only be for its own host or above it.
            const ok = std.ascii.eqlIgnoreCase(d, u.host) or (u.host.len > d.len and u.host[u.host.len - d.len - 1] == '.' and std.ascii.eqlIgnoreCase(u.host[u.host.len - d.len..], d));
            if (!ok) return;
            domain = d;
            host_only = false;
        } else if (std.ascii.eqlIgnoreCase(key, "path") and val.len > 0 and val[0] == '/') {
            path = val;
        } else if (std.ascii.eqlIgnoreCase(key, "secure")) {
            secure = true;
        } else if (std.ascii.eqlIgnoreCase(key, "httponly")) {
            http_only = true;
        } else if (std.ascii.eqlIgnoreCase(key, "max-age")) {
            const secs = std.fmt.parseFloat(f64, val) catch continue;
            expires = now_ms + secs * 1000;
        } else if (std.ascii.eqlIgnoreCase(key, "expires") and expires == null) {
            expires = parseDate(val);
        }
    }
    if (from_script and http_only) return;
    // The same cookie goes away first; an expired one stays away.
    var i: usize = 0;
    while (i < jar.items.len) {
        const c = &jar.items[i];
        if (std.mem.eql(u8, c.name, name) and std.ascii.eqlIgnoreCase(c.domain, domain) and std.mem.eql(u8, c.path, path)) {
            if (from_script and c.http_only) return;
            free(c);
            _ = jar.orderedRemove(i);
        } else i += 1;
    }
    if (expires) |x| if (x <= now_ms) return;
    const copy = Cookie{
        .name = gpa.dupe(u8, name) catch return,
        .value = gpa.dupe(u8, value) catch return,
        .domain = gpa.dupe(u8, domain) catch return,
        .host_only = host_only,
        .path = gpa.dupe(u8, path) catch return,
        .secure = secure,
        .http_only = http_only,
        .expires = expires,
    };
    jar.append(gpa, copy) catch {};
}

/// `Sun, 06 Nov 1994 08:49:37 GMT`, as milliseconds; an unreadable one is a
/// session cookie.
fn parseDate(s: []const u8) ?f64 {
    var it = std.mem.tokenizeAny(u8, s, " ,-:");
    var day: ?i64 = null;
    var month: ?i64 = null;
    var year: ?i64 = null;
    var clock: [3]i64 = .{ 0, 0, 0 };
    var clock_at: usize = 0;
    while (it.next()) |t| {
        if (std.fmt.parseInt(i64, t, 10)) |v| {
            if (day == null and t.len <= 2 and month == null) {
                day = v;
            } else if (year == null and month != null and day != null and clock_at == 0 and (t.len == 4 or t.len == 2)) {
                year = if (v < 70) v + 2000 else if (v < 100) v + 1900 else v;
            } else if (clock_at < 3) {
                clock[clock_at] = v;
                clock_at += 1;
            }
        } else |_| {
            const names = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
            for (names, 0..) |m, i| if (t.len >= 3 and std.ascii.eqlIgnoreCase(t[0..3], m)) {
                month = @intCast(i);
            };
        }
    }
    const y = year orelse return null;
    const mo = month orelse return null;
    const d = day orelse return null;
    // Days from civil, proleptic Gregorian.
    const yy = if (mo < 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp = @mod(mo + 10, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    const secs = days * 86400 + clock[0] * 3600 + clock[1] * 60 + clock[2];
    return @as(f64, @floatFromInt(secs)) * 1000;
}

fn expire(now_ms: f64) void {
    var i: usize = 0;
    while (i < jar.items.len) {
        const c = &jar.items[i];
        if (c.expires) |x| if (x <= now_ms) {
            free(c);
            _ = jar.orderedRemove(i);
            continue;
        };
        i += 1;
    }
}

/// `a=1; b=2` for `url`, in `out_gpa`. `for_script` leaves out `HttpOnly` ones.
pub fn header(out_gpa: std.mem.Allocator, url: []const u8, for_script: bool, now_ms: f64) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(out_gpa);
    const u = parts(url) orelse return out.toOwnedSlice(out_gpa);
    expire(now_ms);
    const https = std.ascii.eqlIgnoreCase(u.scheme, "https");
    for (jar.items) |*c| {
        if (!domainMatches(c, u.host) or !pathMatches(c, u.path)) continue;
        if (c.secure and !https) continue;
        if (for_script and c.http_only) continue;
        if (out.items.len > 0) try out.appendSlice(out_gpa, "; ");
        try out.appendSlice(out_gpa, c.name);
        try out.append(out_gpa, '=');
        try out.appendSlice(out_gpa, c.value);
    }
    return out.toOwnedSlice(out_gpa);
}

/// For tests: an empty jar.
pub fn clear() void {
    for (jar.items) |*c| free(c);
    jar.clearRetainingCapacity();
}

test "a cookie goes where its domain and path say, and expires" {
    clear();
    defer clear();
    const now = 1_000_000.0;
    store("http://a.example.com/x/y", "one=1", false, now);
    store("http://a.example.com/x/y", "two=2; Domain=example.com; Path=/", false, now);
    store("http://a.example.com/x/y", "bad=1; Domain=other.com", false, now);
    store("http://a.example.com/x/y", "gone=1; Max-Age=0", false, now);
    store("http://a.example.com/x/y", "secret=1; HttpOnly", false, now);
    const t = std.testing.allocator;
    const a = try header(t, "http://a.example.com/x/z", true, now);
    defer t.free(a);
    try std.testing.expectEqualStrings("one=1; two=2", a);
    const b = try header(t, "http://b.example.com/q", false, now);
    defer t.free(b);
    try std.testing.expectEqualStrings("two=2", b);
    const c = try header(t, "http://a.example.com/x/z", false, now);
    defer t.free(c);
    try std.testing.expectEqualStrings("one=1; two=2; secret=1", c);
    store("http://a.example.com/x/y", "one=; Expires=Thu, 01 Jan 1970 00:00:00 GMT", true, now);
    const d = try header(t, "http://a.example.com/x/z", true, now);
    defer t.free(d);
    try std.testing.expectEqualStrings("two=2", d);
    try std.testing.expectEqual(@as(?f64, 784111777000), parseDate("Sun, 06 Nov 1994 08:49:37 GMT"));
}
