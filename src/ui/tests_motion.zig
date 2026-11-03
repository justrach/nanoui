//! `ui.motion` through the Tester: a box enters from `initial` and settles
//! at its target, then stops asking for frames; a target changed midway is
//! taken from where the box is; presence keeps a box drawn while it leaves;
//! hover and press move it; numbers ease; reduced motion jumps; and a
//! scaled box draws its pixels where its scale puts them.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const motion = ui.motion;

const Scene = struct {
    wide: bool = false,
    show: bool = true,
    count: f32 = 0,
    last: motion.Frame = .{},
    gone: bool = false,
    shown: f32 = 0,

    fn view(s: *Scene, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull().p(20).gap(10).bg(.white);
        defer root.end();
        s.last = motion.frame(c, .{
            .target = .{ .width = if (s.wide) 300 else 100 },
            .initial = .{ .y = 12, .opacity = 0 },
            .hover = .{ .scale = 1.1 },
            .transition = .{ .spring = .{} },
        });
        {
            const card = ui.div(c).h(40).bg(.hex(0x3366ff)).control().motion(s.last);
            defer card.end();
            ui.text(c, "card", .{ .size = 12 });
        }
        s.gone = true;
        if (motion.present(c, "toast", s.show, .{ .initial = .{ .opacity = 0 }, .exit = .{ .opacity = 0, .y = 20 }, .transition = .{ .tween = .{ .duration = 0.2 } } })) |f| {
            s.gone = false;
            const t = ui.div(c).p(8).bg(.hex(0x222222)).motion(f);
            defer t.end();
            ui.text(c, "toast", .{ .size = 12, .color = .white });
        }
        s.shown = motion.number(c, "count", s.count, .{ .tween = .{ .duration = 0.5, .ease = .linear } });
    }
};

test "a box enters from initial, settles at its target, then draws no more frames" {
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    t.frame();
    // The first frame is where `initial` puts it.
    try testing.expect(s.last.opacity < 0.2 and s.last.y > 10);
    try testing.expect(t.ctx.animating);
    t.settle(3);
    try testing.expectApproxEqAbs(@as(f32, 1), s.last.opacity, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0), s.last.y, 1e-2);
    try testing.expectEqual(@as(?f32, 100), s.last.width);
    try testing.expect(!t.ctx.animating and !s.last.animating);
    const card = t.findText("card").?;
    try testing.expectApproxEqAbs(@as(f32, 20), card.x, 0.5);
}

test "a target changed midway is taken from where the box is" {
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    t.settle(3);
    s.wide = true;
    t.advance(0.08);
    const mid = s.last.width.?;
    try testing.expect(mid > 100 and mid < 300);
    // Back again: it turns from there, without a jump.
    s.wide = false;
    t.frame();
    try testing.expect(@abs(s.last.width.? - mid) < 25);
    t.settle(3);
    try testing.expectApproxEqAbs(@as(f32, 100), s.last.width.?, 1e-2);
}

test "presence: a box leaving stays drawn until its exit settles" {
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    t.settle(3);
    try testing.expect(t.hasText("toast"));
    s.show = false;
    t.advance(0.1);
    try testing.expect(t.hasText("toast") and !s.gone);
    t.settle(1);
    try testing.expect(!t.hasText("toast") and s.gone);
    // Shown again, it enters again.
    s.show = true;
    t.frame();
    try testing.expect(t.hasText("toast"));
}

test "hover scales the card; a number eases; reduced motion jumps" {
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    t.settle(3);
    const card = t.findText("card").?;
    t.moveTo(card.x + 2, card.y + 2);
    t.settle(3);
    try testing.expectApproxEqAbs(@as(f32, 1.1), s.last.scale, 1e-3);
    t.moveTo(390, 290);
    t.settle(3);
    try testing.expectApproxEqAbs(@as(f32, 1), s.last.scale, 1e-3);

    s.count = 10;
    t.advance(0.25);
    try testing.expect(s.shown > 3 and s.shown < 7);
    t.settle(2);
    try testing.expectEqual(@as(f32, 10), s.shown);

    t.ctx.reduced_motion = true;
    s.wide = true;
    t.frame();
    try testing.expectEqual(@as(?f32, 300), s.last.width);
}

const Scaled = struct {
    k: f32,
    fn view(s: *Scaled, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull().p(0).bg(.white);
        defer root.end();
        const b = ui.div(c).w(40).h(40).bg(.hex(0xff0000)).scale(s.k);
        b.end();
    }
};

fn red(px: anytype, x: usize, y: usize) bool {
    const i = (y * px.width + x) * 4;
    return px.bytes[i + 2] > 200 and px.bytes[i + 1] < 60;
}

test "a scaled box draws about its center" {
    var s: Scaled = .{ .k = 0.5 };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scaled.view), .{ .width = 60, .height = 60, .scale = 1 });
    defer t.deinit();
    t.frame();
    const px = try t.render(testing.allocator);
    defer px.deinit(testing.allocator);
    // 40 × 40 at the origin, halved about (20, 20): from 10 to 30.
    try testing.expect(!red(px, 5, 5) and red(px, 12, 12) and red(px, 28, 28) and !red(px, 33, 33));
}

const Swap = struct {
    flipped: bool = false,
    spin: motion.Frame = .{},
    fn view(s: *Swap, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull().bg(.white);
        defer root.end();
        const order: [2]u24 = if (s.flipped) .{ 0x00ff00, 0xff0000 } else .{ 0xff0000, 0x00ff00 };
        for (order) |color| {
            ui.key(c, if (color == 0xff0000) "red" else "green");
            const f = motion.frame(c, .{ .layout = true, .transition = .{ .tween = .{ .duration = 0.4, .ease = .linear } } });
            const b = ui.div(c).w(40).h(40).bg(.hex(color)).motion(f);
            b.end();
        }
        s.spin = motion.keyframes(c, .{ .values = &.{ .{ .x = 0 }, .{ .x = 30 } }, .duration = 1, .ease = .linear, .repeat = 1, .yoyo = true });
        const k = ui.div(c).w(10).h(10).bg(.black).motion(s.spin);
        k.end();
    }
};

/// The y of the first instance drawn in `color`.
fn yOf(t: *ui.Tester, color: u24) ?f32 {
    const want = ui.Color.hex(color);
    for (t.instances.items) |it| if (@abs(it.color[0] - want.r) < 0.01 and @abs(it.color[1] - want.g) < 0.01 and @abs(it.color[2] - want.b) < 0.01 and it.color[3] > 0.9) return it.rect[1];
    return null;
}

test "layout: boxes the layout moves glide from where they were" {
    var s: Swap = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Swap.view), .{ .width = 100, .height = 120 });
    defer t.deinit();
    t.frame();
    t.frame();
    try testing.expectEqual(@as(?f32, 0), yOf(&t, 0xff0000));
    s.flipped = true;
    t.frame();
    // Laid out below now, but drawn where it was, then gliding down.
    try testing.expect(yOf(&t, 0xff0000).? < 5);
    t.advance(0.2);
    const mid = yOf(&t, 0xff0000).?;
    try testing.expect(mid > 10 and mid < 30);
    t.advance(0.5);
    try testing.expectApproxEqAbs(@as(f32, 40), yOf(&t, 0xff0000).?, 0.01);
}

test "animated colors stay inside the renderer's unit range" {
    var f: motion.Frame = .{};
    motion.setChannel(&f, 7, -0.2);
    motion.setChannel(&f, 8, 1.2);
    motion.setChannel(&f, 10, 1.1);
    try testing.expectEqual(ui.Color{ .r = 0, .g = 1, .b = 0, .a = 1 }, f.background.?);
}

test "keyframes play a pass, then back with yoyo, and stop at the end" {
    var s: Swap = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Swap.view), .{ .width = 100, .height = 120 });
    defer t.deinit();
    t.frame();
    t.advance(0.5);
    try testing.expectApproxEqAbs(@as(f32, 15), s.spin.x, 1.5);
    t.advance(0.5);
    t.advance(0.25);
    // The second pass runs back: three quarters of the way to 0... from 30.
    try testing.expect(s.spin.x > 18 and s.spin.x < 26);
    t.advance(1);
    try testing.expectEqual(@as(f32, 0), s.spin.x);
    try testing.expect(!s.spin.animating);
}
