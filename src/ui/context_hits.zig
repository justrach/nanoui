//! Pointer ownership from painted hit boxes, with optional keyboard modality.
const std = @import("std");
const context = @import("context.zig");
const Context = context.Context;
const none = context.none;

pub fn commitHits(c: *Context) void {
    std.mem.swap(std.ArrayList(context.Hit), &c.hits, &c.next_hits);
    computeHot(c);
}

/// Pointer input re-arms hover; committing a frame alone must not do so.
pub fn updateHot(c: *Context) void {
    c.keyboard_modality = false;
    computeHot(c);
}

pub fn noteModality(c: *Context) void {
    if (!c.input.hasKeyboardInput()) return;
    c.keyboard_modality = true;
    if (c.keyboard_hides_hover) {
        c.hot = 0;
        c.hot_index = none;
        c.hot_path.clearRetainingCapacity();
    }
}

pub fn computeHot(c: *Context) void {
    c.hot = 0;
    c.hot_index = none;
    c.hot_path.clearRetainingCapacity();
    if (c.keyboard_hides_hover and c.keyboard_modality) return;
    var i = c.hits.items.len;
    while (i > 0) {
        i -= 1;
        const h = c.hits.items[i];
        if (!h.scroll and !h.scroll_x and h.rect.contains(c.input.mouse)) {
            c.hot = h.id;
            c.hot_index = h.index;
            hotPath(c, h);
            return;
        }
    }
}

/// Interactive ancestors in the previous painted tree.
fn hotPath(c: *Context, h: context.Hit) void {
    if (h.index >= c.nodes.items.len or c.nodes.items[h.index].id != h.id) return;
    var at = h.index;
    while (at != none) {
        const n = c.nodes.items[at];
        if (n.interactive) c.hot_path.append(c.gpa, n.id) catch return;
        at = n.parent;
    }
}

/// Whether the pointer is over text that selects (as last painted):
/// for the cursor when it moves without a frame being drawn.
pub fn pointerOverText(c: *Context) bool {
    for (c.selection.lines.items) |r| if (r.contains(c.input.mouse)) return true;
    return c.selection.dragging;
}

pub fn pointerUp(c: *Context) void {
    c.input.down = false;
    c.input.released = true;
}

/// The secondary button went down (`Input.secondary`): no press, and
/// the focus stays where it was.
pub fn secondaryDown(c: *Context) void {
    c.updateHot();
    c.input.secondary = true;
}

pub fn pointerDown(c: *Context) void {
    c.updateHot();
    c.input.down = true;
    c.input.pressed = true;
    c.right_press = c.input.button == .right or (@import("keys.zig").mac and c.input.button == .left and c.input.ctrl);
    if (@import("scroll.zig").tryPressScrollbar(c)) return;
    if (c.hot == 0) c.focus = 0;
}
