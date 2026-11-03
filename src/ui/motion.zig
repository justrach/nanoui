//! Springs and timed curves, as SwiftUI animates: values a view asks for
//! every frame by id, each moving toward its target from where it is.
//! A spring is the physical one (mass 1, stiffness (2π/response)²,
//! damping 4π·damping/response), stepped at 480 Hz; a tween follows a
//! cubic Bézier over its duration. Under Reduce Motion both are their
//! target at once.
const std = @import("std");
const Context = @import("context.zig").Context;

pub const Spring = @import("types.zig").Spring;

pub const Curve = union(enum) {
    ease_out,
    ease_in_out,
    linear,
    /// CSS's cubic-bezier(x1, y1, x2, y2).
    bezier: [4]f32,
};

const Entry = struct {
    value: f32,
    velocity: f32 = 0,
    target: f32,
    /// A tween's start value and seconds run.
    from: f32 = 0,
    elapsed: f32 = 0,
    /// The frame it last stepped in: a view built twice in one frame
    /// steps once. And the frame it was last asked for, for pruning.
    stepped: u64,
    used: u64,
};

pub const State = struct {
    entries: std.AutoHashMapUnmanaged(u64, Entry) = .empty,
    /// While laying out: how far the ancestors of the box being placed
    /// were moved (offsets, springs, scrolling), for `settleY`.
    carried: f32 = 0,

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        s.entries.deinit(gpa);
    }

    /// Forgets values not asked for in 120 frames.
    pub fn prune(s: *State, frame: u64) void {
        if (s.entries.count() <= 1024 and frame % 64 != 0) return;
        var stale: [1024]u64 = undefined;
        var n: usize = 0;
        var it = s.entries.iterator();
        while (it.next()) |e| {
            if (n == stale.len) break;
            if (frame - e.value_ptr.used > 120) {
                stale[n] = e.key_ptr.*;
                n += 1;
            }
        }
        for (stale[0..n]) |k| _ = s.entries.remove(k);
    }
};

fn keyOf(id: u64, salt: u32) u64 {
    var h = std.hash.Wyhash.init(id ^ 0x6d6f74696f6e);
    h.update(std.mem.asBytes(&salt));
    return h.final();
}

/// The entry for `id`/`salt`, made at `start` the first time; null under
/// Reduce Motion (its state dropped) or out of memory.
fn entry(c: *Context, id: u64, salt: u32, start: f32, target: f32) ?*Entry {
    const k = keyOf(id, salt);
    if (c.reduce_motion) {
        _ = c.motion.entries.remove(k);
        return null;
    }
    const gop = c.motion.entries.getOrPut(c.gpa, k) catch return null;
    if (!gop.found_existing) gop.value_ptr.* = .{ .value = start, .target = target, .from = start, .stepped = c.frame, .used = c.frame };
    gop.value_ptr.used = c.frame;
    return gop.value_ptr;
}

/// `id`'s value springing toward `target`; the first call is `target`.
pub fn spring(c: *Context, id: u64, salt: u32, target: f32, s: Spring) f32 {
    return springFrom(c, id, salt, target, target, s);
}

/// As `spring`, but the first call starts at `from` (an item entering).
pub fn springFrom(c: *Context, id: u64, salt: u32, from: f32, target: f32, s: Spring) f32 {
    const e = entry(c, id, salt, from, target) orelse return target;
    e.target = target;
    const stiffness = std.math.pow(f32, 2 * std.math.pi / s.response, 2);
    const damping = 4 * std.math.pi * s.damping / s.response;
    if (e.stepped != c.frame) {
        e.stepped = c.frame;
        const total = @max(0, @min(c.dt, 0.5) + e.elapsed);
        const h: f32 = 1.0 / 480.0;
        const steps: u32 = @intFromFloat(@floor(total * 480.0));
        e.elapsed = @max(0, total - @as(f32, @floatFromInt(steps)) * h);
        for (0..steps) |_| {
            const a0 = -stiffness * (e.value - target) - damping * e.velocity;
            const vmid = e.velocity + 0.5 * a0 * h;
            const xmid = e.value + 0.5 * e.velocity * h;
            const amid = -stiffness * (xmid - target) - damping * vmid;
            e.velocity += amid * h;
            e.value += vmid * h;
        }
    }
    if (@abs(e.value - target) < 0.0005 * @max(1, @abs(target)) and @abs(e.velocity) < 0.01) {
        e.value = target;
        e.velocity = 0;
        e.elapsed = 0;
        return target;
    }
    c.animating = true;
    const rem = e.elapsed;
    const a_rem = -stiffness * (e.value - target) - damping * e.velocity;
    return e.value + e.velocity * rem + 0.5 * a_rem * rem * rem;
}

/// Sets `id`'s spring or tween to `value` at rest.
pub fn jump(c: *Context, id: u64, salt: u32, value: f32) void {
    const e = entry(c, id, salt, value, value) orelse return;
    e.value = value;
    e.target = value;
    e.from = value;
    e.velocity = 0;
    e.elapsed = 0;
    e.stepped = c.frame;
    e.used = c.frame;
}

/// `id`'s value moving toward `target` over `duration` seconds along
/// `curve`, from where it was when the target changed; the first call is
/// `target`.
pub fn tween(c: *Context, id: u64, salt: u32, target: f32, duration: f32, curve: Curve) f32 {
    const e = entry(c, id, salt, target, target) orelse return target;
    if (e.target != target) {
        e.from = e.value;
        e.target = target;
        e.elapsed = 0;
    }
    if (e.stepped != c.frame) {
        e.stepped = c.frame;
        e.elapsed += @min(c.dt, 0.5);
    }
    const p = if (duration <= 0) 1 else @min(1, e.elapsed / duration);
    e.value = if (p >= 1) target else e.from + (target - e.from) * ease(curve, p);
    if (e.value != target) c.animating = true;
    return e.value;
}

/// The curve's progress at time fraction `x`.
pub fn ease(curve: Curve, x: f32) f32 {
    const p: [4]f32 = switch (curve) {
        .linear => return x,
        .ease_out => .{ 0, 0, 0.58, 1 },
        .ease_in_out => .{ 0.42, 0, 0.58, 1 },
        .bezier => |b| b,
    };
    // Solve x(t) = x by Newton's method, then read y(t).
    var t = x;
    for (0..6) |_| {
        const dx = bezierSlope(p[0], p[2], t);
        if (@abs(dx) < 1e-6) break;
        t = std.math.clamp(t - (bezierAt(p[0], p[2], t) - x) / dx, 0, 1);
    }
    return bezierAt(p[1], p[3], t);
}

fn bezierAt(a: f32, b: f32, t: f32) f32 {
    const u = 1 - t;
    return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t;
}

fn bezierSlope(a: f32, b: f32, t: f32) f32 {
    const u = 1 - t;
    return 3 * u * u * a + 6 * u * t * (b - a) + 3 * t * t * (1 - b);
}

const salt_place: u32 = 0x706c_6163;
const salt_moved: u32 = 0x6d6f_7665;

/// How far box `id` is shown from `natural`, its place down its parent in
/// this layout: moved since the last, it starts from where it was shown
/// and springs to it (`Style.settle_y`).
pub fn settleY(c: *Context, id: u64, natural: f32, s: Spring) f32 {
    const place = entry(c, id, salt_place, natural, natural) orelse return 0;
    const was = place.value;
    place.value = natural;
    const off = entry(c, id, salt_moved, 0, 0) orelse return 0;
    off.value += was - natural;
    return springFrom(c, id, salt_moved, 0, 0, s);
}

/// 1 once `watched` changes and `hold` seconds after, then down to 0 over
/// `fade`: what shows only while something moves (an overlay scroller).
pub fn flash(c: *Context, id: u64, salt: u32, watched: f32, hold: f32, fade: f32) f32 {
    // Kept under Reduce Motion too: the scroller still shows, as macOS's does.
    const gop = c.motion.entries.getOrPut(c.gpa, keyOf(id, salt)) catch return 0;
    if (!gop.found_existing) gop.value_ptr.* = .{ .value = 0, .target = watched, .stepped = c.frame, .used = c.frame };
    gop.value_ptr.used = c.frame;
    const e = gop.value_ptr;
    // `from`: when it last moved, in the context's clock.
    if (watched != e.target) {
        e.target = watched;
        e.from = @floatCast(c.time);
        e.value = 1;
    }
    if (e.value == 0) return 0;
    const elapsed = @as(f32, @floatCast(c.time)) - e.from;
    if (elapsed < hold) {
        c.frameIn(hold - elapsed);
        return 1;
    }
    const v = 1 - (elapsed - hold) / fade;
    if (v <= 0) {
        e.value = 0;
        return 0;
    }
    c.animating = true;
    return v;
}
