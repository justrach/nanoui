//! Delayed overlays never take a decorative owner's clicks or poll while idle.
const std = @import("std");
const ui = @import("ui.zig");
const tip = @import("tooltip.zig");
const testing = std.testing;

const Scene = struct {
    custom: bool = false,
    hide_hover: bool = false,
    owner: u64 = 0,
    clicks: usize = 0,
    fn view(s: *Scene, c: *ui.Context) void {
        c.keyboard_hides_hover = s.hide_hover;
        const row = ui.div(c).size(100, 50).control();
        defer row.end();
        s.owner = row.id();
        if (row.clicked()) s.clicks += 1;
        const decorative = ui.div(c).size(40, 30);
        defer decorative.end();
        if (s.custom) {
            _ = decorative.tooltipWith(s, content, .{ .delay = 0.35 });
        } else {
            _ = decorative.tooltip("Delayed help", .{ .delay = 0.35, .text = .{ .size = 11, .line_height = 18 } });
        }
    }
    fn content(_: *Scene, c: *ui.Context) void {
        ui.text(c, "Custom help", .{ .size = 12 });
        ui.text(c, "Second line", .{ .size = 11 });
    }
};

fn shown(t: *ui.Tester) bool {
    return t.tooltipText() != null;
}

fn shownRect(t: *ui.Tester) ui.Rect {
    return t.tooltipRect().?;
}

test "a decorative tooltip waits then overlays without taking its row's hit" {
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{});
    defer t.deinit();
    try testing.expect(!shown(&t));
    try testing.expectEqual(@as(?f32, null), t.ctx.frame_in);
    t.moveTo(10, 10);
    try testing.expect(!shown(&t));
    try testing.expect(t.ctx.frame_in.? > 0 and t.ctx.frame_in.? <= 0.35);
    t.advance(0.25);
    try testing.expect(!shown(&t));
    t.advance(0.15);
    try testing.expect(shown(&t));
    try testing.expectEqualStrings("Delayed help", t.ctx.tooltip.shown.?.text);
    try testing.expectEqual(@as(f32, 11), shownRect(&t).x);
    try testing.expectEqual(@as(f32, 11), shownRect(&t).y);
    // 18-point line + 6-point vertical padding + 1-point border each side.
    try testing.expectEqual(@as(f32, 32), shownRect(&t).h);
    try testing.expectEqual(s.owner, t.ctx.hot);
    try testing.expectEqual(@as(?f32, null), t.ctx.frame_in);
    try testing.expect(!t.ctx.animating);
    t.click(10, 10);
    try testing.expectEqual(@as(usize, 1), s.clicks);
    try testing.expect(!shown(&t));
    t.advance(0.6);
    try testing.expect(!shown(&t));
    try testing.expect(t.ctx.wants_moves);
    try testing.expectEqual(@as(?f32, null), t.ctx.frame_in);
    t.moveTo(11, 10);
    t.advance(0.4);
    try testing.expect(shown(&t));
    t.moveTo(200, 200);
    try testing.expect(!shown(&t));
    try testing.expectEqual(@as(?f32, null), t.ctx.frame_in);
}

test "keyboard modality hides delayed help until pointer activity and restarts its delay" {
    var s: Scene = .{ .hide_hover = true };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{});
    defer t.deinit();
    t.moveTo(10, 10);
    t.advance(0.4);
    try testing.expect(shown(&t));
    t.key(.escape);
    t.advance(0.5);
    try testing.expect(!shown(&t));
    try testing.expectEqual(@as(?f32, null), t.ctx.frame_in);
    t.moveTo(11, 10);
    try testing.expect(!shown(&t));
    t.advance(0.4);
    try testing.expect(shown(&t));
}

test "custom tooltip content is drawn once outside the owner's layout" {
    var s: Scene = .{ .custom = true };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{});
    defer t.deinit();
    const before = t.ctx.nodes.items[1].rect;
    t.moveTo(10, 10);
    t.advance(0.4);
    try testing.expect(shown(&t));
    try testing.expectEqual(before, t.ctx.rects.get(s.owner).?);
    try testing.expect(t.hasText("Custom help") and t.hasText("Second line"));
    var copies: usize = 0;
    for (t.ctx.nodes.items) |n| {
        if (n.content == .text and std.mem.eql(u8, n.content.text.str, "Custom help")) copies += 1;
    }
    try testing.expectEqual(@as(usize, 1), copies);
    try testing.expectEqual(s.owner, t.ctx.hot);
    try testing.expect(shownRect(&t).h > 20);
}

test "tooltip placement flips each overflowing axis and clamps an oversized panel" {
    const window: ui.Size = .{ .w = 100, .h = 80 };
    try testing.expectEqual(ui.Point{ .x = 59, .y = 49 }, tip.place(.{ .x = 90, .y = 70 }, .{ .w = 30, .h = 20 }, window));
    try testing.expectEqual(ui.Point{ .x = 0, .y = 0 }, tip.place(.{ .x = 20, .y = 20 }, .{ .w = 120, .h = 90 }, window));
}
