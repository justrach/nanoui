//! Offscreen rendering must clear with the theme resolved by the view.
const std = @import("std");
const ui = @import("ui.zig");
const testing = std.testing;

const Scene = struct {
    transparent: bool = true,
    fn view(s: *Scene, c: *ui.Context) void {
        c.theme.background = if (s.transparent) .transparent else ui.Color.hex(0x224466);
        // Leave the root unpainted so the renderer's clear is observable.
        c.node(0).style.background = null;
    }
};

test "offscreen clear follows the view's live theme across transparency changes" {
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 8, .height = 8 });
    defer t.deinit();
    for ([_]bool{ true, false, true }) |transparent| {
        s.transparent = transparent;
        t.frame();
        const pixels = try t.render(testing.allocator);
        defer pixels.deinit(testing.allocator);
        try testing.expectEqual(@as(u8, if (transparent) 0 else 255), pixels.bytes[3]);
        if (!transparent) try testing.expectEqualSlices(u8, &.{ 0x66, 0x44, 0x22, 255 }, pixels.bytes[0..4]);
    }
}
