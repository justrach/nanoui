//! A caret's clock, independent of windows and rendering. Inactive,
//! unfocused and selected carets have no next frame; input starts a fresh
//! 500 ms visible phase. Composition and Vim's block stay solid.
const std = @import("std");

pub const Blink = struct {
    anchor: ?f64 = null,
    steady: bool = false,

    pub const Frame = struct { visible: bool, next: ?f32 = null };

    pub fn step(b: *Blink, now: f64, active: bool, selected: bool, steady: bool, edited: bool) Frame {
        if (!active or selected) {
            b.* = .{};
            return .{ .visible = false };
        }
        if (b.anchor == null or edited or b.steady != steady) b.anchor = now;
        b.steady = steady;
        if (steady) return .{ .visible = true };
        const phase = @mod(@max(0, now - b.anchor.?), 1.0);
        const on = phase < 0.5;
        return .{ .visible = on, .next = @floatCast((if (on) @as(f64, 0.5) else 1.0) - phase) };
    }
};

test "Blink schedules only 500 ms edges and restarts on input" {
    var b: Blink = .{};
    const cases = [_]struct { now: f64, edited: bool = false, visible: bool, next: f32 }{
        .{ .now = 4, .visible = true, .next = 0.5 },
        .{ .now = 4.25, .visible = true, .next = 0.25 },
        .{ .now = 4.5, .visible = false, .next = 0.5 },
        .{ .now = 5, .visible = true, .next = 0.5 },
        .{ .now = 5.75, .visible = false, .next = 0.25 },
        .{ .now = 5.75, .edited = true, .visible = true, .next = 0.5 },
        .{ .now = 6.25, .visible = false, .next = 0.5 },
    };
    for (cases) |case| {
        const f = b.step(case.now, true, false, false, case.edited);
        try std.testing.expectEqual(case.visible, f.visible);
        try std.testing.expectApproxEqAbs(case.next, f.next.?, 0.0001);
    }
}

test "Blink stops for inactivity and selection and resumes with a full phase" {
    for ([_]bool{ false, true }) |selected| {
        var b: Blink = .{};
        _ = b.step(0, true, false, false, false);
        const stopped = b.step(0.75, selected, selected, false, false);
        try std.testing.expect(!stopped.visible);
        try std.testing.expect(stopped.next == null);
        try std.testing.expect(b.anchor == null);
        const still = b.step(10, selected, selected, false, false);
        try std.testing.expect(still.next == null);
        const resumed = b.step(10.75, true, false, false, false);
        try std.testing.expect(resumed.visible);
        try std.testing.expectEqual(@as(?f32, 0.5), resumed.next);
    }
}

test "Blink composition or a block is solid without frames then restarts" {
    var b: Blink = .{};
    _ = b.step(0, true, false, false, false);
    const solid = b.step(0.75, true, false, true, false);
    try std.testing.expect(solid.visible);
    try std.testing.expect(solid.next == null);
    const still = b.step(5.75, true, false, true, false);
    try std.testing.expect(still.visible);
    try std.testing.expect(still.next == null);
    const resumed = b.step(10.75, true, false, false, false);
    try std.testing.expect(resumed.visible);
    try std.testing.expectEqual(@as(?f32, 0.5), resumed.next);
}
