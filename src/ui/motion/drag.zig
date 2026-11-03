//! Drag with snap points and momentum, after gpui-motion's `Drag` and
//! Motion's drag: the next box follows the pointer while pressed, then
//! springs to a snap (or coasts) from the speed it had.
const std = @import("std");
const Context = @import("../context.zig").Context;
const motion = @import("motion.zig");
const Transition = @import("channel.zig").Transition;

pub const Axis = enum { x, y, both };

pub const Options = struct {
    min: [2]f32 = .{ -1e6, -1e6 },
    max: [2]f32 = .{ 1e6, 1e6 },
    /// Nearest of these on release (after `snap_grid`, if set).
    snap: []const [2]f32 = &.{},
    snap_grid: ?f32 = null,
    /// How far past min/max the pointer can pull (0 is hard edges).
    elasticity: f32 = 0,
    /// Keep the pointer's speed on release (a spring then settles).
    momentum: bool = true,
    axis: Axis = .both,
    transition: Transition = .default,
};

pub const Drag = struct {
    x: f32 = 0,
    y: f32 = 0,
    dragging: bool = false,
    /// The pointer moved far enough that this wasn't a click.
    moved: bool = false,
    animating: bool = false,

    pub fn frame(d: Drag) motion.Frame {
        return .{ .x = d.x, .y = d.y, .animating = d.animating or d.dragging, .gestures = true };
    }
};

/// The next box follows the pointer while pressed. Call it just before
/// the box (use `ui.key` first for a list's items).
pub fn drag(c: *Context, opts: Options) Drag {
    const id = c.peekId(null);
    const got = c.motion_store.get(c.gpa, id, c.frame) orelse return .{};
    const s = got.state;
    const chx = &s.ch[0];
    const chy = &s.ch[1];
    if (got.fresh) {
        chx.* = .at(0);
        chy.* = .at(0);
        s.has |= 0b11;
    }
    const over = c.hot == id or std.mem.indexOfScalar(u64, c.hot_path.items, id) != null;
    if (c.input.pressed and over) {
        chx.sample(c.time);
        chy.sample(c.time);
        s.dragging = true;
        s.drag_moved = false;
        s.drag_origin = .{ @floatCast(chx.value), @floatCast(chy.value) };
        s.pointer_origin = .{ c.input.mouse.x, c.input.mouse.y };
        s.pointer_last = s.pointer_origin;
        s.pointer_time = c.time;
        s.pointer_vel = .{ 0, 0 };
    }
    if (s.dragging and c.input.down) {
        var raw = follow(s.drag_origin, s.pointer_origin, .{ c.input.mouse.x, c.input.mouse.y }, opts.axis);
        raw = rubber(raw, opts.min, opts.max, opts.elasticity);
        const dt = @max(c.time - s.pointer_time, 1e-4);
        s.pointer_vel = .{
            (c.input.mouse.x - s.pointer_last[0]) / @as(f32, @floatCast(dt)),
            (c.input.mouse.y - s.pointer_last[1]) / @as(f32, @floatCast(dt)),
        };
        s.pointer_last = .{ c.input.mouse.x, c.input.mouse.y };
        s.pointer_time = c.time;
        if (@abs(raw[0] - s.drag_origin[0]) > 3 or @abs(raw[1] - s.drag_origin[1]) > 3) s.drag_moved = true;
        chx.jump(raw[0]);
        chy.jump(raw[1]);
        c.wants_moves = true;
        c.animationFrame();
    } else if (s.dragging and !c.input.down) {
        const goal = snapTo(.{ @floatCast(chx.value), @floatCast(chy.value) }, opts);
        const tr: Transition = if (c.reduced_motion) .instant else opts.transition;
        if (opts.momentum and !c.reduced_motion) {
            chx.velocity = s.pointer_vel[0];
            chy.velocity = s.pointer_vel[1];
        }
        chx.retarget(goal[0], tr, 0, c.time);
        chy.retarget(goal[1], tr, 0, c.time);
        s.dragging = false;
    }
    chx.sample(c.time);
    chy.sample(c.time);
    const moving = chx.moving or chy.moving or s.dragging;
    if (moving) c.animationFrame();
    return .{
        .x = @floatCast(chx.value),
        .y = @floatCast(chy.value),
        .dragging = s.dragging,
        .moved = s.drag_moved,
        .animating = moving,
    };
}

fn follow(origin: [2]f32, pointer0: [2]f32, pointer: [2]f32, axis: Axis) [2]f32 {
    var p: [2]f32 = .{ origin[0] + pointer[0] - pointer0[0], origin[1] + pointer[1] - pointer0[1] };
    if (axis == .x) p[1] = origin[1];
    if (axis == .y) p[0] = origin[0];
    return p;
}

fn rubber(p: [2]f32, min: [2]f32, max: [2]f32, k: f32) [2]f32 {
    return .{ pull(p[0], min[0], max[0], k), pull(p[1], min[1], max[1], k) };
}

fn pull(v: f32, lo: f32, hi: f32, k: f32) f32 {
    if (v < lo) return lo + (v - lo) * k;
    if (v > hi) return hi + (v - hi) * k;
    return v;
}

fn snapTo(p: [2]f32, opts: Options) [2]f32 {
    var out = p;
    if (opts.snap_grid) |g| if (g > 0) {
        out[0] = @round(out[0] / g) * g;
        out[1] = @round(out[1] / g) * g;
    };
    if (opts.snap.len > 0) {
        var best = opts.snap[0];
        var best_d = dist2(out, best);
        for (opts.snap[1..]) |pt| {
            const d = dist2(out, pt);
            if (d < best_d) {
                best = pt;
                best_d = d;
            }
        }
        out = best;
    }
    out[0] = std.math.clamp(out[0], opts.min[0], opts.max[0]);
    out[1] = std.math.clamp(out[1], opts.min[1], opts.max[1]);
    if (opts.axis == .x) out[1] = p[1];
    if (opts.axis == .y) out[0] = p[0];
    return out;
}

fn dist2(a: [2]f32, b: [2]f32) f32 {
    const dx = a[0] - b[0];
    const dy = a[1] - b[1];
    return dx * dx + dy * dy;
}

test "snap picks the nearest point and a grid" {
    const a = snapTo(.{ 12, 3 }, .{ .snap = &.{ .{ 0, 0 }, .{ 40, 0 } }, .min = .{ 0, 0 }, .max = .{ 40, 0 }, .axis = .x });
    try std.testing.expectEqual(@as(f32, 0), a[0]);
    const b = snapTo(.{ 30, 0 }, .{ .snap = &.{ .{ 0, 0 }, .{ 40, 0 } }, .min = .{ 0, 0 }, .max = .{ 40, 0 } });
    try std.testing.expectEqual(@as(f32, 40), b[0]);
    const g = snapTo(.{ 27, 0 }, .{ .snap_grid = 20, .min = .{ 0, 0 }, .max = .{ 100, 0 } });
    try std.testing.expectEqual(@as(f32, 20), g[0]);
}

test "rubber yields past the edge by elasticity" {
    try std.testing.expectEqual(@as(f32, 10), pull(10, 0, 20, 0.2));
    try std.testing.expectEqual(@as(f32, 22), pull(30, 0, 20, 0.2));
    try std.testing.expectEqual(@as(f32, 20), pull(30, 0, 20, 0));
}
