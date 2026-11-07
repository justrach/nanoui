const std = @import("std");
const ui = @import("ui.zig");
const Model = @import("ruler_physics.zig").Model;
const expect = std.testing.expect;
const eq = std.testing.expectEqual;

const View = struct {
    picker: ui.RulerPicker = .{},
    fn draw(v: *View, c: *ui.Context) void {
        _ = v.picker.draw(c, .{});
    }
};

test "ruler left increases, right decreases, clamps both bounds" {
    var m: Model = .{};
    m.begin(500);
    m.drag(330, 17, 0.1);
    try eq(@as(i32, 10), m.value());
    m.drag(466, 17, 0.1);
    try eq(@as(i32, 2), m.value());
    m.drag(-100000, 17, 0.01);
    try eq(@as(i32, 99), m.value());
    m.drag(100000, 17, 0.01);
    try eq(@as(i32, 0), m.value());
}

test "ruler coasts to an integer and settles at 30 60 120 Hz" {
    var results: [3]f64 = undefined;
    for ([_]f64{ 30, 60, 120 }, 0..) |hz, i| {
        var m: Model = .{};
        m.begin(500);
        m.drag(326, 17, 0.2);
        m.release();
        const released = m.position;
        m.advance(1 / hz, false);
        try expect(m.position > released);
        var j: usize = 1;
        while (j < @as(usize, @intFromFloat(3 * hz))) : (j += 1) m.advance(1 / hz, false);
        try expect(!m.moving());
        try eq(@round(m.position), m.position);
        results[i] = m.position;
    }
    try eq(results[0], results[1]);
    try eq(results[1], results[2]);
}

test "ruler spring can be grabbed and reversed without a position jump" {
    var m: Model = .{};
    m.begin(500);
    m.drag(330, 17, 0.1);
    m.release();
    m.advance(0.04, false);
    const before = m.position;
    m.begin(330);
    try eq(before, m.position);
    m.drag(347, 17, 1.0 / 60.0);
    try std.testing.expectApproxEqAbs(before - 1, m.position, 1e-10);
    m.release();
    m.advance(3, false);
    try expect(!m.moving());
}

test "ruler finite for tiny dt, huge pauses, invalid input and bounds" {
    var m: Model = .{};
    m.begin(0);
    m.drag(-1e30, 17, 1e-30);
    m.release();
    for ([_]f64{ 0, 1e-30, 0.2, 10000, std.math.nan(f64), std.math.inf(f64), -1 }) |dt| {
        m.advance(dt, false);
        try expect(std.math.isFinite(m.position));
        try expect(std.math.isFinite(m.rolling));
        try expect(m.position >= 0 and m.position <= 99);
    }
    m.begin(std.math.nan(f64));
    m.select(std.math.inf(f64));
    try expect(std.math.isFinite(m.target));
    m.select(15);
    m.advance(0, true);
    try eq(@as(i32, 15), m.value());
    try expect(!m.moving());
}

test "ruler pointer capture, tap, release, reduced motion and idle frame" {
    var v: View = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&v, View.draw), .{ .width = 480, .height = 480 });
    defer t.deinit();
    t.drag(400, 268, 230, 268);
    t.settle(3);
    try expect(v.picker.value() >= 10);
    try expect(!t.ctx.animating);
    const before = v.picker.value();
    t.click(274, 268); // Two ticks to the right of the indicator.
    t.settle(3);
    try eq(before + 2, v.picker.value());
    t.ctx.reduced_motion = true;
    t.drag(350, 268, 401, 268);
    t.frame();
    try expect(v.picker.value() < before + 2);
    try expect(!t.ctx.animating);
}

test "rolling position remains continuous through a fast reversal" {
    var m: Model = .{};
    m.select(18);
    m.advance(0.10, false);
    const before = m.rolling;
    m.select(1);
    try eq(before, m.rolling);
    m.advance(1.0 / 120.0, false);
    try expect(@abs(m.rolling - before) < 2);
    m.advance(3, false);
    try eq(@as(f64, 1), m.rolling);
}

test "ruler keyboard steps, outside release and held numerals settle" {
    var v: View = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&v, View.draw), .{ .width = 480, .height = 480 });
    defer t.deinit();
    t.key(.tab);
    t.key(.right);
    t.settle(3);
    try eq(@as(i32, 1), v.picker.value());
    t.key(.left);
    t.settle(3);
    try eq(@as(i32, 0), v.picker.value());
    t.moveTo(400, 268);
    t.ctx.pointerDown();
    t.frame();
    t.moveTo(-800, 268); // The captured gesture survives leaving the box.
    t.advance(1);
    try expect(v.picker.model.dragging);
    try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(v.picker.value())), v.picker.model.rolling, 0.001);
    try expect(!t.ctx.animating);
    t.ctx.pointerUp();
    t.frame();
    t.settle(3);
    try expect(!v.picker.model.dragging);
    try expect(v.picker.value() > 50);
    try expect(!t.ctx.animating);
}

test "ruler sanitizes reversed bounds and invalid width on the first frame" {
    const Bounded = struct {
        picker: ui.RulerPicker = .{},
        fn draw(v: *@This(), c: *ui.Context) void {
            _ = v.picker.draw(c, .{ .min = 20, .max = 5, .width = std.math.nan(f32) });
        }
    };
    var v: Bounded = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&v, Bounded.draw), .{});
    defer t.deinit();
    try eq(@as(i32, 20), v.picker.value());
    try expect(t.hasText("20"));
    try expect(!t.ctx.animating);
}
