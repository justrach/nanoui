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
