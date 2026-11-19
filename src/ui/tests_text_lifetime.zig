//! Text from a buffer that goes when the view returns: `text`, `richText`
//! and `tooltip` copy what they're given into the frame, which lays it out
//! and paints it after the view function returns.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const Scene = struct {
    label: [16]u8 = undefined,
    rich: [16]u8 = undefined,
    spans: [1]ui.Span = undefined,
    tip: [16]u8 = undefined,
    n: u32 = 7,

    fn view(s: *Scene, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(8), .gap = 4 });
        defer ui.end(c);
        // At (8, 8), 80 by 20.
        const d = ui.div(c).size(80, 20);
        _ = d.tooltip(std.fmt.bufPrint(&s.tip, "{d} to sync", .{s.n}) catch unreachable, .{ .delay = 0 });
        d.end();
        ui.text(c, std.fmt.bufPrint(&s.label, "{d} files", .{s.n}) catch unreachable, .{});
        s.spans = .{.{ .start = 0, .end = 1, .color = .hex(0xff0000) }};
        ui.richText(c, std.fmt.bufPrint(&s.rich, "{d} new", .{s.n}) catch unreachable, &s.spans, .{});
        // As a buffer on the stack is, once the view returns: reused.
        @memset(&s.label, 'x');
        @memset(&s.rich, 'x');
        @memset(&s.tip, 'x');
        s.spans[0] = .{ .start = 0, .end = 0 };
    }
};

test "text and richText draw what they were given, not what replaced it" {
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{});
    defer t.deinit();
    t.frame();
    try testing.expect(t.hasText("7 files"));
    try testing.expect(t.hasText("7 new"));
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, "7 new")) {
            try testing.expectEqual(@as(usize, 1), tx.spans.len);
            try testing.expectEqual(@as(u32, 1), tx.spans[0].end);
        },
        else => {},
    };
}

test "a tooltip draws the text it was given, after the view returns" {
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{});
    defer t.deinit();
    t.frame();
    t.moveTo(20, 15);
    t.frame();
    try testing.expectEqualStrings("7 to sync", t.tooltipText().?);
    try testing.expect(t.hasText("7 to sync"));
}
