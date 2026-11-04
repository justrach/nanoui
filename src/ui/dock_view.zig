//! Dockable panels drawn: every group of a `dock.Tree` as a panel with a
//! tab strip, dividers that resize a split when dragged, and tabs that
//! dock elsewhere when dragged onto another group's edge or center (the
//! landing zone is washed while the tab is over it).
//!
//!     ui.dock.view(c, &s.tree, &s.dock_state, style, s, Hooks);
//!
//! `Hooks` is a struct type with the app's parts:
//!
//!     fn tab(ctx: Ctx, c: *ui.Context, panel: ui.dock.PanelId, t: ui.dock.TabState) void  // a tab's insides
//!     fn content(ctx: Ctx, c: *ui.Context, panel: ui.dock.PanelId, r: ui.Rect) void       // the shown panel
//!     fn header(ctx: Ctx, c: *ui.Context, panel: ui.dock.PanelId, r: ui.Rect) void        // optional: after the tabs
//!
//! `content` is built inside a column the size of the panel's content
//! rect (`r`, in window points), which clips it.
const std = @import("std");
const types = @import("types.zig");
const dock = @import("dock.zig");
const dl = @import("dock_layout.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const Color = types.Color;
const Rect = types.Rect;

pub const Style = struct {
    /// Behind the panels: the gutters.
    background: ?Color = null,
    panel: Color = .hex(0x1c1c1e),
    header: ?Color = null,
    border: ?Color = null,
    radius: f32 = 5,
    /// Room before the first tab and between tabs.
    tab_inset: f32 = 6,
    tab_gap: f32 = 2,
    /// A divider while the pointer is on it or dragging it.
    divider_hot: Color = .{ .r = 1, .g = 1, .b = 1, .a = 0.12 },
    /// The landing zone of a dragged tab.
    drop: Color = .{ .r = 0.49, .g = 0.42, .b = 0.96, .a = 0.22 },
    drop_border: Color = .{ .r = 0.49, .g = 0.42, .b = 0.96, .a = 0.9 },
};

/// What a tab is drawn as.
pub const TabState = struct {
    active: bool,
    hovered: bool,
    /// Being dragged: drawn again under the pointer as the ghost.
    ghost: bool = false,
};

/// The dock's state between frames, kept by the app beside its tree.
pub const State = struct {
    /// The last frame's layout (window points), for the app's own hit tests.
    layout: dl.Layout = .{},
    origin: types.Point = .{},
    /// A tab pressed: dragged once it moves past `drag_threshold`.
    press_panel: ?dock.PanelId = null,
    press_at: types.Point = .{},
    dragging: bool = false,
    divider: ?dl.DividerItem = null,
    divider_last: f32 = 0,
    /// The last drop, for the app to persist the layout.
    moved: u32 = 0,
};

pub const drag_threshold: f32 = 4;

pub fn view(c: *Context, t: *dock.Tree, st: *State, style: Style, ctx: anytype, comptime Hooks: type) void {
    const root = c.open(.{ .width = .fill, .height = .fill, .grow = 1, .background = style.background }, "dock-root");
    const rid = c.node(root).id;
    const bounds = c.rects.get(rid) orelse Rect{ .w = c.size.w, .h = c.size.h };
    st.origin = .{ .x = bounds.x, .y = bounds.y };
    var l = t.layout(.{ .w = bounds.w, .h = bounds.h });
    st.layout = l;

    for (l.groups[0..l.group_count]) |g| group(c, t, st, style, g, bounds, ctx, Hooks);
    for (l.dividers[0..l.divider_count]) |d| divider(c, t, st, &l, d);
    dragOverlay(c, t, st, style, &l, bounds, ctx, Hooks);
    c.end();
}

fn abs(r: Rect) types.Style {
    return .{ .absolute = true, .offset = .{ .x = r.x, .y = r.y }, .width = .{ .px = r.w }, .height = .{ .px = r.h } };
}

fn group(c: *Context, t: *dock.Tree, st: *State, style: Style, g: dl.GroupItem, bounds: Rect, ctx: anytype, comptime Hooks: type) void {
    const node = t.nodes[g.node];
    var s = abs(g.rect);
    s.background = style.panel;
    s.border = style.border;
    s.radius = style.radius;
    s.clip = true;
    s.direction = .column;
    _ = c.open(s, c.print("dock-g{d}", .{if (node.activePanel()) |p| @as(u16, p) else 999}));
    defer c.end();

    // The header: tabs, then the app's own controls.
    _ = c.open(.{ .direction = .row, .width = .fill, .height = .{ .px = g.header.h }, .background = style.header, .align_items = .end, .padding = .{ .left = style.tab_inset }, .gap = style.tab_gap }, null);
    for (node.tabs[0..node.tab_count], 0..) |p, i| {
        const ti = c.open(.{ .direction = .row, .align_items = .center, .height = .fill, .control = true }, c.print("dock-tab{d}", .{p}));
        const it = c.interact(ti, .{});
        const active = i == node.active_tab;
        const dragged_away = st.dragging and st.press_panel == p;
        c.node(ti).style.opacity = if (dragged_away) 0.35 else 1;
        if (it.clicked and !st.dragging) {
            t.setActive(g.node, @intCast(i));
            c.changed = true;
        }
        if (c.input.pressed and it.hovered and c.input.button == .left and c.hot == it.id) {
            st.press_panel = p;
            st.press_at = c.input.mouse;
            st.dragging = false;
        }
        Hooks.tab(ctx, c, p, .{ .active = active, .hovered = it.hovered });
        c.end();
    }
    _ = c.open(.{ .grow = 1, .height = .fill }, null);
    c.end();
    if (@hasDecl(Hooks, "header")) {
        if (node.activePanel()) |p| Hooks.header(ctx, c, p, translate(g.header, bounds));
    }
    c.end();

    const p = node.activePanel() orelse return;
    const cr = g.content;
    _ = c.open(.{ .absolute = true, .offset = .{ .x = cr.x - g.rect.x, .y = cr.y - g.rect.y }, .width = .{ .px = cr.w }, .height = .{ .px = cr.h }, .clip = true, .direction = .column }, c.print("dock-c{d}", .{p}));
    Hooks.content(ctx, c, p, translate(cr, bounds));
    c.end();
}

fn translate(r: Rect, bounds: Rect) Rect {
    return .{ .x = r.x + bounds.x, .y = r.y + bounds.y, .w = r.w, .h = r.h };
}

fn divider(c: *Context, t: *dock.Tree, st: *State, l: *const dl.Layout, d: dl.DividerItem) void {
    const slop = t.metrics.grab_slop;
    var r = d.rect;
    if (d.axis == .row) {
        r.x -= slop;
        r.w += slop * 2;
    } else {
        r.y -= slop;
        r.h += slop * 2;
    }
    const i = c.open(abs(r), c.print("dock-d{d}-{d}", .{ d.split, d.index }));
    const it = c.interact(i, .{});
    const mine = if (st.divider) |cur| cur.split == d.split and cur.index == d.index else false;
    if (it.hovered or mine) c.cursor = if (d.axis == .row) .resize_left_right else .resize_up_down;
    const along = if (d.axis == .row) c.input.mouse.x else c.input.mouse.y;
    if (it.pressed and !mine and st.divider == null) {
        st.divider = d;
        st.divider_last = along;
    } else if (mine) {
        if (!c.input.down) {
            st.divider = null;
        } else if (along != st.divider_last) {
            t.adjustDivider(l, d, along - st.divider_last);
            st.divider_last = along;
            c.changed = true;
        }
    }
    c.end();
}

fn dragOverlay(c: *Context, t: *dock.Tree, st: *State, style: Style, l: *const dl.Layout, bounds: Rect, ctx: anytype, comptime Hooks: type) void {
    const p = st.press_panel orelse return;
    const m = c.input.mouse;
    if (!st.dragging) {
        if (!c.input.down) {
            st.press_panel = null;
            return;
        }
        if (@abs(m.x - st.press_at.x) + @abs(m.y - st.press_at.y) < drag_threshold) return;
        st.dragging = true;
    }
    const local_x = m.x - bounds.x;
    const local_y = m.y - bounds.y;
    const target = dl.dropTarget(t, l, local_x, local_y);
    if (!c.input.down) {
        if (target) |tg| {
            if (t.move(p, tg)) st.moved += 1;
        }
        st.press_panel = null;
        st.dragging = false;
        c.changed = true;
        return;
    }
    c.cursor = .closed_hand;
    c.animationFrame();
    if (target) |tg| {
        const g = l.group(tg.group).?;
        const z = dl.zoneRect(g.rect, tg.zone).inset(.all(3));
        var s = abs(z);
        s.background = style.drop;
        s.border = style.drop_border;
        s.radius = style.radius;
        s.layer = 1;
        _ = c.open(s, "dock-drop");
        c.end();
    }
    // The ghost: the tab again, under the pointer.
    var gs = abs(.{ .x = local_x + 8, .y = local_y - 14, .w = 0, .h = 28 });
    gs.width = .auto;
    gs.direction = .row;
    gs.align_items = .center;
    gs.layer = 2;
    gs.opacity = 0.9;
    gs.background = style.panel;
    gs.border = style.drop_border;
    gs.radius = style.radius;
    gs.padding = .{ .right = 4 };
    _ = c.open(gs, "dock-ghost");
    Hooks.tab(ctx, c, p, .{ .active = true, .hovered = false, .ghost = true });
    c.end();
}
