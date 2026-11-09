//! A box that takes the wheel itself (`Div.wheel`): over a scrolling page,
//! as a menu's strip of tabs is, the wheel pans the strip and leaves the
//! page where it was. Without it, the page behind the menu scrolled.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const Scene = struct {
    wheel: bool,
    panned: f32 = 0,
    page: u64 = 0,
    fn view(s: *Scene, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull();
        defer root.end();
        {
            ui.key(c, "page");
            const page = ui.div(c).column().wFull().h(200).scrollY();
            defer page.end();
            s.page = c.node(page.index).id;
            for (0..20) |_| ui.div(c).wFull().h(40).end();
        }
        // An overlay over the page, with a strip that pans sideways.
        const menu = ui.div(c).fixed().offset(10, 10).w(100).h(100).layer(1).column();
        defer menu.end();
        const strip = ui.div(c).wFull().h(30).clip();
        const s2 = if (s.wheel) strip.wheel() else strip;
        defer s2.end();
        if (s2.hovered()) {
            c.wants_wheel = true;
            s.panned -= c.input.scroll.y;
        }
    }
};

fn pageOffset(t: *ui.Tester, s: *const Scene) f32 {
    return t.ctx.scroll.get(s.page) orelse 0;
}

test "the wheel over a wheel box pans it, not the scrolling page behind" {
    var s: Scene = .{ .wheel = true };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 200, .height = 200, .scale = 1 });
    defer t.deinit();
    t.settle(0.1);
    t.moveTo(30, 20);
    t.scroll(30, 20, -40);
    try testing.expectEqual(@as(f32, 40), s.panned);
    try testing.expectEqual(@as(f32, 0), pageOffset(&t, &s));
    // Off the strip, the page scrolls as before.
    t.moveTo(150, 150);
    t.scroll(150, 150, -40);
    try testing.expectEqual(@as(f32, 40), pageOffset(&t, &s));
}

const Horizontal = struct {
    page: u64 = 0,
    panned: f32 = 0,
    fn view(s: *Horizontal, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull();
        defer root.end();
        {
            const page = c.open(.{ .direction = .row, .scroll_x = true, .width = .fill, .height = .fill, .scroll_bar = false }, null);
            defer c.end();
            s.page = c.node(page).id;
            for (0..5) |_| ui.div(c).w(100).h(100).end();
        }
        const strip = ui.div(c).fixed().offset(10, 10).w(100).h(30).layer(1).clip().wheel();
        defer strip.end();
        if (strip.hovered()) {
            c.wants_wheel = true;
            s.panned -= c.input.scroll.x;
        }
    }
};

test "a wheel overlay consumes x without moving the horizontal page behind" {
    var s: Horizontal = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Horizontal.view), .{ .width = 200, .height = 200, .scale = 1 });
    defer t.deinit();
    t.moveTo(30, 20);
    t.hscroll(30, 20, -40);
    try testing.expectEqual(@as(f32, 40), s.panned);
    try testing.expectEqual(@as(f32, 0), t.ctx.scroll_x.get(s.page) orelse 0);
    // Outside the painted strip the normal horizontal scroller still owns x.
    t.moveTo(150, 150);
    t.hscroll(150, 150, -40);
    try testing.expectEqual(@as(f32, 40), s.panned);
    try testing.expectEqual(@as(f32, 40), t.ctx.scroll_x.get(s.page).?);
    // A positive delta reverses direction, clamping at the start as before.
    t.hscroll(150, 150, 100);
    try testing.expectEqual(@as(f32, 0), t.ctx.scroll_x.get(s.page).?);
}

test "without it, the page behind takes the wheel (what `wheel` fixes)" {
    var s: Scene = .{ .wheel = false };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 200, .height = 200, .scale = 1 });
    defer t.deinit();
    t.settle(0.1);
    t.moveTo(30, 20);
    t.scroll(30, 20, -40);
    try testing.expectEqual(@as(f32, 0), s.panned);
    try testing.expectEqual(@as(f32, 40), pageOffset(&t, &s));
}

/// A canvas that pans with two fingers: it marks itself `wheel` and reads
/// `input.scroll` without setting `wants_wheel`.
const Canvas = struct {
    x: f32 = 0,
    y: f32 = 0,
    fn view(s: *Canvas, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull();
        defer root.end();
        const cv = ui.div(c).w(200).h(200).clip().wheel();
        defer cv.end();
        if (cv.hovered()) {
            s.x += c.input.scroll.x;
            s.y += c.input.scroll.y;
        }
    }
};

test "a wheel box gets the wheel's vertical deltas without asking each frame" {
    var s: Canvas = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Canvas.view), .{ .width = 300, .height = 300, .scale = 1 });
    defer t.deinit();
    t.settle(0.1);
    t.moveTo(100, 100);
    t.frame();
    t.scroll(100, 100, 30);
    try testing.expectEqual(@as(f32, 30), s.y);
}
