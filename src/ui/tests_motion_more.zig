//! Scroll-linked values, drag-and-snap, shared-element, and staggered
//! text, through the Tester.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const motion = ui.motion;

const ScrollScene = struct {
    sid: u64 = 0,
    progress: f32 = 0,
    mapped: f32 = 0,
    max: f32 = 0,

    fn view(s: *ScrollScene, c: *ui.Context) void {
        const sc = ui.div(c).column().sizeFull().scrollY().p(8);
        defer sc.end();
        s.sid = sc.id();
        s.progress = motion.scroll.of(c, s.sid);
        s.max = c.scroll_max.get(s.sid) orelse 0;
        s.mapped = motion.scroll.value(c, "bar", s.sid, .{ 0, 100 }, .instant);
        for (0..40) |i| {
            ui.key(c, c.print("row{d}", .{i}));
            ui.text(c, c.print("row {d} of the scroller", .{i}), .{ .size = 16 });
        }
    }
};

test "every scroller stores scroll_max, and progress follows the wheel" {
    var s: ScrollScene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, ScrollScene.view), .{ .width = 200, .height = 120 });
    defer t.deinit();
    t.settle(0.2);
    try testing.expect(s.max > 200);
    try testing.expectEqual(@as(f32, 0), s.progress);
    t.scroll(40, 40, -80);
    t.frame();
    try testing.expect(s.progress > 0 and s.progress < 1);
    try testing.expectApproxEqAbs(s.progress * 100, s.mapped, 0.5);
}

const DragScene = struct {
    last: motion.Drag = .{},
    fn view(s: *DragScene, c: *ui.Context) void {
        const root = ui.div(c).sizeFull().p(10).bg(.white);
        defer root.end();
        s.last = motion.drag(c, .{
            .min = .{ 0, 0 },
            .max = .{ 200, 0 },
            .axis = .x,
            .snap = &.{ .{ 0, 0 }, .{ 200, 0 } },
            .momentum = false,
            .transition = .{ .tween = .{ .duration = 0.2, .ease = .linear } },
        });
        const box = ui.div(c).w(40).h(40).bg(.hex(0x3366ff)).control().motion(s.last.frame());
        defer box.end();
        ui.text(c, "knob", .{ .size = 10, .color = .white });
    }
};

test "a drag follows the pointer and snaps to the nearest point" {
    var s: DragScene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, DragScene.view), .{ .width = 280, .height = 80 });
    defer t.deinit();
    t.settle(0.2);
    const knob = t.findText("knob").?;
    t.drag(knob.x + 4, knob.y + 4, knob.x + 160, knob.y + 4);
    try testing.expect(s.last.x > 80);
    t.settle(1);
    try testing.expectApproxEqAbs(@as(f32, 200), s.last.x, 1);
    try testing.expect(!s.last.animating);
}

const ShareScene = struct {
    right: bool = false,
    fn view(s: *ShareScene, c: *ui.Context) void {
        const root = ui.div(c).row().sizeFull().gap(80).p(0).bg(.white);
        defer root.end();
        {
            const left = ui.div(c).w(40).h(40);
            defer left.end();
            if (motion.share(c, "chip", !s.right, .{ .transition = .{ .tween = .{ .duration = 0.4, .ease = .linear } } })) |f| {
                const chip = ui.div(c).size(40, 40).bg(.hex(0xff0000)).motion(f);
                chip.end();
            }
        }
        {
            const right = ui.div(c).w(40).h(40);
            defer right.end();
            if (motion.share(c, "chip", s.right, .{ .transition = .{ .tween = .{ .duration = 0.4, .ease = .linear } } })) |f| {
                const chip = ui.div(c).size(40, 40).bg(.hex(0xff0000)).motion(f);
                chip.end();
            }
        }
    }
};

fn xOf(t: *ui.Tester, color: u24) ?f32 {
    const want = ui.Color.hex(color);
    for (t.instances.items) |it| {
        if (@abs(it.color[0] - want.r) < 0.01 and @abs(it.color[1] - want.g) < 0.01 and @abs(it.color[2] - want.b) < 0.01 and it.color[3] > 0.9)
            return it.rect[0];
    }
    return null;
}

test "a shared chip glides from where it was to the other slot" {
    var s: ShareScene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, ShareScene.view), .{ .width = 200, .height = 50 });
    defer t.deinit();
    t.frame();
    t.frame();
    const start = xOf(&t, 0xff0000).?;
    try testing.expect(start < 10);
    s.right = true;
    t.frame();
    // Laid out on the right, drawn where it was, then gliding across.
    try testing.expect(xOf(&t, 0xff0000).? < 20);
    t.advance(0.2);
    const mid = xOf(&t, 0xff0000).?;
    try testing.expect(mid > 20 and mid < 100);
    t.advance(0.5);
    try testing.expect(xOf(&t, 0xff0000).? > 100);
}

const LettersScene = struct {
    fn view(_: *LettersScene, c: *ui.Context) void {
        const root = ui.div(c).row().sizeFull().p(8).bg(.white);
        defer root.end();
        motion.letters(c, "Hi", .{ .size = 20 }, .{
            .unit = .letters,
            .enter = .{ .y = 8, .opacity = 0 },
            .stagger_each = 0.05,
            .transition = .{ .tween = .{ .duration = 0.2, .ease = .linear } },
        });
    }
};

test "staggered letters enter from their initial and then sit still" {
    var s: LettersScene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, LettersScene.view), .{ .width = 120, .height = 50 });
    defer t.deinit();
    try testing.expect(t.hasText("H") and t.hasText("i"));
    try testing.expect(t.ctx.animating);
    t.settle(2);
    try testing.expect(t.hasText("H") and t.hasText("i"));
    try testing.expect(!t.ctx.animating);
}
