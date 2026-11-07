const std = @import("std");
const effects = @import("effects.zig");
const Color = @import("../types.zig").Color;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;

fn close(expected: f32, actual: f32) !void {
    try std.testing.expectApproxEqAbs(expected, actual, 0.00001);
}

test "source pulse and resize timing constants" {
    try equal(@as(u64, 2400), effects.harness_pulse_ms);
    try equal(@as(u64, 750), effects.gradient_spin_ms);
    try equal(@as(u64, 220), effects.resize_edge_bounce_ms);
    try close(5, effects.resize_edge_nudge);
    try close(0.32, effects.resize_edge_bounce_out_fraction);
}

test "source pulse quarter cycles and extrapolating lerp" {
    try close(2, effects.lerp(2, 6, 0));
    try close(6, effects.lerp(2, 6, 1));
    try close(0, effects.lerp(2, 6, -0.5));
    try close(8, effects.lerp(2, 6, 1.5));
    const phases = [_]f32{ -0.5, 0, 0.25, 0.5, 0.75, 1, 1.5 };
    const waves = [_]f32{ 1, 0, 0.5, 1, 0.5, 0, 1 };
    for (phases, waves) |phase, wave| {
        try close(wave, effects.pulseWave(phase));
    }
    try close(0.08, effects.pulseOpacity(0));
    try close(0.54, effects.pulseOpacity(0.25));
    try close(1, effects.pulseOpacity(0.5));
    try close(0.9, effects.pulseScale(0));
    try close(0.95, effects.pulseScale(0.25));
    try close(1, effects.pulseScale(0.5));
}

test "stagger wraps negatives and matrix guards zero count" {
    try close(0.0625, effects.pulse_stagger);
    try close(0.9375, effects.staggeredPhase(0, 1, effects.pulse_stagger));
    try close(0.175, effects.staggeredPhase(0.3, 2, effects.pulse_stagger));
    try close(0.175, effects.staggeredPhase(1.3, 2, effects.pulse_stagger));
    try close(0.625, effects.staggeredPhase(-0.25, 2, effects.pulse_stagger));
    try close(0, effects.staggeredPhase(-1, 0, effects.pulse_stagger));
    try close(1, effects.matrixWave(0.5, 0, 5));
    try close(0, effects.matrixWave(0.25, 1, 4));
    try close(1, effects.matrixWave(-0.25, 1, 4));
    try close(1, effects.matrixWave(0.5, 3, 0));
    try close(1, effects.matrixWave(0.5, 3, 1));
}

test "gradient spin exact breakpoints, ramp midpoints, and wrapping" {
    const phases = [_]f32{ 0, 0.225, 0.45, 0.7, 0.92, 0.96, 1, -0.04, 1.225 };
    const values = [_]f32{ 1, 0.55, 0.1, 0.1, 0.1, 0.55, 1, 0.55, 0.55 };
    for (phases, values) |phase, value| {
        try close(value, effects.gspinOpacity(phase, effects.gspin_dim));
    }
    try close(0.6, effects.gspinOpacity(0.225, 0.2));
}

test "resize exact edges, held latch, release, opposite edge, and reduced motion" {
    const first = effects.resizeDragSample(100, 100, 300, null, false);
    try close(100, first.width);
    try equal(@as(?effects.ResizeEdge, .min), first.edge);
    try expect(first.starts_bounce);
    const held = effects.resizeDragSample(80, 100, 300, first.edge, false);
    try close(100, held.width);
    try equal(first.edge, held.edge);
    try expect(!held.starts_bounce);
    const release = effects.resizeDragSample(200, 100, 300, held.edge, false);
    try close(200, release.width);
    try equal(@as(?effects.ResizeEdge, null), release.edge);
    try expect(!release.starts_bounce);
    try expect(effects.resizeDragSample(99, 100, 300, release.edge, false).starts_bounce);
    const opposite = effects.resizeDragSample(300, 100, 300, first.edge, false);
    try equal(@as(?effects.ResizeEdge, .max), opposite.edge);
    try expect(opposite.starts_bounce);
    const max_held = effects.resizeDragSample(400, 100, 300, opposite.edge, false);
    try close(300, max_held.width);
    try expect(!max_held.starts_bounce);
    for ([_]f32{ 80, 100, 200, 300, 400 }) |requested| {
        const normal = effects.resizeDragSample(requested, 100, 300, null, false);
        const reduced = effects.resizeDragSample(requested, 100, 300, null, true);
        try close(normal.width, reduced.width);
        try equal(normal.edge, reduced.edge);
        try expect(!reduced.starts_bounce);
    }
    // Source checks min first when the bounds coincide.
    const collapsed = effects.resizeDragSample(100, 100, 100, null, false);
    try equal(@as(?effects.ResizeEdge, .min), collapsed.edge);
}

test "resize bounce clamped endpoints, smoothstep halves and rounded peak" {
    const phases = [_]f32{ -1, 0, 0.16, 0.32, 0.66, 1, 2 };
    const offsets = [_]f32{ 0, 0, 2.5, 5, 2.5, 0, 0 };
    for (phases, offsets) |phase, offset| {
        try close(offset, effects.resizeBounceOffset(.max, phase));
        try close(-offset, effects.resizeBounceOffset(.min, phase));
    }
    // At dt=.001 the smooth joins move quadratically rather than linearly.
    try expect(effects.resizeBounceOffset(.max, 0.001) < 0.0002);
    try expect(effects.resizeBounceOffset(.max, 0.319) > 4.9998);
    try expect(effects.resizeBounceOffset(.max, 0.321) > 4.9998);
    try expect(effects.resizeBounceOffset(.max, 0.999) < 0.0002);
}

test "premultiplied sRGB mix preserves endpoints and transparent target hue" {
    const red: Color = .{ .r = @as(f32, 1), .g = @as(f32, 0), .b = @as(f32, 0), .a = @as(f32, 0.25) };
    const blue: Color = .{ .r = @as(f32, 0), .g = @as(f32, 0), .b = @as(f32, 1), .a = @as(f32, 0.75) };
    const midpoint = effects.mix(red, blue, 0.5);
    try close(0.25, midpoint.r);
    try close(0, midpoint.g);
    try close(0.75, midpoint.b);
    try close(0.5, midpoint.a);
    for ([_]f32{ -1, 0 }) |t| {
        const value = effects.mix(red, blue, t);
        try close(1, value.r);
        try close(0.25, value.a);
    }
    for ([_]f32{ 1, 2 }) |t| {
        const value = effects.mix(red, blue, t);
        try close(1, value.b);
        try close(0.75, value.a);
    }
    const transparent: Color = .{ .r = @as(f32, 0), .g = @as(f32, 1), .b = @as(f32, 0), .a = @as(f32, 0) };
    for ([_]f32{ 0.25, 0.5, 0.75 }) |t| {
        const entering = effects.mix(transparent, blue, t);
        const leaving = effects.mix(blue, transparent, 1 - t);
        try close(0, entering.g);
        try close(1, entering.b);
        try close(0.75 * t, entering.a);
        try close(1, leaving.b);
        try close(0.75 * t, leaving.a);
    }
    const clear_red: Color = .{ .r = @as(f32, 1), .g = @as(f32, 0), .b = @as(f32, 0), .a = @as(f32, 0) };
    const clear_mix = effects.mix(clear_red, transparent, 0.5);
    try close(0, clear_mix.r);
    try close(1, clear_mix.g);
    try close(0, clear_mix.a);
    const epsilon_blue: Color = .{ .r = @as(f32, 0), .g = @as(f32, 0), .b = @as(f32, 1), .a = std.math.floatEps(f32) * 2 };
    const cutoff = effects.mix(clear_red, epsilon_blue, 0.5);
    try close(1, cutoff.b);
    try equal(@as(f32, 0), cutoff.a);
    const above = effects.mix(clear_red, epsilon_blue, 0.75);
    try expect(above.a > std.math.floatEps(f32));
}

test "all 24 reduced motion combinations match source truth table" {
    const preferences = [_]effects.ReduceMotion{ .system, .on, .off };
    // Columns: system*4 + pause_in_background*2 + active.
    const expected = [_][8]bool{
        .{ false, false, true, false, true, true, true, true },
        .{ true, true, true, true, true, true, true, true },
        .{ false, false, true, false, false, false, true, false },
    };
    for (preferences, expected) |preference, row| {
        for (row, 0..) |value, index| {
            try equal(value, effects.resolve(preference, index & 4 != 0, index & 2 != 0, index & 1 != 0));
        }
    }
}
