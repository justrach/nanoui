//! One animated number: where it is, how fast it's going, and where it's
//! headed by which transition since when. Retargeting is interruptible: a
//! spring keeps its position and velocity, a tween starts again from where
//! the value is.
const std = @import("std");
const Easing = @import("easing.zig").Easing;
const Spring = @import("spring.zig").Spring;

/// How a value goes from where it is to its target.
pub const Transition = union(enum) {
    /// At once (and always so when the system asks for reduced motion).
    instant,
    tween: struct { duration: f32 = 0.3, ease: Easing = .ease_out },
    spring: Spring,

    pub const default: Transition = .{ .spring = .{} };
};

pub const Channel = struct {
    /// Where it was and how fast when the current move began, and since when.
    from: f64 = 0,
    velocity0: f64 = 0,
    target: f64 = 0,
    since: f64 = 0,
    /// The move waits this long first (seconds).
    delay: f64 = 0,
    transition: Transition = .instant,
    /// Where it is now, and how fast, as last sampled.
    value: f64 = 0,
    velocity: f64 = 0,
    moving: bool = false,

    /// Placed at `v`, still.
    pub fn at(v: f64) Channel {
        return .{ .from = v, .target = v, .value = v };
    }

    /// Heads for `target` from now (`now` seconds), unless it already is.
    pub fn retarget(ch: *Channel, target: f64, tr: Transition, delay: f64, now: f64) void {
        // An accessibility snap interrupts even an unchanged destination.
        if (tr == .instant and delay <= 0) return ch.jump(target);
        if (target == ch.target and (ch.moving or ch.value == target)) return;
        ch.sample(now);
        ch.from = ch.value;
        // A tween's own velocity isn't carried on; a spring's is.
        ch.velocity0 = if (tr == .spring) ch.velocity else 0;
        ch.target = target;
        ch.since = now;
        ch.delay = delay;
        ch.transition = tr;
        ch.moving = ch.from != target or ch.velocity0 != 0;
    }

    /// There at once, still.
    pub fn jump(ch: *Channel, v: f64) void {
        ch.* = .{ .from = v, .target = v, .value = v };
    }

    /// Brings `value` and `velocity` up to `now`.
    pub fn sample(ch: *Channel, now: f64) void {
        if (!ch.moving) return;
        const t = now - ch.since - ch.delay;
        if (t < 0) {
            ch.value = ch.from;
            ch.velocity = 0;
            return;
        }
        switch (ch.transition) {
            .instant => ch.jump(ch.target),
            .tween => |tw| {
                const d: f64 = @max(tw.duration, 1e-4);
                const u = t / d;
                if (u >= 1) return ch.jump(ch.target);
                const e = tw.ease.sample(@floatCast(u));
                const span = ch.target - ch.from;
                ch.value = ch.from + span * e[0];
                ch.velocity = span * e[1] / d;
            },
            .spring => |s| {
                const m = s.matrix(t);
                const x0 = ch.from - ch.target;
                const x = m[0] * x0 + m[1] * ch.velocity0;
                const v = m[2] * x0 + m[3] * ch.velocity0;
                // At rest within a thousandth of the move (and of a point).
                const eps = @max(1e-3 * @abs(x0), 1e-3);
                if (s.settled(x, v, eps)) return ch.jump(ch.target);
                ch.value = ch.target + x;
                ch.velocity = v;
            },
        }
    }
};

test "a tween eases from where it was to its target, and stops there" {
    var ch: Channel = .at(0);
    ch.retarget(100, .{ .tween = .{ .duration = 1, .ease = .linear } }, 0, 10);
    ch.sample(10.25);
    try std.testing.expectApproxEqAbs(@as(f64, 25), ch.value, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 100), ch.velocity, 1e-6);
    ch.sample(11.5);
    try std.testing.expect(!ch.moving and ch.value == 100);
}

test "a spring retargeted mid-flight keeps its position and velocity" {
    var ch: Channel = .at(0);
    ch.retarget(100, .default, 0, 0);
    ch.sample(0.1);
    const pos = ch.value;
    const vel = ch.velocity;
    try std.testing.expect(pos > 0 and pos < 100 and vel > 0);
    ch.retarget(0, .default, 0, 0.1);
    ch.sample(0.1);
    try std.testing.expectApproxEqAbs(pos, ch.value, 1e-9);
    try std.testing.expectApproxEqAbs(vel, ch.velocity, 1e-9);
    ch.sample(5);
    try std.testing.expect(!ch.moving and ch.value == 0);
}

test "a delay holds the value where it was" {
    var ch: Channel = .at(1);
    ch.retarget(0, .{ .tween = .{ .duration = 0.2 } }, 0.5, 0);
    ch.sample(0.4);
    try std.testing.expectEqual(@as(f64, 1), ch.value);
    ch.sample(0.8);
    try std.testing.expectEqual(@as(f64, 0), ch.value);
}
