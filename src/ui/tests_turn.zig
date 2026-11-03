//! A card turning about the vertical axis (`Style.turn`): the pivot, the
//! eye's distance and the faces reach the shader, and the turn springs.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");

const Card = struct {
    angle: f32 = 0,
    springy: bool = false,
    target: f32 = 0,

    fn view(s: *Card, c: *ui.Context) void {
        const root = ui.div(c).wFull().hFull().p(20);
        defer root.end();
        var card = ui.div(c).size(200, 100).bg(.hex(0x009645)).rounded(20).pivot(0.1, 0.2).turn(s.angle, 1100);
        if (s.springy) card = card.motion(ui.motion.frame(c, .{ .target = .{ .turn = s.target }, .transition = .{ .spring = .{ .stiffness = 110, .damping = 19 } } }));
        defer card.end();
        ui.div(c).wFull().hFull().face(.front).bg(.white).end();
        ui.div(c).wFull().hFull().face(.back).bg(.black).end();
    }
};

fn quads(t: *ui.Tester, out: *[3]gpu.Instance) usize {
    var n: usize = 0;
    // The card and its two faces; not the window's ground.
    for (t.instances.items) |i| if (i.kind == gpu.Kind.quad and i.rect[0] == 20 and n < 3) {
        out[n] = i;
        n += 1;
    };
    return n;
}

test "a turn carries its angle, eye and pivot to the card and what is in it" {
    var s: Card = .{ .angle = -1.2 };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Card.view), .{});
    defer t.deinit();
    var q: [3]gpu.Instance = undefined;
    try testing.expectEqual(3, quads(&t, &q));
    for (q) |i| {
        try testing.expectApproxEqAbs(-1.2, i.turn[0], 1e-6);
        try testing.expectEqual(1100, i.turn[1]);
        // Pivot at 10%, 20% of the 200 x 100 card at (20, 20).
        try testing.expectApproxEqAbs(40, i.turn[2], 0.01);
        try testing.expectApproxEqAbs(40, i.turn[3], 0.01);
    }
    // The card itself is on both faces; its front and back children each on one,
    // the back mirrored about the card's middle.
    try testing.expectEqual(0, q[0].vel[2]);
    try testing.expectEqual(1, q[1].vel[2]);
    try testing.expectEqual(2, q[2].vel[2]);
    try testing.expectApproxEqAbs(120, q[2].vel[3], 0.01);
}

test "no turn leaves instances as they were" {
    var s: Card = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Card.view), .{});
    defer t.deinit();
    var q: [3]gpu.Instance = undefined;
    _ = quads(&t, &q);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0 }, &q[0].turn);
}

test "a turn springs as a motion channel" {
    var s: Card = .{ .springy = true };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Card.view), .{});
    defer t.deinit();
    s.target = -1.95;
    t.frame();
    t.advance(0.1);
    var q: [3]gpu.Instance = undefined;
    _ = quads(&t, &q);
    const midway = q[0].turn[0];
    try testing.expect(midway < -0.05 and midway > -1.95);
    t.advance(2);
    _ = quads(&t, &q);
    try testing.expectApproxEqAbs(-1.95, q[0].turn[0], 0.01);
}
