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
/// input, and the last frame's tree is still there.
pub fn takeScrollX(c: *Context) void {
    const dx = c.input.scroll.x;
    if (dx == 0) return;
    var id: u64 = 0;
    for (c.nodes.items) |nd| {
        if (!nd.style.scroll_x) continue;
        const r = c.rects.get(nd.id) orelse continue;
        if (r.contains(c.input.mouse)) id = nd.id;
    }
    if (id == 0) return;
    const g = c.scroll_x.getOrPut(c.gpa, id) catch return;
    g.value_ptr.* = @max(0, (if (g.found_existing) g.value_ptr.* else 0) - dx);
}
