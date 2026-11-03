//! A faint border on an opaque rounded box, as a composer draws it: round
//! the corners no pixel may be lighter than the border laid over the fill.
//! Mixing the two straight made the anti-aliased pixels between them light
//! and nearly opaque, a bright rim on every curve.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const fill: ui.Color = .{ .r = 0.14, .g = 0.13, .b = 0.10, .a = 1 };
const edge: ui.Color = .{ .r = 1, .g = 1, .b = 1, .a = 0.10 };

const Scene = struct {
    pub fn view(_: *Scene, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull().p(20).bg(.{ .r = 0.12, .g = 0.11, .b = 0.09, .a = 1 });
        defer root.end();
        const box = ui.div(c).w(200).h(100).rounded(26).bg(fill).border(edge).borderW(1);
        box.end();
    }
};

test "a faint border round a rounded box is never lighter than over its fill" {
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 240, .height = 140 });
    defer t.deinit();
    t.settle(1);
    const px = try t.render(testing.allocator);
    defer px.deinit(testing.allocator);
    // The border over the fill, the lightest anything on the box may be.
    const ceiling = fill.r + edge.a * (1 - fill.r);
    var lightest: f32 = 0;
    // The top-left corner's curve, at the display's scale.
    const sc: usize = @intFromFloat(t.scale);
    for (20 * sc..50 * sc) |y| for (20 * sc..50 * sc) |x| {
        const i = (y * px.width + x) * 4;
        // BGRA: the red channel.
        lightest = @max(lightest, @as(f32, @floatFromInt(px.bytes[i + 2])) / 255);
    };
    try testing.expect(lightest <= ceiling + 0.02);
}

test "a shadow's spread grows or shrinks its box before the blur; layers stack" {
    const Two = struct {
        pub fn view(_: *@This(), c: *ui.Context) void {
            const root = ui.div(c).column().sizeFull().p(40);
            defer root.end();
            const box = ui.div(c).w(100).h(50).rounded(10).bg(fill).shadows(&ui.Shadow.lg);
            box.end();
        }
    };
    var s: Two = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Two.view), .{ .width = 200, .height = 160 });
    defer t.deinit();
    t.settle(1);
    var shadows: usize = 0;
    for (t.instances.items) |i| if (i.kind == @import("gpu.zig").Kind.shadow) {
        shadows += 1;
        // Spread -3 then -4: a box 6 or 8 points narrower, 7 (radius - 3) or
        // 6 (radius - 4) round.
        try testing.expect(i.rect[2] == 94 or i.rect[2] == 92);
        try testing.expect(i.radius == 7 or i.radius == 6);
    };
    try testing.expectEqual(@as(usize, 2), shadows);
}

test "a dashed border: dashes twice its width, gaps once, round the box" {
    const raster = @import("raster_shapes.zig");
    // A 1-point border round a 100 by 50 box, corners 10.
    const w: f32 = 1;
    // Along the top: dashes and gaps alternate; most of a period is dash.
    var on: usize = 0;
    var off: usize = 0;
    var x: f32 = -30;
    while (x < 30) : (x += 0.05) {
        if (raster.dashCover(x, -24.5, 50, 25, 10, w, 0.5) > 0.5) on += 1 else off += 1;
    }
    const share = @as(f32, @floatFromInt(on)) / @as(f32, @floatFromInt(on + off));
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), share, 0.06);
    // Round a corner too: dashes go on through the curve.
    var corner_on = false;
    var a: f32 = 0;
    while (a < 1.5) : (a += 0.01) {
        const cx = 40 + 9.5 * @cos(-a);
        const cy = -15 + 9.5 * @sin(-a);
        if (raster.dashCover(cx, cy, 50, 25, 10, w, 0.5) > 0.5) corner_on = true;
    }
    try std.testing.expect(corner_on);
}
