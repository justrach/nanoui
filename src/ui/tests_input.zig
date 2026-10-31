//! The pointer's other buttons, the modifier keys alone, drops from other
//! apps, help, and boxes that move the window: tested through `Tester`.
const std = @import("std");
const ui = @import("ui.zig");
const testing = std.testing;

const Clicks = struct {
    left: u32 = 0,
    right: u32 = 0,
    middle: u32 = 0,
    double: u32 = 0,
    pressed: bool = false,
    mods: u32 = 0,
    cmd: bool = false,
    dropped: ?[]const u8 = null,
    dropped_on: u8 = 0,
    over: bool = false,
    drag_window: bool = false,
    fn view(s: *Clicks, c: *ui.Context) void {
        ui.row(c, .{ .padding = .all(20), .gap = 20 });
        defer ui.end(c);
        for (0..2) |n| {
            const i = c.open(.{ .width = .{ .px = 100 }, .height = .{ .px = 40 }, .window_drag = n == 1 }, null);
            defer c.end();
            const it = c.interact(i, .{});
            c.help(i, if (n == 0) "First" else "Second");
            c.acceptDrop(i);
            if (n == 0) {
                if (it.clicked) s.left += 1;
                if (it.right_clicked) s.right += 1;
                if (it.middle_clicked) s.middle += 1;
                if (it.pressed) s.pressed = true;
                if (c.input.drag_over) |p| s.over = it.rect != null and it.rect.?.contains(p);
            } else if (it.double_clicked) s.double += 1;
            if (c.dropAt(i)) |d| {
                s.dropped = if (d.urls.len > 0) d.urls[0] else d.text;
                s.dropped_on = @intCast(n + 1);
            }
        }
        if (c.input.mods_changed) {
            s.mods += 1;
            s.cmd = c.input.cmd;
        }
    }
};

fn start(t: *ui.Tester, s: *Clicks) !void {
    try t.init(testing.allocator, .init(s, Clicks.view), .{});
}

test "right click reports right_clicked only" {
    var s: Clicks = .{};
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    t.rightClick(70, 40);
    try testing.expectEqual(@as(u32, 1), s.right);
    try testing.expectEqual(@as(u32, 0), s.left);
    try testing.expect(!s.pressed);
    t.click(70, 40);
    try testing.expectEqual(@as(u32, 1), s.left);
    try testing.expectEqual(@as(u32, 1), s.right);
}

test "middle click reports middle_clicked" {
    var s: Clicks = .{};
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    t.middleClick(70, 40);
    try testing.expectEqual(@as(u32, 1), s.middle);
    try testing.expectEqual(@as(u32, 0), s.left + s.right);
}

test "flags change runs frame with mods_changed" {
    var s: Clicks = .{};
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    t.setMods(.{ .cmd = true });
    try testing.expectEqual(@as(u32, 1), s.mods);
    try testing.expect(s.cmd);
    t.setMods(.{});
    try testing.expectEqual(@as(u32, 2), s.mods);
    try testing.expect(!s.cmd);
    // An edge: the next frame has none.
    t.frame();
    try testing.expectEqual(@as(u32, 2), s.mods);
}

test "drop delivers urls to target" {
    var s: Clicks = .{};
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    // Over a box that takes drops: offered, and the view sees where.
    try testing.expect(t.ctx.acceptsDropAt(.{ .x = 70, .y = 40 }));
    try testing.expect(!t.ctx.acceptsDropAt(.{ .x = 5, .y = 5 }));
    t.drop(190, 40, &.{"https://kea.app/"}, "");
    try testing.expectEqualStrings("https://kea.app/", s.dropped.?);
    try testing.expectEqual(@as(u8, 2), s.dropped_on);
    t.drop(70, 40, &.{}, "some text");
    try testing.expectEqualStrings("some text", s.dropped.?);
    try testing.expectEqual(@as(u8, 1), s.dropped_on);
    try testing.expect(t.ctx.input.drop == null);
}

test "window_drag box moves the window on a press and takes double clicks" {
    var s: Clicks = .{};
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    t.moveTo(190, 40);
    t.ctx.input.click_count = 1;
    try testing.expect(t.ctx.startsWindowDrag());
    t.ctx.input.click_count = 2;
    try testing.expect(!t.ctx.startsWindowDrag());
    t.moveTo(70, 40);
    t.ctx.input.click_count = 1;
    try testing.expect(!t.ctx.startsWindowDrag());
    t.doubleClick(190, 40);
    try testing.expectEqual(@as(u32, 1), s.double);
}

test "help follows the hot box" {
    var s: Clicks = .{};
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    t.moveTo(70, 40);
    try testing.expectEqualStrings("First", t.ctx.hotHelp().?);
    t.moveTo(190, 40);
    try testing.expectEqualStrings("Second", t.ctx.hotHelp().?);
    t.moveTo(5, 5);
    try testing.expect(t.ctx.hotHelp() == null);
}

const Strip = struct {
    sideways: f32 = 0,
    fn view(s: *Strip, c: *ui.Context) void {
        s.sideways += c.input.scroll.x;
        ui.column(c, .{ .width = .fill, .height = .fill });
        ui.end(c);
    }
};

test "a sideways scroll reaches the view" {
    var s: Strip = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Strip.view), .{});
    defer t.deinit();
    t.hscroll(50, 50, -30);
    try testing.expectEqual(@as(f32, -30), s.sideways);
}

test "right_clicked fires on right press and Ctrl+left press and clears down" {
    var s: Clicks = .{};
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    // Right press alone (before release) triggers right_clicked and clears down.
    t.moveTo(70, 40);
    t.ctx.input.button = .right;
    t.ctx.pointerDown();
    t.frame();
    try testing.expectEqual(@as(u32, 1), s.right);
    try testing.expect(!t.ctx.input.down);
    try testing.expectEqual(@as(u64, 0), t.ctx.active);
    // Ctrl+left press triggers right_clicked, not left click or pressed.
    t.ctx.input.button = .left;
    t.ctx.input.ctrl = true;
    t.ctx.pointerDown();
    t.frame();
    t.ctx.input.ctrl = false;
    try testing.expectEqual(@as(u32, 2), s.right);
    try testing.expectEqual(@as(u32, 0), s.left);
    try testing.expect(!s.pressed);
    try testing.expect(!t.ctx.input.down);
}

const ScrollBox = struct {
    id: u64 = 0,
    edge_clicks: u32 = 0,
    fn view(s: *ScrollBox, c: *ui.Context) void {
        const b = c.open(.{ .scroll = true, .direction = .column, .width = .{ .px = 100 }, .height = .{ .px = 100 } }, "sbox");
        defer c.end();
        s.id = c.node(b).id;
        ui.row(c, .{ .width = .fill, .height = .{ .px = 30 }, .justify = .end });
        const btn = c.open(.{ .width = .{ .px = 16 }, .height = .{ .px = 16 } }, "edge_btn");
        if (c.interact(btn, .{}).clicked) s.edge_clicks += 1;
        c.end();
        ui.end(c);
        for (0..9) |_| _ = c.leaf(.{ .width = .fill, .height = .{ .px = 30 } }, .none, null);
    }
};

test "rubber-band overscroll on precise trackpad and spring back" {
    var s: ScrollBox = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, ScrollBox.view), .{});
    defer t.deinit();
    t.ctx.input.mouse = .{ .x = 50, .y = 50 };
    t.ctx.input.precise = true;
    t.ctx.input.scroll_phase = .began;
    t.ctx.scroll_holding = true;
    _ = t.ctx.applyScroll(40); // pull down past top (0)
    t.frame();
    try testing.expectApproxEqAbs(@as(f32, -14), t.ctx.overscroll.get(s.id).?, 0.1);
    try testing.expectApproxEqAbs(@as(f32, 14), t.ctx.nodes.items[2].rect.y, 0.5);
    // Release fingers: springs back to 0.
    t.ctx.scroll_holding = false;
    t.ctx.input.scroll_phase = .ended;
    t.settle(1.5);
    try testing.expectApproxEqAbs(@as(f32, 0), t.ctx.overscroll.get(s.id).?, 0.1);
    try testing.expectApproxEqAbs(@as(f32, 0), t.ctx.nodes.items[2].rect.y, 0.5);
}

test "button flush against the right edge of a scroll box gets its click" {
    var s: ScrollBox = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, ScrollBox.view), .{});
    defer t.deinit();
    t.click(95, 8);
    try testing.expectEqual(@as(u32, 1), s.edge_clicks);
}

const CloseOnce = struct {
    builds: u32 = 0,

    fn view(r: *CloseOnce, c: *ui.Context) void {
        r.builds += 1;
        const root = ui.div(c).p(10);
        defer root.end();
        ui.text(c, "close me", .{});
        // A one-shot ask, the way a click action makes it. The rebuild the ask
        // causes must not take the request back out: that was a window that
        // never closed no matter how often the button was pressed.
        if (r.builds == 1) c.requestClose();
    }
};

test "a one-shot requestClose survives the rebuild it asked for" {
    var s: CloseOnce = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, CloseOnce.view), .{});
    defer t.deinit();
    // The first build asked; the rebuild it caused ran the view again (a
    // window that did close on this path built twice and closed never).
    try testing.expect(s.builds >= 2);
    try testing.expect(t.ctx.close_request);
}
