//! Scroll-linked values, as Motion's `useScroll` / `useTransform` and
//! gpui-motion's `scroll_progress`: a scroller's offset becomes a number
//! in [0, 1], then a range, without an extra object to keep.
const std = @import("std");
const Context = @import("../context.zig").Context;
const types = @import("../types.zig");
const motion = @import("motion.zig");
const Transition = @import("channel.zig").Transition;

/// How far scroller `id` has gone: 0 at the top, 1 at `scroll_max`.
pub fn of(c: *Context, id: u64) f32 {
    return progress(c.scroll.get(id) orelse 0, c.scroll_max.get(id) orelse 0);
}

/// `offset` of `max` as a number in [0, 1].
pub fn progress(offset: f32, max: f32) f32 {
    if (max <= 0) return 0;
    return std.math.clamp(offset / max, 0, 1);
}

/// `t` of `from` mapped onto `to`. `clamp_out` keeps the result inside `to`.
pub fn remap(t: f32, from: [2]f32, to: [2]f32, clamp_out: bool) f32 {
    const span = from[1] - from[0];
    const u = if (@abs(span) < 1e-9) 0 else (t - from[0]) / span;
    const v = to[0] + u * (to[1] - to[0]);
    if (!clamp_out) return v;
    const lo = @min(to[0], to[1]);
    const hi = @max(to[0], to[1]);
    return std.math.clamp(v, lo, hi);
}

/// A number following scroller `id`: progress remapped onto `range`,
/// eased by `tr` (`.instant` tracks the wheel with no lag).
pub fn value(c: *Context, key: []const u8, id: u64, range: [2]f32, tr: Transition) f32 {
    const p = of(c, id);
    return motion.number(c, key, range[0] + (range[1] - range[0]) * p, tr);
}

/// How much of `item` lies in `viewport` (0 hidden, 1 fully inside).
pub fn inView(viewport: types.Rect, item: types.Rect) f32 {
    const ix = @max(viewport.x, item.x);
    const iy = @max(viewport.y, item.y);
    const ax = @min(viewport.x + viewport.w, item.x + item.w);
    const ay = @min(viewport.y + viewport.h, item.y + item.h);
    const iw = @max(0, ax - ix);
    const ih = @max(0, ay - iy);
    const area = item.w * item.h;
    if (area <= 0) return 0;
    return (iw * ih) / area;
}

test "progress is 0 at the top and 1 at the end" {
    try std.testing.expectEqual(@as(f32, 0), progress(0, 0));
    try std.testing.expectEqual(@as(f32, 0), progress(0, 200));
    try std.testing.expectEqual(@as(f32, 0.5), progress(100, 200));
    try std.testing.expectEqual(@as(f32, 1), progress(200, 200));
    try std.testing.expectEqual(@as(f32, 1), progress(400, 200));
}

test "remap maps a range onto another and can clamp" {
    try std.testing.expectEqual(@as(f32, 50), remap(0.25, .{ 0, 1 }, .{ 0, 200 }, true));
    try std.testing.expectEqual(@as(f32, 200), remap(2, .{ 0, 1 }, .{ 0, 200 }, true));
    try std.testing.expectEqual(@as(f32, 400), remap(2, .{ 0, 1 }, .{ 0, 200 }, false));
}

test "inView is the overlapping fraction of the item" {
    const vp: types.Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    try std.testing.expectEqual(@as(f32, 1), inView(vp, .{ .x = 10, .y = 10, .w = 20, .h = 20 }));
    try std.testing.expectEqual(@as(f32, 0), inView(vp, .{ .x = 200, .y = 0, .w = 20, .h = 20 }));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), inView(vp, .{ .x = 50, .y = 0, .w = 100, .h = 100 }), 1e-5);
}
