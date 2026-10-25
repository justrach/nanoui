//! Tooltips (`tooltip.zig`): not before the delay, then by the pointer;
//! gone when it leaves or presses; the pointer's other side at the
//! window's edge; a tooltip on a box inside a row leaves the row's click;
//! the app's own content; a frame asked for when the wait ends.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const App = struct {
    clicks: u32 = 0,
    row_clicks: u32 = 0,
    fn view(a: *App, c: *ui.Context) void {
        const col = ui.div(c).column().sizeFull().p(10).gap(10);
        defer col.end();
        {
            const b = ui.div(c).size(60, 24).center().bg(.hex(0xdddddd)).tooltip("Sidebar view options", .{ .delay = 0.35 });
            defer b.end();
            if (b.clicked()) a.clicks += 1;
            ui.text(c, "More", .{ .size = 12 });
        }
        {
            // A row that clicks, and an icon in it with a tooltip of its own.
            const row = ui.div(c).row().w(200).h(30).gap(8).itemsCenter().bg(.hex(0xeeeeee));
            defer row.end();
            if (row.clicked()) a.row_clicks += 1;
            const icon = ui.div(c).size(20, 20).bg(.hex(0x888888)).tooltip("Project · Device", .{});
            icon.end();
            ui.text(c, "Row", .{ .size = 12 });
        }
        {
            const card = ui.div(c).size(60, 24).bg(.hex(0xcccccc)).tooltipWith(a, drawCard, .{ .background = .hex(0x222222), .border = null, .themed = false });
            defer card.end();
            ui.text(c, "Card", .{ .size = 12 });
        }
        {
            const right = ui.div(c).row().wFull().justifyEnd();
            defer right.end();
            const b = ui.div(c).size(40, 24).bg(.hex(0xdddddd)).tooltip("Pauses it. Memory and files are kept; billing stops.", .{});
            defer b.end();
            ui.text(c, "Off", .{ .size = 12 });
        }
    }
    fn drawCard(a: *App, c: *ui.Context) void {
        ui.text(c, c.print("Clicked {d}", .{a.clicks}), .{ .size = 11, .color = .hex(0xffffff) });
    }
};

fn setup(a: *App, t: *ui.Tester) !void {
    a.* = .{};
    try t.init(testing.allocator, .init(a, App.view), .{ .width = 400, .height = 200 });
    t.settle(1);
}

test "a tooltip shows after its delay, not before, by the pointer; leaving hides it" {
    var a: App = undefined;
    var t: ui.Tester = undefined;
    try setup(&a, &t);
    defer t.deinit();
    t.moveTo(30, 20);
    t.advance(0.3);
    try testing.expect(t.tooltipText() == null and !t.hasText("Sidebar view options"));
    // The wait asks for the frame it ends in.
    try testing.expect(t.ctx.frame_in != null and t.ctx.frame_in.? <= 0.06);
    t.advance(0.1);
    try testing.expectEqualStrings("Sidebar view options", t.tooltipText().?);
    const r = t.tooltipRect().?;
    try testing.expectEqual(@as(f32, 31), r.x);
    try testing.expectEqual(@as(f32, 21), r.y);
    // text_tooltip's box: the text, 8 + 1 either side.
    const label = t.findText("Sidebar view options").?;
    try testing.expectApproxEqAbs(label.w + 18, r.w, 1);
    try testing.expectApproxEqAbs(label.x, r.x + 9, 0.01);
    // Moving on the box keeps it where it showed.
    t.moveTo(40, 22);
    try testing.expectEqual(@as(f32, 31), t.tooltipRect().?.x);
    // Leaving hides it at once; coming back waits again.
    t.moveTo(300, 150);
    try testing.expect(t.tooltipText() == null);
    t.moveTo(30, 20);
    try testing.expect(t.tooltipText() == null);
    t.advance(0.4);
    try testing.expect(t.tooltipText() != null);
}

test "a press hides a tooltip until the pointer moves; it waits again then" {
    var a: App = undefined;
    var t: ui.Tester = undefined;
    try setup(&a, &t);
    defer t.deinit();
    t.moveTo(30, 20);
    t.advance(0.5);
    try testing.expect(t.tooltipText() != null);
    t.click(30, 20);
    try testing.expectEqual(@as(u32, 1), a.clicks);
    t.advance(1);
    try testing.expect(t.tooltipText() == null);
    // Still, it asks for every move, to see the one off the press.
    try testing.expect(t.ctx.wants_moves);
    t.moveTo(32, 20);
    t.advance(0.2);
    try testing.expect(t.tooltipText() == null);
    t.advance(0.2);
    try testing.expect(t.tooltipText() != null);
}

test "a tooltip on a box inside a row leaves the row its click" {
    var a: App = undefined;
    var t: ui.Tester = undefined;
    try setup(&a, &t);
    defer t.deinit();
    // The icon: x 10..30, y 49..69 (the row is 30 tall at y 44).
    t.moveTo(20, 59);
    t.advance(0.6);
    try testing.expectEqualStrings("Project · Device", t.tooltipText().?);
    t.click(20, 59);
    try testing.expectEqual(@as(u32, 1), a.row_clicks);
    // Over the row past the icon: no tooltip.
    t.moveTo(150, 59);
    t.advance(0.6);
    try testing.expect(t.tooltipText() == null);
}

test "at the window's right edge it turns to the pointer's left, and long text wraps at 280" {
    var a: App = undefined;
    var t: ui.Tester = undefined;
    try setup(&a, &t);
    defer t.deinit();
    const off = t.findText("Off").?;
    t.moveTo(off.x + 2, off.y + 2);
    t.advance(0.6);
    const r = t.tooltipRect().?;
    try testing.expect(r.x + r.w <= off.x + 2 - 1 + 0.01);
    try testing.expect(r.w <= 280);
    try testing.expect(r.x + r.w <= 400);
}

test "a tooltip draws the app's own content" {
    var a: App = undefined;
    var t: ui.Tester = undefined;
    try setup(&a, &t);
    defer t.deinit();
    const card = t.findText("Card").?;
    t.moveTo(card.x + 2, card.y + 2);
    t.advance(0.6);
    try testing.expectEqualStrings("", t.tooltipText().?);
    try testing.expect(t.hasText("Clicked 0"));
    const r = t.tooltipRect().?;
    try testing.expectEqual(card.x + 3, r.x);
    try t.screenshot("/tmp/nanoui-tooltip.png");
}
