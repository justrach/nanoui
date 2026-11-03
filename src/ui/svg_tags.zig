//! The tags of an SVG document, enough of XML for icons: elements and their
//! attributes (quoted either way), self-closing tags, and closing tags.
//! Text, comments, `<?…?>`, `<!…>` and CDATA are passed over.
const std = @import("std");

pub const Kind = enum { open, empty, close };

pub const Attr = struct { name: []const u8, value: []const u8 };

pub const Tag = struct {
    kind: Kind,
    name: []const u8,
    /// What lies between the name and `>` (or `/>`).
    rest: []const u8 = "",

    pub fn attrs(t: Tag) Attrs {
        return .{ .s = t.rest };
    }

    pub fn attr(t: Tag, name: []const u8) ?[]const u8 {
        var it = t.attrs();
        while (it.next()) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
        return null;
    }
};

pub const Attrs = struct {
    s: []const u8,
    i: usize = 0,

    pub fn next(it: *Attrs) ?Attr {
        const s = it.s;
        while (it.i < s.len and std.ascii.isWhitespace(s[it.i])) it.i += 1;
        const start = it.i;
        while (it.i < s.len and s[it.i] != '=' and !std.ascii.isWhitespace(s[it.i])) it.i += 1;
        if (it.i == start) return null;
        const name = s[start..it.i];
        while (it.i < s.len and std.ascii.isWhitespace(s[it.i])) it.i += 1;
        if (it.i >= s.len or s[it.i] != '=') return .{ .name = name, .value = "" };
        it.i += 1;
        while (it.i < s.len and std.ascii.isWhitespace(s[it.i])) it.i += 1;
        if (it.i >= s.len) return null;
        const q = s[it.i];
        if (q != '"' and q != '\'') return null;
        const end = std.mem.indexOfScalarPos(u8, s, it.i + 1, q) orelse return null;
        const value = s[it.i + 1 .. end];
        it.i = end + 1;
        return .{ .name = name, .value = value };
    }
};

pub const Tags = struct {
    s: []const u8,
    i: usize = 0,

    pub fn next(it: *Tags) ?Tag {
        const s = it.s;
        while (std.mem.indexOfScalarPos(u8, s, it.i, '<')) |lt| {
            const after = s[lt + 1 ..];
            if (std.mem.startsWith(u8, after, "!--")) {
                it.i = (std.mem.indexOfPos(u8, s, lt, "-->") orelse return null) + 3;
                continue;
            }
            if (std.mem.startsWith(u8, after, "![CDATA[")) {
                it.i = (std.mem.indexOfPos(u8, s, lt, "]]>") orelse return null) + 3;
                continue;
            }
            if (after.len > 0 and (after[0] == '?' or after[0] == '!')) {
                it.i = (std.mem.indexOfScalarPos(u8, s, lt, '>') orelse return null) + 1;
                continue;
            }
            // The tag's end: the first `>` outside quotes.
            var j = lt + 1;
            var quote: u8 = 0;
            while (j < s.len) : (j += 1) {
                const c = s[j];
                if (quote != 0) {
                    if (c == quote) quote = 0;
                } else if (c == '"' or c == '\'') quote = c else if (c == '>') break;
            }
            if (j >= s.len) return null;
            it.i = j + 1;
            var body = s[lt + 1 .. j];
            var kind: Kind = .open;
            if (body.len > 0 and body[0] == '/') {
                kind = .close;
                body = body[1..];
            } else if (body.len > 0 and body[body.len - 1] == '/') {
                kind = .empty;
                body = body[0 .. body.len - 1];
            }
            var n: usize = 0;
            while (n < body.len and !std.ascii.isWhitespace(body[n])) n += 1;
            if (n == 0) continue;
            return .{ .kind = kind, .name = localName(body[0..n]), .rest = body[n..] };
        }
        return null;
    }
};

/// `svg:path` is a `path`.
fn localName(n: []const u8) []const u8 {
    const colon = std.mem.lastIndexOfScalar(u8, n, ':') orelse return n;
    return n[colon + 1 ..];
}

test "tags, attributes either quoted, and what's passed over" {
    var it: Tags = .{ .s =
    \\<?xml version="1.0"?><!-- a > b --><svg viewBox='0 0 24 24' fill="none">
    \\  <title>x &gt; y</title><path d="M0 0" stroke-width = "1.5"/></svg>
    };
    const svg = it.next().?;
    try std.testing.expectEqual(Kind.open, svg.kind);
    try std.testing.expectEqualStrings("0 0 24 24", svg.attr("viewBox").?);
    try std.testing.expectEqualStrings("none", svg.attr("fill").?);
    try std.testing.expectEqualStrings("title", it.next().?.name);
    try std.testing.expectEqual(Kind.close, it.next().?.kind);
    const p = it.next().?;
    try std.testing.expectEqual(Kind.empty, p.kind);
    try std.testing.expectEqualStrings("1.5", p.attr("stroke-width").?);
    try std.testing.expect(p.attr("fill") == null);
    try std.testing.expectEqualStrings("svg", it.next().?.name);
    try std.testing.expect(it.next() == null);
}
