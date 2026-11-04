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
    /// A light in the gutter of the divider under the pointer, brightest
    /// where the pointer is and fading along the gutter (null: none).
    glow: ?Color = null,
    /// How far along the gutter the glow reaches, in points.
    glow_length: f32 = 140,
    /// Seconds the glow takes to come up or go out.
    glow_fade: f32 = 0.12,
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
    /// The glow (`Style.glow`): how lit, on which divider, where along it.
    glow: f32 = 0,
    glow_divider: ?dl.DividerItem = null,
    glow_along: f32 = 0,
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
    var hot: ?dl.DividerItem = null;
    for (l.dividers[0..l.divider_count]) |d| {
        if (divider(c, t, st, &l, d)) hot = d;
    }
    if (st.press_panel != null) hot = null;
    glow(c, st, style, &l, hot);
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

/// Whether the pointer is on the divider or dragging it.
fn divider(c: *Context, t: *dock.Tree, st: *State, l: *const dl.Layout, d: dl.DividerItem) bool {
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
    return (it.hovered and st.divider == null) or mine;
}

fn glow(c: *Context, st: *State, style: Style, l: *const dl.Layout, hot: ?dl.DividerItem) void {
    const color = style.glow orelse return;
    if (hot) |d| {
        st.glow_divider = d;
        st.glow_along = if (d.axis == .row) c.input.mouse.y - st.origin.y else c.input.mouse.x - st.origin.x;
    }
    // Hovering a divider wants a frame per move, so the light follows.
    if (hot != null) c.wants_moves = true;
    const target: f32 = if (hot != null) 1 else 0;
    if (st.glow != target) {
        const step = @min(c.dt, 0.05) / @max(style.glow_fade, 0.001);
        st.glow = if (st.glow < target) @min(target, st.glow + step) else @max(target, st.glow - step);
        c.animationFrame();
    }
    if (st.glow <= 0) return;
    const was = st.glow_divider orelse return;
    // The divider as laid out this frame: a drag moves it.
    const d = for (l.dividers[0..l.divider_count]) |x| {
        if (x.split == was.split and x.index == was.index) break x;
    } else return;
    // Eased, so the light swells and settles rather than ramping.
    const k = st.glow * st.glow * (3 - 2 * st.glow);
    const vertical = d.axis == .row;
    const span_lo = if (vertical) d.rect.y else d.rect.x;
    const span = if (vertical) d.rect.h else d.rect.w;
    const mid = if (vertical) d.rect.x + d.rect.w / 2 else d.rect.y + d.rect.h / 2;
    // Lights on one line, each shorter and tighter: a wide haze down to a
    // hot point at the pointer, so the gutter tapers off on both sides.
    const Light = struct { length: f32, width: f32, blur: f32, alpha: f32 };
    const lights = [_]Light{
        .{ .length = 1.0, .width = 10, .blur = 44, .alpha = 0.4 },
        .{ .length = 0.6, .width = 4, .blur = 16, .alpha = 0.7 },
        .{ .length = 0.32, .width = 2.5, .blur = 7, .alpha = 0.8 },
        .{ .length = 0.12, .width = 2, .blur = 3, .alpha = 1 },
    };
    for (lights, 0..) |li, i| {
        const len = @min(style.glow_length * li.length, span);
        const lo = std.math.clamp(st.glow_along - len / 2, span_lo, span_lo + span - len);
        const r: Rect = if (vertical)
            .{ .x = mid - li.width / 2, .y = lo, .w = li.width, .h = len }
        else
            .{ .x = lo, .y = mid - li.width / 2, .w = len, .h = li.width };
        var s = abs(r);
        s.layer = 1;
        s.radius = li.width / 2;
        s.shadow = .{ .color = color.alpha(li.alpha * k), .blur = li.blur, .y = 0 };
        _ = c.open(s, c.print("dock-glow{d}", .{i}));
        c.end();
    }
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
