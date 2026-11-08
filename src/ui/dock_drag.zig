//! A dock tab dragged (`dock_view.zig`): it starts past
//! `Style.drag_threshold`, washes the landing zone of the group content
//! under the pointer, follows the pointer as a ghost, and on release
//! docks there, or, released outside the dock, goes to the app
//! (`Hooks.dropOutside`). A tab dragged in from another window
//! (`State.external_drag`) is drawn the same, and docks on `dropExternal`.
const std = @import("std");
const types = @import("types.zig");
const dock = @import("dock.zig");
const dl = @import("dock_layout.zig");
const Context = @import("context.zig").Context;
const view = @import("dock_view.zig");
const Rect = types.Rect;

fn abs(r: Rect) types.Style {
    return .{ .absolute = true, .offset = .{ .x = r.x, .y = r.y }, .width = .{ .px = r.w }, .height = .{ .px = r.h } };
}

/// Where the ghost sits from the pointer, and its size, without a
/// `Hooks.ghost`.
pub const ghost_offset: types.Point = .{ .x = 10, .y = 8 };
pub const ghost_size: types.Size = .{ .w = 110, .h = 24 };

pub fn overlay(c: *Context, t: *dock.Tree, st: *view.State, style: view.Style, l: *const dl.Layout, bounds: Rect, ctx: anytype, comptime Hooks: type) void {
    const p = st.press_panel orelse return;
    const m = c.input.mouse;
    if (!st.dragging) {
        if (!c.input.down) {
            st.press_panel = null;
            return;
        }
        const dx = m.x - st.press_at.x;
        const dy = m.y - st.press_at.y;
        if (dx * dx + dy * dy < style.drag_threshold * style.drag_threshold) return;
        st.dragging = true;
    }
    const local_x = m.x - bounds.x;
    const local_y = m.y - bounds.y;
    const target = dl.dropTarget(t, l, local_x, local_y);
    if (!c.input.down) {
        if (target) |tg| {
            // Back onto its own group's middle is no move.
            if (!home(t, p, tg) and t.move(p, tg)) st.moved += 1;
        } else if (outside(bounds, m, t.metrics.divider)) {
            if (@hasDecl(Hooks, "dropOutside")) Hooks.dropOutside(ctx, p, m);
        }
        st.press_panel = null;
        st.dragging = false;
        c.changed = true;
        return;
    }
    c.cursor = .closed_hand;
    c.animationFrame();
    // Back onto its own group's middle changes nothing: no wash.
    if (target) |tg| if (!home(t, p, tg)) wash(c, style, l, tg);
    ghost(c, style, p, m, .{ .x = local_x, .y = local_y }, ctx, Hooks);
}

fn home(t: *const dock.Tree, p: dock.PanelId, tg: dock.DropTarget) bool {
    return t.groupOf(p) == tg.group and tg.zone == .center;
}

/// A tab dragged in from another window (`State.external_drag`): its
/// landing zone washed and its ghost under the point, as for one of the
/// dock's own. The app drops it with `dropExternal`.
pub fn external(c: *Context, t: *dock.Tree, st: *view.State, style: view.Style, l: *const dl.Layout, bounds: Rect, ctx: anytype, comptime Hooks: type) void {
    const x = st.external_drag orelse return;
    if (st.press_panel != null) return;
    const local: types.Point = .{ .x = x.point.x - bounds.x, .y = x.point.y - bounds.y };
    if (dl.dropTarget(t, l, local.x, local.y)) |tg| if (!home(t, x.panel, tg)) wash(c, style, l, tg);
    ghost(c, style, x.panel, x.point, local, ctx, Hooks);
}

/// Where the external drag would land now, from the last frame's layout.
pub fn externalTarget(t: *const dock.Tree, st: *const view.State) ?dock.DropTarget {
    const x = st.external_drag orelse return null;
    return dl.dropTarget(t, &st.layout, x.point.x - st.origin.x, x.point.y - st.origin.y);
}

/// Releases the external drag where it is: the panel docks there (moved
/// if the tree has it, else added), and the drag ends either way. Where
/// it landed, or null over no group (the app keeps the panel where it was).
pub fn dropExternal(t: *dock.Tree, st: *view.State) ?dock.DropTarget {
    const tg = externalTarget(t, st);
    const x = st.external_drag orelse return null;
    st.external_drag = null;
    const target = tg orelse return null;
    if (home(t, x.panel, target)) return null;
    const ok = if (t.contains(x.panel)) t.move(x.panel, target) else t.insertAt(x.panel, target);
    if (!ok) return null;
    st.moved += 1;
    return target;
}

fn wash(c: *Context, style: view.Style, l: *const dl.Layout, tg: dock.DropTarget) void {
    const g = l.group(tg.group) orelse return;
    const z = dl.zoneRect(g.content, tg.zone).inset(.all(3));
    var s = abs(z);
    s.background = style.drop;
    s.border = style.drop_border;
    s.radius = style.radius;
    s.layer = 1;
    _ = c.open(s, "dock-drop");
    c.end();
}

/// The ghost: the tab again, under the pointer (`m` in window points,
/// `local` in the dock's).
fn ghost(c: *Context, style: view.Style, p: dock.PanelId, m: types.Point, local: types.Point, ctx: anytype, comptime Hooks: type) void {
    const r: Rect = .{ .x = local.x + ghost_offset.x, .y = local.y + ghost_offset.y, .w = ghost_size.w, .h = ghost_size.h };
    var gs = abs(r);
    gs.layer = 2;
    if (@hasDecl(Hooks, "ghost")) {
        _ = c.open(gs, "dock-ghost");
        Hooks.ghost(ctx, c, p, Rect{ .x = m.x + ghost_offset.x, .y = m.y + ghost_offset.y, .w = r.w, .h = r.h });
        c.end();
        return;
    }
    gs.direction = .row;
    gs.align_items = .center;
    gs.opacity = 0.9;
    gs.clip = true;
    gs.background = style.panel;
    gs.border = style.drop_border;
    gs.radius = style.radius;
    gs.padding = .{ .right = 4 };
    _ = c.open(gs, "dock-ghost");
    Hooks.tab(ctx, c, p, .{ .active = true, .hovered = false, .ghost = true });
    c.end();
}

/// Whether `m` is off the dock: outside `bounds` grown by `gutter`.
pub fn outside(bounds: Rect, m: types.Point, gutter: f32) bool {
    return m.x < bounds.x - gutter or m.y < bounds.y - gutter or m.x > bounds.x + bounds.w + gutter or m.y > bounds.y + bounds.h + gutter;
}
