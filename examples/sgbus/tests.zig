//! `zig build test-sgbus`: the planner on the bundled stop lists, for
//! three real trips, with no live data (the model alone) and with made-up
//! live boards (to check that waits and pace are used). It prints what it
//! plans, so the numbers can be read against real trips.
const std = @import("std");
const data = @import("data.zig");
const raptor = @import("raptor.zig");
const Coord = @import("nanoui").map.Coord;

test {
    _ = @import("onemap.zig");
}

test "fares follow LTA's table from 27 December 2025" {
    try std.testing.expectEqual(@as(u16, 128), raptor.fareCents(3.2, false));
    try std.testing.expectEqual(@as(u16, 138), raptor.fareCents(3.21, false));
    try std.testing.expectEqual(@as(u16, 149), raptor.fareCents(4.3, false));
    try std.testing.expectEqual(@as(u16, 186), raptor.fareCents(10.2, false));
    try std.testing.expectEqual(@as(u16, 256), raptor.fareCents(40.2, false));
    try std.testing.expectEqual(@as(u16, 257), raptor.fareCents(55, false));
    try std.testing.expectEqual(@as(u16, 228), raptor.fareCents(2, true));
    try std.testing.expect(raptor.express("10e") and raptor.express("502") and !raptor.express("14"));
}

const Trip = struct { name: []const u8, from: Coord, to: Coord };

const trips = [_]Trip{
    .{ .name = "Joo Chiat (Joo Chiat Pl) to Suntec City", .from = .{ .lat = 1.31451, .lng = 103.90998 }, .to = .{ .lat = 1.29504, .lng = 103.85846 } },
    .{ .name = "Tampines Int to Jurong East Int", .from = .{ .lat = 1.35360, .lng = 103.94430 }, .to = .{ .lat = 1.33315, .lng = 103.74220 } },
    .{ .name = "Ang Mo Kio Int to Orchard (ION)", .from = .{ .lat = 1.36916, .lng = 103.84825 }, .to = .{ .lat = 1.30400, .lng = 103.83200 } },
};

fn show(d: *const data.Data, t: Trip, got: []const raptor.Option) void {
    std.debug.print("\n{s}\n", .{t.name});
    for (got) |o| {
        std.debug.print("  {d:>5.1} min  {d} change(s)  walk {d:>4.0} m  {d:>4.1} km  fare ", .{ o.arrive, o.n - 1, o.walk_m, o.km });
        if (o.fare) |f| std.debug.print("${d}.{d:0>2}", .{ f / 100, f % 100 }) else std.debug.print("n/a", .{});
        std.debug.print("  ", .{});
        for (0..o.n) |i| {
            const rd = o.rides[i];
            std.debug.print("{s}{s} ({s}>{s}, {d} stops, wait {d:.1}{s}, ride {d:.1})", .{ if (i > 0) " + " else "", d.services[rd.svc].no, d.stops[raptor.stopAt(d, rd.svc, rd.dir, rd.from)].code, d.stops[raptor.stopAt(d, rd.svc, rd.dir, rd.to)].code, rd.to - rd.from, o.waits[i], if (o.live[i]) " live" else "", o.ride_min[i] });
        }
        if (o.tags.fastest) std.debug.print("  [fastest]", .{});
        if (o.tags.fewest) std.debug.print("  [fewest changes]", .{});
        if (o.tags.least_walk) std.debug.print("  [least walking]", .{});
        std.debug.print("\n", .{});
    }
}

test "three real trips, by the model alone (10:00 on a weekday)" {
    const gpa = std.testing.allocator;
    const d = try data.Data.load(gpa);
    defer d.deinit(gpa);
    var out: [4]raptor.Option = undefined;
    for (trips) |t| {
        const got = try raptor.plan(d, gpa, t.from, t.to, .{ .clock = 10 * 3600 }, &out);
        show(d, t, got);
        try std.testing.expect(got.len > 0);
        var tags: u8 = 0;
        for (got) |o| {
            tags |= @bitCast(o.tags);
            try std.testing.expect(o.arrive > 5 and o.arrive < 240);
            // Pareto: no way is beaten on all three by another.
            for (got) |p| try std.testing.expect(!(p.arrive < o.arrive - 1 and p.n < o.n and p.walk_m < o.walk_m - 50));
        }
        try std.testing.expectEqual(@as(u8, 7), tags);
    }
}

/// Live boards made up for the test: every service at every stop has a
/// bus in `first` minutes and then each `gap`, except `gone`.
const Fake = struct {
    first: f64,
    gap: f64,
    gone: ?u16 = null,

    fn look(ctx: ?*const anyopaque, stop: u16, svc: u16) raptor.Look {
        _ = stop;
        const f: *const Fake = @ptrCast(@alignCast(ctx.?));
        if (f.gone == svc) return .absent;
        return .{ .seen = .{ f.first, f.first + f.gap, f.first + 2 * f.gap } };
    }
};

test "live waits are used, and a service not on the board is not boarded" {
    const gpa = std.testing.allocator;
    const d = try data.Data.load(gpa);
    defer d.deinit(gpa);
    var out: [4]raptor.Option = undefined;
    const t = trips[0];
    var fake: Fake = .{ .first = 20, .gap = 12 };
    const late = try raptor.plan(d, gpa, t.from, t.to, .{ .ctx = &fake, .look = Fake.look }, &out);
    try std.testing.expect(late.len > 0);
    try std.testing.expect(late[0].live[0]);
    // The first bus is 20 minutes out: no way gets there before it.
    for (late) |o| try std.testing.expect(o.arrive > 20);
    const first = late[0].rides[0].svc;
    fake = .{ .first = 2, .gap = 8, .gone = first };
    const without = try raptor.plan(d, gpa, t.from, t.to, .{ .ctx = &fake, .look = Fake.look }, &out);
    for (without) |o| for (0..o.n) |i| try std.testing.expect(o.rides[i].svc != first);
}

test "pace: buses slower than the model slow the rides" {
    const gpa = std.testing.allocator;
    const d = try data.Data.load(gpa);
    defer d.deinit(gpa);
    // A 14 two stretches back of its stop, taking twice the model's time.
    const svc = d.service("14").?;
    const v = d.visits[d.find("83139") orelse return error.SkipZigTest][0];
    _ = svc;
    const st = d.services[v.svc].dirs[v.dir];
    if (v.pos < 4) return error.SkipZigTest;
    var model: f64 = 0;
    for (v.pos - 4..v.pos) |k| model += raptor.segMin(d, v.svc, v.dir, k);
    const obs = [_]raptor.Obs{.{ .stop = st[v.pos], .svc = v.svc, .eta = 2 * model, .at = d.stops[st[v.pos - 4]].at }};
    var pace = try raptor.Pace.init(gpa, d, &obs);
    defer pace.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), pace.samples);
    try std.testing.expectApproxEqAbs(@as(f32, 2), pace.by_svc[v.svc], 0.01);
}
