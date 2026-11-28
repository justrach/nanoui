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
    const ts = t.text;
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
