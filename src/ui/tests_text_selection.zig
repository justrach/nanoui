//! End-to-end pointer double-click tests through `ui.Tester` verifying UAX #29
//! extended grapheme cluster and Unicode word/punctuation boundaries.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const SelectableText = struct {
    text: []const u8,
    fn view(s: *SelectableText, c: *ui.Context) void {
        const d = ui.div(c).column().sizeFull().p(16);
        c.node(d.index).style.selectable = true;
        defer d.end();
        ui.text(c, s.text, .{ .size = 14 });
    }
};

fn glyphX(layout: anytype, at: usize) f32 {
    for (layout.glyphs) |g| if (g.index >= at) return g.x;
    return layout.width;
}

test "double-click preserves whole Unicode graphemes across both halves of a glyph cell" {
    for ([_][]const u8{ "a\u{301}", "👍🏽", "🇸🇬", "👩‍💻", "👨‍👩‍👧‍👦" }) |cluster| {
        const str = try std.fmt.allocPrint(testing.allocator, "Start {s} end", .{cluster});
        defer testing.allocator.free(str);
        var s: SelectableText = .{ .text = str };
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&s, SelectableText.view), .{ .width = 400, .height = 120 });
        defer t.deinit();
        t.settle(1);

        const r = t.findText(str).?;
        const lay = t.ctx.text.layout(str, .{ .size = 14 });
        const left = r.x + glyphX(lay, 6);
        const width = glyphX(lay, 6 + cluster.len) - glyphX(lay, 6);
        if (width <= 0) continue;

        for ([_]f32{ 0.01, 0.49, 0.51, 0.99 }) |fraction| {
            t.doubleClick(left + width * fraction, r.y + r.h / 2);
            t.settle(0.1);
            t.textOps(&.{.{ .command = .copy }});
            try testing.expectEqualStrings(cluster, t.clipboard.items);
        }
    }
}

test "double-click keeps identifier Unicode word and punctuation boundaries" {
    const str = "alpha_beta42, café! 中文.";
    var s: SelectableText = .{ .text = str };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, SelectableText.view), .{ .width = 400, .height = 120 });
    defer t.deinit();
    t.settle(1);

    const r = t.findText(str).?;
    const lay = t.ctx.text.layout(str, .{ .size = 14 });
    for ([_]struct { start: usize, end: usize, expected: []const u8 }{
        .{ .start = 0, .end = 1, .expected = "alpha_beta42" },
        .{ .start = 11, .end = 12, .expected = "alpha_beta42" },
        .{ .start = 12, .end = 13, .expected = "," },
        .{ .start = 14, .end = 15, .expected = "café" },
        .{ .start = 19, .end = 20, .expected = "!" },
        .{ .start = 21, .end = 24, .expected = "中文" },
        .{ .start = 27, .end = 28, .expected = "." },
    }) |hit| {
        const left = r.x + glyphX(lay, hit.start);
        const width = glyphX(lay, hit.end) - glyphX(lay, hit.start);
        for ([_]f32{ 0.01, 0.99 }) |fraction| {
            t.doubleClick(left + width * fraction, r.y + r.h / 2);
            t.settle(0.1);
            t.textOps(&.{.{ .command = .copy }});
            try testing.expectEqualStrings(hit.expected, t.clipboard.items);
        }
    }
}
