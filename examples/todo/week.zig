//! The week across the top: each day's initial, a ring of how much of it
//! got done, and its date. Today's initial sits on a soft pill; days to
//! come are faint and empty. Today's ring fills as tasks are checked.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const motion = ui.motion;
const todo = @import("todo.zig");

const pink = ui.Color.hex(0xf26d6d);
const blush = ui.Color.hex(0xfdeceb);
const faint = ui.Color.hex(0xeeeff1);

const Day = struct { letter: []const u8, date: u8, done: ?f32 };
/// Monday the 20th to Sunday the 26th; today is Thursday. Past days' share
/// done, and null for days still to come.
const days = [_]Day{
    .{ .letter = "M", .date = 20, .done = 0.15 },
    .{ .letter = "T", .date = 21, .done = 1 },
    .{ .letter = "W", .date = 22, .done = 0.3 },
    .{ .letter = "T", .date = 23, .done = 0 },
    .{ .letter = "F", .date = 24, .done = null },
    .{ .letter = "S", .date = 25, .done = null },
    .{ .letter = "S", .date = 26, .done = null },
};
const today = 3;
const size = 32;

pub fn strip(c: *ui.Context, done: usize, total: usize) void {
    const r = ui.div(c).row().wFull().justifyBetween();
    defer r.end();
    // Today's share, eased as it changes.
    const share: f32 = if (total == 0) 0 else @as(f32, @floatFromInt(done)) / @as(f32, @floatFromInt(total));
    const now = motion.number(c, "today", share, .{ .spring = motion.Spring.visual(0.6, 0) });
    for (days, 0..) |d, i| {
        const col = ui.div(c).column().w(40).gap(8).itemsCenter();
        defer col.end();
        {
            const is_today = i == today;
            const pill = ui.div(c).w(22).h(22).rounded(11).bg(if (is_today) ui.Color.hex(0xe6e7ea) else faint.alpha(0)).center();
            defer pill.end();
            ui.text(c, d.letter, .{ .size = 12, .weight = .semibold, .color = if (is_today) todo.ink else if (d.done == null) ui.Color.hex(0xc9cbd0) else todo.muted });
        }
        ring(c, if (i == today) now else d.done);
        ui.text(c, c.print("{d}", .{d.date}), .{
            .size = 14,
            .weight = if (i == today) .bold else .semibold,
            .tabular = true,
            .color = if (i == today) todo.ink else if (d.done == null) ui.Color.hex(0xc9cbd0) else ui.Color.hex(0x6b6e76),
        });
    }
}

/// A day's ring: a blush disc with a pink arc of what got done, green and
/// whole once all of it did; a faint disc for a day still to come.
fn ring(c: *ui.Context, value: ?f32) void {
    const cv = ui.canvas(c, .{ .width = .{ .px = size }, .height = .{ .px = size } });
    const mid: ui.Point = .{ .x = size / 2, .y = size / 2 };
    const v = value orelse {
        cv.circle(mid, size / 2, faint);
        return;
    };
    const p = std.math.clamp(v, 0, 1);
    // Blush to white, pink to green, over the last tenth.
    const whole = std.math.clamp((p - 0.9) * 10, 0, 1);
    cv.circle(mid, size / 2, blush.mix(.white, whole));
    const arc = pink.mix(todo.green, whole);
    const r = size / 2 - 2.5;
    if (whole > 0) cv.ring(mid, r + 1.75, 3.5, todo.green.alpha(0.15 * whole));
    if (p <= 0.001) return;
    var pts: [65]ui.Point = undefined;
    const n: usize = @max(2, @as(usize, @intFromFloat(@ceil(p * 64))));
    for (0..n + 1) |k| {
        const a = -std.math.pi / 2.0 + 2 * std.math.pi * p * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
        pts[k] = .{ .x = mid.x + r * @cos(a), .y = mid.y + r * @sin(a) };
    }
    cv.polyline(pts[0 .. n + 1], .{ .width = 3.5, .color = arc });
}
