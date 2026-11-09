//! A scroll box's offset set and read back (`ui.scrollBox`,
//! `ui.setScrollOffset`, `ui.scrollOffset`), its end found (`scrollAtEnd`)
//! and gone to (`scrollToEnd`), as a chat's thread following its tail.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const Scene = struct {
    id: u64 = 0,
    rows: usize = 40,
    follow: bool = false,
    set_to: ?f32 = null,
    to_end: bool = false,

    fn view(s: *Scene, c: *ui.Context) void {
        s.id = ui.scrollBox(c, .{ .width = .fill, .height = .{ .px = 200 }, .follow_end = s.follow }, "thread");
        defer ui.end(c);
        if (s.set_to) |v| ui.setScrollOffset(c, s.id, .y, v);
        s.set_to = null;
        if (s.to_end) ui.scrollToEnd(c, s.id);
        s.to_end = false;
        for (0..s.rows) |i| {
            _ = c.open(.{ .width = .fill, .height = .{ .px = 20 } }, c.print("row{d}", .{i}));
            c.end();
        }
    }
};

test "scroll: an offset set reads back, clamped to the content" {
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 300, .height = 300, .scale = 1 });
    defer t.deinit();
    t.settle(0.1);
    // 40 rows of 20 in 200: 600 to scroll.
    try testing.expectEqual(@as(f32, 600), ui.scrollMax(&t.ctx, s.id));
    try testing.expectEqual(@as(f32, 0), ui.scrollOffset(&t.ctx, s.id, .y));
    try testing.expect(!ui.scrollAtEnd(&t.ctx, s.id));
    s.set_to = 120;
    t.frame();
    try testing.expectEqual(@as(f32, 120), ui.scrollOffset(&t.ctx, s.id, .y));
    s.set_to = 5000;
    t.frame();
    try testing.expectEqual(@as(f32, 600), ui.scrollOffset(&t.ctx, s.id, .y));
    try testing.expect(ui.scrollAtEnd(&t.ctx, s.id));
    s.to_end = true;
    s.set_to = 0;
    t.frame();
    s.to_end = true;
    t.frame();
    try testing.expect(ui.scrollAtEnd(&t.ctx, s.id));
}

test "scroll: a follow_end thread follows new rows until scrolled up, then again from its end" {
    var s: Scene = .{ .follow = true };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 300, .height = 300, .scale = 1 });
    defer t.deinit();
    t.settle(0.2);
    try testing.expect(ui.scrollAtEnd(&t.ctx, s.id));
    s.rows += 5;
    t.settle(0.2);
    try testing.expectEqual(@as(f32, 700), ui.scrollOffset(&t.ctx, s.id, .y));
    // Scrolled up by the app: it stays there as rows come.
    s.set_to = 100;
    t.settle(0.2);
    s.rows += 5;
    t.settle(0.2);
    try testing.expectEqual(@as(f32, 100), ui.scrollOffset(&t.ctx, s.id, .y));
    try testing.expect(!ui.scrollAtEnd(&t.ctx, s.id));
    s.to_end = true;
    t.settle(0.2);
    s.rows += 5;
    t.settle(0.2);
    try testing.expect(ui.scrollAtEnd(&t.ctx, s.id));
    try testing.expectEqual(@as(f32, 900), ui.scrollOffset(&t.ctx, s.id, .y));
}
