//! Declarative, interruptible motion, after gpui-motion: say where a box
//! should be (its target) and how to get there (a spring or a tween), every
//! frame; motion remembers where it is and moves it there, and a target
//! that changes midway is taken from where the box is, a spring keeping its
//! speed. Boxes enter from `initial` and, through `present`, leave to
//! `exit`; `hover` and `press` are targets while the pointer is over or
//! pressing. State lives in the Context by the box's id: no objects to
//! keep. Frames are drawn only while something moves.
//!
//!     const f = ui.motion.frame(c, .{
//!         .target = .{ .width = if (open) 320 else 180 },
//!         .initial = .{ .y = 12, .opacity = 0 },
//!         .press = .{ .scale = 0.97 },
//!     });
//!     const card = ui.div(c).bg(...).control().motion(f);
const std = @import("std");
const types = @import("../types.zig");
const Context = @import("../context.zig").Context;
const store = @import("store.zig");
const ch_mod = @import("channel.zig");
pub const Channel = ch_mod.Channel;
pub const Transition = ch_mod.Transition;
pub const Spring = @import("spring.zig").Spring;
pub const Easing = @import("easing.zig").Easing;
pub const State = store.State;
pub const Keyframes = @import("keyframes.zig").Keyframes;
pub const keyframes = @import("keyframes.zig").keyframes;
pub const layoutShift = @import("layout.zig").shift;
pub const Store = store.Store;
pub const scroll = @import("scroll.zig");
pub const drag = @import("drag.zig").drag;
pub const Drag = @import("drag.zig").Drag;
pub const DragOptions = @import("drag.zig").Options;
pub const Axis = @import("drag.zig").Axis;
pub const share = @import("share.zig").share;
pub const shareId = @import("share.zig").idOf;
pub const letters = @import("text.zig").text;
pub const TextUnit = @import("text.zig").Unit;
pub const TextOptions = @import("text.zig").Options;
pub const roll = @import("roll.zig").roll;
pub const RollOptions = @import("roll.zig").Options;
pub const Pull = @import("pull.zig").Pull;
const Color = types.Color;

/// Where a box is headed; what's left null is left alone.
pub const Target = struct {
    /// Moved by (points), as `Style.offset` moves a box.
    x: ?f32 = null,
    y: ?f32 = null,
    /// Drawn larger or smaller about its center.
    scale: ?f32 = null,
    opacity: ?f32 = null,
    width: ?f32 = null,
    height: ?f32 = null,
    radius: ?f32 = null,
    background: ?Color = null,

    /// `base` with what `patch` sets put over it.
    pub fn overlay(base: Target, patch: Target) Target {
        var t = base;
        inline for (@typeInfo(Target).@"struct".field_names) |name| {
            if (@field(patch, name)) |v| @field(t, name) = v;
        }
        return t;
    }

    /// Channel `i`'s value, if the target sets it.
    pub fn get(t: Target, i: usize) ?f32 {
        return switch (i) {
            0 => t.x,
            1 => t.y,
            2 => t.scale,
            3 => t.opacity,
            4 => t.width,
            5 => t.height,
            6 => t.radius,
            7 => if (t.background) |c| c.r else null,
            8 => if (t.background) |c| c.g else null,
            9 => if (t.background) |c| c.b else null,
            10 => if (t.background) |c| c.a else null,
            else => null,
        };
    }
};

/// Where a channel rests when no target names it: in place, full size, seen.
fn rest(i: usize) ?f32 {
    return switch (i) {
        0, 1 => 0,
        2, 3 => 1,
        else => null,
    };
}

pub const Motion = struct {
    target: Target = .{},
    /// Where it starts the first time it's drawn (else at its target).
    initial: ?Target = null,
    /// Where `present` takes it as it leaves.
    exit: ?Target = null,
    /// Over the target while the pointer is over it, or pressing it.
    hover: ?Target = null,
    press: ?Target = null,
    transition: Transition = .default,
    /// Seconds before it moves (`stagger` for a list's).
    delay: f32 = 0,
    /// When the layout moves the box, it glides there (by `transition`).
    layout: bool = false,
};

/// A box's look this frame: apply it with `Div.motion` or `apply`.
pub const Frame = struct {
    x: f32 = 0,
    y: f32 = 0,
    scale: f32 = 1,
    opacity: f32 = 1,
    width: ?f32 = null,
    height: ?f32 = null,
    radius: ?f32 = null,
    background: ?Color = null,
    /// Something is still moving.
    animating: bool = false,
    /// It has hover or press targets: its box must take the pointer.
    gestures: bool = false,
    /// Its box glides when the layout moves it (the box's id).
    layout: u64 = 0,

    pub fn apply(f: Frame, s: *types.Style) void {
        s.offset.x += f.x;
        s.offset.y += f.y;
        s.scale *= f.scale;
        s.opacity *= std.math.clamp(f.opacity, 0, 1);
        if (f.width) |w| s.width = .{ .px = @max(0, w) };
        if (f.height) |h| s.height = .{ .px = @max(0, h) };
        if (f.radius) |r| s.radius = @max(0, r);
        if (f.background) |b| s.background = b;
        if (f.layout != 0) s.layout_motion = f.layout;
    }
};

/// The look of the next box, moving toward `m`'s target. Call it just
/// before the box (use `ui.key` first for a list's items).
pub fn frame(c: *Context, m: Motion) Frame {
    const id = c.peekId(null);
    const got = c.motion_store.get(c.gpa, id, c.frame) orelse return still(m.target);
    const s = got.state;
    if (got.fresh) s.mounted = true;
    return step(c, s, id, m, if (got.fresh) m.initial else null, false);
}

/// Presence: the next box (keyed `key`) while `show`, entering from
/// `m.initial`; once `show` goes false it leaves to `m.exit`, and this
/// returns null when it's gone. Draw the box only when it returns a frame.
pub fn present(c: *Context, key: []const u8, show: bool, m: Motion) ?Frame {
    c.next_key = key;
    const id = c.peekId(null);
    const known = c.motion_store.map.getPtr(id);
    if (!show and (known == null or !known.?.mounted)) {
        c.next_key = null;
        return null;
    }
    const got = c.motion_store.get(c.gpa, id, c.frame) orelse return if (show) still(m.target) else null;
    const s = got.state;
    const entering = !s.mounted;
    if (show) {
        s.mounted = true;
        s.exiting = false;
    } else s.exiting = true;
    const f = step(c, s, id, m, if (entering) m.initial else null, s.exiting);
    if (s.exiting and !f.animating) {
        // Gone: next time it's shown it enters again.
        s.* = .{};
        c.next_key = null;
        return null;
    }
    return f;
}

/// A number easing to `value` (a counter, a meter): keyed `key` under the
/// box now open.
pub fn number(c: *Context, key: []const u8, value: f32, tr: Transition) f32 {
    const id = scoped(c, key);
    const got = c.motion_store.get(c.gpa, id, c.frame) orelse return value;
    const ch = &got.state.ch[0];
    if (got.fresh) ch.* = .at(value);
    ch.retarget(value, if (c.reduced_motion or c.reduce_motion) .instant else tr, 0, c.time);
    ch.sample(c.time);
    if (ch.moving) c.animationFrame();
    return @floatCast(ch.value);
}

/// The delay of item `i` of a list whose items follow each other by `each`
/// seconds.
pub fn stagger(i: usize, each: f32) f32 {
    return @as(f32, @floatFromInt(i)) * each;
}

fn scoped(c: *Context, key: []const u8) u64 {
    var h = std.hash.Wyhash.init(c.peekId(null));
    h.update("motion:");
    h.update(key);
    return h.final();
}

/// The target as it stands, without motion (when memory runs out).
fn still(t: Target) Frame {
    var f: Frame = .{};
    for (0..store.channels) |i| if (t.get(i)) |v| setChannel(&f, i, v);
    return f;
}

pub fn setChannel(f: *Frame, i: usize, v: f32) void {
    switch (i) {
        0 => f.x = v,
        1 => f.y = v,
        2 => f.scale = v,
        3 => f.opacity = v,
        4 => f.width = v,
        5 => f.height = v,
        6 => f.radius = v,
        7...10 => {
            var b = f.background orelse Color{};
            const value = std.math.clamp(v, 0, 1);
            switch (i) {
                7 => b.r = value,
                8 => b.g = value,
                9 => b.b = value,
                else => b.a = value,
            }
            f.background = b;
        },
        else => {},
    }
}

/// Moves `s` toward what `m` asks now and reads it out.
fn step(c: *Context, s: *State, id: u64, m: Motion, initial: ?Target, leaving: bool) Frame {
    var goal = m.target;
    if (leaving) {
        if (m.exit) |e| goal = goal.overlay(e);
    } else {
        // Over it, or over something in it; pressing it alone.
        const over = c.hot == id or std.mem.indexOfScalar(u64, c.hot_path.items, id) != null;
        if (m.hover) |h| if (over) {
            goal = goal.overlay(h);
        };
        if (m.press) |p| if (c.active == id) {
            goal = goal.overlay(p);
        };
    }
    const tr: Transition = if (c.reduced_motion or c.reduce_motion) .instant else m.transition;
    var f: Frame = .{ .gestures = m.hover != null or m.press != null, .layout = if (m.layout) id else 0 };
    if (m.layout) s.layout_transition = m.transition;
    for (0..store.channels) |i| {
        const bit = @as(u16, 1) << @intCast(i);
        const ch = &s.ch[i];
        const entry: ?f32 = if (initial) |t| t.get(i) else null;
        const known = s.has & bit != 0;
        // Named now; else back to rest once it has moved, or from `initial`.
        const target = goal.get(i) orelse if (known or entry != null)
            rest(i) orelse entry orelse @as(f32, @floatCast(ch.target))
        else
            continue;
        if (!known) {
            // First seen: from where `initial` puts it, else from rest (a
            // hover's scale grows from 1), else there already.
            ch.* = .at(entry orelse rest(i) orelse target);
            s.has |= bit;
        }
        ch.retarget(target, tr, m.delay, c.time);
        ch.sample(c.time);
        setChannel(&f, i, @floatCast(ch.value));
        if (ch.moving) f.animating = true;
    }
    if (f.animating) c.animationFrame();
    return f;
}

test {
    _ = @import("keyframes.zig");
    _ = @import("layout.zig");
    _ = @import("easing.zig");
    _ = @import("spring.zig");
    _ = @import("channel.zig");
    _ = @import("scroll.zig");
    _ = @import("drag.zig");
    _ = @import("share.zig");
    _ = @import("text.zig");
    _ = @import("roll.zig");
    _ = @import("pull.zig");
}
