//! What was typed in the address field, as a place to go. What isn't one is a
//! search (`search.zig`).
const std = @import("std");

/// The URL `typed` means, in `gpa`; null when it isn't an address.
pub fn parse(gpa: std.mem.Allocator, typed: []const u8) std.mem.Allocator.Error!?[]u8 {
    const s = std.mem.trim(u8, typed, " \t\r\n");
    if (s.len == 0) return null;
    if (std.mem.indexOf(u8, s, "://") != null or std.mem.startsWith(u8, s, "about:") or std.mem.startsWith(u8, s, "data:")) {
        if (std.mem.indexOfAny(u8, s, " \t") != null and !std.mem.startsWith(u8, s, "data:")) return null;
        return try gpa.dupe(u8, s);
    }
    if (std.mem.indexOfAny(u8, s, " \t") != null) return null;
    const end = std.mem.indexOfAny(u8, s, "/?#") orelse s.len;
    const authority = s[0..end];
    const host = authority[0 .. std.mem.lastIndexOfScalar(u8, authority, ':') orelse authority.len];
    if (host.len == 0) return null;
    if (std.mem.eql(u8, host, "localhost") or isIp(host)) return try std.fmt.allocPrint(gpa, "http://{s}", .{s});
    // A name with a dot, and a last label that could be a top-level domain.
    const dot = std.mem.lastIndexOfScalar(u8, host, '.') orelse return null;
    const tld = host[dot + 1 ..];
    if (tld.len < 2 or dot == 0) return null;
    for (tld) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-') return null;
    for (host) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '.' and ch < 0x80) return null;
    return try std.fmt.allocPrint(gpa, "https://{s}", .{s});
}

fn isIp(host: []const u8) bool {
    if (std.mem.indexOfScalar(u8, host, '.') == null) return false;
    for (host) |ch| if (!std.ascii.isDigit(ch) and ch != '.') return false;
    return true;
}

/// A URL as a person reads it: no scheme, no `www.`, no lone trailing slash.
pub fn display(url: []const u8) []const u8 {
    var s = url;
    if (std.mem.indexOf(u8, s, "://")) |i| s = s[i + 3 ..];
    if (std.mem.startsWith(u8, s, "www.")) s = s[4..];
    if (std.mem.endsWith(u8, s, "/")) s = s[0 .. s.len - 1];
    return s;
}

/// The host of a URL, for a tab with no title yet.
pub fn hostOf(url: []const u8) []const u8 {
    const s = display(url);
    return s[0 .. std.mem.indexOfAny(u8, s, "/?#") orelse s.len];
}

test "what is an address" {
    const gpa = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "example.com", "https://example.com" },
        .{ "  en.wikipedia.org/wiki/Bird ", "https://en.wikipedia.org/wiki/Bird" },
        .{ "localhost:3000/x", "http://localhost:3000/x" },
        .{ "127.0.0.1:8080", "http://127.0.0.1:8080" },
        .{ "http://a.b", "http://a.b" },
        .{ "file:///tmp/a.html", "file:///tmp/a.html" },
        .{ "about:blank", "about:blank" },
    };
    for (cases) |k| {
        const got = (try parse(gpa, k[0])).?;
        defer gpa.free(got);
        try std.testing.expectEqualStrings(k[1], got);
    }
    for ([_][]const u8{ "", "   ", "hello world", "bird", "what is a bird?", ".com", "a.b" }) |no| {
        try std.testing.expect((try parse(gpa, no)) == null);
    }
    try std.testing.expectEqualStrings("en.wikipedia.org/wiki/Bird", display("https://www.en.wikipedia.org/wiki/Bird"));
    try std.testing.expectEqualStrings("example.com", display("https://example.com/"));
    try std.testing.expectEqualStrings("example.com", hostOf("https://www.example.com/a?b"));
}
