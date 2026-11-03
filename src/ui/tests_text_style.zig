//! Text styles: wrapped text kept to `max_lines`, and tabular digits.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const long = "A summary that runs on for many words, well past the two lines its little card has room for, and then some more.";

const Card = struct {
    fn view(_: *Card, c: *ui.Context) void {
        ui.column(c, .{ .width = .{ .px = 120 } });
        defer ui.end(c);
        ui.text(c, long, .{ .size = 13, .wrap = true, .max_lines = 2 });
        ui.text(c, "Fits.", .{ .size = 13, .wrap = true, .max_lines = 2 });
    }
};

test "max_lines keeps two lines ending in an ellipsis" {
    var s: Card = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Card.view), .{});
    defer t.deinit();
    var cut: u32 = 0;
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.endsWith(u8, tx.str, "…")) {
            cut += 1;
            try testing.expectEqual(@as(usize, 2), tx.lines.len);
            try testing.expectEqual(tx.str.len, tx.lines[1].end);
            try testing.expect(std.mem.startsWith(u8, long, tx.str[0 .. tx.str.len - "…".len]));
            try testing.expect(tx.lines[1].width <= n.rect.w + 0.5);
            try testing.expectEqual(2 * t.text.lineHeight(tx.style), n.rect.h);
        },
        else => {},
    };
    try testing.expectEqual(@as(u32, 1), cut);
    try testing.expect(t.hasText("Fits."));
}

test "tabular digits: 111 and 888 measure the same" {
    var s: Card = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Card.view), .{});
    defer t.deinit();
    const style: ui.TextStyle = .{ .size = 13, .tabular = true };
    try testing.expectApproxEqAbs(t.text.width("111", style), t.text.width("888", style), 0.01);
    try testing.expectEqual(@as(usize, 3), t.text.layout("111", style).glyphs.len);
    // Digit widths are equal even on fonts whose defaults are already tabular.
}
