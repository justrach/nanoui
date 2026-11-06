//! Whether anything animating can be seen. A pulsing dot scrolled off the top of
//! a long page would otherwise rebuild its whole display list every frame, and
//! keep the frames coming for as long as the page is open.
const std = @import("std");
const dom = @import("dom.zig");
const layout = @import("layout/layout.zig");
const geometry = @import("web/api_geometry.zig");
const Page = @import("page.zig").Page;

/// How often what can't be seen is looked at again, in seconds: its events and
/// its coming into view don't need more.
pub const unseen_pace: f32 = 0.25;

/// Whether anything running shows, or may. Where it can't tell, it may.
pub fn anyShown(p: *const Page) bool {
    if (p.doc.layout_dirty or p.tree == null) return true;
    var it = p.engine.anim.states.keyIterator();
    while (it.next()) |k| if (shown(p, k.node)) return true;
    return false;
}

fn shown(p: *const Page, n: *dom.Node) bool {
    var boxed: ?*dom.Node = null;
    var at: ?*dom.Node = n;
    while (at) |a| : (at = a.parentElement()) {
        if (a.computed) |s| if (s.display == .none) return false;
        // The parts of an `<svg>` have no boxes: the picture they're in does.
        if (boxed == null and layout.boxOfNode(a) != null) boxed = a;
    }
    const r = geometry.placedRect(p, boxed orelse return true);
    // A window's worth around it: a pseudo-element or a shadow may reach past its
    // box, and what comes into view should have started by then.
    const mx = p.viewport_w;
    const my = p.viewport_h;
    return r.x + r.w > -mx and r.x < 2 * mx and r.y + r.h > -my and r.y < 2 * my;
}
