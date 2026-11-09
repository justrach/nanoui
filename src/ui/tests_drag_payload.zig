//! A value dragged from one box to another (`ui.dragSource`,
//! `ui.dropTarget`): it holds the pointer past its own box, lands once on
//! the box it is let go over, not on one it only crossed, never from a
//! press that didn't move, and not after Escape.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const Scene = struct {
    /// The last frame's B box, for the drop.
    b: ?ui.Rect = null,
    dropped: ?u64 = null,
    drops: u32 = 0,
    over_b: bool = false,
    clicks: u32 = 0,
    released: bool = false,

    fn view(s: *Scene, c: *ui.Context) void {
        ui.row(c, .{ .width = .fill, .height = .fill, .gap = 100, .padding = .all(20) });
        defer ui.end(c);
        // A, the source, carrying 42.
        const a = c.open(.{ .width = .{ .px = 80 }, .height = .{ .px = 60 }, .background = ui.Color.hex(0x335577) }, "box-a");
        const src = ui.dragSource(c, a, 42);
        if (src.interaction.clicked and !src.released) s.clicks += 1;
        if (src.released) s.released = true;
        c.end();
        // Between them, a panel boundary: a clipped box the drag crosses.
        _ = c.open(.{ .width = .{ .px = 40 }, .height = .fill, .clip = true }, "gap");
        c.end();
        const b = c.open(.{ .width = .{ .px = 80 }, .height = .{ .px = 60 }, .background = ui.Color.hex(0x775533) }, "box-b");
        c.end();
        s.b = c.rects.get(c.node(b).id);
        if (s.b) |r| {
            s.over_b = ui.dragOver(c, r) != null;
            if (ui.dropTarget(c, r)) |p| {
                s.dropped = p;
                s.drops += 1;
            }
        }
    }
};

fn start(t: *ui.Tester, s: *Scene) !void {
    try t.init(testing.allocator, .init(s, Scene.view), .{ .width = 480, .height = 120, .scale = 1 });
    t.settle(0.1);
}

test "drag payload: from box A it drops on box B" {
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    const b = s.b.?;
    t.down(40, 50);
    // Out of A, over the gap: dragging, not over B yet.
    t.move(120, 50);
    try testing.expect(ui.dragging(&t.ctx) != null);
    try testing.expectEqual(@as(u64, 42), ui.dragging(&t.ctx).?.payload);
    try testing.expect(!s.over_b);
    t.move(b.x + 20, b.y + 20);
    try testing.expect(s.over_b);
    try testing.expect(s.dropped == null);
    t.up();
    try testing.expectEqual(@as(?u64, 42), s.dropped);
    try testing.expectEqual(@as(u32, 1), s.drops);
    try testing.expect(s.released);
    try testing.expectEqual(@as(u32, 0), s.clicks);
    // Over: further frames drop nothing again.
    t.frame();
    t.frame();
    try testing.expectEqual(@as(u32, 1), s.drops);
    try testing.expect(ui.dragging(&t.ctx) == null);
}

test "drag payload: a still press clicks, a drop elsewhere and Escape land nothing" {
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    const b = s.b.?;
    t.click(40, 50);
    try testing.expectEqual(@as(u32, 1), s.clicks);
    try testing.expect(s.dropped == null);
    // Across B and let go past it: no drop.
    t.down(40, 50);
    t.move(b.x + 20, b.y + 20);
    t.move(470, 110);
    t.up();
    try testing.expect(s.dropped == null);
    // Over B, then Escape: given up before the release.
    t.down(40, 50);
    t.move(b.x + 20, b.y + 20);
    t.key(.escape);
    try testing.expect(ui.dragging(&t.ctx) == null);
    t.up();
    try testing.expect(s.dropped == null);
    try testing.expectEqual(@as(u32, 0), s.drops);
}
