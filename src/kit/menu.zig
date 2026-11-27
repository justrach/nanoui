//! Menus made of popovers: items, separators, and hover-opened submenus.
//! An opt-in safe triangle (`Options.safe_triangle`, off by default) holds
//! the open submenu while the pointer aims at it, so a diagonal move does
//! not switch rows on the way. `debug` draws the triangle and a trail.
const std = @import("std");
const ui = @import("../ui/ui.zig");
const kit = @import("kit.zig");
const overlay = @import("overlay.zig");
const safe = @import("safe_triangle.zig");

pub const MenuItem = struct {
    label: []const u8 = "",
    icon: []const u8 = "",
    /// A shortcut's text, shown at the right ("⌘C").
    shortcut: []const u8 = "",
    danger: bool = false,
    disabled: bool = false,
    /// A checkmark when true; room for one when false.
    checked: ?bool = null,
    /// A line between groups (the rest is ignored).
    separator: bool = false,
    /// Hover opens this list beside the row.
    submenu: ?[]const MenuItem = null,
    /// Written to `Options.chosen_id` when this leaf is picked.
    id: []const u8 = "",
};

pub const Options = struct {
    placement: overlay.Placement = .bottom_start,
    width: f32 = 220,
    glass: bool = false,
    /// Hold a submenu open while the pointer aims at it. Off by default.
    safe_triangle: bool = false,
    /// Seconds of no movement inside the triangle before hover switching resumes.
    idle: f32 = safe.default_idle,
    /// Draw the triangle outline and a trail of the pointer.
    debug: bool = false,
    /// Extra space around the triangle, in points.
    pad: f32 = safe.default_pad,
    /// Set to the chosen leaf's `id`, or its label when `id` is empty.
    chosen_id: ?*[]const u8 = null,
};

const none: u16 = std.math.maxInt(u16);

const Hover = struct {
    last_x: f32 = 0,
    last_y: f32 = 0,
    idle: f32 = 0,
    open: u16 = none,
    n: u8 = 0,
    xs: [6]i16 = @splat(0),
    ys: [6]i16 = @splat(0),
};

comptime {
    std.debug.assert(@sizeOf(Hover) <= 48);
}

const Pick = union(enum) { leaf: usize, nested };

/// A menu by `anchor` while `open.*`; the index of a root-level leaf chosen
/// (and then it closes). A nested leaf closes it too and writes `chosen_id`.
pub fn menu(
    c: *ui.Context,
    id: []const u8,
    open: *bool,
    anchor: ?ui.Rect,
    items: []const MenuItem,
    opts: Options,
) ?usize {
    const pad = if (opts.glass) @as(f32, 7) else 5;
    const p = overlay.popover(c, id, open, anchor, .{
        .placement = opts.placement,
        .width = opts.width,
        .padding = pad,
        .glass = opts.glass,
    }) orelse return null;
    defer p.end();
    const result = panel(c, id, items, opts) orelse return null;
    open.* = false;
    c.changed = true;
    return switch (result) {
        .leaf => |i| i,
        .nested => null,
    };
}

fn panel(c: *ui.Context, id: []const u8, items: []const MenuItem, opts: Options) ?Pick {
    const t = kit.tokens(c);
    const state = c.state(Hover, id);
    const mouse = c.input.mouse;
    track(state, mouse, c.dt, opts.debug);

    const sub_id = if (state.open != none) c.print("sub-{d}", .{state.open}) else "";
    const sub_rect = if (state.open != none) peekRect(c, sub_id) else null;
    const open_row_last = if (state.open != none) peekRect(c, c.print("mi-{d}", .{state.open})) else null;
    const side: safe.Side = if (open_row_last) |row| if (sub_rect) |sub| safe.sideOf(row, sub) else .right else .right;
    const decision: safe.Decision = if (opts.safe_triangle) if (sub_rect) |sub| safe.decide(.{
        .cursor = mouse,
        .prev = .{ .x = state.last_x, .y = state.last_y },
        .submenu = sub,
        .parent_row = open_row_last,
        .idle = state.idle,
        .idle_limit = opts.idle,
        .pad = opts.pad,
    }, side) else .release else .release;
    const holding = opts.safe_triangle and safe.holds(decision);
    if (holding and decision == .hold) {
        c.frameIn(@max(0.016, opts.idle - state.idle));
    }

    var chosen: ?Pick = null;
    const checks = for (items) |it| {
        if (it.checked != null) break true;
    } else false;

    var hovered_sub: u16 = none;
    var hovered_row: ?ui.Rect = null;
    var open_row: ?ui.Rect = open_row_last;
    for (items, 0..) |it, i| {
        ui.key(c, c.print("mi-{d}", .{i}));
        if (it.separator) {
            const s = ui.div(c).wFull().py(4);
            defer s.end();
            _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = t.border }, .none, null);
            continue;
        }
        const row = ui.div(c).row().wFull().gap(8).px(8).h(30).itemsCenter().rounded(t.radius - 2).control();
        const ix = row.interaction();
        const live = !it.disabled;
        const is_open = state.open == i;
        const hot = live and if (holding) is_open else (ix.hovered or is_open);
        if (hot) c.node(row.index).style.background = if (it.danger) t.danger.alpha(0.12) else t.surface_hover;
        if (!live) c.node(row.index).style.opacity = 0.45;
        defer row.end();
        const fg = if (it.danger) t.danger else t.foreground;
        if (checks) {
            const box = ui.div(c).w(14).center();
            defer box.end();
            if (it.checked orelse false) ui.icon(c, "checkmark", .{ .size = 11, .weight = .semibold, .color = fg });
        }
        if (it.icon.len > 0) ui.icon(c, it.icon, .{ .size = 13, .frame = 16, .color = if (it.danger) t.danger else t.muted });
        ui.text(c, it.label, .{ .size = 13, .color = fg });
        ui.spacer(c);
        if (it.submenu != null) {
            ui.icon(c, "chevron.right", .{ .size = 9, .color = t.muted });
        } else if (it.shortcut.len > 0) {
            ui.text(c, it.shortcut, .{ .size = 11.5, .color = t.muted });
        }
        if (is_open) open_row = ix.rect;
        if (live and ix.hovered and it.submenu != null) {
            hovered_sub = @intCast(i);
            hovered_row = ix.rect;
        }
        if (live and ix.clicked and it.submenu == null) {
            if (opts.chosen_id) |slot| slot.* = if (it.id.len > 0) it.id else it.label;
            chosen = .{ .leaf = i };
        }
    }

    var want = hovered_sub;
    const in_sub = if (sub_rect) |sub| sub.contains(mouse) else false;
    if (in_sub or decision == .inside_submenu) want = state.open;
    if (holding) {
        // Keep the current submenu; ignore the row under the pointer.
    } else if (want != state.open) {
        state.open = want;
        c.changed = true;
    }

    const anchor = if (state.open == hovered_sub) hovered_row else open_row;
    if (state.open != none and state.open < items.len) {
        if (items[state.open].submenu) |sub_items| {
            if (drawSub(c, state.open, sub_items, opts, anchor)) |pick| {
                chosen = if (pick == .leaf) .nested else pick;
            }
        }
    }

    if (opts.debug) {
        const show_tri = if (sub_rect) |sub| !sub.contains(mouse) else false;
        drawDebug(c, state, if (sub_rect) |sub| safe.triangle(mouse, sub, side) else null, show_tri);
    }

    state.last_x = mouse.x;
    state.last_y = mouse.y;
    return chosen;
}

fn drawSub(
    c: *ui.Context,
    index: u16,
    items: []const MenuItem,
    opts: Options,
    row: ?ui.Rect,
) ?Pick {
    const sub_id = c.print("sub-{d}", .{index});
    var sub_open = true;
    const p = overlay.popover(c, sub_id, &sub_open, row, .{
        .placement = .right,
        .width = opts.width,
        .padding = if (opts.glass) 7 else 5,
        .gap = 4,
        .dismissable = false,
        .glass = opts.glass,
    }) orelse return null;
    defer p.end();
    return panel(c, sub_id, items, withDebugOff(opts));
}

fn withDebugOff(opts: Options) Options {
    var o = opts;
    o.debug = false;
    return o;
}

fn peekRect(c: *ui.Context, key: []const u8) ?ui.Rect {
    return c.rects.get(c.peekId(key));
}

fn track(state: *Hover, mouse: ui.Point, dt: f32, debug: bool) void {
    if (state.n == 0 and state.last_x == 0 and state.last_y == 0) {
        state.last_x = mouse.x;
        state.last_y = mouse.y;
        if (debug) pushTrail(state, mouse);
        return;
    }
    const dx = mouse.x - state.last_x;
    const dy = mouse.y - state.last_y;
    const moving = dx * dx + dy * dy >= safe.default_move_eps * safe.default_move_eps;
    if (moving) {
        state.idle = 0;
        if (debug) pushTrail(state, mouse);
    } else {
        state.idle += dt;
    }
}

fn pushTrail(state: *Hover, p: ui.Point) void {
    const x: i16 = toI16(p.x);
    const y: i16 = toI16(p.y);
    if (state.n > 0 and state.xs[state.n - 1] == x and state.ys[state.n - 1] == y) return;
    if (state.n < state.xs.len) {
        state.xs[state.n] = x;
        state.ys[state.n] = y;
        state.n += 1;
        return;
    }
    var i: u8 = 0;
    while (i < state.xs.len - 1) : (i += 1) {
        state.xs[i] = state.xs[i + 1];
        state.ys[i] = state.ys[i + 1];
    }
    state.xs[state.xs.len - 1] = x;
    state.ys[state.ys.len - 1] = y;
}

fn toI16(v: f32) i16 {
    return @intFromFloat(std.math.clamp(v, -32768, 32767));
}

fn drawDebug(c: *ui.Context, state: *Hover, tri: ?safe.Triangle, active: bool) void {
    const cv = ui.canvas(c, .{
        .width = .{ .px = c.size.w },
        .height = .{ .px = c.size.h },
        .absolute = true,
        .fixed = true,
        .layer = overlay.layer_tooltip + 1,
    });
    const grey: ui.Color = .{ .r = 0.55, .g = 0.55, .b = 0.55, .a = 0.9 };
    if (active) if (tri) |t| {
        const pts = [_]ui.Point{ t.apex, t.near_top, t.near_bottom, t.apex };
        cv.polyline(&pts, .{ .width = 1.5, .color = grey });
    };
    var i: u8 = 0;
    while (i < state.n) : (i += 1) {
        hollowSquare(cv, .{ .x = @floatFromInt(state.xs[i]), .y = @floatFromInt(state.ys[i]) }, 3.5, grey);
    }
}

fn hollowSquare(cv: *ui.Canvas, p: ui.Point, r: f32, color: ui.Color) void {
    const s = ui.Stroke{ .width = 1, .color = color };
    const x0 = p.x - r;
    const y0 = p.y - r;
    const x1 = p.x + r;
    const y1 = p.y + r;
    cv.line(.{ .x = x0, .y = y0 }, .{ .x = x1, .y = y0 }, s);
    cv.line(.{ .x = x1, .y = y0 }, .{ .x = x1, .y = y1 }, s);
    cv.line(.{ .x = x1, .y = y1 }, .{ .x = x0, .y = y1 }, s);
    cv.line(.{ .x = x0, .y = y1 }, .{ .x = x0, .y = y0 }, s);
}
