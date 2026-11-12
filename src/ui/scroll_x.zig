//! Scroll offsets set by hand and by the wheel's x (`Style.scroll_x`);
//! `layout.arrange` clamps them to the content.
const std = @import("std");
const types = @import("types.zig");
const Context = @import("context.zig").Context;

pub const Axis = enum { x, y };

/// How far a finger moves before it scrolls rather than presses, points.
pub const touch_slop: f32 = 10;
/// UIScrollView's normal deceleration: speed kept per millisecond.
pub const fling_deceleration: f64 = 0.998;
/// Slower than this, points per second, a fling ends.
pub const min_fling_speed: f32 = 20;

/// Initial scroll displacement once a finger passes `touch_slop`: subtracts
/// `touch_slop` so content starts moving continuously from 0 instead of
/// jumping by `touch_slop` on the first frame.
pub fn scrollStartDelta(total: f32) f32 {
    if (total > touch_slop) return total - touch_slop;
    if (total < -touch_slop) return total + touch_slop;
    return 0;
}

/// One step of a fling's speed over `dt_sec` seconds (`dt` capped to 50 ms),
/// returning 0 once speed drops below `min_fling_speed`.
pub fn stepFlingSpeed(speed: f32, dt_sec: f64) f32 {
    if (speed == 0) return 0;
    const dt = @max(0.0, @min(dt_sec, 0.05));
    const next: f32 = speed * @as(f32, @floatCast(std.math.pow(f64, fling_deceleration, dt * 1000.0)));
    return if (@abs(next) < min_fling_speed) 0 else next;
}

/// The innermost scrolling box along `axis` under `p` in the last frame, if
/// any, stopping at a wheel-owning box.
pub fn scrollerAtAxis(c: *const Context, p: types.Point, axis: Axis) ?u64 {
    const hits = c.hits.items;
    var i = hits.len;
    while (i > 0) {
        i -= 1;
        const h = hits[i];
        if (!h.rect.contains(p)) continue;
        if (h.wheel) return null;
        if (if (axis == .x) h.scroll_x else h.scroll) return h.id;
    }
    return null;
}

/// Chooses the scroll axis for a touch drag `(tx, ty)` starting at `start`.
pub fn pickTouchAxis(c: *const Context, start: types.Point, tx: f32, ty: f32) ?Axis {
    const has_x = @abs(tx) > touch_slop and scrollerAtAxis(c, start, .x) != null;
    const has_y = @abs(ty) > touch_slop and scrollerAtAxis(c, start, .y) != null;
    if (has_x and has_y) return if (@abs(tx) > @abs(ty)) .x else .y;
    if (has_x and @abs(tx) >= @abs(ty)) return .x;
    if (has_y and @abs(ty) >= @abs(tx)) return .y;
    return null;
}

/// Scrolls the box under `at` along `axis` by `delta` points (the finger's way).
pub fn applyTouchDelta(c: *Context, at: types.Point, axis: Axis, delta: f32) void {
    const prev = c.input.mouse;
    c.input.mouse = at;
    defer c.input.mouse = prev;
    if (axis == .y) {
        _ = c.applyScroll(delta);
    } else {
        const prev_sx = c.input.scroll.x;
        c.input.scroll.x = delta;
        takeScrollX(c);
        c.input.scroll.x = prev_sx;
    }
}

/// Sets box `id`'s scroll offset along `axis` (clamped by the next layout):
/// `c.setScroll(id, .x, 120)`.
pub fn setScroll(c: *Context, id: u64, axis: Axis, value: f32) void {
    const map = if (axis == .x) &c.scroll_x else &c.scroll;
    map.put(c.gpa, id, @max(0, value)) catch {};
}

/// A vertical scroll box (`ui.scroll`'s) under `key`, open until `ui.end`:
/// its id, for reading and setting where it is scrolled to.
pub fn scrollBox(c: *Context, style: @import("types.zig").Style, key: ?[]const u8) u64 {
    var s = style;
    s.scroll = true;
    s.direction = .column;
    return c.node(c.open(s, key)).id;
}

/// How far box `id` is scrolled along `axis`, in points, as last laid out
/// (or as set since).
pub fn scrollOffset(c: *const Context, id: u64, axis: Axis) f32 {
    const map = if (axis == .x) &c.scroll_x else &c.scroll;
    return map.get(id) orelse 0;
}

/// Scrolls box `id` to `value` points along `axis`: the next layout keeps
/// it within the content. A `follow_end` box set short of its end stops
/// following until it is back there.
pub fn setScrollOffset(c: *Context, id: u64, axis: Axis, value: f32) void {
    setScroll(c, id, axis, value);
}

/// The furthest box `id` scrolls down, as last laid out (0: it all fits).
pub fn scrollMax(c: *const Context, id: u64) f32 {
    return c.scroll_max.get(id) orelse 0;
}

/// Whether box `id` is scrolled to its end (within a point), or has
/// nothing to scroll: where a chat's thread follows its tail.
pub fn atEnd(c: *const Context, id: u64) bool {
    return scrollOffset(c, id, .y) >= scrollMax(c, id) - 1;
}

/// Scrolls box `id` to its end at the next layout (a `follow_end` box
/// follows from there again).
pub fn scrollToEnd(c: *Context, id: u64) void {
    setScrollOffset(c, id, .y, std.math.floatMax(f32));
}

/// Moves the innermost `scroll_x` box under the pointer in the last frame
/// by the wheel's x. Run before the view is built: a rebuild clears the
/// input. Painted hits preserve clipping, layers and wheel ownership.
pub fn takeScrollX(c: *Context) void {
    const dx = c.input.scroll.x;
    if (dx == 0) return;
    var i = c.hits.items.len;
    while (i > 0) {
        i -= 1;
        const h = c.hits.items[i];
        if (!h.rect.contains(c.input.mouse)) continue;
        // Leave the delta for the view, not a scroller behind its wheel box.
        if (h.wheel) return;
        if (!h.scroll_x) continue;
        const g = c.scroll_x.getOrPut(c.gpa, h.id) catch return;
        g.value_ptr.* = @max(0, (if (g.found_existing) g.value_ptr.* else 0) - dx);
        return;
    }
}
