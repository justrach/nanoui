//! Scroll polish: idle-hiding scrollbars, coalescent nonlinear rubber-band
//! overscroll, and single bottom momentum rebounds.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const IdleScene = struct {
    id: u64 = 0,

    fn view(s: *IdleScene, c: *ui.Context) void {
        const box = ui.div(c).column().size(100, 100).scrollY().scrollBarIdle(3.0);
        s.id = box.id();
        defer box.end();
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 300 } }, .none, null);
    }
};

const StretchScene = struct {
    id: u64 = 0,

    fn view(s: *StretchScene, c: *ui.Context) void {
        const box = ui.div(c).column().size(100, 200).scrollY();
        s.id = box.id();
        defer box.end();
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 400 } }, .none, null);
    }
};

test "scrollBarIdle hides when idle, ignores stationary hover, and stays alive while dragging" {
    var s: IdleScene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, IdleScene.view), .{ .width = 120, .height = 120 });
    defer t.deinit();
    t.settle(0.2);
    try testing.expectEqual(@as(usize, 0), t.ctx.scrollbars.count());
    try testing.expect(!t.ctx.animating);

    // Scrolling reveals the idle-hiding bar.
    t.scroll(50, 50, -40);
    t.frame();
    try testing.expectEqual(@as(usize, 1), t.ctx.scrollbars.count());

    // Stationary pointer hover on the scrollbar rail must NOT keep it alive.
    t.moveTo(96, 30);
    t.advance(3.6);
    try testing.expectEqual(@as(usize, 0), t.ctx.scrollbars.count());
    try testing.expect(!t.ctx.animating);

    // Re-reveal, then hold the thumb past the idle timeout: must stay visible.
    t.scroll(50, 50, -20);
    t.frame();
    const geom = t.ctx.scrollbars.get(s.id) orelse return error.NoScrollbar;
    t.down(geom.track_x + 3, geom.thumb_y + 4);
    t.advance(3.6);
    try testing.expectEqual(@as(usize, 1), t.ctx.scrollbars.count());

    // Releasing restarts the countdown: visible at 1s, gone cleanly after 3s.
    t.up();
    t.advance(1.0);
    try testing.expectEqual(@as(usize, 1), t.ctx.scrollbars.count());
    t.advance(2.8);
    try testing.expectEqual(@as(usize, 0), t.ctx.scrollbars.count());
    try testing.expect(!t.ctx.animating);
}

test "nonlinear rubber-band overscroll coalesces identically and reverses smoothly" {
    var big: StretchScene = .{};
    var t_big: ui.Tester = undefined;
    try t_big.init(testing.allocator, .init(&big, StretchScene.view), .{ .width = 120, .height = 220 });
    defer t_big.deinit();

    var step: StretchScene = .{};
    var t_step: ui.Tester = undefined;
    try t_step.init(testing.allocator, .init(&step, StretchScene.view), .{ .width = 120, .height = 220 });
    defer t_step.deinit();

    inline for (.{ &t_big, &t_step }) |t| {
        t.ctx.input.mouse = .{ .x = 50, .y = 50 };
        t.ctx.input.precise = true;
        t.ctx.input.scroll_phase = .began;
        t.ctx.scroll_holding = true;
    }

    _ = t_big.ctx.applyScroll(120);
    for (0..12) |_| _ = t_step.ctx.applyScroll(10);
    const o_big = t_big.ctx.overscroll.get(big.id) orelse 0;
    const o_step = t_step.ctx.overscroll.get(step.id) orelse 0;
    try testing.expectApproxEqAbs(o_big, o_step, 0.01);

    // Reversing back past the pull recovers zero overscroll and scrolls content cleanly.
    _ = t_big.ctx.applyScroll(-150);
    try testing.expectApproxEqAbs(@as(f32, 0), t_big.ctx.overscroll.get(big.id) orelse 0, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 30), t_big.ctx.scroll.get(big.id) orelse 0, 0.01);

    // Asymptotic bound keeps even huge pulls below 160pt.
    t_big.ctx.scroll.put(t_big.gpa, big.id, 0) catch {};
    _ = t_big.ctx.applyScroll(2000);
    const capped = t_big.ctx.overscroll.get(big.id) orelse 0;
    try testing.expect(@abs(capped) < 160 and capped < -120);
}

test "precise momentum crossing bottom rebounds once without moving logical scroll past max" {
    var s: StretchScene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, StretchScene.view), .{ .width = 120, .height = 220 });
    defer t.deinit();
    t.settle(0.1);

    const max_s = t.ctx.scroll_max.get(s.id) orelse 0;
    try testing.expectEqual(@as(f32, 200), max_s);

    // Position 5pt above the bottom, then deliver a precise momentum fling past max.
    try t.ctx.scroll.put(t.gpa, s.id, max_s - 5);
    t.ctx.input.mouse = .{ .x = 50, .y = 50 };
    t.ctx.input.precise = true;
    t.ctx.input.scroll_phase = .momentum;
    t.ctx.scroll_holding = false;
    t.ctx.retain.scroll_scene_ok = true;

    try testing.expect(t.ctx.applyScroll(-60));
    try testing.expectEqual(max_s, t.ctx.scroll.get(s.id) orelse 0);
    const impact = t.ctx.overscroll.get(s.id) orelse 0;
    try testing.expect(impact > 0);
    try testing.expect(!t.ctx.retain.scroll_scene_ok);

    // Further momentum events already at the bottom must not pump the impact deeper.
    try testing.expect(t.ctx.applyScroll(-60));
    try testing.expectEqual(max_s, t.ctx.scroll.get(s.id) orelse 0);
    try testing.expectApproxEqAbs(impact, t.ctx.overscroll.get(s.id) orelse 0, 0.001);

    t.frame();
    t.settle(1.5);
    try testing.expectApproxEqAbs(@as(f32, 0), t.ctx.overscroll.get(s.id) orelse 0, 0.1);
    try testing.expectEqual(max_s, t.ctx.scroll.get(s.id) orelse 0);
}
