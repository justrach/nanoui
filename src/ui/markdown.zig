//! A little Markdown as rich text (`ui.richText`'s spans): what an
//! agent's messages use. `**bold**` and `__bold__`, `*italic*` and
//! `_italic_`, `` `code` `` (monospaced, on a tint), `# headings` (bold),
//! `- bullets` (as •), fenced code blocks (monospaced, markers gone) and
//! `\` escapes. Anything else stays as written; a marker never closed is
//! kept as text.
//!
//!     ui.markdown.view(c, entry.text, .{ .size = 13, .wrap = true }, .{});
const std = @import("std");
const types = @import("types.zig");
const Context = @import("context.zig").Context;
const Span = types.Span;

pub const Options = struct {
    /// Behind inline code (null: none).
    code_background: ?types.Color = .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 0.18 },
    code_color: ?types.Color = null,
    heading_weight: types.Weight = .bold,
    bullet: []const u8 = "• ",
};

/// The text with its markers gone, and the spans that style it (byte
/// ranges of `text`, in order, never overlapping).
pub const Rich = struct {
    text: []const u8,
    spans: []const Span,
};

/// `src` as rich text, in `a`'s memory (a frame's: `c.alloc()`).
pub fn parse(a: std.mem.Allocator, src: []const u8, opts: Options) !Rich {
    var p: Parser = .{ .a = a, .opts = opts };
    var lines = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    var fenced = false;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "```")) {
            fenced = !fenced;
            continue;
        }
        if (!first) try p.out.append(a, '\n');
        first = false;
        if (fenced) {
            const start = p.out.items.len;
            try p.out.appendSlice(a, line);
            try p.span(start, .{ .start = 0, .end = 0, .mono = true, .color = opts.code_color });
            continue;
        }
        try p.line(line);
    }
    return .{ .text = try p.out.toOwnedSlice(a), .spans = try p.spans.toOwnedSlice(a) };
}

/// `src` drawn as one rich text (`ui.richText`), in the frame's memory.
pub fn view(c: *Context, src: []const u8, style: types.TextStyle, opts: Options) void {
    const r = parse(c.alloc(), src, opts) catch return @import("widgets.zig").text(c, src, style);
    @import("widgets.zig").richText(c, r.text, r.spans, style);
}

const Parser = struct {
    a: std.mem.Allocator,
    opts: Options,
    out: std.ArrayList(u8) = .empty,
    spans: std.ArrayList(Span) = .empty,
    bold: bool = false,
    italic: bool = false,
    heading: bool = false,
    run: usize = 0,

    fn span(p: *Parser, start: usize, s: Span) !void {
        if (p.out.items.len <= start) return;
        var v = s;
        v.start = @intCast(start);
        v.end = @intCast(p.out.items.len);
        try p.spans.append(p.a, v);
    }

    /// Ends the run of text styled as it is now.
    fn flush(p: *Parser) !void {
        const bold = p.bold or p.heading;
        if (bold or p.italic) try p.span(p.run, .{ .start = 0, .end = 0, .weight = if (bold) (if (p.heading) p.opts.heading_weight else .bold) else null, .italic = p.italic });
        p.run = p.out.items.len;
    }

    fn line(p: *Parser, src: []const u8) !void {
        var s = src;
        const indent = s.len - std.mem.trimStart(u8, s, " ").len;
        const body = s[indent..];
        p.run = p.out.items.len;
        if (headingLevel(body)) |n| {
            p.heading = true;
            s = std.mem.trimStart(u8, body[n..], " ");
        } else if (body.len >= 2 and (body[0] == '-' or body[0] == '*' or body[0] == '+') and body[1] == ' ') {
            try p.out.appendSlice(p.a, s[0..indent]);
            try p.out.appendSlice(p.a, p.opts.bullet);
            p.run = p.out.items.len;
            s = body[2..];
        }
        try p.inline_(s);
        try p.flush();
        // Styles end with their line, closed or not.
        p.bold = false;
        p.italic = false;
        p.heading = false;
    }

    fn inline_(p: *Parser, s: []const u8) !void {
        var i: usize = 0;
        while (i < s.len) {
            const ch = s[i];
            if (ch == '\\' and i + 1 < s.len and isPunct(s[i + 1])) {
                try p.out.append(p.a, s[i + 1]);
                i += 2;
                continue;
            }
            if (ch == '`') if (std.mem.indexOfScalarPos(u8, s, i + 1, '`')) |close| {
                try p.flush();
                const start = p.out.items.len;
                try p.out.appendSlice(p.a, s[i + 1 .. close]);
                try p.span(start, .{ .start = 0, .end = 0, .mono = true, .background = p.opts.code_background, .color = p.opts.code_color });
                p.run = p.out.items.len;
                i = close + 1;
                continue;
            };
            if ((ch == '*' or ch == '_') and i + 1 < s.len and s[i + 1] == ch) {
                const marker = s[i .. i + 2];
                if (p.bold or std.mem.indexOfPos(u8, s, i + 2, marker) != null) {
                    try p.flush();
                    p.bold = !p.bold;
                    i += 2;
                    continue;
                }
            } else if (ch == '*' or ch == '_') {
                const before_ok = ch == '*' or i == 0 or !std.ascii.isAlphanumeric(s[i - 1]);
                const after_ok = ch == '*' or i + 1 >= s.len or !std.ascii.isAlphanumeric(s[i + 1]);
                const opens = !p.italic and before_ok and i + 1 < s.len and s[i + 1] != ' ' and closes(s, i + 1, ch);
                if (opens or (p.italic and after_ok)) {
                    try p.flush();
                    p.italic = !p.italic;
                    i += 1;
                    continue;
                }
            }
            try p.out.append(p.a, ch);
            i += 1;
        }
    }
};

/// Whether a single `ch` closes an emphasis opened before `from`.
fn closes(s: []const u8, from: usize, ch: u8) bool {
    var j = from;
    while (std.mem.indexOfScalarPos(u8, s, j, ch)) |k| : (j = k + 1) {
        const doubled = k + 1 < s.len and s[k + 1] == ch;
        if (doubled) {
            j = k + 1;
            continue;
        }
        if (s[k - 1] != ' ') return true;
    }
    return false;
}

fn headingLevel(s: []const u8) ?usize {
    var n: usize = 0;
    while (n < s.len and n < 6 and s[n] == '#') n += 1;
    if (n == 0 or n >= s.len or s[n] != ' ') return null;
    return n;
}

fn isPunct(ch: u8) bool {
    return std.mem.indexOfScalar(u8, "\\`*_{}[]()#+-.!|>~", ch) != null;
}

test "markdown: **a** `b` is a bold a and a monospaced b" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "**a** `b`", .{});
    try std.testing.expectEqualStrings("a b", r.text);
    try std.testing.expectEqual(@as(usize, 2), r.spans.len);
    try std.testing.expectEqual(@as(u32, 0), r.spans[0].start);
    try std.testing.expectEqual(@as(u32, 1), r.spans[0].end);
    try std.testing.expectEqual(types.Weight.bold, r.spans[0].weight.?);
    try std.testing.expect(!r.spans[0].mono);
    try std.testing.expectEqual(@as(u32, 2), r.spans[1].start);
    try std.testing.expectEqual(@as(u32, 3), r.spans[1].end);
    try std.testing.expect(r.spans[1].mono and r.spans[1].background != null);
}

test "markdown: italics, bullets, headings, fences, escapes and stray markers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parse(a, "# Plan\n- *one* and _two_\n* snake_case stays\n```\nx = 1\n```\n2 * 3 \\*x\\* **open", .{});
    try std.testing.expectEqualStrings("Plan\n• one and two\n• snake_case stays\nx = 1\n2 * 3 *x* **open", r.text);
    // Heading bold, two italics, the fenced line monospaced.
    try std.testing.expectEqual(@as(usize, 4), r.spans.len);
    try std.testing.expectEqualStrings("Plan", r.text[r.spans[0].start..r.spans[0].end]);
    try std.testing.expect(r.spans[0].weight != null);
    try std.testing.expectEqualStrings("one", r.text[r.spans[1].start..r.spans[1].end]);
    try std.testing.expect(r.spans[1].italic);
    try std.testing.expectEqualStrings("two", r.text[r.spans[2].start..r.spans[2].end]);
    try std.testing.expectEqualStrings("x = 1", r.text[r.spans[3].start..r.spans[3].end]);
    try std.testing.expect(r.spans[3].mono);
    // Bold over italic: one run each, never overlapping.
    const b = try parse(a, "**bold *both* end**", .{});
    try std.testing.expectEqualStrings("bold both end", b.text);
    try std.testing.expectEqual(@as(usize, 3), b.spans.len);
    try std.testing.expect(b.spans[1].italic and b.spans[1].weight != null);
    for (b.spans[1..], b.spans[0 .. b.spans.len - 1]) |x, prev| try std.testing.expect(x.start >= prev.end);
}
