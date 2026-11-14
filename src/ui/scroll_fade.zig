//! A scrolling viewport's hidden-edge mask, in points. Render the content
//! into a transparent group, then multiply its premultiplied color once.
const std = @import("std");

pub const Edges = struct {
    top: f32 = 0,
    bottom: f32 = 0,

    pub fn active(e: Edges) bool {
        return e.top > 0 or e.bottom > 0;
    }

    /// Logical offsets are clamped before testing hidden edges, including
    /// fractional scroll positions and rubber-band overscroll at either end.
    pub fn of(height: f32, offset: f32, max_scroll: f32, length: f32) Edges {
        if (!std.math.isFinite(height) or !std.math.isFinite(offset) or !std.math.isFinite(max_scroll) or !std.math.isFinite(length)) return .{};
        if (height <= 0 or max_scroll <= 0 or length <= 0) return .{};
        const fade = @min(length, height / 2);
        const at = std.math.clamp(offset, 0, max_scroll);
        return .{ .top = if (at > 0) fade else 0, .bottom = if (at < max_scroll) fade else 0 };
    }
};

/// `layer_end.border_color`: viewport top/bottom and the two fade lengths.
/// Zero lengths preserve the existing ordinary grouped-opacity behavior.
pub fn alpha(mask: [4]f32, y: f32) f32 {
    var value: f32 = 1;
    if (mask[2] > 0) value = @min(value, std.math.clamp((y - mask[0]) / mask[2], 0, 1));
    if (mask[3] > 0) value = @min(value, std.math.clamp((mask[1] - y) / mask[3], 0, 1));
    return value;
}

test "scroll fade only masks hidden edges and clamps fractional overscroll and tiny viewports" {
    const t = std.testing;
    try t.expectEqual(Edges{}, Edges.of(260, 0, 0, 12));
    try t.expectEqual(Edges{}, Edges.of(0, 10, 100, 12));
    try t.expectEqual(Edges{}, Edges.of(260, 10, 100, 0));
    try t.expectEqual(Edges{ .bottom = 12 }, Edges.of(260, -40, 100, 12));
    try t.expectEqual(Edges{ .bottom = 12 }, Edges.of(260, 0, 100, 12));
    try t.expectEqual(Edges{ .top = 12, .bottom = 12 }, Edges.of(260, 0.25, 100, 12));
    try t.expectEqual(Edges{ .top = 12, .bottom = 12 }, Edges.of(260, 99.75, 100, 12));
    try t.expectEqual(Edges{ .top = 12 }, Edges.of(260, 100, 100, 12));
    try t.expectEqual(Edges{ .top = 12 }, Edges.of(260, 140, 100, 12));
    try t.expectEqual(Edges{ .top = 3, .bottom = 3 }, Edges.of(6, 50, 100, 12));
    try t.expectEqual(Edges{}, Edges.of(260, std.math.nan(f32), 100, 12));
    try t.expectEqual(@as(f32, 1), alpha(.{ 10, 110, 0, 0 }, 10));
    try t.expectEqual(@as(f32, 0), alpha(.{ 10, 110, 12, 12 }, 10));
    try t.expectApproxEqAbs(@as(f32, 0.5), alpha(.{ 10, 110, 12, 12 }, 16), 0.0001);
    try t.expectEqual(@as(f32, 1), alpha(.{ 10, 110, 12, 12 }, 60));
    try t.expectEqual(@as(f32, 0), alpha(.{ 10, 110, 12, 12 }, 110));
}
