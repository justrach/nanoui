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

test "ruler outgoing and incoming glyph pixels never escape inset or pill" {
    const gpu = @import("gpu.zig");
    var v: View = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&v, View.draw), .{ .width = 480, .height = 480, .scale = 2 });
    defer t.deinit();
    t.dt = 0;
    t.time = 0;
    var top: usize = 0;
    var bottom: usize = 0;
    var changed: usize = 0;
    var negative_outside: usize = 0;
    var negative_shadow: usize = 0;
    // Both directions, including near-edge outgoing glyphs at high opacity.
    // Direct phases hold the exact control's rolling coordinate for a
    // deterministic strongest-edge sweep, independent of spring timing.
    const phases = [_]f64{ 16.05, 16.2, 16.4, 16.6, 16.8, 16.95, 16.8, 16.6, 16.4, 16.2, 16.05 };
    for (phases) |phase| {
        v.picker.model.position = 17;
        v.picker.model.target = 17;
        v.picker.model.rolling = phase;
        v.picker.model.rolling_velocity = 0;
        t.frame();
        const full = try t.render(std.testing.allocator);
        defer full.deinit(std.testing.allocator);
        const saved = try std.testing.allocator.dupe(gpu.Instance, t.instances.items);
        defer std.testing.allocator.free(saved);
        defer @memcpy(t.instances.items, saved);
        for (t.instances.items) |*inst| if (inst.kind == gpu.Kind.text) {
            try eq(@as([4]f32, .{ 200, 116.5, 280, 164.5 }), inst.clip);
            inst.color[3] = 0;
        };
        const bare = try t.render(std.testing.allocator);
        defer bare.deinit(std.testing.allocator);
        for (0..full.height) |y| for (0..full.width) |x| {
            const at = (y * full.width + x) * 4;
            const with = full.bytes[at..][0..4];
            const without = bare.bytes[at..][0..4];
            if (std.mem.eql(u8, with, without)) continue;
            try expect(x >= 400 and x < 560 and y >= 233 and y < 329);
            try eq(@as(u8, 0), without[0]);
            try eq(@as(u8, 0), without[1]);
            try eq(@as(u8, 0), without[2]);
            changed += 1;
            if (y == 233) top += 1;
            if (y == 328) bottom += 1;
        };
        // Negative control: expand ONLY the rendered glyph instances' clip.
        // The same audit must now detect both inset and real pill overflow.
        @memcpy(t.instances.items, saved);
        for (t.instances.items) |*inst| if (inst.kind == gpu.Kind.text) {
            inst.clip = .{ 0, 0, 480, 480 };
        };
        const unclipped = try t.render(std.testing.allocator);
        defer unclipped.deinit(std.testing.allocator);
        for (0..unclipped.height) |y| for (0..unclipped.width) |x| {
            const at = (y * unclipped.width + x) * 4;
            if (std.mem.eql(u8, unclipped.bytes[at..][0..4], bare.bytes[at..][0..4])) continue;
            if (x < 400 or x >= 560 or y < 233 or y >= 329) negative_outside += 1;
            if (bare.bytes[at] != 0 or bare.bytes[at + 1] != 0 or bare.bytes[at + 2] != 0) negative_shadow += 1;
        };
    }
    // Nonvacuous: visible glyph coverage really reaches BOTH clip edges,
    // and the comparator detects the deliberately broken clipping control.
    try expect(changed > 0 and top > 0 and bottom > 0);
    try expect(negative_outside > 0 and negative_shadow > 0);
}
