//! A scrolling box's overlay bar (`Scrollbar.overlay`) through the Tester:
//! nothing while still, the bar while and just after it scrolls, gone once
//! the linger and fade are over; and the stroke weight text gets from its
//! colour (`atlas.dilationFor`).
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");

const bar_color: ui.Color = .{ .r = 0.2, .g = 0.6, .b = 0.9, .a = 1 };

const Scene = struct {
    pub fn view(_: *Scene, c: *ui.Context) void {
        ui.scroll(c, .{ .width = .fill, .height = .fill, .scrollbar = .{ .overlay = bar_color } });
        defer ui.end(c);
        for (0..40) |_| _ = c.leaf(.{ .width = .fill, .height = .{ .px = 30 } }, .none, null);
    }
};

/// The bar's quad this frame, if one is drawn: the instance in the bar's
/// colour.
fn bar(t: *ui.Tester) ?gpu.Instance {
    const want = gpu.color4(bar_color);
    for (t.instances.items) |i| if (i.color[0] == want[0] and i.color[1] == want[1] and i.color[3] > 0) return i;
    return null;
}

test "an overlay bar shows while its box scrolls, then fades out" {
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 200, .height = 300 });
    defer t.deinit();
    t.settle(1);
    try testing.expect(bar(&t) == null);
    t.scroll(100, 150, -120);
    t.frame();
    const shown = bar(&t) orelse return error.NoBar;
    // 3 points wide, 2 from the edge.
    try testing.expectApproxEqAbs(@as(f32, 3), shown.rect[2], 0.01);
    try testing.expectApproxEqAbs(@as(f32, 200 - 2 - 3), shown.rect[0], 0.01);
    // Still there inside the linger, gone after it and the fade.
    t.advance(1.0);
    try testing.expect(bar(&t) != null);
    t.advance(1.0);
    try testing.expect(bar(&t) == null);
    // On its strip, it's held, and wider.
    t.moveTo(195, 150);
    t.frame();
    try testing.expectApproxEqAbs(@as(f32, 5), (bar(&t) orelse return error.NoBar).rect[2], 0.01);
}

test "lighter text is drawn with thicker strokes, none with smoothing off" {
    const atlas = @import("atlas.zig");
    const was = atlas.smoothing_allowed;
    defer atlas.smoothing_allowed = was;
    atlas.smoothing_allowed = true;
    try testing.expectEqual(@as(u8, 4), atlas.dilationFor(1, 1, 1));
    try testing.expectEqual(@as(u8, 0), atlas.dilationFor(0, 0, 0));
    try testing.expectEqual(@as(u8, 2), atlas.dilationFor(0.5, 0.5, 0.5));
    // Luminance weighs green most: pure green is lighter than pure blue.
    try testing.expect(atlas.dilationFor(0, 1, 0) > atlas.dilationFor(0, 0, 1));
    atlas.smoothing_allowed = false;
    try testing.expectEqual(@as(u8, 0), atlas.dilationFor(1, 1, 1));
}
