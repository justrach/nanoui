//! Pointer word selection is not word-cursor navigation. Select the word
//! under the pointer, or exactly one extended grapheme for symbols/emoji.
//! UTF-8 byte offsets stay offsets into the original source: no projection,
//! normalization, platform tokenizer or replacement strings reach Copy.
const std = @import("std");
const data = @import("text_selection_data.zig");
const Break = data.Break;

const Scalar = struct { cp: u21, end: usize };

fn scalar(s: []const u8, at: usize) Scalar {
    const count = std.unicode.utf8ByteSequenceLength(s[at]) catch 1;
    const end = @min(at + count, s.len);
    const cp = std.unicode.utf8Decode(s[at..end]) catch return .{ .cp = 0xfffd, .end = at + 1 };
    return .{ .cp = cp, .end = end };
}

fn property(cp: u21) Break {
    if (cp >= 0xac00 and cp <= 0xd7a3) return if ((cp - 0xac00) % 28 == 0) .lv else .lvt;
    return data.breakOf(cp);
}

fn control(p: Break) bool {
    return p == .cr or p == .lf or p == .control;
}

/// UAX #29 extended grapheme clusters, Unicode 17 (GB3-GB13/GB999).
/// `start` is a cluster boundary. Each scalar is visited once, including
/// arbitrary combining/ZWJ tails; the property lookups are binary searches.
pub fn graphemeEnd(s: []const u8, start: usize) usize {
    if (start >= s.len) return s.len;
    var prev = scalar(s, start);
    var p = property(prev.cp);
    var ri: usize = if (p == .regional_indicator) 1 else 0;
    var emoji_tail = data.isPictographic(prev.cp);
    var zwj_after_emoji = false;
    var indic_active = data.indicOf(prev.cp) == .consonant;
    var indic_linker = false;
    while (prev.end < s.len) {
        const next = scalar(s, prev.end);
        const q = property(next.cp);
        const indic = data.indicOf(next.cp);
        const join = if (p == .cr and q == .lf)
            true // GB3
        else if (control(p) or control(q))
            false // GB4/5 precede Extend/Prepend handling.
        else if (p == .l and (q == .l or q == .v or q == .lv or q == .lvt))
            true // GB6
        else if ((p == .lv or p == .v) and (q == .v or q == .t))
            true // GB7
        else if ((p == .lvt or p == .t) and q == .t)
            true // GB8
        else if (q == .extend or q == .zwj or q == .spacingmark or p == .prepend)
            true // GB9/9a/9b
        else if (indic == .consonant and indic_active and indic_linker)
            true // GB9c
        else if (p == .zwj and zwj_after_emoji and data.isPictographic(next.cp))
            true // GB11
        else
            p == .regional_indicator and q == .regional_indicator and ri % 2 == 1; // GB12/13
        if (!join) return prev.end;
        if (q == .zwj) {
            zwj_after_emoji = emoji_tail;
            emoji_tail = false;
        } else {
            zwj_after_emoji = false;
            if (q != .extend) emoji_tail = data.isPictographic(next.cp);
        }
        switch (indic) {
            .consonant => {
                indic_active = true;
                indic_linker = false;
            },
            .extend => {},
            .linker => {
                if (indic_active) indic_linker = true;
            },
            .none => {
                indic_active = false;
                indic_linker = false;
            },
        }
        ri = if (q == .regional_indicator) ri + 1 else 0;
        prev = next;
        p = q;
    }
    return s.len;
}

const Class = enum { word, space, atom };

fn class(s: []const u8, at: usize) Class {
    const cp = scalar(s, at).cp;
    if (cp == '_' or data.isWord(cp)) return .word;
    // Unicode White_Space, independent of the process's locale.
    return switch (cp) {
        0x09...0x0d, 0x20, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => .space,
        else => .atom,
    };
}

/// The source-byte word/whitespace run or single symbol grapheme at `at`.
/// Even offsets inside a scalar/cluster are resolved to whole graphemes.
/// Unlike prevWord/nextWord this never crosses a separator to another word.
pub fn wordRange(s: []const u8, at: usize) [2]usize {
    if (s.len == 0) return .{ 0, 0 };
    const hit = @min(at, s.len - 1);
    var start: usize = 0;
    var run: usize = 0;
    var previous: Class = .atom;
    while (start < s.len) {
        const end = graphemeEnd(s, start);
        const current = class(s, start);
        if (current == .atom or current != previous) run = start;
        if (hit < end) {
            if (current == .atom) return .{ start, end };
            var tail = end;
            while (tail < s.len and class(s, tail) == current) tail = graphemeEnd(s, tail);
            return .{ run, tail };
        }
        previous = current;
        start = end;
    }
    unreachable;
}

/// A word click uses the glyph cell under the pointer, not its nearest
/// insertion caret (the latter jumps across half a glyph/emoji). Shared by
/// native and reference shaping; their glyph indices remain source bytes.
pub fn glyphClusterAt(glyphs: anytype, width: f32, x: f32) usize {
    var best: usize = 0;
    var distance = std.math.inf(f32);
    for (glyphs, 0..) |g, i| {
        const edge = if (i + 1 < glyphs.len) glyphs[i + 1].x else width;
        const left = @min(g.x, edge);
        const right = @max(g.x, edge);
        if (right <= left) continue; // Zero-advance glyphs do not own cells.
        if (x >= left and x < right) return g.index;
        const d = if (x < left) left - x else x - right;
        if (d < distance) {
            distance = d;
            best = g.index;
        }
    }
    return best;
}

fn checkGraphemeVectors(source: []const u8) !usize {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var cases: usize = 0;
    while (lines.next()) |line| {
        const body = line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len];
        var tokens = std.mem.tokenizeAny(u8, body, " \t\r");
        var bytes: [1024]u8 = undefined;
        var length: usize = 0;
        var boundaries: [256]usize = undefined;
        var count: usize = 0;
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "÷")) {
                boundaries[count] = length;
                count += 1;
            } else if (!std.mem.eql(u8, token, "×")) {
                const cp = try std.fmt.parseInt(u21, token, 16);
                var encoded: [4]u8 = undefined;
                const n = try std.unicode.utf8Encode(cp, &encoded);
                @memcpy(bytes[length..][0..n], encoded[0..n]);
                length += n;
            }
        }
        if (count == 0) continue;
        const text = bytes[0..length];
        var at: usize = 0;
        for (boundaries[1..count]) |end| {
            try std.testing.expectEqual(end, graphemeEnd(text, at));
            at = end;
        }
        try std.testing.expectEqual(length, at);
        cases += 1;
    }
    return cases;
}

test "selection Unicode grapheme clusters conform to Unicode 17 break vectors" {
    var cases: usize = 0;
    cases += try checkGraphemeVectors(@embedFile("grapheme_break_test_1.txt"));
    cases += try checkGraphemeVectors(@embedFile("grapheme_break_test_2.txt"));
    try std.testing.expect(cases > 700);
}

test "selection word hit preserves identifiers punctuation and every cluster byte" {
    const t = std.testing;
    for ([_][]const u8{ "a\u{301}", "👍🏽", "🇸🇬", "👩‍💻", "👨‍👩‍👧‍👦", "क्\u{200d}ष" }) |cluster| {
        var buf: [200]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "Start {s} end", .{cluster});
        for (6..6 + cluster.len) |at| {
            const r = wordRange(s, at);
            try t.expectEqualStrings(cluster, s[r[0]..r[1]]);
        }
    }
    const s = "alpha_beta42,中文 café!  tail";
    for ([_]struct { at: usize, expected: []const u8 }{
        .{ .at = 0, .expected = "alpha_beta42" },
        .{ .at = 11, .expected = "alpha_beta42" },
        .{ .at = 12, .expected = "," },
        .{ .at = 13, .expected = "中文" },
        .{ .at = 20, .expected = "café" },
        .{ .at = 25, .expected = "!" },
        .{ .at = 26, .expected = "  " },
        .{ .at = s.len, .expected = "tail" },
    }) |vector| {
        const r = wordRange(s, vector.at);
        try t.expectEqualStrings(vector.expected, s[r[0]..r[1]]);
    }
}

test "selection pointer cell chooses its cluster on both sides of caret midpoint" {
    const Glyph = struct { x: f32, index: usize };
    const glyphs = [_]Glyph{ .{ .x = 0, .index = 0 }, .{ .x = 10, .index = 1 }, .{ .x = 30, .index = 9 }, .{ .x = 30, .index = 10 }, .{ .x = 40, .index = 11 } };
    for ([_]f32{ 10, 10.001, 19, 20, 29.999 }) |x| try std.testing.expectEqual(@as(usize, 1), glyphClusterAt(&glyphs, 50, x));
    try std.testing.expectEqual(@as(usize, 10), glyphClusterAt(&glyphs, 50, 30));
    try std.testing.expectEqual(@as(usize, 0), glyphClusterAt(&glyphs, 50, -5));
    try std.testing.expectEqual(@as(usize, 11), glyphClusterAt(&glyphs, 50, 55));
}
