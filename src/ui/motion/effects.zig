//! Pure motion math ported from Harness ui/proto motion.rs.
//! Colors are unassociated sRGB; mix premultiplies only during interpolation.
const std = @import("std");
const Color = @import("../types.zig").Color;

pub const harness_pulse_ms: u64 = 2400;
pub const gradient_spin_ms: u64 = 750;
pub const pulse_min_opacity: f32 = 0.08;
pub const pulse_min_scale: f32 = 0.9;
pub const pulse_stagger: f32 = 0.15 / 2.4;
pub const gspin_dim: f32 = 0.1;
pub const resize_edge_nudge: f32 = 5.0;
pub const resize_edge_bounce_ms: u64 = 220;
pub const resize_edge_bounce_out_fraction: f32 = 0.32;

pub const ReduceMotion = enum { system, on, off };
pub const ResizeEdge = enum { min, max };
pub const ResizeDragSample = struct {
    width: f32,
    edge: ?ResizeEdge,
    starts_bounce: bool,
};

pub fn lerp(from: f32, to: f32, t: f32) f32 {
    return from + (to - from) * t;
}

// Rust rem_euclid: preserve the donor's floating-point remainder behavior.
fn wrapPhase(value: f32) f32 {
    const remainder = @rem(value, @as(f32, 1.0));
    return if (remainder < 0.0) remainder + 1.0 else remainder;
}

pub fn staggeredPhase(raw_delta: f32, index: usize, stagger: f32) f32 {
    return wrapPhase(raw_delta - @as(f32, @floatFromInt(index)) * stagger);
}

pub fn pulseWave(phase: f32) f32 {
    return 0.5 - 0.5 * @cos(phase * @as(f32, 2.0 * std.math.pi));
}

pub fn pulseOpacity(phase: f32) f32 {
    return pulse_min_opacity + (1.0 - pulse_min_opacity) * pulseWave(phase);
}

pub fn pulseScale(phase: f32) f32 {
    return pulse_min_scale + (1.0 - pulse_min_scale) * pulseWave(phase);
}

pub fn gspinOpacity(phase: f32, dim: f32) f32 {
    const t = wrapPhase(phase);
    if (t < 0.45) return lerp(1.0, dim, t / 0.45);
    if (t < 0.92) return dim;
    return lerp(dim, 1.0, (t - 0.92) / 0.08);
}

pub fn matrixWave(raw_delta: f32, wave_index: usize, wave_count: usize) f32 {
    const count: f32 = @floatFromInt(@max(wave_count, 1));
    return pulseWave(staggeredPhase(raw_delta, wave_index, 1.0 / count));
}

/// The caller stores edge as the next sample's latch; null releases it.
pub fn resizeDragSample(
    requested: f32,
    min: f32,
    max: f32,
    latched_edge: ?ResizeEdge,
    reduced_motion: bool,
) ResizeDragSample {
    std.debug.assert(min <= max);
    const edge: ?ResizeEdge = if (requested <= min) .min else if (requested >= max) .max else null;
    return .{
        .width = std.math.clamp(requested, min, max),
        .edge = edge,
        .starts_bounce = !reduced_motion and edge != null and edge != latched_edge,
    };
}

fn smoothstep(value: f32) f32 {
    const t = std.math.clamp(value, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

/// Phase is normalized elapsed time, independent of clocks or frame scheduling.
pub fn resizeBounceOffset(edge: ResizeEdge, phase: f32) f32 {
    const raw = std.math.clamp(phase, 0.0, 1.0);
    const magnitude = (if (raw < resize_edge_bounce_out_fraction)
        smoothstep(raw / resize_edge_bounce_out_fraction)
    else
        1.0 - smoothstep((raw - resize_edge_bounce_out_fraction) / (1.0 - resize_edge_bounce_out_fraction))) * resize_edge_nudge;
    return switch (edge) {
        .min => -magnitude,
        .max => magnitude,
    };
}

/// Premultiplied-alpha interpolation in sRGB (not linear-light RGB).
pub fn mix(from: Color, to: Color, progress: f32) Color {
    const t = std.math.clamp(progress, 0.0, 1.0);
    if (t <= 0.0) return from;
    if (t >= 1.0) return to;
    const a = lerp(from.a, to.a, t);
    if (a <= std.math.floatEps(f32)) {
        var transparent = to;
        transparent.a = 0.0;
        return transparent;
    }
    return .{
        .r = lerp(from.r * from.a, to.r * to.a, t) / a,
        .g = lerp(from.g * from.a, to.g * to.a, t) / a,
        .b = lerp(from.b * from.a, to.b * to.a, t) / a,
        .a = a,
    };
}

pub fn resolve(preference: ReduceMotion, system: bool, pause_in_background: bool, active: bool) bool {
    const reduced = switch (preference) {
        .system => system,
        .on => true,
        .off => false,
    };
    return reduced or (pause_in_background and !active);
}
