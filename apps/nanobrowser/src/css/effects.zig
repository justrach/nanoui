//! The kinds of value paint and animation read from a `Style`: transforms and
//! their matrices, clipping shapes, filters, and the timing of animations and
//! transitions. Lengths stay percentages here until a box says of what.
const std = @import("std");

const Len = @import("style.zig").Len;
const Color = @import("style.zig").Color;
const Shadow = @import("style.zig").Shadow;

/// A transform of the plane: x' = a x + c y + e, y' = b x + d y + f.
pub const Mat = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    e: f32 = 0,
    f: f32 = 0,

    pub const identity: Mat = .{};

    pub fn apply(m: Mat, x: f32, y: f32) [2]f32 {
        return .{ m.a * x + m.c * y + m.e, m.b * x + m.d * y + m.f };
    }

    /// `m` after `n`: what `n` puts somewhere, `m` then moves.
    pub fn times(m: Mat, n: Mat) Mat {
        return .{
            .a = m.a * n.a + m.c * n.b,
            .b = m.b * n.a + m.d * n.b,
            .c = m.a * n.c + m.c * n.d,
            .d = m.b * n.c + m.d * n.d,
            .e = m.a * n.e + m.c * n.f + m.e,
            .f = m.b * n.e + m.d * n.f + m.f,
        };
    }

    pub fn inverse(m: Mat) ?Mat {
        const det = m.a * m.d - m.b * m.c;
        if (@abs(det) < 1e-9) return null;
        const k = 1 / det;
        return .{ .a = m.d * k, .b = -m.b * k, .c = -m.c * k, .d = m.a * k, .e = (m.c * m.f - m.d * m.e) * k, .f = (m.b * m.e - m.a * m.f) * k };
    }

    /// Only moves things, or not even that.
    pub fn onlyMoves(m: Mat) bool {
        return m.a == 1 and m.b == 0 and m.c == 0 and m.d == 1;
    }

    pub fn translate(x: f32, y: f32) Mat {
        return .{ .e = x, .f = y };
    }

    pub fn scale(x: f32, y: f32) Mat {
        return .{ .a = x, .d = y };
    }

    pub fn rotate(deg: f32) Mat {
        const r = deg * std.math.pi / 180;
        const ca = @cos(r);
        const sa = @sin(r);
        return .{ .a = ca, .b = sa, .c = -sa, .d = ca };
    }

    pub fn skew(x_deg: f32, y_deg: f32) Mat {
        return .{ .b = @tan(y_deg * std.math.pi / 180), .c = @tan(x_deg * std.math.pi / 180) };
    }
};

/// One function of `transform`, its lengths still to be resolved against a box.
pub const Op = union(enum) {
    translate: struct { x: Len, y: Len },
    scale: [2]f32,
    /// Degrees.
    rotate: f32,
    /// Degrees.
    skew: [2]f32,
    matrix: Mat,
    /// Part way from one list to another of another shape (an animation).
    mix: *const Mix,
};

pub const Mix = struct { a: []const Op, b: []const Op, k: f32 };

/// `transform`.
pub const Transform = struct { ops: []const Op = &.{} };

/// `clip-path`'s shapes, in lengths against the border box.
pub const ClipPath = union(enum) {
    /// Top, right, bottom, left insets, and the corners' radius.
    inset: struct { t: Len, r: Len, b: Len, l: Len, radius: Len },
    /// Percentages of a circle's radius are of the box's diagonal, over √2.
    circle: struct { r: Len, cx: Len, cy: Len, closest: bool = false, farthest: bool = false },
    ellipse: struct { rx: Len, ry: Len, cx: Len, cy: Len, closest: bool = false, farthest: bool = false },
    polygon: []const [2]Len,
};

/// `clip: rect(...)`: the sides from the box's top left, null for `auto`.
pub const ClipRect = struct { top: ?f32 = null, right: ?f32 = null, bottom: ?f32 = null, left: ?f32 = null };

pub const FilterKind = enum { blur, brightness, contrast, grayscale, hue_rotate, invert, opacity, saturate, sepia, drop_shadow };

/// One function of `filter`.
pub const Filter = struct {
    kind: FilterKind,
    /// A blur's radius in pixels, a hue's turn in degrees, else the amount
    /// (1 for 100%).
    amount: f32 = 1,
    /// `drop-shadow`.
    shadow: Shadow = .{},
};

/// `animation-timing-function`, `transition-timing-function`.
pub const Timing = union(enum) {
    linear,
    bezier: [4]f32,
    steps: struct { n: u32, jump_start: bool, jump_end: bool },

    pub const ease: Timing = .{ .bezier = .{ 0.25, 0.1, 0.25, 1 } };
    pub const ease_in: Timing = .{ .bezier = .{ 0.42, 0, 1, 1 } };
    pub const ease_out: Timing = .{ .bezier = .{ 0, 0, 0.58, 1 } };
    pub const ease_in_out: Timing = .{ .bezier = .{ 0.42, 0, 0.58, 1 } };

    /// How far along at `t` (0 to 1) of the time.
    pub fn at(s: Timing, t_in: f32) f32 {
        const t = std.math.clamp(t_in, 0, 1);
        switch (s) {
            .linear => return t,
            .bezier => |b| return bezierY(b, t),
            .steps => |p| {
                const n: f32 = @floatFromInt(@max(p.n, 1));
                var step = @floor(t * n);
                if (p.jump_start) step += 1;
                var total = n;
                if (!p.jump_start and !p.jump_end) total = @max(n - 1, 1);
                if (p.jump_start and p.jump_end) total = n + 1;
                if (t >= 1 and !p.jump_end) return 1;
                return std.math.clamp(step / total, 0, 1);
            },
        }
    }
};

/// The curve's height where its x is `x`, found by bisection on x(u).
fn bezierY(b: [4]f32, x: f32) f32 {
    const curve = struct {
        fn f(p1: f32, p2: f32, u: f32) f32 {
            const v = 1 - u;
            return 3 * v * v * u * p1 + 3 * v * u * u * p2 + u * u * u;
        }
    }.f;
    var lo: f32 = 0;
    var hi: f32 = 1;
    var u = x;
    for (0..24) |_| {
        const got = curve(b[0], b[2], u);
        if (@abs(got - x) < 1e-4) break;
        if (got < x) lo = u else hi = u;
        u = (lo + hi) / 2;
    }
    return curve(b[1], b[3], u);
}

pub const FillMode = enum { none, forwards, backwards, both };
pub const Direction = enum { normal, reverse, alternate, alternate_reverse };

/// One name of `animation-name`, and what the other properties give it.
pub const Animation = struct {
    name: []const u8 = "",
    duration: f32 = 0,
    delay: f32 = 0,
    timing: Timing = Timing.ease,
    /// Infinite when `inf`.
    iterations: f32 = 1,
    direction: Direction = .normal,
    fill: FillMode = .none,
    paused: bool = false,
};

/// One entry of `transition-property`: `all` when `name` is.
pub const Transition = struct {
    name: []const u8 = "all",
    duration: f32 = 0,
    delay: f32 = 0,
    timing: Timing = Timing.ease,
};

test "timings" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), (Timing{ .linear = {} }).at(0.5), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.802), Timing.ease.at(0.5), 0.01);
    try std.testing.expectEqual(@as(f32, 1), Timing.ease.at(1));
    const s: Timing = .{ .steps = .{ .n = 2, .jump_start = false, .jump_end = true } };
    try std.testing.expectEqual(@as(f32, 0), s.at(0.25));
    try std.testing.expectEqual(@as(f32, 0.5), s.at(0.75));
    try std.testing.expectEqual(@as(f32, 1), s.at(1));
}

test "matrices" {
    const m = Mat.translate(10, 0).times(Mat.scale(2, 3));
    try std.testing.expectEqual(@as(f32, 12), m.apply(1, 1)[0]);
    try std.testing.expectEqual(@as(f32, 3), m.apply(1, 1)[1]);
    const r = Mat.rotate(90);
    try std.testing.expectApproxEqAbs(@as(f32, 1), r.apply(1, 0)[1], 1e-5);
    const i = m.inverse().?;
    try std.testing.expectApproxEqAbs(@as(f32, 1), i.apply(12, 3)[0], 1e-4);
}
