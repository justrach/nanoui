//! Text too long for its box: cut before an ellipsis, or faded out toward
//! the box's end; either way it gives room back in a row, so what follows
//! it stays whole.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const title = "A deliberately long conversation title that cannot fit";

const Row = struct {
    how: ui.Truncate = .fade,
    fn view(s: *Row, c: *ui.Context) void {
        const col = ui.div(c).column().sizeFull().p(10).bg(.hex(0xffffff));
        defer col.end();
        const row = ui.div(c).row().w(200).gap(8).itemsCenter();
        defer row.end();
        ui.text(c, title, .{ .size = 13, .truncate = s.how, .color = .hex(0x000000) });
        ui.text(c, "6m", .{ .size = 12, .color = .hex(0x000000) });
    }
};

/// The darkest pixel of column `x` in rows [y0, y1): ink is dark on white.
fn ink(px: @import("gpu.zig").Pixels, x: usize, y0: usize, y1: usize) u8 {
    var most: u8 = 0;
    for (y0..y1) |y| most = @max(most, 255 - px.bytes[(y * px.width + x) * 4 + 1]);
    return most;
}

test "a long line fades out or ends in an ellipsis, and what follows it stays whole" {
    for ([_]ui.Truncate{ .fade, .ellipsis }) |how| {
        var s: Row = .{ .how = how };
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&s, Row.view), .{ .width = 260, .height = 40 });
        defer t.deinit();
        t.settle(1);
        const time = t.findText("6m").?;
        // The row is 200 wide from x = 10: "6m" ends inside it.
        try testing.expect(time.x + time.w <= 210.5);
        var title_box: ?ui.Rect = null;
        for (t.ctx.nodes.items) |n| if (n.content == .text and n.content.text.str.len == title.len) {
            title_box = n.rect;
        };
        const r = title_box.?;
        try testing.expect(r.w < 200 - time.w);
        const px = try t.render(testing.allocator);
        defer px.deinit(testing.allocator);
        const y0: usize = @intFromFloat(r.y * 2);
        const y1: usize = @intFromFloat((r.y + r.h) * 2);
        const end: usize = @intFromFloat((r.x + r.w) * 2);
        // Nothing past the title's box but the gap before "6m".
        try testing.expectEqual(@as(u8, 0), ink(px, end + 4, y0, y1));
        // The last 3 points (a fade's faintest), or 12 (where the
        // ellipsis is, before the slack a whole glyph's cut leaves).
        var near_end: u8 = 0;
        for (end - @as(usize, if (how == .fade) 6 else 24)..end) |x| near_end = @max(near_end, ink(px, x, y0, y1));
        var start: u8 = 0;
        for (22..40) |x| start = @max(start, ink(px, x, y0, y1));
        try testing.expect(start > 150);
        // Faded: barely any ink in the last 3 points; an ellipsis is dark.
        if (how == .fade) try testing.expect(near_end < 80) else try testing.expect(near_end > 100);
    }
}

test "a line height in points spaces wrapped lines exactly" {
    const Para = struct {
        fn view(_: *@This(), c: *ui.Context) void {
            const col = ui.div(c).column().w(120).p(0);
            defer col.end();
            ui.text(c, "one two three four five six seven eight nine ten", .{ .size = 14, .line_height = 22, .wrap = true });
        }
    };
    var p: Para = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Para.view), .{ .width = 200, .height = 200 });
    defer t.deinit();
    t.settle(1);
    for (t.ctx.nodes.items) |n| if (n.content == .text) {
        const lines: f32 = @floatFromInt(n.content.text.lines.len);
        try testing.expect(lines >= 3);
        try testing.expectEqual(22 * lines, n.rect.h);
    };
}

test "inline code at the text's own size when mono_scale is 1" {
    const Code = struct {
        fn view(_: *@This(), c: *ui.Context) void {
            const col = ui.div(c).column().p(0);
            defer col.end();
            const spans = [_]ui.Span{.{ .start = 0, .end = 8, .mono = true }};
            ui.richText(c, "fetchAll", &spans, .{ .size = 14 });
            ui.richText(c, "fetchAll", &spans, .{ .size = 14, .mono_scale = 1 });
        }
    };
    var s: Code = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Code.view), .{ .width = 300, .height = 100 });
    defer t.deinit();
    t.settle(1);
    var widths: [2]f32 = undefined;
    var n: usize = 0;
    for (t.ctx.nodes.items) |node| if (node.content == .text) {
        widths[n] = node.rect.w;
        n += 1;
    };
    try testing.expectEqual(@as(usize, 2), n);
    // Ten percent larger, to the pixel's rounding.
    try testing.expect(widths[1] > widths[0] * 1.07);
}
