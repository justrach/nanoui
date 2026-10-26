const std = @import("std");
const testing = std.testing;
const ui = @import("../ui.zig");
const motion = ui.motion;
const catalog = motion.catalog;

fn close(expected: f32, actual: f32) !void {
    try testing.expectApproxEqAbs(expected, actual, 0.00001);
}

test "motion.rs catalog timings, delay, curves and boundary progress" {
    const entries = [_]catalog.MotionSpec{
        catalog.fade_in,    catalog.fade_quick,            catalog.menu_in,       catalog.menu_out,
        catalog.dialog_in,  catalog.splash_out,            catalog.resize,        catalog.tab_slide,
        catalog.collapse,   catalog.new_thread_transition, catalog.chevron,       catalog.scroll_glide,
        catalog.hover_fade, catalog.harness_pulse,         catalog.gradient_spin, catalog.hover_reveal,
    };
    const milliseconds = [_]u32{ 500, 150, 140, 100, 180, 500, 200, 150, 180, 420, 200, 500, 150, 2400, 750, 320 };
    const curves = [_][4]f32{
        .{ 0.16, 1, 0.3, 1 },    .{ 0.25, 0.1, 0.25, 1 }, .{ 0.25, 0.1, 0.25, 1 }, .{ 0.25, 0.1, 0.25, 1 },
        .{ 0.25, 0.1, 0.25, 1 }, .{ 0.25, 0.1, 0.25, 1 }, .{ 0, 0, 0.58, 1 },      .{ 0, 0, 0.58, 1 },
        .{ 0, 0, 0.58, 1 },      .{ 0.22, 1, 0.36, 1 },   .{ 0.25, 0.1, 0.25, 1 }, .{ 0.42, 0, 0.58, 1 },
        .{ 0.4, 0, 0.2, 1 },     .{ 0.25, 0.1, 0.25, 1 }, .{ 0.25, 0.1, 0.25, 1 }, .{ 0.22, 1, 0.36, 1 },
    };
    for (entries, milliseconds, curves, 0..) |spec, ms, curve, index| {
        try testing.expectEqual(ms, spec.duration_ms);
        try testing.expectEqual(@as(u32, if (index == 5) 150 else 0), spec.delay_ms);
        try testing.expectEqual(curve, spec.curve.bezier);
        try close(0, spec.progress(-1));
        try close(1, spec.progress(2));
        for (0..1001) |step| {
            const value = spec.progress(@as(f32, @floatFromInt(step)) / 1000);
            try testing.expect(value >= 0 and value <= 1);
        }
    }
    try close(0.6846432, catalog.resize.progress(0.5));
    try close(0, catalog.splash_out.progress(0.15 / 0.65));
    try close(catalog.ease.sample(0.5)[0], catalog.splash_out.progress(0.4 / 0.65));
    try testing.expectApproxEqAbs(@as(f64, 0.65), catalog.splash_out.total(), 1e-9);
    const empty: catalog.MotionSpec = .{ .duration_ms = 0, .delay_ms = 500, .curve = catalog.ease };
    try close(1, empty.progress(0));
    try testing.expectEqual(motion.Transition.instant, empty.transition());
    try close(0, empty.animate(.{}, .{}).delay);
}

test "motion catalog explicit timing scale and transitions" {
    const slow = catalog.splash_out.scaled(10);
    try testing.expectEqual(@as(u32, 5000), slow.duration_ms);
    try testing.expectEqual(@as(u32, 1500), slow.delay_ms);
    try close(1, catalog.fade_in.scaled(std.math.nan(f32)).transition().tween.duration * 2);
    try close(0.005, catalog.fade_in.scaled(-1).transition().tween.duration);
    const m = catalog.fade_in.withDelay(75).animate(.{ .opacity = 0 }, .{ .opacity = 1 });
    try close(0.075, m.delay);
    try close(0.5, m.transition.tween.duration);
}

const Entrance = enum { fade, settle, quick, menu, dialog, splash };
const EntryScene = struct {
    kind: Entrance = .fade,
    last: motion.Frame = .{},
    fn view(s: *EntryScene, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull();
        defer root.end();
        s.last = switch (s.kind) {
            .fade => motion.fadeIn(c),
            .settle => motion.settleDown(c),
            .quick => motion.fadeQuick(c),
            .menu => motion.menuIn(c),
            .dialog => motion.dialogIn(c),
            .splash => motion.splashOut(c),
        };
        const box = ui.div(c).w(100).h(20).motion(s.last).bg(.hex(0xff0000));
        box.end();
        const sibling = ui.div(c).w(100).h(20);
        defer sibling.end();
        ui.text(c, "stationary sibling", .{});
    }
};

test "motion.rs entrance helpers preserve starting looks, finish, and park" {
    const kinds = [_]Entrance{ .fade, .settle, .quick, .menu, .dialog, .splash };
    const opacities = [_]f32{ 0, 0, 0, 0.3, 0, 1 };
    const offsets = [_]f32{ 4, -10, 0, -2, 2, 0 };
    for (kinds, opacities, offsets) |kind, opacity, y| {
        var s: EntryScene = .{ .kind = kind };
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&s, EntryScene.view), .{ .width = 200, .height = 150 });
        defer t.deinit();
        try close(opacity, s.last.opacity);
        try close(y, s.last.y);
        const sibling_y = t.findText("stationary sibling").?.y;
        if (kind == .splash) {
            t.advance(0.1);
            try close(1, s.last.opacity);
            try close(0, s.last.y);
        }
        t.advance(0.8);
        try close(if (kind == .splash) 0 else 1, s.last.opacity);
        try close(if (kind == .splash) -6 else 0, s.last.y);
        try close(sibling_y, t.findText("stationary sibling").?.y);
        try testing.expect(!s.last.animating and !t.ctx.animating);
        try testing.expectEqual(@as(?f32, null), t.ctx.frame_in);
    }
}

test "reduced motion enabled mid-entrance snaps and stops frames immediately" {
    var s: EntryScene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, EntryScene.view), .{});
    defer t.deinit();
    t.advance(0.05);
    try testing.expect(s.last.opacity > 0 and s.last.opacity < 1);
    t.ctx.reduced_motion = true;
    t.frame();
    try close(1, s.last.opacity);
    try close(0, s.last.y);
    try testing.expect(!t.ctx.animating);
}

const HoverScene = struct {
    hovered: bool = false,
    read: bool = true,
    hover: f32 = 0,
    reveal: f32 = 0,
    reset: bool = false,
    fn view(s: *HoverScene, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull();
        defer root.end();
        if (s.reset) motion.resetReveal(c, "row");
        if (s.read) {
            s.hover = motion.hoverT(c, "row", s.hovered);
            s.reveal = motion.revealT(c, "row", s.hovered);
            _ = motion.hoverBlend(c, "color", s.hovered, .transparent, .white);
        }
    }
};

test "hover/reveal reverse continuously, prune only hover, reset and reduce" {
    var s: HoverScene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, HoverScene.view), .{});
    defer t.deinit();
    s.hovered = true;
    t.advance(0.07);
    const mid = s.hover;
    try testing.expect(mid > 0 and mid < 1);
    t.dt = 0;
    t.time = t.ctx.time;
    s.hovered = false;
    t.frame();
    try close(mid, s.hover);
    t.dt = 1.0 / 60.0;
    t.advance(0.5);
    try close(0, s.hover);
    try close(0, s.reveal);
    try testing.expect(!t.ctx.animating);
    s.hovered = true;
    t.advance(0.5);
    s.read = false;
    t.frame();
    t.frame();
    s.read = true;
    t.frame();
    try close(0, s.hover);
    try close(1, s.reveal);
    s.reset = true;
    t.frame();
    try close(0, s.reveal);
    s.reset = false;
    t.ctx.reduced_motion = true;
    t.frame();
    try close(1, s.hover);
    try close(1, s.reveal);
    try testing.expect(!t.ctx.animating);
}

const LoopScene = struct {
    mounted: bool = true,
    options: motion.PulseOptions = .{},
    phase: f32 = 0,
    closing: f32 = 1,
    exit: motion.Frame = .{},
    fn view(s: *LoopScene, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull();
        defer root.end();
        if (s.mounted) s.phase = motion.pulseDelta(c, catalog.gradient_spin, s.options);
        s.exit = motion.menuOut(c, s.closing);
    }
};

test "loader ticks are bounded, background throttled, phase stable and mount scoped" {
    var s: LoopScene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, LoopScene.view), .{});
    defer t.deinit();
    try close(0.033, t.ctx.frame_in.?);
    try testing.expect(!t.ctx.animating);
    t.time = 0.375;
    t.frame();
    try close(0.5, s.phase);
    s.options.slow = true;
    t.time = 0.375;
    t.frame();
    try close(0.066, t.ctx.frame_in.?);
    try close(0.5, s.phase);
    s.options.active = false;
    t.frame();
    try close(0.198, t.ctx.frame_in.?);
    s.options.slow = false;
    t.frame();
    try close(0.099, t.ctx.frame_in.?);
    t.ctx.reduced_motion = true;
    t.frame();
    try close(0, s.phase);
    try testing.expectEqual(@as(?f32, null), t.ctx.frame_in);
    t.ctx.reduced_motion = false;
    s.mounted = false;
    s.closing = 0.5;
    t.frame();
    try close(0.5, s.exit.opacity);
    try close(-1, s.exit.y);
    try testing.expect(t.ctx.animating);
    s.closing = 1;
    t.frame();
    try testing.expect(!t.ctx.animating);
    try testing.expectEqual(@as(?f32, null), t.ctx.frame_in);
    try close(0.5, motion.phaseAt(catalog.gradient_spin, -0.375));
}

test "reduced motion skips a delayed splash hold" {
    var s: EntryScene = .{ .kind = .splash };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, EntryScene.view), .{});
    defer t.deinit();
    t.ctx.reduced_motion = true;
    t.frame();
    try close(0, s.last.opacity);
    try close(-6, s.last.y);
    try testing.expect(!t.ctx.animating);
}

test "instant retarget cancels a moving channel even at the same destination" {
    var ch: motion.Channel = .at(0);
    ch.retarget(1, catalog.fade_in.transition(), 0, 0);
    ch.sample(0.1);
    try testing.expect(ch.moving and ch.value < 1);
    ch.retarget(1, .instant, 0, 0.1);
    try testing.expectEqual(@as(f64, 1), ch.value);
    try testing.expect(!ch.moving);
}

test {
    _ = @import("effects_test.zig");
}
