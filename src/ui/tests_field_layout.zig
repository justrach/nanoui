//! Wrapping depends on the preceding layout, not on focus animation.
const std = @import("std");
const ui = @import("ui.zig");
const testing = std.testing;
const Scene = struct {
    buffer: ui.TextBuffer = .{},
    anchor: ?ui.Rect = null,
    id: u64 = 0,
    width: f32 = 140,
    fn view(s: *Scene, c: *ui.Context) void {
        s.id = c.peekId(null);
        s.anchor = c.rects.get(s.id);
        _ = ui.textField(c, &s.buffer, .{ .width = .{ .px = s.width }, .multiline = true, .bare = true, .line_height = 20 });
    }
};

test "multiline layout settles its anchor without a focus animation" {
    var s: Scene = .{};
    defer s.buffer.deinit();
    s.buffer.set("Synthetic text wraps into several lines without keyboard focus or any incidental animation.");
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 400, .height = 400 });
    defer t.deinit();
    t.settle(0.2);
    const laid_out = t.ctx.rects.get(s.id).?;
    try testing.expect(laid_out.h > 40);
    try testing.expectEqual(laid_out.h, s.anchor.?.h);
    try testing.expect(!t.ctx.animating);
    s.width = 300;
    t.settle(0.2);
    const wider = t.ctx.rects.get(s.id).?;
    try testing.expect(wider.h < laid_out.h);
    try testing.expectEqual(wider.h, s.anchor.?.h);
    try testing.expect(!t.ctx.animating);
}
