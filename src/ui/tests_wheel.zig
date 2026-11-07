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
