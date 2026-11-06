//! Opt-in input modality and pixel-grid layout, through real offscreen frames.
const std = @import("std");
const ui = @import("ui.zig");
const testing = std.testing;

const Hover = struct {
    hide: bool = true,
    parent_hovered: bool = false,
    child_hovered: bool = false,
    child: u64 = 0,
    fn view(s: *Hover, c: *ui.Context) void {
        c.keyboard_hides_hover = s.hide;
        const parent = ui.div(c).size(100, 60).control();
        defer parent.end();
        s.parent_hovered = parent.hovered();
        const child = ui.div(c).size(40, 30).control();
        defer child.end();
        s.child = child.id();
        s.child_hovered = child.hovered();
    }
};

test "keyboard hover suppression survives frame hit commits until pointer input" {
    var s: Hover = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Hover.view), .{});
    defer t.deinit();
    t.moveTo(10, 10);
    t.frame();
    try testing.expect(s.parent_hovered and s.child_hovered);
    try testing.expectEqual(s.child, t.ctx.hot);
    try testing.expect(t.ctx.hot_index < t.ctx.nodes.items.len);
    t.key(.escape);
    t.frame();
    try testing.expectEqual(@as(u64, 0), t.ctx.hot);
    try testing.expectEqual(@import("context.zig").none, t.ctx.hot_index);
    try testing.expectEqual(@as(usize, 0), t.ctx.hot_path.items.len);
    try testing.expect(!s.parent_hovered and !s.child_hovered);
    t.moveTo(11, 10);
    t.frame();
    try testing.expect(s.parent_hovered and s.child_hovered);
    t.typeText("x");
    t.frame();
    try testing.expectEqual(@as(u64, 0), t.ctx.hot);
    // A press at the same point restores pointer modality without a move.
    t.ctx.pointerDown();
    t.frame();
    try testing.expectEqual(s.child, t.ctx.hot);
    try testing.expectEqual(s.child, t.ctx.active);
    t.ctx.pointerUp();
    t.frame();
}

test "keyboard input keeps hover by default and text operations hide it when opted in" {
    var s: Hover = .{ .hide = false };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Hover.view), .{});
    defer t.deinit();
    t.moveTo(10, 10);
    t.key(.escape);
    t.frame();
    try testing.expectEqual(s.child, t.ctx.hot);
    try testing.expect(s.parent_hovered and s.child_hovered);
    s.hide = true;
    t.frame();
    t.textOps(&.{.{ .command = .copy }});
    t.frame();
    try testing.expectEqual(@as(u64, 0), t.ctx.hot);
    t.ctx.secondaryDown();
    t.frame();
    try testing.expectEqual(s.child, t.ctx.hot);
}

const Grid = struct {
    snap: bool = true,
    text_snap: bool = true,
    fn view(s: *Grid, c: *ui.Context) void {
        c.pixel_snap = s.snap;
        c.pixel_snap_text = s.text_snap;
        const row = ui.div(c).row().w(51).h(20).offset(-0.25, 0.25);
        defer row.end();
        const first = ui.div(c).w(20.5).h(10.5).bg(.hex(0xff0000)).control();
        _ = first.interaction();
        first.end();
        const second = ui.div(c).w(30.5).h(10.5).control();
        _ = second.interaction();
        second.end();
    }
};

test "pixel snapping rounds absolute edges together including half ties and hit boxes" {
    var s: Grid = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Grid.view), .{ .scale = 2 });
    defer t.deinit();
    const a = t.ctx.nodes.items[2].rect;
    const b = t.ctx.nodes.items[3].rect;
    try testing.expectEqual(ui.Rect{ .x = 0, .y = 0, .w = 20, .h = 10.5 }, a);
    try testing.expectEqual(a.x + a.w, b.x);
    try testing.expectEqual(@as(f32, 50.5), b.x + b.w);
    try testing.expectEqual(a, t.ctx.rects.get(t.ctx.nodes.items[2].id).?);
    try testing.expectEqual(a, t.ctx.hits.items[0].rect);
    var painted = false;
    for (t.instances.items) |instance| {
        if (instance.color[0] == 1 and instance.color[1] == 0 and instance.color[3] == 1) {
            try testing.expectEqual([4]f32{ a.x, a.y, a.w, a.h }, instance.rect);
            painted = true;
        }
    }
    try testing.expect(painted);
    s.snap = false;
    t.frame();
    try testing.expectEqual(@as(f32, -0.25), t.ctx.nodes.items[2].rect.x);
    try testing.expectEqual(@as(f32, 0.25), t.ctx.nodes.items[2].rect.y);
}

const TextGrid = struct {
    fn view(_: *TextGrid, c: *ui.Context) void {
        c.pixel_snap = true;
        ui.text(c, "Fractional width", .{ .size = 11.3, .line_height = 17.3 });
        ui.text(c, "Fractional width", .{ .size = 11.3, .line_height = 17.3, .wrap = true });
    }
};

test "pixel snapping optionally rounds both wrapped and unwrapped text measurement" {
    var s: TextGrid = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, TextGrid.view), .{ .scale = 2 });
    defer t.deinit();
    for (t.ctx.nodes.items[1..3]) |n| {
        try testing.expectEqual(@as(f32, 17.5), n.measured.h);
        try testing.expectEqual(@ceil(n.measured.w * 2), n.measured.w * 2);
    }
    t.ctx.pixel_snap_text = false;
    t.frame();
    for (t.ctx.nodes.items[1..3]) |n| try testing.expectApproxEqAbs(@as(f32, 17.3), n.measured.h, 0.0001);
}
