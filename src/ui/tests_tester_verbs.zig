//! The Tester's script verbs (`drop:`, `down:`/`move:`/`up`, `mods:`, the
//! app's own), a frame asked for from another thread waking `pump`, and
//! keyboard focus: Tab reaching a focusable box, Return and Space
//! clicking it, the focus ring drawn round it.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const Scene = struct {
    dropped: [4][128]u8 = undefined,
    dropped_len: [4]usize = @splat(0),
    drops: usize = 0,
    drop_at: ui.Point = .{},
    pressed_shift: bool = false,
    presses: u32 = 0,
    releases: u32 = 0,
    last_mouse: ui.Point = .{},
    clicks: [2]u32 = .{ 0, 0 },
    focused: [2]bool = .{ false, false },
    frames: u32 = 0,
    cmds: u32 = 0,

    fn view(s: *Scene, c: *ui.Context) void {
        s.frames += 1;
        if (c.input.drop) |d| {
            s.drop_at = d.point;
            s.drops = @min(d.urls.len, 4);
            for (d.urls[0..s.drops], 0..) |u, i| {
                const n = @min(u.len, 128);
                @memcpy(s.dropped[i][0..n], u[0..n]);
                s.dropped_len[i] = n;
            }
        }
        if (c.input.pressed) {
            s.presses += 1;
            s.pressed_shift = c.input.shift;
        }
        if (c.input.released) s.releases += 1;
        if (c.input.down) s.last_mouse = c.input.mouse;
        ui.column(c, .{ .width = .fill, .height = .fill, .gap = 10, .padding = .all(10) });
        defer ui.end(c);
        for (0..2) |i| {
            const b = c.open(.{ .width = .{ .px = 80 }, .height = .{ .px = 30 }, .background = .hex(0x333333) }, c.print("box{d}", .{i}));
            const it = c.interact(b, .{ .focusable = true });
            if (it.clicked) s.clicks[i] += 1;
            s.focused[i] = it.focused;
            ui.text(c, if (i == 0) "One" else "Two", .{ .size = 12 });
            c.end();
        }
    }

    fn verb(ctx: ?*anyopaque, _: *ui.Tester, op: []const u8, arg: []const u8) anyerror!bool {
        const s: *Scene = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, op, "cmd")) return false;
        if (std.mem.eql(u8, arg, "count")) s.cmds += 1;
        return true;
    }
};

test "tester: drop: brings files as file URLs at a point" {
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 300, .height = 200, .scale = 1 });
    defer t.deinit();
    try t.runScript("drop:40,50,/tmp/a b.mov|https://x.org/c.wav");
    try testing.expectEqual(@as(usize, 2), s.drops);
    try testing.expectEqualStrings("file:///tmp/a%20b.mov", s.dropped[0][0..s.dropped_len[0]]);
    try testing.expectEqualStrings("https://x.org/c.wav", s.dropped[1][0..s.dropped_len[1]]);
    try testing.expectEqual(@as(f32, 50), s.drop_at.y);
}

test "tester: down, move and up with the keys mods: holds, and the app's verbs" {
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 300, .height = 200, .scale = 1 });
    defer t.deinit();
    t.app_verbs = .{ .ctx = &s, .run = Scene.verb };
    try t.runScript("mods:shift; down:20,20; move:60,70");
    try testing.expectEqual(@as(u32, 1), s.presses);
    try testing.expect(s.pressed_shift);
    try testing.expect(t.ctx.input.down);
    try testing.expectEqual(@as(f32, 70), s.last_mouse.y);
    try t.runScript("up; mods:; cmd:count; cmd:count");
    try testing.expectEqual(@as(u32, 1), s.releases);
    try testing.expect(!t.ctx.input.down and !t.ctx.input.shift);
    try testing.expectEqual(@as(u32, 2), s.cmds);
    try testing.expectError(error.UnknownStep, t.runScript("nope:1"));
}

fn asker(t: *ui.Tester) void {
    std.Io.sleep(testing.io, .fromMilliseconds(30), .awake) catch {};
    t.ctx.requestFrameFromAnyThread();
}

test "tester: a frame asked for from another thread wakes pump" {
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 300, .height = 200, .scale = 1 });
    defer t.deinit();
    const before = s.frames;
    const started = ui.clock.now();
    const th = try std.Thread.spawn(.{}, asker, .{&t});
    t.pump(10);
    th.join();
    // Back well before the 10 seconds, with a frame drawn.
    try testing.expect(ui.clock.now() - started < 5);
    try testing.expect(s.frames > before);
    try testing.expect(!t.woken.load(.acquire));
}

test "focus: Tab reaches focusable boxes; Return and Space click; the ring shows" {
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 300, .height = 200, .scale = 1 });
    defer t.deinit();
    t.ctx.focus_ring = .{ .color = .hex(0xff0000), .width = 2 };
    t.frame();
    try testing.expect(!s.focused[0] and !s.focused[1]);
    t.key(.tab);
    t.frame();
    try testing.expect(s.focused[0] and !s.focused[1]);
    t.key(.tab);
    t.frame();
    try testing.expect(!s.focused[0] and s.focused[1]);
    t.key(.enter);
    try testing.expectEqual(@as(u32, 1), s.clicks[1]);
    t.typeText(" ");
    try testing.expectEqual(@as(u32, 2), s.clicks[1]);
    // As the Mac offers bare keys first, a shortcut.
    try testing.expect(t.shortcut(.{ .key = ' ' }));
    try testing.expectEqual(@as(u32, 3), s.clicks[1]);
    try testing.expectEqual(@as(u32, 0), s.clicks[0]);
    var ringed = false;
    for (t.ctx.nodes.items) |n| {
        if (n.style.border) |b| if (b.r == 1 and b.g == 0) {
            ringed = true;
        };
    }
    try testing.expect(ringed);
    // Shift-Tab goes back.
    t.ctx.input.shift = true;
    t.key(.tab);
    t.ctx.input.shift = false;
    t.frame();
    try testing.expect(s.focused[0]);
}
