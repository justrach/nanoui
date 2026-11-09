//! Scroll offsets set by hand and by the wheel's x (`Style.scroll_x`);
//! `layout.arrange` clamps them to the content.
const std = @import("std");
const Context = @import("context.zig").Context;

pub const Axis = enum { x, y };

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
