//! Keyframes: a box through a list of targets over a duration, once, a
//! number of times, or forever, there and back with `yoyo`; each step
//! eased. They start over when the keyframes themselves change.
const std = @import("std");
const Context = @import("../context.zig").Context;
const motion = @import("motion.zig");
const store = @import("store.zig");
const Easing = @import("easing.zig").Easing;
const Target = motion.Target;
const Frame = motion.Frame;

pub const Keyframes = struct {
    /// Two or more.
    values: []const Target,
    /// Where each value falls, 0 to 1, rising (else evenly spread).
    times: ?[]const f32 = null,
    /// Seconds a pass takes.
    duration: f32 = 1,
    /// Each step's curve.
    ease: Easing = .ease_in_out,
    /// Passes after the first: 0 plays once, null forever.
    repeat: ?u32 = 0,
    /// Every other pass runs backward.
    yoyo: bool = false,
    delay: f32 = 0,
};

/// The next box's look, played through `k` (a pulse, a shake, a spinner).
pub fn keyframes(c: *Context, k: Keyframes) Frame {
    if (k.values.len == 0) return .{};
    const id = c.peekId(null);
    const got = c.motion_store.get(c.gpa, id, c.frame) orelse return look(k, 0);
    const s = got.state;
    const which = identity(k);
    if (got.fresh or s.clip_id != which) {
        s.clip_id = which;
        s.clip_start = c.time;
    }
    // Reduced motion: where it ends, or its first look if it never does.
    if (c.reduced_motion or c.reduce_motion) return look(k, if (k.repeat == null) 0 else end(k));
    const elapsed = c.time - s.clip_start - k.delay;
    if (elapsed < 0) {
        c.animationFrame();
        var f = look(k, 0);
        f.animating = true;
        return f;
    }
    const d: f64 = @max(k.duration, 1e-3);
    const pass: u64 = @intFromFloat(@floor(elapsed / d));
    if (k.repeat) |r| if (pass > r) return look(k, end(k));
    var u: f32 = @floatCast(@mod(elapsed, d) / d);
    if (k.yoyo and pass % 2 == 1) u = 1 - u;
    var f = look(k, u);
    f.animating = true;
    c.animationFrame();
    return f;
}

/// Where the last pass ends: backward on an odd one with `yoyo`.
fn end(k: Keyframes) f32 {
    const passes = (k.repeat orelse 0) + 1;
    return if (k.yoyo and passes % 2 == 0) 0 else 1;
}

fn identity(k: Keyframes) u64 {
    var h = std.hash.Wyhash.init(0);
    for (k.values) |v| h.update(std.mem.asBytes(&v));
    if (k.times) |t| h.update(std.mem.sliceAsBytes(t));
    h.update(std.mem.asBytes(&k.duration));
    return h.final();
}

fn timeOf(k: Keyframes, i: usize) f32 {
    if (k.times) |t| if (i < t.len) return t[i];
    if (k.values.len < 2) return 0;
    return @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(k.values.len - 1));
}

/// The look at `u` of the way through a pass.
pub fn look(k: Keyframes, u: f32) Frame {
    var seg: usize = 0;
    while (seg + 2 < k.values.len and u > timeOf(k, seg + 1)) seg += 1;
    const t0 = timeOf(k, seg);
    const t1 = timeOf(k, @min(seg + 1, k.values.len - 1));
    const local = if (t1 > t0) std.math.clamp((u - t0) / (t1 - t0), 0, 1) else 1;
    const e = k.ease.sample(local)[0];
    const a = k.values[seg];
    const b = k.values[@min(seg + 1, k.values.len - 1)];
    var f: Frame = .{};
    for (0..store.channels) |i| {
        const va = a.get(i) orelse b.get(i) orelse continue;
        const vb = b.get(i) orelse va;
        motion.setChannel(&f, i, va + (vb - va) * e);
    }
    return f;
}

test "keyframes: steps eased in turn, passes repeated, there and back" {
    const k: Keyframes = .{
        .values = &.{ .{ .x = 0 }, .{ .x = 10 }, .{ .x = 0 } },
        .ease = .linear,
    };
    try std.testing.expectEqual(@as(f32, 5), look(k, 0.25).x);
    try std.testing.expectEqual(@as(f32, 10), look(k, 0.5).x);
    try std.testing.expectEqual(@as(f32, 5), look(k, 0.75).x);
    const uneven: Keyframes = .{ .values = &.{ .{ .opacity = 0 }, .{ .opacity = 1 } }, .times = &.{ 0, 0.5 }, .ease = .linear };
    try std.testing.expectEqual(@as(f32, 1), look(uneven, 0.75).opacity);
    try std.testing.expectEqual(@as(f32, 0), end(.{ .values = k.values, .repeat = 1, .yoyo = true }));
}
