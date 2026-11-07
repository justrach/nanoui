//! Search engines, as the address field sees them: where a search goes, where
//! suggestions come from, and which one was chosen last time.
const std = @import("std");
const nanoui = @import("nanoui");
const address = @import("address.zig");

pub const Engine = enum {
    google,
    duckduckgo,

    pub fn name(e: Engine) []const u8 {
        return switch (e) {
            .google => "Google",
            .duckduckgo => "DuckDuckGo",
        };
    }

    pub fn prompt(e: Engine) []const u8 {
        return switch (e) {
            .google => "Search Google or enter an address",
            .duckduckgo => "Search DuckDuckGo or enter an address",
        };
    }

    fn results(e: Engine) []const u8 {
        return switch (e) {
            .google => "https://www.google.com/search?q=",
            .duckduckgo => "https://duckduckgo.com/?q=",
        };
    }

    fn suggestions(e: Engine) []const u8 {
        return switch (e) {
            .google => "https://suggestqueries.google.com/complete/search?client=firefox&ie=utf-8&oe=utf-8&q=",
            .duckduckgo => "https://duckduckgo.com/ac/?type=list&q=",
        };
    }
};

fn withQuery(gpa: std.mem.Allocator, base: []const u8, query: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, base);
    for (query) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.append(gpa, ch);
        } else if (ch == ' ') {
            try out.append(gpa, '+');
        } else {
            var buf: [3]u8 = undefined;
            try out.appendSlice(gpa, std.fmt.bufPrint(&buf, "%{X:0>2}", .{ch}) catch unreachable);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Where a search for `query` goes. `base`, for a test, in place of the engine's.
pub fn resultsUrl(gpa: std.mem.Allocator, e: Engine, query: []const u8, base: ?[]const u8) ![]u8 {
    return withQuery(gpa, base orelse e.results(), std.mem.trim(u8, query, " \t\r\n"));
}

pub fn suggestUrl(gpa: std.mem.Allocator, e: Engine, query: []const u8) ![]u8 {
    return withQuery(gpa, e.suggestions(), query);
}

/// Where what was typed goes: the address it is, else a search for it. Null when
/// nothing was.
pub fn destination(gpa: std.mem.Allocator, typed: []const u8, e: Engine, base: ?[]const u8) !?[]u8 {
    if (try address.parse(gpa, typed)) |url| return url;
    if (std.mem.trim(u8, typed, " \t\r\n").len == 0) return null;
    return try resultsUrl(gpa, e, typed, base);
}

/// Both engines answer `["what was typed", ["one", "two", ...], ...]`. What isn't
/// that is no suggestions. The strings are in `arena`.
pub fn parseSuggestions(arena: std.mem.Allocator, body: []const u8, max: usize) []const []const u8 {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return &.{};
    if (root != .array or root.array.items.len < 2) return &.{};
    const list = root.array.items[1];
    if (list != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (list.array.items) |v| {
        if (out.items.len >= max) break;
        if (v == .string and v.string.len > 0) out.append(arena, v.string) catch break;
    }
    return out.items;
}

const key = "search-engine";

/// The engine chosen last time; Google until one is.
pub fn load(gpa: std.mem.Allocator) Engine {
    const name_kept = nanoui.kv.standard().get(gpa, key) catch return .google;
    const text = name_kept orelse return .google;
    defer gpa.free(text);
    return std.meta.stringToEnum(Engine, text) orelse .google;
}

pub fn save(e: Engine) void {
    nanoui.kv.standard().set(key, @tagName(e)) catch {};
}

test "what was typed goes to an address or a search" {
    const gpa = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "whatsapp", "https://www.google.com/search?q=whatsapp" },
        .{ " birds of paradise ", "https://www.google.com/search?q=birds+of+paradise" },
        .{ "c++ & café?", "https://www.google.com/search?q=c%2B%2B+%26+caf%C3%A9%3F" },
        .{ "example.com", "https://example.com" },
        .{ "localhost:8000", "http://localhost:8000" },
    };
    for (cases) |x| {
        const got = (try destination(gpa, x[0], .google, null)).?;
        defer gpa.free(got);
        try std.testing.expectEqualStrings(x[1], got);
    }
    const ddg = (try destination(gpa, "whatsapp", .duckduckgo, null)).?;
    defer gpa.free(ddg);
    try std.testing.expectEqualStrings("https://duckduckgo.com/?q=whatsapp", ddg);
    try std.testing.expect((try destination(gpa, "   ", .google, null)) == null);
}

test "suggestions as both engines give them, and what isn't" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const google = parseSuggestions(arena, "[\"caf\u{e9}\",[\"caf\u{e9} one\",\"two\"],[],{\"google:suggesttype\":[\"QUERY\"]}]", 8);
    try std.testing.expectEqual(@as(usize, 2), google.len);
    try std.testing.expectEqualStrings("caf\u{e9} one", google[0]);
    try std.testing.expectEqual(@as(usize, 1), parseSuggestions(arena, "[\"x\",[\"a\",\"b\",\"c\"]]", 1).len);
    for ([_][]const u8{ "", "<html>sorry</html>", "{}", "[\"x\"]", "[\"x\",3]" }) |bad| {
        try std.testing.expectEqual(@as(usize, 0), parseSuggestions(arena, bad, 8).len);
    }
}
