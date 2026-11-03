//! Adjustable accessibility elements: VoiceOver's AXIncrement and
//! AXDecrement come to the box's `interact` as `a11y_step`.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const Divider = struct {
    id: u64 = 0,
    steps: i32 = 0,
    fn view(s: *Divider, c: *ui.Context) void {
        const i = c.leaf(.{ .width = .{ .px = 7 }, .height = .{ .px = 100 } }, .none, null);
        const it = c.interact(i, .{});
        c.adjustable(i, .{ .role = .splitter, .label = "Column width", .value = "232" });
        s.id = it.id;
        s.steps += it.a11y_step;
    }
};

test "a11y increment steps +1 on the next frame" {
    var s: Divider = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Divider.view), .{});
    defer t.deinit();
    const items = t.ctx.a11y_items.items;
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expect(items[0].adjustable);
    try testing.expectEqual(ui.A11yRole.splitter, items[0].role);
    try testing.expectEqualStrings("232", items[0].value);
    try testing.expectEqual(@as(i32, 0), s.steps);
    // As `accessibilityPerformIncrement` does.
    t.ctx.a11yStep(s.id, 1);
    t.frame();
    try testing.expectEqual(@as(i32, 1), s.steps);
    // An edge: the next frame has none.
    t.frame();
    try testing.expectEqual(@as(i32, 1), s.steps);
    t.ctx.a11yStep(s.id, -1);
    t.frame();
    try testing.expectEqual(@as(i32, 0), s.steps);
    // Another box's step is not this one's.
    t.ctx.a11yStep(s.id +% 1, 1);
    t.frame();
    try testing.expectEqual(@as(i32, 0), s.steps);
}
