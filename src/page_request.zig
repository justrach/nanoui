//! Platform-free request validation, origin scoping, and deferred/latest-wins
//! pending navigation queue for `PageOptions.defer_initial_load` and
//! `Window.loadPageRequest` / `Page.loadRequest`.
const std = @import("std");
const page = @import("page.zig");
const window_types = @import("window_types.zig");

pub const PageHeader = window_types.PageHeader;
pub const PageRequest = window_types.PageRequest;

pub const Error = error{
    InvalidUrl,
    InvalidHeaderName,
    InvalidHeaderValue,
    Unsupported,
    NoPage,
    PagesUnsupported,
    OutOfMemory,
};

pub const OwnedHeader = struct {
    name: []u8,
    value: []u8,
};

/// Heap-owned request copy safe across asynchronous backend initialization.
pub const OwnedRequest = struct {
    url: []u8,
    headers: []OwnedHeader,

    pub fn clone(gpa: std.mem.Allocator, req: PageRequest) Error!OwnedRequest {
        try validate(req);
        const url = try gpa.dupe(u8, req.url);
        errdefer gpa.free(url);
        const headers = try gpa.alloc(OwnedHeader, req.headers.len);
        var built: usize = 0;
        errdefer {
            for (headers[0..built]) |h| {
                gpa.free(h.name);
                gpa.free(h.value);
            }
            gpa.free(headers);
        }
        for (req.headers) |h| {
            const name = try gpa.dupe(u8, h.name);
            errdefer gpa.free(name);
            const value = try gpa.dupe(u8, h.value);
            headers[built] = .{ .name = name, .value = value };
            built += 1;
        }
        return .{ .url = url, .headers = headers };
    }

    pub fn deinit(self: *OwnedRequest, gpa: std.mem.Allocator) void {
        gpa.free(self.url);
        for (self.headers) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        gpa.free(self.headers);
        self.* = undefined;
    }

    pub fn sliceHeaders(self: *const OwnedRequest, scratch: []PageHeader) []const PageHeader {
        const n = @min(self.headers.len, scratch.len);
        for (0..n) |i| scratch[i] = .{ .name = self.headers[i].name, .value = self.headers[i].value };
        return scratch[0..n];
    }

    pub fn asRequest(self: *const OwnedRequest, gpa: std.mem.Allocator) Error![]PageHeader {
        const out = try gpa.alloc(PageHeader, self.headers.len);
        for (self.headers, 0..) |h, i| out[i] = .{ .name = h.name, .value = h.value };
        return out;
    }

    /// Formats `Name: Value\r\n` pairs (owned by caller) for WebView2.
    pub fn formatCrlfHeaders(self: *const OwnedRequest, gpa: std.mem.Allocator) ![]u8 {
        var total: usize = 0;
        for (self.headers) |h| total += h.name.len + 2 + h.value.len + 2;
        const out = try gpa.alloc(u8, total);
        var pos: usize = 0;
        for (self.headers) |h| {
            @memcpy(out[pos .. pos + h.name.len], h.name);
            pos += h.name.len;
            @memcpy(out[pos .. pos + 2], ": ");
            pos += 2;
            @memcpy(out[pos .. pos + h.value.len], h.value);
            pos += h.value.len;
            @memcpy(out[pos .. pos + 2], "\r\n");
            pos += 2;
        }
        return out;
    }
};

fn isTchar(b: u8) bool {
    if ((b >= '0' and b <= '9') or (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z')) return true;
    return switch (b) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

/// Validates URL scheme/characters and RFC 9110 header names/values.
pub fn validate(req: PageRequest) Error!void {
    if (req.url.len == 0 or req.url.len > 2048) return error.InvalidUrl;
    for (req.url) |b| if (b < 0x20 or b == 0x7f) return error.InvalidUrl;
    if (std.mem.indexOf(u8, req.url, "://")) |sep| {
        const scheme = req.url[0..sep];
        const ok = std.ascii.eqlIgnoreCase(scheme, "http") or
            std.ascii.eqlIgnoreCase(scheme, "https") or
            std.ascii.eqlIgnoreCase(scheme, "nanoui");
        if (!ok or sep + 3 >= req.url.len) return error.InvalidUrl;
    } else if (req.url[0] != '/') {
        // Reject scheme: payloads like javascript:, data:, file: without "://".
        const end = std.mem.indexOfAny(u8, req.url, "/?#") orelse req.url.len;
        if (std.mem.indexOfScalar(u8, req.url[0..end], ':') != null) return error.InvalidUrl;
    }

    for (req.headers) |h| {
        if (h.name.len == 0) return error.InvalidHeaderName;
        for (h.name) |b| if (!isTchar(b)) return error.InvalidHeaderName;
        for (h.value) |b| {
            if ((b < 0x20 and b != '\t') or b == 0x7f) return error.InvalidHeaderValue;
        }
    }
}

/// Resolves relative paths onto `page.origin`, leaving `http://`, `https://`,
/// and `nanoui://` (case-insensitive) absolute URLs intact.
pub fn resolveUrl(buf: []u8, url: []const u8) []const u8 {
    if (url.len >= 9 and std.ascii.eqlIgnoreCase(url[0..9], "nanoui://")) return url;
    if (url.len >= 7 and std.ascii.eqlIgnoreCase(url[0..7], "http://")) return url;
    if (url.len >= 8 and std.ascii.eqlIgnoreCase(url[0..8], "https://")) return url;
    return page.fullUrl(buf, url);
}

const Origin = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,
};

fn parseOrigin(buf: *[2048]u8, raw: []const u8) ?Origin {
    const url = resolveUrl(buf, raw);
    const sep = std.mem.indexOf(u8, url, "://") orelse return null;
    const scheme = url[0..sep];
    const after = url[sep + 3 ..];
    const auth_end = std.mem.indexOfAny(u8, after, "/?#") orelse after.len;
    const auth = after[0..auth_end];
    if (auth.len == 0) return null;
    const hostport = if (std.mem.lastIndexOfScalar(u8, auth, '@')) |at| auth[at + 1 ..] else auth;
    if (hostport.len == 0) return null;

    var host: []const u8 = hostport;
    var port: ?u16 = null;
    if (hostport[0] == '[') {
        const close = std.mem.indexOfScalar(u8, hostport, ']') orelse return null;
        host = hostport[0 .. close + 1];
        if (close + 1 < hostport.len) {
            if (hostport[close + 1] != ':') return null;
            port = std.fmt.parseInt(u16, hostport[close + 2 ..], 10) catch return null;
        }
    } else if (std.mem.indexOfScalar(u8, hostport, ':')) |colon| {
        host = hostport[0..colon];
        port = std.fmt.parseInt(u16, hostport[colon + 1 ..], 10) catch return null;
    }
    if (host.len == 0) return null;
    const default_port: u16 = if (std.ascii.eqlIgnoreCase(scheme, "http")) 80 else if (std.ascii.eqlIgnoreCase(scheme, "https")) 443 else 0;
    return .{ .scheme = scheme, .host = host, .port = port orelse default_port };
}

/// True when `a` and `b` share scheme, case-insensitive host, and effective port.
pub fn sameOrigin(a: []const u8, b: []const u8) bool {
    var buf_a: [2048]u8 = undefined;
    var buf_b: [2048]u8 = undefined;
    const oa = parseOrigin(&buf_a, a) orelse return false;
    const ob = parseOrigin(&buf_b, b) orelse return false;
    return oa.port == ob.port and
        std.ascii.eqlIgnoreCase(oa.scheme, ob.scheme) and
        std.ascii.eqlIgnoreCase(oa.host, ob.host);
}

pub fn isSensitiveHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "authorization") or
        std.ascii.eqlIgnoreCase(name, "proxy-authorization") or
        std.ascii.eqlIgnoreCase(name, "cookie") or
        std.ascii.eqlIgnoreCase(name, "cookie2");
}

/// Tracks the origin and header names of an in-flight `loadRequest` so
/// redirects to another origin strip custom headers and completed navigations
/// clear scope cleanly.
pub const ActiveScope = struct {
    origin_url: ?[]u8 = null,
    header_names: [][]u8 = &.{},

    pub fn set(self: *ActiveScope, gpa: std.mem.Allocator, url: []const u8, headers: []const PageHeader) void {
        self.clear(gpa);
        if (headers.len == 0) return;
        const orig = gpa.dupe(u8, url) catch return;
        const names = gpa.alloc([]u8, headers.len) catch {
            gpa.free(orig);
            return;
        };
        var n: usize = 0;
        for (headers) |h| {
            names[n] = gpa.dupe(u8, h.name) catch {
                for (names[0..n]) |item| gpa.free(item);
                gpa.free(names);
                gpa.free(orig);
                return;
            };
            n += 1;
        }
        self.origin_url = orig;
        self.header_names = names;
    }

    pub fn allowsHeadersFor(self: *const ActiveScope, target_url: []const u8) bool {
        const orig = self.origin_url orelse return false;
        return sameOrigin(orig, target_url);
    }

    pub fn clear(self: *ActiveScope, gpa: std.mem.Allocator) void {
        if (self.origin_url) |u| gpa.free(u);
        for (self.header_names) |n| gpa.free(n);
        if (self.header_names.len > 0) gpa.free(self.header_names);
        self.origin_url = null;
        self.header_names = &.{};
    }
};

/// Single-slot latest-wins pending request state for asynchronous backends
/// (iOS lazy realization, Windows async WebView2 creation).
pub const PendingState = struct {
    deferred: bool = false,
    closed: bool = false,
    pending: ?OwnedRequest = null,

    pub const Action = union(enum) {
        none,
        default_url: []const u8,
        request: OwnedRequest,
    };

    pub fn init(defer_initial_load: bool) PendingState {
        return .{ .deferred = defer_initial_load };
    }

    pub fn submitRequest(self: *PendingState, gpa: std.mem.Allocator, req: PageRequest) Error!void {
        if (self.closed) return error.NoPage;
        const owned = try OwnedRequest.clone(gpa, req);
        if (self.pending) |*old| old.deinit(gpa);
        self.pending = owned;
    }

    pub fn submitUrl(self: *PendingState, gpa: std.mem.Allocator, url: []const u8) Error!void {
        return self.submitRequest(gpa, .{ .url = url });
    }

    pub fn takeReadyAction(self: *PendingState, gpa: std.mem.Allocator, default_url: []const u8) Action {
        if (self.closed) {
            self.close(gpa);
            return .none;
        }
        if (self.pending) |owned| {
            self.pending = null;
            return .{ .request = owned };
        }
        if (!self.deferred) return .{ .default_url = default_url };
        return .none;
    }

    pub fn close(self: *PendingState, gpa: std.mem.Allocator) void {
        self.closed = true;
        if (self.pending) |*old| old.deinit(gpa);
        self.pending = null;
    }
};

test "validate rejects control characters, invalid schemes and CRLF header injection" {
    try validate(.{ .url = "/index.html" });
    try validate(.{ .url = "http://127.0.0.1:8080/app", .headers = &.{.{ .name = "Authorization", .value = "Bearer tok" }} });
    try validate(.{ .url = "https://Example.COM/path" });
    try std.testing.expectError(error.InvalidUrl, validate(.{ .url = "" }));
    try std.testing.expectError(error.InvalidUrl, validate(.{ .url = "javascript:alert(1)" }));
    try std.testing.expectError(error.InvalidUrl, validate(.{ .url = "file:///etc/passwd" }));
    try std.testing.expectError(error.InvalidUrl, validate(.{ .url = "https://example.com/\r\nX: y" }));
    try std.testing.expectError(error.InvalidHeaderName, validate(.{ .url = "https://a.test", .headers = &.{.{ .name = "Bad Name", .value = "x" }} }));
    try std.testing.expectError(error.InvalidHeaderName, validate(.{ .url = "https://a.test", .headers = &.{.{ .name = "X-Key:", .value = "x" }} }));
    try std.testing.expectError(error.InvalidHeaderValue, validate(.{ .url = "https://a.test", .headers = &.{.{ .name = "Authorization", .value = "a\r\nb" }} }));
}

test "sameOrigin compares normalized scheme, case-insensitive host, and default ports" {
    try std.testing.expect(sameOrigin("http://example.com:80/a", "HTTP://EXAMPLE.COM/b"));
    try std.testing.expect(sameOrigin("https://api.example.com/1", "https://api.example.com:443/2"));
    try std.testing.expect(!sameOrigin("http://example.com/a", "https://example.com/a"));
    try std.testing.expect(!sameOrigin("http://127.0.0.1:8001/a", "http://127.0.0.1:8002/a"));
    try std.testing.expect(!sameOrigin("https://example.com/a", "https://sub.example.com/a"));
}

test "PendingState latest-wins queuing, deferral and close cancellation without leaks" {
    const gpa = std.testing.allocator;
    var p = PendingState.init(true);
    defer p.close(gpa);

    // Deferred stays idle when nothing submitted.
    try std.testing.expectEqual(PendingState.Action.none, p.takeReadyAction(gpa, "https://default.test"));

    // First submitted request replaced cleanly by second (latest wins).
    try p.submitRequest(gpa, .{ .url = "https://first.test", .headers = &.{.{ .name = "Authorization", .value = "Bearer old" }} });
    try p.submitRequest(gpa, .{ .url = "https://second.test", .headers = &.{.{ .name = "Authorization", .value = "Bearer new" }} });
    const act = p.takeReadyAction(gpa, "https://default.test");
    switch (act) {
        .request => |owned| {
            var copy = owned;
            defer copy.deinit(gpa);
            try std.testing.expectEqualStrings("https://second.test", copy.url);
            try std.testing.expectEqualStrings("Bearer new", copy.headers[0].value);
            const crlf = try copy.formatCrlfHeaders(gpa);
            defer gpa.free(crlf);
            try std.testing.expectEqualStrings("Authorization: Bearer new\r\n", crlf);
        },
        else => return error.TestUnexpectedResult,
    }

    // Close frees queued state cleanly.
    try p.submitRequest(gpa, .{ .url = "https://third.test", .headers = &.{.{ .name = "X-Test", .value = "1" }} });
    p.close(gpa);
    try std.testing.expectEqual(PendingState.Action.none, p.takeReadyAction(gpa, "https://default.test"));
    try std.testing.expectError(error.NoPage, p.submitRequest(gpa, .{ .url = "https://after-close.test" }));
}
