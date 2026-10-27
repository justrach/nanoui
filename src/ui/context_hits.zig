//! Resolve hover ownership from the last painted hit boxes and their ancestors.
const context = @import("context.zig");
const Context = context.Context;
const none = context.none;

pub fn computeHot(c: *Context) void {
    c.hot = 0;
    c.hot_path.clearRetainingCapacity();
    if (c.keyboard_hides_hover and c.keyboard_modality) return;
    var i = c.hits.items.len;
    while (i > 0) {
        i -= 1;
        const h = c.hits.items[i];
        if (!h.scroll and h.rect.contains(c.input.mouse)) {
            c.hot = h.id;
            hotPath(c, h);
            return;
        }
    }
}

/// The hot box's interactive ancestors, from the tree it was painted
/// in (between frames, still the last one).
fn hotPath(c: *Context, h: anytype) void {
    if (h.index >= c.nodes.items.len or c.nodes.items[h.index].id != h.id) return;
    var at = h.index;
    while (at != none) {
        const n = c.nodes.items[at];
        if (n.interactive) c.hot_path.append(c.gpa, n.id) catch return;
        at = n.parent;
    }
}
