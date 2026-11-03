//! A damped spring, solved exactly (as gpui-motion solves it): no stepping,
//! so a value at any time is the same however the frames fell, and a
//! spring retargeted mid-flight keeps its position and its velocity.
const std = @import("std");

/// The last closed-form solution: channels of one spring share a clock.
var cache: struct {
    t: f64 = -1,
    stiffness: f32 = 0,
    damping: f32 = 0,
    mass: f32 = 0,
    m: [4]f64 = .{ 0, 0, 0, 0 },
} = .{};

pub const Spring = struct {
    stiffness: f32 = 240,
    damping: f32 = 26,
    mass: f32 = 1,

    /// A spring that first reaches 90% of a step in `duration` seconds;
    /// `bounce` in (-1, 1) sets the damping ratio to 1 - bounce (below 0 is
    /// overdamped). gpui-motion's visual convention.
    pub fn visual(duration: f32, bounce: f32) Spring {
        const ratio: f64 = 1 - @as(f64, std.math.clamp(bounce, -0.99, 0.99));
        const unit: Spring = .{ .stiffness = 1, .damping = @floatCast(2 * ratio), .mass = 1 };
        var high: f64 = 1;
        while (unit.matrix(high)[0] > 0.1) high *= 2;
        var low: f64 = 0;
        for (0..64) |_| {
            const mid = (low + high) / 2;
            if (unit.matrix(mid)[0] > 0.1) low = mid else high = mid;
        }
        const omega = high / @max(@as(f64, duration), 1e-3);
        return .{ .stiffness = @floatCast(omega * omega), .damping = @floatCast(2 * ratio * omega), .mass = 1 };
    }

    /// Gentle, snappy and bouncy presets.
    pub const gentle: Spring = .{ .stiffness = 120, .damping = 20 };
    pub const snappy: Spring = .{ .stiffness = 400, .damping = 34 };
    pub const bouncy: Spring = .{ .stiffness = 300, .damping = 14 };

    /// How displacement x0 and velocity v0 at time 0 become x and v at
    /// `seconds`: x = m[0] x0 + m[1] v0, v = m[2] x0 + m[3] v0, the exact
    /// solution of m x'' + c x' + k x = 0.
    pub fn matrix(s: Spring, seconds: f64) [4]f64 {
        // Many channels of the same spring share a clock: the last
        // solution is reused when stiffness, damping, mass and t match.
        if (seconds == cache.t and s.stiffness == cache.stiffness and s.damping == cache.damping and s.mass == cache.mass)
            return cache.m;
        const m = s.compute(seconds);
        cache = .{ .t = seconds, .stiffness = s.stiffness, .damping = s.damping, .mass = s.mass, .m = m };
        return m;
    }

    fn compute(s: Spring, seconds: f64) [4]f64 {
        const k: f64 = s.stiffness;
        const c: f64 = s.damping;
        const m: f64 = s.mass;
        const omega = @sqrt(k / m);
        const decay = c / (2 * m);
        const disc = decay * decay - omega * omega;
        var a: f64 = undefined;
        var b: f64 = undefined;
        if (@abs(disc) <= omega * omega * 1e-10) {
            const e = @exp(-decay * seconds);
            a = e;
            b = e * seconds;
        } else if (disc < 0) {
            const f = @sqrt(-disc);
            const e = @exp(-decay * seconds);
            a = e * @cos(f * seconds);
            b = e * @sin(f * seconds) / f;
        } else {
            const root = @sqrt(disc);
            // The quotient avoids cancellation in -decay + root.
            const slow = -omega * omega / (decay + root);
            const fast = -decay - root;
            const se = @exp(slow * seconds);
            const fe = @exp(fast * seconds);
            a = (se + fe) / 2;
            b = (se - fe) / (2 * root);
        }
        return .{ a + decay * b, b, -omega * omega * b, a - decay * b };
    }

    /// Whether it has come to rest at its target: within `epsilon` units
    /// and moving slower than its frequency allows for that.
    pub fn settled(s: Spring, displacement: f64, velocity: f64, epsilon: f64) bool {
        return @abs(displacement) <= epsilon and @abs(velocity) <= epsilon * @sqrt(@as(f64, s.stiffness) / s.mass);
    }
};

test "a spring settles at its target, and its velocity is the position's slope" {
    const s: Spring = .{};
    const x0: f64 = -100;
    var t: f64 = 0.01;
    while (t < 3) : (t += 0.01) {
        const h = 1e-6;
        const ahead = s.matrix(t + h)[0] * x0;
        const behind = s.matrix(t - h)[0] * x0;
        const v = s.matrix(t)[2] * x0;
        try std.testing.expectApproxEqAbs((ahead - behind) / (2 * h), v, 1e-3 * @max(1, @abs(v)));
    }
    const end = s.matrix(3);
    try std.testing.expect(s.settled(end[0] * x0, end[2] * x0, 0.01));
}

test "a visual spring reaches 90% of a step in its duration" {
    for ([_]f32{ 0, 0.3, -0.5 }) |bounce| {
        const s = Spring.visual(0.4, bounce);
        // Displacement from the target falls to 10% at 0.4 s.
        try std.testing.expectApproxEqAbs(@as(f64, 0.1), s.matrix(0.4)[0], 2e-3);
    }
}
