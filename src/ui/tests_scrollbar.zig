const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const Page = struct {
    id: u64 = 0,
    clicks: usize = 0,

    fn view(p: *Page, c: *ui.Context) void {
        const box = ui.div(c).column().w(100).h(100).scrollY();
        defer box.end();
        p.id = c.node(box.index).id;
        for (0..20) |i| {
            ui.key(c, c.print("row-{d}", .{i}));
            const row = ui.div(c).h(10).control();
            if (row.clicked()) p.clicks += 1;
            row.end();
        }
    }
};

test "a scrollbar thumb drag scrolls and its release is not a click" {
    var p: Page = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Page.view), .{ .width = 200, .height = 120 });
    defer t.deinit();

    // 200 points of content in a 100-point view: the 50-point thumb has
    // 50 points of travel, so dragging 25 points scrolls 50 of 100.
    t.drag(96, 20, 96, 45);
    try testing.expectApproxEqAbs(@as(f32, 50), t.ctx.scroll.get(p.id) orelse 0, 0.001);
    try testing.expectEqual(@as(usize, 0), p.clicks);
}

test "a track press jumps to the pointer and its drag keeps scrolling" {
    var p: Page = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Page.view), .{ .width = 200, .height = 120 });
    defer t.deinit();

    t.drag(96, 80, 96, 90);
    try testing.expectEqual(@as(f32, 100), t.ctx.scroll.get(p.id) orelse 0);
}
