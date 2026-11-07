//! Boxes that scroll sideways (`Style.scroll_x`): children at their own
//! widths, clipped, moved by the wheel's x or `setScroll`, and scroll
//! indicators that a box can do without (`Style.scroll_bar`).
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const Strip = struct {
    box: u32 = 0,
    items: [5]u32 = undefined,
    fn view(s: *Strip, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(10) });
        defer ui.end(c);
        s.box = c.open(.{ .direction = .row, .scroll_x = true, .width = .{ .px = 200 }, .height = .{ .px = 40 }, .scroll_bar = false }, null);
        defer c.end();
        for (&s.items, 0..) |*it, i| {
            const shade: f32 = @as(f32, @floatFromInt(i)) / 5;
            it.* = c.leaf(.{ .width = .{ .px = 100 }, .height = .{ .px = 40 }, .background = .{ .r = shade, .g = 0.5, .b = 0.2 } }, .none, null);
        }
    }
};

test "scroll_x clips and offsets children" {
    var s: Strip = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Strip.view), .{});
    defer t.deinit();
    const c = &t.ctx;
    // At their own widths, past the box.
    try testing.expectEqual(@as(f32, 10), c.node(s.items[0]).rect.x);
    try testing.expectEqual(@as(f32, 410), c.node(s.items[4]).rect.x);
    try testing.expectEqual(@as(f32, 100), c.node(s.items[4]).rect.w);
    // Clipped to the box.
    var clipped: u32 = 0;
    for (t.instances.items) |i| if (i.color[1] == 0.5) {
        clipped += 1;
        try testing.expectEqual([4]f32{ 10, 10, 210, 50 }, i.clip);
    };
    try testing.expectEqual(@as(u32, 2), clipped); // the rest is culled
    const id = c.node(s.box).id;
    c.setScroll(id, .x, 50);
    t.frame();
    try testing.expectEqual(@as(f32, -40), c.node(s.items[0]).rect.x);
    // Clamped to its content: 500 wide in 200.
    c.setScroll(id, .x, 10_000);
    t.frame();
    try testing.expectEqual(@as(f32, 300), c.scroll_x.get(id).?);
    try testing.expectEqual(@as(f32, 110), c.node(s.items[4]).rect.x);
    // The wheel's x, over the box: a swipe left goes right.
    c.setScroll(id, .x, 0);
    t.frame();
    c.input.mouse = .{ .x = 100, .y = 30 };
    c.input.scroll.x = -30;
    t.frame();
    try testing.expectEqual(@as(f32, -20), c.node(s.items[0]).rect.x);
    // Not over it: nothing moves.
    c.input.mouse = .{ .x = 300, .y = 200 };
    c.input.scroll.x = -30;
    t.frame();
    try testing.expectEqual(@as(f32, -20), c.node(s.items[0]).rect.x);
}

const Both = struct {
    bars: bool = true,
    fn view(s: *Both, c: *ui.Context) void {
        ui.row(c, .{ .gap = 10 });
        defer ui.end(c);
        {
            _ = c.open(.{ .scroll = true, .width = .{ .px = 100 }, .height = .{ .px = 100 }, .scroll_bar = s.bars }, null);
            defer c.end();
            for (0..5) |_| _ = c.leaf(.{ .width = .{ .px = 80 }, .height = .{ .px = 50 }, .background = .{ .g = 1 } }, .none, null);
        }
        _ = c.open(.{ .direction = .row, .scroll_x = true, .width = .{ .px = 100 }, .height = .{ .px = 40 }, .scroll_bar = s.bars }, null);
        defer c.end();
        for (0..5) |_| _ = c.leaf(.{ .width = .{ .px = 50 }, .height = .{ .px = 40 }, .background = .{ .b = 1 } }, .none, null);
    }
};

fn bars(t: *ui.Tester) u32 {
    var n: u32 = 0;
    for (t.instances.items) |i| if (i.radius == 2 and (i.rect[2] == 4 or i.rect[3] == 4)) {
        n += 1;
    };
    return n;
}

test "scroll_bar false paints no bar" {
    var s: Both = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Both.view), .{});
    defer t.deinit();
    try testing.expectEqual(@as(u32, 2), bars(&t));
    s.bars = false;
    t.frame();
    try testing.expectEqual(@as(u32, 0), bars(&t));
}

const Ownership = struct {
    front_first: bool,
    front: u64 = 0,
    back: u64 = 0,
    fn view(s: *Ownership, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull();
        defer root.end();
        if (s.front_first) s.foreground(c);
        {
            const back = c.open(.{ .direction = .row, .scroll_x = true, .absolute = true, .fixed = true, .layer = 1, .width = .fill, .height = .fill, .scroll_bar = false }, null);
            defer c.end();
            s.back = c.node(back).id;
            for (0..5) |_| ui.div(c).w(100).h(40).end();
        }
        if (!s.front_first) s.foreground(c);
    }
    fn foreground(s: *Ownership, c: *ui.Context) void {
        const clip = ui.div(c).fixed().offset(10, 10).w(80).h(80).layer(2).clip();
        defer clip.end();
        const front = c.open(.{ .direction = .row, .scroll_x = true, .width = .{ .px = 160 }, .height = .{ .px = 40 }, .scroll_bar = false }, null);
        defer c.end();
        s.front = c.node(front).id;
        for (0..5) |_| ui.div(c).w(100).h(40).end();
    }
};

fn checkOwnership(front_first: bool) !void {
    var s: Ownership = .{ .front_first = front_first };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Ownership.view), .{ .width = 200, .height = 160, .scale = 1 });
    defer t.deinit();
    // Scroll regions must not turn noninteractive boxes into hover/click hits.
    t.moveTo(30, 20);
    try testing.expectEqual(@as(u64, 0), t.ctx.hot);
    try testing.expect(!t.ctx.hitAt(.{ .x = 30, .y = 20 }));
    t.hscroll(30, 20, -40);
    try testing.expectEqual(@as(f32, 40), t.ctx.scroll_x.get(s.front) orelse 0);
    try testing.expectEqual(@as(f32, 0), t.ctx.scroll_x.get(s.back) orelse 0);
    // Inside the front's raw rectangle, but outside its parent's painted clip.
    t.hscroll(120, 20, -40);
    try testing.expectEqual(@as(f32, 40), t.ctx.scroll_x.get(s.front) orelse 0);
    try testing.expectEqual(@as(f32, 40), t.ctx.scroll_x.get(s.back).?);
}

test "horizontal ownership follows layers, not the order nodes were built" {
    try checkOwnership(true);
}

test "a clipped horizontal scroller cannot take x outside its painted region" {
    try checkOwnership(false);
}

const Nested = struct {
    outer: u64 = 0,
    inner: u64 = 0,
    fn view(s: *Nested, c: *ui.Context) void {
        const outer = c.open(.{ .direction = .row, .scroll_x = true, .width = .{ .px = 200 }, .height = .{ .px = 100 }, .scroll_bar = false }, null);
        defer c.end();
        s.outer = c.node(outer).id;
        {
            const inner = c.open(.{ .direction = .row, .scroll_x = true, .width = .{ .px = 100 }, .height = .{ .px = 80 }, .scroll_bar = false }, null);
            defer c.end();
            s.inner = c.node(inner).id;
            for (0..3) |_| ui.div(c).w(80).h(40).end();
        }
        ui.div(c).w(400).h(40).end();
    }
};

test "nested horizontal scrolling keeps innermost ownership and clamping" {
    var s: Nested = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Nested.view), .{ .scale = 1 });
    defer t.deinit();
    t.hscroll(30, 20, -500);
    try testing.expectEqual(@as(f32, 140), t.ctx.scroll_x.get(s.inner).?);
    try testing.expectEqual(@as(f32, 0), t.ctx.scroll_x.get(s.outer) orelse 0);
    t.hscroll(30, 20, 20);
    try testing.expectEqual(@as(f32, 120), t.ctx.scroll_x.get(s.inner).?);
    t.hscroll(150, 20, -30);
    try testing.expectEqual(@as(f32, 30), t.ctx.scroll_x.get(s.outer).?);
    try testing.expectEqual(@as(f32, 120), t.ctx.scroll_x.get(s.inner).?);
}

const Axes = struct {
    vertical: u64 = 0,
    horizontal: u64 = 0,
    fn view(s: *Axes, c: *ui.Context) void {
        const page = ui.div(c).column().w(200).h(160).scrollY();
        defer page.end();
        s.vertical = c.node(page.index).id;
        {
            const row = c.open(.{ .direction = .row, .scroll_x = true, .width = .{ .px = 180 }, .height = .{ .px = 80 }, .scroll_bar = false }, null);
            defer c.end();
            s.horizontal = c.node(row).id;
            for (0..5) |_| ui.div(c).w(100).h(40).end();
        }
        ui.div(c).wFull().h(400).end();
    }
};

test "horizontal regions leave vertical scrolling to the vertical ancestor" {
    var s: Axes = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Axes.view), .{ .scale = 1 });
    defer t.deinit();
    t.hscroll(30, 20, -40);
    try testing.expectEqual(@as(f32, 40), t.ctx.scroll_x.get(s.horizontal).?);
    try testing.expectEqual(@as(f32, 0), t.ctx.scroll.get(s.vertical) orelse 0);
    t.scroll(30, 20, -30);
    try testing.expectEqual(@as(f32, 30), t.ctx.scroll.get(s.vertical).?);
    try testing.expectEqual(@as(f32, 40), t.ctx.scroll_x.get(s.horizontal).?);
    try testing.expectEqual(@as(f32, 0), t.ctx.scroll.get(s.horizontal) orelse 0);
    try testing.expectEqual(@as(f32, 0), t.ctx.scroll_x.get(s.vertical) orelse 0);
}
