//! Trains in the planner: the eval trips (journey/eval.md), planned at
//! 10:00 on a weekday with no live data, bus only and with trains.
//! Each prints its ways; the checks are the ones a rider would make.
const std = @import("std");
const data = @import("data.zig");
const raptor = @import("raptor.zig");
const Coord = @import("nanoui").map.Coord;

pub const Trip = @import("tests.zig").Trip;

fn c(lat: f64, lng: f64) Coord {
    return .{ .lat = lat, .lng = lng };
}

pub const trips = [_]Trip{
    .{ .name = "Tampines MRT to Jurong East MRT", .from = c(1.35330, 103.94520), .to = c(1.33320, 103.74220) },
    .{ .name = "Woodlands MRT to Raffles Place MRT", .from = c(1.43700, 103.78650), .to = c(1.28400, 103.85150) },
    .{ .name = "Joo Chiat Pl to Suntec City", .from = c(1.31451, 103.90998), .to = c(1.29504, 103.85846) },
    .{ .name = "Ang Mo Kio MRT to Orchard MRT", .from = c(1.37000, 103.84960), .to = c(1.30430, 103.83200) },
    .{ .name = "Changi Airport MRT to Marina Bay Sands", .from = c(1.35740, 103.98840), .to = c(1.28340, 103.86070) },
    .{ .name = "Punggol MRT to Paya Lebar MRT", .from = c(1.40520, 103.90240), .to = c(1.31770, 103.89260) },
    .{ .name = "Bedok MRT to Changi Airport T3", .from = c(1.32400, 103.93000), .to = c(1.35550, 103.98640) },
    .{ .name = "Bishan MRT to Serangoon MRT", .from = c(1.35100, 103.84850), .to = c(1.34970, 103.87320) },
    .{ .name = "Clementi MRT to NUS Central Library", .from = c(1.31510, 103.76520), .to = c(1.29660, 103.77230) },
    .{ .name = "Jurong East MRT to Jurong Point", .from = c(1.33320, 103.74220), .to = c(1.33970, 103.70660) },
    .{ .name = "Bukit Panjang MRT to Bugis MRT", .from = c(1.37840, 103.76190), .to = c(1.30090, 103.85590) },
    .{ .name = "Sengkang MRT to Hougang MRT", .from = c(1.39160, 103.89540), .to = c(1.37120, 103.89250) },
    .{ .name = "Yishun MRT to Sembawang MRT", .from = c(1.42940, 103.83500), .to = c(1.44910, 103.82010) },
    .{ .name = "Holland Village MRT to Dhoby Ghaut MRT", .from = c(1.31120, 103.79610), .to = c(1.29900, 103.84550) },
    .{ .name = "Pasir Ris MRT to Changi Village", .from = c(1.37300, 103.94930), .to = c(1.38930, 103.98770) },
    .{ .name = "Toa Payoh MRT to Novena MRT", .from = c(1.33270, 103.84740), .to = c(1.32040, 103.84380) },
};

fn hasTrain(d: *const data.Data, o: raptor.Option) bool {
    for (0..o.n) |i| if (d.services[o.rides[i].svc].rail != null) return true;
    return false;
}

fn fastest(got: []const raptor.Option) raptor.Option {
    var b = got[0];
    for (got) |o| if (o.arrive < b.arrive) {
        b = o;
    };
    return b;
}

/// One line for journey/eval.py: trip, mode, door to door, on board (first
/// boarding to last alighting, changes included, waits not), the stations
/// if it is trains only, fare, km.
fn evalLine(d: *const data.Data, i: usize, mode: []const u8, o: raptor.Option) void {
    var board: f64 = 0;
    var all_rail = true;
    for (0..o.n) |k| {
        board += o.ride_min[k];
        if (k > 0) board += if (d.services[o.rides[k].svc].rail != null and d.services[o.rides[k - 1].svc].rail != null and o.walks[k] == 0) raptor.rail.interchange_min else raptor.walkMin(o.walks[k]);
        all_rail = all_rail and d.services[o.rides[k].svc].rail != null;
    }
    const a = o.rides[0];
    const z = o.rides[o.n - 1];
    std.debug.print("EVAL|{d}|{s}|{d:.1}|{d:.1}|{s}|{s}|{d}|{d:.1}|", .{ i + 1, mode, o.arrive, board, if (all_rail) d.stops[raptor.stopAt(d, a.svc, a.dir, a.from)].name else "-", if (all_rail) d.stops[raptor.stopAt(d, z.svc, z.dir, z.to)].name else "-", o.fare orelse 0, o.km });
    for (0..o.n) |k| std.debug.print("{s}{s}", .{ if (k > 0) "+" else "", d.services[o.rides[k].svc].no });
    std.debug.print("\n", .{});
}

test "eval trips: bus only and with trains" {
    const gpa = std.testing.allocator;
    const d = try data.Data.load(gpa);
    defer d.deinit(gpa);
    var out: [5]raptor.Option = undefined;
    var bus_out: [5]raptor.Option = undefined;
    for (trips, 0..) |t, i| {
        const bus = try raptor.plan(d, gpa, t.from, t.to, .{ .clock = 10 * 3600, .trains = false }, &bus_out);
        const got = try raptor.plan(d, gpa, t.from, t.to, .{ .clock = 10 * 3600 }, &out);
        std.debug.print("\n#{d} bus only:", .{i + 1});
        @import("tests.zig").show(d, t, bus);
        std.debug.print("#{d} with trains:", .{i + 1});
        @import("tests.zig").show(d, t, got);
        try std.testing.expect(got.len > 0 and bus.len > 0);
        evalLine(d, i, "bus", fastest(bus));
        evalLine(d, i, "any", fastest(got));
        for (bus) |o| try std.testing.expect(!hasTrain(d, o));
        // Trains can only help.
        try std.testing.expect(fastest(got).arrive <= fastest(bus).arrive + 0.01);
    }
}

test "trains win the long cross-island trips, buses the short awkward ones" {
    const gpa = std.testing.allocator;
    const d = try data.Data.load(gpa);
    defer d.deinit(gpa);
    var out: [5]raptor.Option = undefined;
    const want_train = [_]usize{ 0, 1, 3, 4, 10 };
    for (want_train) |i| {
        const got = try raptor.plan(d, gpa, trips[i].from, trips[i].to, .{ .clock = 10 * 3600 }, &out);
        try std.testing.expect(hasTrain(d, fastest(got)));
    }
    // Clementi to NUS, Pasir Ris to Changi Village: no line goes there.
    for ([_]usize{ 8, 14 }) |i| {
        const got = try raptor.plan(d, gpa, trips[i].from, trips[i].to, .{ .clock = 10 * 3600 }, &out);
        try std.testing.expect(!hasTrain(d, fastest(got)));
    }
}

test "rail fares: one distance fare for bus and train, 50 cents off before 7:45" {
    const gpa = std.testing.allocator;
    const d = try data.Data.load(gpa);
    defer d.deinit(gpa);
    var out: [5]raptor.Option = undefined;
    const t = trips[0];
    const day = try raptor.plan(d, gpa, t.from, t.to, .{ .clock = 10 * 3600 }, &out);
    const f = fastest(day);
    try std.testing.expectEqual(raptor.fareCents(f.km, false), f.fare.?);
    const early = try raptor.plan(d, gpa, t.from, t.to, .{ .clock = 6 * 3600 + 30 * 60 }, &out);
    const e = fastest(early);
    try std.testing.expect(hasTrain(d, e) and e.n == 1);
    try std.testing.expectEqual(raptor.fareCents(e.km, false) - raptor.early_rail_off, e.fare.?);
    // No trains at 1am.
    const night = try raptor.plan(d, gpa, t.from, t.to, .{ .clock = 1 * 3600 }, &out);
    for (night) |o| try std.testing.expect(!hasTrain(d, o));
}

test "a train fare counts the shortest track, as SimplyGo's eGuide does" {
    const gpa = std.testing.allocator;
    const d = try data.Data.load(gpa);
    defer d.deinit(gpa);
    var out: [5]raptor.Option = undefined;
    // Tampines to Jurong East: we ride the EWL (32 km) but the fare is
    // by 29.5 km over the DTL and CCL; SimplyGo charges $2.46.
    const day = try raptor.plan(d, gpa, trips[0].from, trips[0].to, .{ .clock = 10 * 3600 }, &out);
    try std.testing.expectEqual(@as(u16, 246), fastest(day).fare.?);
    var a: ?u16 = null;
    var b: ?u16 = null;
    for (d.n_bus..d.stops.len) |i| {
        if (std.mem.eql(u8, d.stops[i].name, "Bishan")) a = @intCast(i);
        if (std.mem.eql(u8, d.stops[i].name, "Serangoon")) b = @intCast(i);
    }
    const km = raptor.rail.shortestKm(d, a.?, b.?);
    try std.testing.expect(km > 2 and km < 4);
    try std.testing.expectApproxEqAbs(km, raptor.rail.shortestKm(d, b.?, a.?), 0.01);
}
