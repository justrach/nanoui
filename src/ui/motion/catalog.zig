//! Harness's motion.rs catalog, in milliseconds. Adapters use nanoui's
//! existing interruptible channels, not a second animation engine.
const std = @import("std");
const motion = @import("motion.zig");
const Easing = motion.Easing;

pub const ease_out_expo: Easing = .{ .bezier = .{ 0.16, 1, 0.3, 1 } };
pub const ease_out: Easing = Easing.css_ease_out;
pub const ease: Easing = Easing.css_ease;
pub const ease_out_quint: Easing = .{ .bezier = .{ 0.22, 1, 0.36, 1 } };
pub const ease_resort: Easing = ease_out_quint;
pub const ease_in_out: Easing = Easing.css_ease_in_out;
pub const ease_tailwind: Easing = .{ .bezier = .{ 0.4, 0, 0.2, 1 } };

pub const MotionSpec = struct {
    duration_ms: u32,
    delay_ms: u32 = 0,
    curve: Easing,

    pub fn withDelay(spec: MotionSpec, milliseconds: u32) MotionSpec {
        var result = spec;
        result.delay_ms = milliseconds;
        return result;
    }

    /// Whole timeline in seconds, including the initial hold.
    pub fn total(spec: MotionSpec) f64 {
        return (@as(f64, @floatFromInt(spec.duration_ms)) + @as(f64, @floatFromInt(spec.delay_ms))) / 1000;
    }

    /// Eased progress across the whole timeline; holds zero during delay.
    pub fn progress(spec: MotionSpec, raw_delta: f32) f32 {
        if (spec.duration_ms == 0) return 1;
        const duration: f32 = @floatFromInt(spec.duration_ms);
        const delay: f32 = @floatFromInt(spec.delay_ms);
        const t = (std.math.clamp(raw_delta, 0, 1) * (duration + delay) - delay) / duration;
        // Catalog curves describe opacity too: f32 roundoff must not exceed 1.
        return std.math.clamp(spec.curve.sample(std.math.clamp(t, 0, 1))[0], 0, 1);
    }

    /// Duration/curve for number(), layout motion, or a custom target.
    /// A channel's delay is separate; motion() applies it automatically.
    pub fn transition(spec: MotionSpec) motion.Transition {
        if (spec.duration_ms == 0) return .instant;
        return .{ .tween = .{ .duration = @as(f32, @floatFromInt(spec.duration_ms)) / 1000, .ease = spec.curve } };
    }

    /// Declarative entry from initial to target, including delay.
    pub fn animate(spec: MotionSpec, initial: motion.Target, target: motion.Target) motion.Motion {
        return .{
            .initial = initial,
            .target = target,
            .transition = spec.transition(),
            .delay = if (spec.duration_ms == 0) 0 else @as(f32, @floatFromInt(spec.delay_ms)) / 1000,
        };
    }

    /// Explicit measurement knob, like HARNESS_MOTION_SCALE, without reading
    /// process environment or changing any other window's timing.
    pub fn scaled(spec: MotionSpec, factor: f32) MotionSpec {
        const scale: f64 = if (std.math.isFinite(factor)) std.math.clamp(factor, 0.01, 100) else 1;
        const limit: f64 = std.math.maxInt(u32);
        return .{
            .duration_ms = @intFromFloat(@min(limit, @round(@as(f64, @floatFromInt(spec.duration_ms)) * scale))),
            .delay_ms = @intFromFloat(@min(limit, @round(@as(f64, @floatFromInt(spec.delay_ms)) * scale))),
            .curve = spec.curve,
        };
    }
};

pub const fade_in: MotionSpec = .{ .duration_ms = 500, .curve = ease_out_expo };
pub const fade_quick: MotionSpec = .{ .duration_ms = 150, .curve = ease };
pub const menu_in: MotionSpec = .{ .duration_ms = 140, .curve = ease };
pub const menu_out: MotionSpec = .{ .duration_ms = 100, .curve = ease };
pub const dialog_in: MotionSpec = .{ .duration_ms = 180, .curve = ease };
pub const splash_out: MotionSpec = .{ .duration_ms = 500, .delay_ms = 150, .curve = ease };
pub const resize: MotionSpec = .{ .duration_ms = 200, .curve = ease_out };
pub const tab_slide: MotionSpec = .{ .duration_ms = 150, .curve = ease_out };
pub const collapse: MotionSpec = .{ .duration_ms = 180, .curve = ease_out };
pub const new_thread_transition: MotionSpec = .{ .duration_ms = 420, .curve = ease_resort };
pub const chevron: MotionSpec = .{ .duration_ms = 200, .curve = ease };
pub const scroll_glide: MotionSpec = .{ .duration_ms = 500, .curve = ease_in_out };
pub const hover_fade: MotionSpec = .{ .duration_ms = 150, .curve = ease_tailwind };
pub const harness_pulse: MotionSpec = .{ .duration_ms = 2400, .curve = ease };
pub const gradient_spin: MotionSpec = .{ .duration_ms = 750, .curve = ease };
pub const hover_reveal: MotionSpec = .{ .duration_ms = 320, .curve = ease_out_quint };
