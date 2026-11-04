//! URLs joined: where a link, a redirect or a stylesheet's `url()` leads
//! from the document it is in.
const std = @import("std");

/// `ref` as a link from `base` reaches it: an absolute URL, `//host/x`,
/// `/path`, `?query`, `#fragment` or a relative path with its dot segments
/// worked out. Owned by `gpa`.
pub fn resolve(gpa: std.mem.Allocator, base: []const u8, ref_in: []const u8) ![]u8 {
    const ref = std.mem.trim(u8, ref_in, " \t\r\n");
    if (hasScheme(ref)) return gpa.dupe(u8, ref);
    const sep = std.mem.indexOf(u8, base, "://") orelse return gpa.dupe(u8, ref);
    const scheme = base[0..sep];
    if (std.mem.startsWith(u8, ref, "//")) return std.fmt.allocPrint(gpa, "{s}:{s}", .{ scheme, ref });
    const after = sep + 3;
    const path_at = if (std.mem.indexOfAnyPos(u8, base, after, "/?#")) |i| i else base.len;
    const origin = base[0..path_at];
    const rest = base[path_at..];
    const query_at = std.mem.indexOfAny(u8, rest, "?#") orelse rest.len;
    const base_path = rest[0..query_at];
    if (ref.len == 0) return gpa.dupe(u8, base[0 .. std.mem.indexOfScalar(u8, base, '#') orelse base.len]);
    if (ref[0] == '#') return std.fmt.allocPrint(gpa, "{s}{s}", .{ base[0 .. std.mem.indexOfScalar(u8, base, '#') orelse base.len], ref });
    if (ref[0] == '?') return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ origin, if (base_path.len == 0) "/" else base_path, ref });
    // The path's and what follows it, split: dots count only in the path.
    const ref_end = std.mem.indexOfAny(u8, ref, "?#") orelse ref.len;
    const joined = if (ref[0] == '/')
        try gpa.dupe(u8, ref[0..ref_end])
    else
        try std.fmt.allocPrint(gpa, "{s}{s}", .{ base_path[0 .. if (std.mem.lastIndexOfScalar(u8, base_path, '/')) |i| i + 1 else 0], ref[0..ref_end] });
    defer gpa.free(joined);
    // At most as many segments as slashes, plus the first.
    const segments = try gpa.alloc([]const u8, std.mem.count(u8, joined, "/") + 2);
    defer gpa.free(segments);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, joined, '/');
    var trailing = false;
    while (it.next()) |seg| {
        trailing = false;
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) {
            if (seg.len == 2 and n > 0) n -= 1;
            trailing = true;
        } else if (seg.len > 0 or it.index == null) {
            segments[n] = seg;
            n += 1;
        }
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, origin);
    for (segments[0..n]) |seg| {
        try out.append(gpa, '/');
        try out.appendSlice(gpa, seg);
    }
    if (n == 0 or trailing) try out.append(gpa, '/');
    try out.appendSlice(gpa, ref[ref_end..]);
    return out.toOwnedSlice(gpa);
}

fn hasScheme(s: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return false;
    if (colon == 0 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s[0..colon]) |c| if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    return true;
}

test "links resolve against where they are" {
    const gpa = std.testing.allocator;
    const cases = [_][3][]const u8{
        .{ "https://a.org/x/y?q#f", "https://b.org/z", "https://b.org/z" },
        .{ "https://a.org/x/y", "mailto:me@a.org", "mailto:me@a.org" },
        .{ "https://a.org/x/y", "//b.org/z", "https://b.org/z" },
        .{ "https://a.org/x/y?q", "/z?r#s", "https://a.org/z?r#s" },
        .{ "https://a.org/x/y", "z", "https://a.org/x/z" },
        .{ "https://a.org/x/y/", "z", "https://a.org/x/y/z" },
        .{ "https://a.org", "z", "https://a.org/z" },
        .{ "https://a.org/x/y/w", "../z", "https://a.org/x/z" },
        .{ "https://a.org/x/y/w", "./", "https://a.org/x/y/" },
        .{ "https://a.org/x/y/w", "../..", "https://a.org/" },
        .{ "https://a.org/x", "../../../z", "https://a.org/z" },
        .{ "https://a.org/x/y?q#f", "?r", "https://a.org/x/y?r" },
        .{ "https://a.org", "?r", "https://a.org/?r" },
        .{ "https://a.org/x?q#f", "#g", "https://a.org/x?q#g" },
        .{ "https://a.org/x?q#f", "", "https://a.org/x?q" },
        .{ "https://a.org/x", "y/../z/?a/../b", "https://a.org/z/?a/../b" },
    };
    for (cases) |c| {
        const got = try resolve(gpa, c[0], c[1]);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(c[2], got);
    }
}
