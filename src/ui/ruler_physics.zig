//! Bounded ruler motion in value units; the existing exact spring solver
//! makes release independent of the display's refresh rate.
const std = @import("std");
const Spring = @import("motion/spring.zig").Spring;
const spring: Spring = .{ .stiffness = 240, .damping = 31 };
const numeral_spring: Spring = .{ .stiffness = 2500, .damping = 100 };

pub const Model = struct {
    min: f64 = 0,
    max: f64 = 99,
    position: f64 = 0,
    velocity: f64 = 0,
    target: f64 = 0,
    dragging: bool = false,
    moved: bool = false,
    origin: f64 = 0,
    pointer: f64 = 0,
    previous: f64 = 0,
    age: f64 = 0,
    rolling: f64 = 0,
    rolling_velocity: f64 = 0,

    pub fn value(m: Model) i32 {
        return @intFromFloat(@round(std.math.clamp(m.position, m.min, m.max)));
    }

    pub fn begin(m: *Model, x: f64) void {
        if (!std.math.isFinite(x)) return;
        m.dragging = true;
        m.moved = false;
        m.origin = m.position;
        m.pointer = x;
        m.previous = x;
        m.velocity = 0;
        m.age = 0;
    }

    /// Leftward content motion increases the selected value.
    pub fn drag(m: *Model, x: f64, spacing: f64, dt: f64) void {
        if (!m.dragging or !std.math.isFinite(x) or !std.math.isFinite(spacing) or spacing <= 0) return;
        const next = std.math.clamp(m.origin - (x - m.pointer) / spacing, m.min, m.max);
        if (@abs(x - m.pointer) > 3) m.moved = true;
        if (x != m.previous) {
            if (dt > 0 and std.math.isFinite(dt))
                m.velocity = std.math.clamp((next - m.position) / @max(dt, 0.001), -120, 120);
            m.age = 0;
        }
        m.position = next;
        m.previous = x;
    }

    pub fn release(m: *Model) void {
        if (!m.dragging) return;
        m.dragging = false;
        if (m.age > 0.08) m.velocity = 0;
        m.target = std.math.clamp(@round(m.position + m.velocity * 0.10), m.min, m.max);
    }

    pub fn select(m: *Model, value_: f64) void {
        if (!std.math.isFinite(value_)) return;
        m.target = std.math.clamp(@round(value_), m.min, m.max);
    }

    pub fn advance(m: *Model, dt: f64, reduced: bool) void {
        if (!std.math.isFinite(dt) or dt < 0) return;
        m.age += dt;
        if (!m.dragging) {
            if (reduced) {
                m.position = m.target;
                m.velocity = 0;
            } else {
                solve(spring, &m.position, &m.velocity, m.target, dt);
                const bounded = std.math.clamp(m.position, m.min, m.max);
                if (bounded != m.position) m.velocity = 0;
                m.position = bounded;
            }
        }
        const goal: f64 = @floatFromInt(m.value());
        if (reduced) {
            m.rolling = goal;
            m.rolling_velocity = 0;
        } else solve(numeral_spring, &m.rolling, &m.rolling_velocity, goal, dt);
    }

    pub fn moving(m: Model) bool {
        return (!m.dragging and (@abs(m.position - m.target) > 0.0001 or @abs(m.velocity) > 0.001)) or
            @abs(m.rolling - @as(f64, @floatFromInt(m.value()))) > 0.0001 or @abs(m.rolling_velocity) > 0.001;
    }
};

fn solve(config: Spring, p: *f64, v: *f64, target: f64, dt: f64) void {
    const mat = config.matrix(dt);
    const d = p.* - target;
    const vel = v.*;
    p.* = target + mat[0] * d + mat[1] * vel;
    v.* = mat[2] * d + mat[3] * vel;
    if (config.settled(p.* - target, v.*, 0.0001)) {
        p.* = target;
        v.* = 0;
    }
}
