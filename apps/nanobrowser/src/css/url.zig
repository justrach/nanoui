//! Joining a URL reference to a base: enough of RFC 3986 for `url()` in a
//! stylesheet. Absolute references and `data:` come back unchanged.
const std = @import("std");
const Allocator = std.mem.Allocator;

fn hasScheme(s: []const u8) bool {
    for (s, 0..) |c, i| {
        if (c == ':') return i > 0;
        if (i == 0 and !std.ascii.isAlphabetic(c)) return false;
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    return false;
}

/// `ref` against `base`, in `arena`. A `base` that is empty or has no scheme
/// and no slash leaves `ref` as it is.
pub fn join(arena: Allocator, base: []const u8, ref: []const u8) Allocator.Error![]const u8 {
    const r = std.mem.trim(u8, ref, " \t\r\n\x0c");
    if (r.len == 0 or hasScheme(r) or base.len == 0) return r;
    if (!hasScheme(base)) return r;
    // `about:blank`, `data:` and kin have no path to join to.
    const colon = std.mem.indexOfScalar(u8, base, ':').?;
    if (!std.mem.startsWith(u8, base[colon + 1 ..], "/")) return r;
    if (r[0] == '#') {
        const end = std.mem.indexOfScalar(u8, base, '#') orelse base.len;
        return std.mem.concat(arena, u8, &.{ base[0..end], r });
    }
    const scheme_end = std.mem.indexOfScalar(u8, base, ':').?;
    if (std.mem.startsWith(u8, r, "//")) return std.mem.concat(arena, u8, &.{ base[0 .. scheme_end + 1], r });
    // The authority, when there is one.
    var path_at = scheme_end + 1;
    if (std.mem.startsWith(u8, base[path_at..], "//")) {
        const after = path_at + 2;
        path_at = std.mem.indexOfAnyPos(u8, base, after, "/?#") orelse base.len;
    }
    const prefix = base[0..path_at];
    const path_end = std.mem.indexOfAnyPos(u8, base, path_at, "?#") orelse base.len;
    const base_path = base[path_at..path_end];
    if (r[0] == '?') return std.mem.concat(arena, u8, &.{ base[0..path_end], r });
    const ref_end = std.mem.indexOfAny(u8, r, "?#") orelse r.len;
    const ref_path = r[0..ref_end];
    const tail = r[ref_end..];
    var merged: []const u8 = undefined;
    if (ref_path.len > 0 and ref_path[0] == '/') {
        merged = ref_path;
    } else {
        const dir_end = if (std.mem.lastIndexOfScalar(u8, base_path, '/')) |i| i + 1 else 0;
        const dir = if (base_path.len == 0) "/" else base_path[0..dir_end];
        merged = try std.mem.concat(arena, u8, &.{ dir, ref_path });
    }
    const clean = try removeDots(arena, merged);
    return std.mem.concat(arena, u8, &.{ prefix, clean, tail });
}

fn removeDots(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOf(u8, path, "./") == null and !std.mem.endsWith(u8, path, "/.") and !std.mem.endsWith(u8, path, "/..")) return path;
    var segs: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, path, '/');
    var trailing = false;
    while (it.next()) |s| {
        trailing = false;
        if (std.mem.eql(u8, s, ".")) {
            trailing = true;
        } else if (std.mem.eql(u8, s, "..")) {
            trailing = true;
            if (segs.items.len > 1) segs.items.len -= 1;
        } else {
            try segs.append(arena, s);
        }
    }
    if (trailing) try segs.append(arena, "");
    return std.mem.join(arena, "/", segs.items);
}

test "join" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const al = a.allocator();
    const Case = struct { base: []const u8, ref: []const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .base = "https://a.com/x/y.css", .ref = "z.png", .want = "https://a.com/x/z.png" },
        .{ .base = "https://a.com/x/y.css", .ref = "../z.png", .want = "https://a.com/z.png" },
        .{ .base = "https://a.com/x/y.css", .ref = "/z.png?q=1", .want = "https://a.com/z.png?q=1" },
        .{ .base = "https://a.com", .ref = "z.png", .want = "https://a.com/z.png" },
        .{ .base = "https://a.com/x/y.css", .ref = "//b.com/z", .want = "https://b.com/z" },
        .{ .base = "https://a.com/x", .ref = "data:image/png;base64,AA", .want = "data:image/png;base64,AA" },
        .{ .base = "https://a.com/x/y.css?v=1", .ref = "./z.png", .want = "https://a.com/x/z.png" },
        .{ .base = "https://a.com/x/", .ref = "#a", .want = "https://a.com/x/#a" },
        .{ .base = "about:blank", .ref = "z.png", .want = "z.png" },
        .{ .base = "", .ref = "z.png", .want = "z.png" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c.want, try join(al, c.base, c.ref));
}
