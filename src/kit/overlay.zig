//! What opens over the page, on a layer: tooltips after the pointer rests
//! on something, and popovers anchored to what opened them (placed where
//! they fit, closed by Escape or a click elsewhere). Menus are in
//! `menu.zig`, made of these. Each comes and goes with `ui.motion` presence.
const std = @import("std");
const ui = @import("../ui/ui.zig");
const kit = @import("kit.zig");
const motion = ui.motion;

/// Layers: popovers and menus, then tooltips over them.
pub const layer_popover = 20;
pub const layer_tooltip = 30;

pub const Placement = enum { bottom_start, bottom, bottom_end, top_start, top, top_end, left, right };

/// Where a panel `size` goes beside `anchor` at `placement`, turned to the
/// other side and kept in the window when it would leave it.
pub fn place(c: *ui.Context, anchor: ui.Rect, size: ui.Size, placement: Placement, gap: f32) ui.Point {
    var p = placement;
    const W = c.size.w;
    const H = c.size.h;
    // The other side when this one hasn't room and that one has.
    switch (p) {
        .bottom_start, .bottom, .bottom_end => if (anchor.y + anchor.h + gap + size.h > H and anchor.y - gap - size.h >= 0) {
            p = switch (p) {
                .bottom_start => .top_start,
                .bottom => .top,
                else => .top_end,
            };
        },
        .top_start, .top, .top_end => if (anchor.y - gap - size.h < 0 and anchor.y + anchor.h + gap + size.h <= H) {
            p = switch (p) {
                .top_start => .bottom_start,
                .top => .bottom,
                else => .bottom_end,
            };
        },
        .left => if (anchor.x - gap - size.w < 0) {
            p = .right;
        },
        .right => if (anchor.x + anchor.w + gap + size.w > W) {
            p = .left;
        },
    }
    var x: f32 = switch (p) {
        .bottom_start, .top_start => anchor.x,
        .bottom, .top => anchor.x + (anchor.w - size.w) / 2,
        .bottom_end, .top_end => anchor.x + anchor.w - size.w,
        .left => anchor.x - gap - size.w,
        .right => anchor.x + anchor.w + gap,
    };
    var y: f32 = switch (p) {
        .bottom_start, .bottom, .bottom_end => anchor.y + anchor.h + gap,
        .top_start, .top, .top_end => anchor.y - gap - size.h,
        .left, .right => anchor.y + (anchor.h - size.h) / 2,
    };
    x = std.math.clamp(x, 6, @max(6, W - size.w - 6));
    y = std.math.clamp(y, 6, @max(6, H - size.h - 6));
    return .{ .x = x, .y = y };
}

/// A label that appears over `trigger` once the pointer has rested on it
/// for half a second, and goes when it leaves.
pub fn tooltip(c: *ui.Context, trigger: ui.Interaction, text: []const u8, opts: struct { placement: Placement = .top, delay: f32 = 0.5 }) void {
    const t = kit.tokens(c);
    const key = c.print("tip-{x}", .{trigger.id});
    // How long the pointer has rested, as a number climbing to 1.
    const rested = motion.number(c, key, if (trigger.hovered and !trigger.pressed) 1 else 0, if (trigger.hovered) .{ .tween = .{ .duration = opts.delay, .ease = .linear } } else .instant);
    const anchor = trigger.rect orelse return;
    const show = trigger.hovered and rested >= 0.999;
    const f = motion.present(c, key, show, .{ .initial = .{ .opacity = 0, .scale = 0.96 }, .exit = .{ .opacity = 0 }, .transition = .{ .tween = .{ .duration = 0.12 } } }) orelse return;
    const id = c.peekId(null);
    const size = if (c.rects.get(id)) |r| ui.Size{ .w = r.w, .h = r.h } else ui.Size{ .w = 8 * @as(f32, @floatFromInt(text.len)), .h = 24 };
    const at = place(c, anchor, size, opts.placement, 6);
    const d = ui.div(c).fixed().offset(at.x, at.y).layer(layer_tooltip).px(8).py(4).rounded(6).bg(t.foreground).shadow(.{ .color = t.shadow.alpha(0.5), .blur = 8, .y = 2 }).motion(f);
    defer d.end();
    ui.text(c, text, .{ .size = 11.5, .color = t.background });
}

pub const PopoverOptions = struct {
    placement: Placement = .bottom_start,
    width: ?f32 = null,
    /// Space around what's in it.
    padding: f32 = 12,
    gap: f32 = 6,
    /// A click outside closes it.
    dismissable: bool = true,
    /// A pane of Liquid Glass, as macOS 26's menus are.
    glass: bool = false,
};

/// An open popover: draw what's in it, then `end`.
pub const Popover = struct {
    div: ui.Div,
    pub fn end(p: Popover) void {
        p.div.end();
    }
};

/// A panel by `anchor` while `open.*`: Escape or a click outside it (and
/// outside the anchor) sets `open.*` false; it fades out from there.
pub fn popover(c: *ui.Context, id: []const u8, open: *bool, anchor: ?ui.Rect, opts: PopoverOptions) ?Popover {
    const t = kit.tokens(c);
    const a = anchor orelse ui.Rect{ .x = c.size.w / 2, .y = c.size.h / 2, .w = 0, .h = 0 };
    c.next_key = id;
    const panel_id = c.peekId(null);
    c.next_key = null;
    if (open.* and opts.dismissable) {
        const inside = c.hot == panel_id or std.mem.indexOfScalar(u64, c.hot_path.items, panel_id) != null;
        const on_anchor = a.contains(c.input.mouse);
        if ((c.input.pressed and !inside and !on_anchor) or c.shortcut(.{ .key = ui.Shortcut.escape })) {
            open.* = false;
            c.changed = true;
        }
    }
    const f = motion.present(c, id, open.*, .{
        .initial = .{ .opacity = 0, .scale = 0.97, .y = -4 },
        .exit = .{ .opacity = 0, .scale = 0.98 },
        .transition = .{ .spring = motion.Spring.snappy },
    }) orelse return null;
    const size = if (c.rects.get(panel_id)) |r| ui.Size{ .w = r.w, .h = r.h } else ui.Size{ .w = opts.width orelse 220, .h = 120 };
    const at = place(c, a, size, opts.placement, opts.gap);
    var d = ui.div(c).fixed().offset(at.x, at.y).layer(layer_popover).column().gap(2).p(opts.padding).rounded(t.radius + 2).shadow(.{ .color = t.shadow.alpha(0.9), .blur = 24, .y = 8 });
    d = if (opts.glass) d.rounded(t.radius + 8).glass(.{}) else d.bg(t.popover).border(t.border);
    if (opts.width) |w| d = d.w(w);
    // Block pointer and scroll pass-through (so clicks inside aren't "outside").
    d = d.occlude();
    return .{ .div = d.motion(f) };
}

test "a panel goes where it fits" {
    var ctx: ui.Context = undefined;
    ctx.size = .{ .w = 400, .h = 300 };
    const below = place(&ctx, .{ .x = 10, .y = 10, .w = 80, .h = 30 }, .{ .w = 120, .h = 100 }, .bottom_start, 6);
    try std.testing.expectEqual(ui.Point{ .x = 10, .y = 46 }, below);
    // Near the bottom: above instead.
    const above = place(&ctx, .{ .x = 10, .y = 250, .w = 80, .h = 30 }, .{ .w = 120, .h = 100 }, .bottom_start, 6);
    try std.testing.expectEqual(@as(f32, 144), above.y);
    // Near the right edge: kept in the window.
    const kept = place(&ctx, .{ .x = 380, .y = 10, .w = 20, .h = 20 }, .{ .w = 120, .h = 40 }, .bottom_start, 6);
    try std.testing.expectEqual(@as(f32, 274), kept.x);
}
