//! Scrollbar thumb dragging, shared by every window backend and the Tester.
//! The geometry mirrors paint.zig; the drag itself is applied before the
//! next view build so virtualized lists immediately build the newly visible rows.
const std = @import("std");
const Context = @import("context.zig").Context;

pub const Drag = struct {
    id: u64,
    start_y: f32,
    start_offset: f32,
    max_scroll: f32,
    travel: f32,
};

/// Starts when the primary button goes down on a visible scrollbar thumb.
pub fn begin(c: *Context) bool {
    var i = c.hits.items.len;
    while (i > 0) {
        i -= 1;
        const h = c.hits.items[i];
        if (!h.scroll or !h.rect.contains(c.input.mouse)) continue;
        if (c.input.mouse.x < h.rect.x + h.rect.w - 10) return false;
        if (h.index >= c.nodes.items.len) return false;
        const n = c.node(h.index);
        if (n.id != h.id or n.first_child == @import("context.zig").none) return false;
        const first = c.node(n.first_child).rect;
        const last = c.node(n.last_child).rect;
        const content_h = last.y + last.h - first.y + n.style.padding.vertical();
        const view_h = n.rect.h;
        if (content_h <= view_h + 0.5) return false;
        const max_scroll = content_h - view_h;
        const overlay = n.style.scrollbar == .overlay;
        const inset: f32 = if (overlay) 4 else 2;
        const track = view_h - 2 * inset;
        const bar_h = if (overlay)
            @max(24, track * view_h / content_h)
        else
            @max(24, view_h * view_h / content_h);
        const thumb_h = if (overlay) bar_h else bar_h - 4;
        const travel = track - thumb_h;
        if (travel <= 0) return false;
        const offset = std.math.clamp((c.scroll.get(n.id) orelse 0) / max_scroll, 0, 1);
        const thumb_y = n.rect.y + inset + travel * offset;
        if (c.input.mouse.y < thumb_y or c.input.mouse.y > thumb_y + thumb_h) return false;
        c.scrollbar_drag = .{
            .id = n.id,
            .start_y = c.input.mouse.y,
            .start_offset = offset * max_scroll,
            .max_scroll = max_scroll,
            .travel = travel,
        };
        return true;
    }
    return false;
}

/// Applies the pointer's latest position before a frame builds its view.
pub fn update(c: *Context) void {
    const d = c.scrollbar_drag orelse return;
    const offset = d.start_offset + (c.input.mouse.y - d.start_y) * d.max_scroll / d.travel;
    c.scroll.put(c.gpa, d.id, std.math.clamp(offset, 0, d.max_scroll)) catch {};
}

/// Consumes the release that ends a drag, so it can't click what is below.
pub fn end(c: *Context) bool {
    if (c.scrollbar_drag == null) return false;
    c.scrollbar_drag = null;
    return true;
}
