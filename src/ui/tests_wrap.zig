//! Wrapping's fast path (text_mac.zig `oneLine`: a line that fits needs no
//! typesetter) gives what CoreText's typesetter gives, wherever it answers:
//! over strings with trailing spaces, tabs, wide characters and emoji,
//! styled spans, at widths from too narrow to roomy.
const std = @import("std");
const ui = @import("ui.zig");
const types = @import("types.zig");

fn nothing(_: *u8, _: *ui.Context) void {}

test "a line that fits wraps to itself, as the typesetter says" {
    var page: u8 = 0;
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&page, nothing), .{ .width = 200, .height = 100 });
    defer t.deinit();
    const ts = &t.text;
    const samples = [_][]const u8{
        "",
        "ls -la",
        "drwxr-xr-x   12 root  wheel   384 Oct 19 22:10 bin",
        "trailing spaces   ",
        "a\ttab\tseparated\tline",
        "line 42: the quick brown fox jumps over the lazy dog, again and again",
        "日本語のテキストと English mixed",
        "emoji 🎉 and ✓ marks ✗",
        "averyveryverylongwordwithoutanyspacesatallthatmustbreaksomewhere",
    };
    const bold: [1]types.Span = .{.{ .start = 0, .end = 4, .weight = .bold }};
    const styles = [_]types.TextStyle{ .{ .size = 13 }, .{ .size = 12.5, .mono = true }, .{ .size = 15, .weight = .semibold } };
    var answered: usize = 0;
    for (samples) |s| for (styles) |style| for ([_][]const types.Span{ &.{}, &bold }) |spans| {
        if (spans.len > 0 and s.len < 4) continue;
        var w: f32 = 8;
        while (w < 700) : (w += 7) {
            const fast = ts.oneLine(s, style, spans, w) orelse continue;
            answered += 1;
            const slow = try ts.breakLines(s, style, spans, w);
            defer std.testing.allocator.free(slow);
            errdefer std.debug.print("\"{s}\" at {d}: {any} vs {any}\n", .{ s, w, fast, slow });
            try std.testing.expectEqual(@as(usize, 1), slow.len);
            try std.testing.expectEqual(slow[0].start, fast.start);
            try std.testing.expectEqual(slow[0].end, fast.end);
            try std.testing.expectApproxEqAbs(slow[0].width, fast.width, 0.001);
        }
    };
    try std.testing.expect(answered > 500);
}

test "GPUI's rule: a word that fits only without the space after it goes down a line" {
    var page: u8 = 0;
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&page, nothing), .{ .width = 200, .height = 100 });
    defer t.deinit();
    const ts = &t.text;
    if (@hasField(@TypeOf(ts.*), "wrap_rule") and @hasDecl(@TypeOf(ts.*), "breakAtGlyphs")) {
        const style: types.TextStyle = .{ .size = 13 };
        const s = "aa bbb ccc";
        const w = ts.width("aa bbb", style) + 0.5;
        // The typesetter keeps "bbb": its space doesn't count.
        const native = try ts.breakLines(s, style, &.{}, w);
        defer std.testing.allocator.free(native);
        try std.testing.expectEqualStrings("aa bbb", s[native[0].start..native[0].end]);
        // GPUI counts the space after it: "bbb" goes down.
        const g = try ts.breakAtGlyphs(s, style, &.{}, w);
        defer std.testing.allocator.free(g);
        try std.testing.expectEqual(@as(usize, 3), g.len);
        try std.testing.expectEqualStrings("aa", s[g[0].start..g[0].end]);
        try std.testing.expectEqualStrings("bbb", s[g[1].start..g[1].end]);
        try std.testing.expectEqualStrings("ccc", s[g[2].start..g[2].end]);
        // Paragraphs break on their own; an empty one is a line.
        const p = try ts.breakAtGlyphs("one\n\ntwo", style, &.{}, 500);
        defer std.testing.allocator.free(p);
        try std.testing.expectEqual(@as(usize, 3), p.len);
        try std.testing.expectEqual(p[1].start, p[1].end);
        // A word longer than the line breaks inside it.
        const long = try ts.breakAtGlyphs("averyveryverylongword", style, &.{}, 40);
        defer std.testing.allocator.free(long);
        try std.testing.expect(long.len > 1);
        for (long) |l| try std.testing.expect(l.width <= 40 or l.end - l.start == 1);
        // Closing punctuation stays on its word.
        const T = @TypeOf(ts.*);
        try std.testing.expect(T.isWordChar(',') and !T.isWordChar(')') and T.isWordChar(0xE9));
    }
}
