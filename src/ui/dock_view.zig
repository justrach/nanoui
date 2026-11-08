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
//!     fn ghost(ctx: Ctx, c: *ui.Context, panel: ui.dock.PanelId, r: ui.Rect) void         // optional: the dragged tab
//!     fn divider(ctx: Ctx, c: *ui.Context, d: ui.dock.DividerItem, hovered: bool, along: f32) void  // optional
//!     fn dropOutside(ctx: Ctx, panel: ui.dock.PanelId, at: ui.Point) void                 // optional
//!
//! `content` is built inside a column the size of the panel's content
//! rect (`r`, in window points), which clips it. `divider` draws a divider
//! in place of nanoui's light (`Style.glow`), inside a box over the
//! gutter: `d.rect` is in window points and `along` is the pointer's
//! distance from the gutter's start. `ghost` draws inside a box under the
//! pointer. `dropOutside` gets a tab released off the dock (outside its
//! bounds grown by a gutter), with the pointer in window points.
const std = @import("std");
const types = @import("types.zig");
const dock = @import("dock.zig");
const dl = @import("dock_layout.zig");
const ctx_mod = @import("context.zig");
const glow = @import("dock_glow.zig");
const drag = @import("dock_drag.zig");
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
    /// How far either side of the pointer the line stays bright, in points
    /// (twice the falloff's width).
    glow_length: f32 = 180,
    /// How lit the line is far from the pointer, 0 to 1: it runs the
    /// gutter's whole length.
    glow_floor: f32 = 0.22,
    /// Seconds the glow takes to come up or go out (0: at once).
    glow_fade: f32 = 0.12,
    /// How far (points, any direction) a pressed tab moves before it drags.
    drag_threshold: f32 = drag_threshold,
    /// Points a divider moves for one VoiceOver increment.
    a11y_nudge: f32 = 16,
    /// One panel's group alone over the dock (a maximized panel): its
    /// header with all its tabs, no dividers, drops only onto it.
    solo: ?dock.PanelId = null,
    /// Room round the solo group.
    solo_margin: f32 = 0,
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
    /// The divider being dragged changed its split's weights.
    divider_moved: bool = false,
    /// The glow (`Style.glow`): how lit, on which divider, where along it.
    glow: f32 = 0,
    glow_divider: ?dl.DividerItem = null,
    glow_along: f32 = 0,
    /// The last drop, for the app to persist the layout.
    moved: u32 = 0,
    /// A divider drag that changed the weights ended (or VoiceOver nudged
    /// one): for the app to persist the layout.
    resized: u32 = 0,
    /// A tab dragged from another window (a floating panel's header), the
    /// pointer in this dock's window points: its landing zone and ghost
    /// are drawn as for one of the dock's own. The app sets it on each
    /// move of that drag and docks it with `dropExternal` on release
    /// (null: none).
    external_drag: ?ExternalDrag = null,
};

pub const ExternalDrag = struct { panel: dock.PanelId, point: types.Point };

/// Where `State.external_drag` would land now (the last frame's layout).
pub const externalTarget = drag.externalTarget;
/// Docks `State.external_drag` where it is and ends it: where it landed.
pub const dropExternal = drag.dropExternal;

/// `Style.drag_threshold`'s default.
pub const drag_threshold: f32 = 6;

pub fn view(c: *Context, t: *dock.Tree, st: *State, style: Style, ctx: anytype, comptime Hooks: type) void {
    const root = c.open(.{ .width = .fill, .height = .fill, .grow = 1, .background = style.background }, "dock-root");
    const rid = c.node(root).id;
    const bounds = c.rects.get(rid) orelse Rect{ .w = c.size.w, .h = c.size.h };
    st.origin = .{ .x = bounds.x, .y = bounds.y };
    const solo_group: ?u8 = if (style.solo) |p| t.groupOf(p) else null;
    var l = if (solo_group) |g|
        dl.soloLayout(t, g, (Rect{ .w = bounds.w, .h = bounds.h }).inset(.all(style.solo_margin)))
    else
        t.layout(.{ .w = bounds.w, .h = bounds.h });
    st.layout = l;

    for (l.groups[0..l.group_count]) |g| group(c, t, st, style, g, bounds, ctx, Hooks);
    var hot: ?dl.DividerItem = null;
    for (l.dividers[0..l.divider_count]) |d| {
        if (divider(c, t, st, style, &l, d)) hot = d;
    }
    if (st.press_panel != null) hot = null;
    glow.update(c, st, style, hot);
    if (@hasDecl(Hooks, "divider")) {
        for (l.dividers[0..l.divider_count]) |d| dividerHook(c, st, d, hot, bounds, ctx, Hooks);
    } else glow.draw(c, st, style, &l);
    drag.overlay(c, t, st, style, &l, bounds, ctx, Hooks);
    drag.external(c, t, st, style, &l, bounds, ctx, Hooks);
    c.end();
}

fn abs(r: Rect) types.Style {
    return .{ .absolute = true, .offset = .{ .x = r.x, .y = r.y }, .width = .{ .px = r.w }, .height = .{ .px = r.h } };
}

fn same(a: ?dl.DividerItem, d: dl.DividerItem) bool {
    const x = a orelse return false;
    return x.split == d.split and x.index == d.index;
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
    const strip = c.open(.{ .direction = .row, .width = .fill, .height = .{ .px = g.header.h }, .background = style.header, .align_items = .end, .padding = .{ .left = style.tab_inset }, .gap = style.tab_gap }, null);
    c.addA11y(strip, .group, "Panel tabs", "", false, true);
    for (node.tabs[0..node.tab_count], 0..) |p, i| {
        const ti = c.open(.{ .direction = .row, .align_items = .center, .height = .fill, .control = true }, c.print("dock-tab{d}", .{p}));
        const active = i == node.active_tab;
        c.addA11y(ti, .tab, t.title(p), "", active, true);
        const it = c.interact(ti, .{});
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
fn divider(c: *Context, t: *dock.Tree, st: *State, style: Style, l: *const dl.Layout, d: dl.DividerItem) bool {
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
    c.adjustable(i, .{ .role = .splitter, .label = "Panel divider" });
    const it = c.interact(i, .{});
    const mine = same(st.divider, d);
    if (it.hovered or mine) c.cursor = if (d.axis == .row) .resize_left_right else .resize_up_down;
    const along = if (d.axis == .row) c.input.mouse.x else c.input.mouse.y;
    if (it.pressed and !mine and st.divider == null) {
        st.divider = d;
        st.divider_last = along;
        st.divider_moved = false;
    } else if (mine) {
        if (!c.input.down) {
            st.divider = null;
            if (st.divider_moved) st.resized += 1;
            st.divider_moved = false;
        } else if (along != st.divider_last) {
            if (adjust(t, l, d, along - st.divider_last)) st.divider_moved = true;
            st.divider_last = along;
            c.changed = true;
        }
    }
    if (it.a11y_step != 0) {
        if (adjust(t, l, d, @as(f32, @floatFromInt(it.a11y_step)) * style.a11y_nudge)) st.resized += 1;
        c.changed = true;
    }
    c.end();
    return (it.hovered and st.divider == null) or mine;
}

/// Moves the divider; whether its split's weights changed.
fn adjust(t: *dock.Tree, l: *const dl.Layout, d: dl.DividerItem, delta: f32) bool {
    const n = t.nodes[d.split].child_count;
    const before = t.nodes[d.split].weights;
    t.adjustDivider(l, d, delta);
    return !std.mem.eql(f32, before[0..n], t.nodes[d.split].weights[0..n]);
}

/// The app's divider, in a box over the gutter.
fn dividerHook(c: *Context, st: *State, d: dl.DividerItem, hot: ?dl.DividerItem, bounds: Rect, ctx: anytype, comptime Hooks: type) void {
    const hovered = same(hot, d) or same(st.divider, d);
    const start = if (d.axis == .row) d.rect.y else d.rect.x;
    // Where the light was last, for one fading out; else the pointer.
    const along = if (same(st.glow_divider, d))
        st.glow_along - start
    else if (d.axis == .row) c.input.mouse.y - bounds.y - start else c.input.mouse.x - bounds.x - start;
    var s = abs(d.rect);
    s.layer = 1;
    _ = c.open(s, c.print("dock-dh{d}-{d}", .{ d.split, d.index }));
    var w = d;
    w.rect = translate(d.rect, bounds);
    Hooks.divider(ctx, c, w, hovered, along);
    c.end();
}
