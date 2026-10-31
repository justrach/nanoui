//! A bus-only journey planner over the bundled stop lists, for when
//! OneMap's routing can't be asked (no key, offline, rate limited): walk
//! to a stop, one bus or two with a walk between, walk to the place.
//! The data has stops in order but no timetable, so a ride's time is an
//! estimate: its length at 20 km/h plus 24 seconds a stop. Waits come from
//! live arrivals when the view has them (journey.zig).
const std = @import("std");
const nanoui = @import("nanoui");
const data = @import("data.zig");
const Coord = nanoui.map.Coord;

pub const Ride = struct { svc: u16, dir: u8, from: u16, to: u16 };

pub const Trip = struct {
    /// Walks before, between and after the rides, meters (`walks[i]`
    /// before `rides[i]`, the last one after the last ride).
    walks: [3]f64 = .{ 0, 0, 0 },
    rides: [2]Ride = undefined,
    n: u8 = 0,
    /// Minutes, with a guessed wait for each bus: for ranking only.
    guess: f64 = 0,
};

pub const walk_radius = 450;
const transfer_radius = 250;
const guess_wait = 6;
const transfer_cost = 4;

pub fn walkMin(m: f64) f64 {
    return m * 1.3 / 80;
}

/// Ride minutes from position `a` to `b` along a direction's stops.
pub fn rideMin(d: *const data.Data, r: Ride) f64 {
    const stops = d.services[r.svc].dirs[r.dir];
    var m: f64 = 0;
    var i = r.from;
    while (i < r.to) : (i += 1) m += data.meters(d.stops[stops[i]].at, d.stops[stops[i + 1]].at);
    return m / 333 + 0.4 * @as(f64, @floatFromInt(r.to - r.from));
}

/// The stop a ride's position stands at.
pub fn stopAt(d: *const data.Data, svc: u16, dir: u8, pos: u16) u16 {
    return d.services[svc].dirs[dir][pos];
}

/// The best `out.len` trips from `from` to `to`, best first.
pub fn plan(d: *const data.Data, gpa: std.mem.Allocator, from: Coord, to: Coord, out: []Trip) ![]Trip {
    var sbuf: [64]data.Near = undefined;
    var ebuf: [64]data.Near = undefined;
    var xbuf: [48]data.Near = undefined;
    var starts = d.near(from, walk_radius, &sbuf);
    std.mem.sort(data.Near, starts, {}, nearer);
    starts = starts[0..@min(starts.len, 12)];
    const ends = try gpa.alloc(f32, d.stops.len);
    defer gpa.free(ends);
    @memset(ends, -1);
    for (d.near(to, walk_radius, &ebuf)) |e| ends[e.stop] = @floatCast(e.m);
    var all: std.ArrayList(Trip) = .empty;
    defer all.deinit(gpa);
    for (starts) |s| for (d.visits[s.stop]) |v| {
        const stops = d.services[v.svc].dirs[v.dir];
        var j = v.pos + 1;
        while (j < stops.len) : (j += 1) {
            const a = stops[j];
            const first: Ride = .{ .svc = v.svc, .dir = v.dir, .from = v.pos, .to = j };
            if (endOf(ends, a)) |em| {
                const t = walkMin(s.m) + guess_wait + rideMin(d, first) + walkMin(em);
                try all.append(gpa, .{ .walks = .{ s.m, em, 0 }, .rides = .{ first, undefined }, .n = 1, .guess = t });
            }
            if (j - v.pos > 45) continue;
            // A second bus, from a stop near where this one is left.
            for (d.near(d.stops[a].at, transfer_radius, &xbuf)) |x| for (d.visits[x.stop]) |w| {
                if (w.svc == v.svc or same(d, w.svc, v.svc)) continue;
                const st2 = d.services[w.svc].dirs[w.dir];
                var l = w.pos + 1;
                while (l < st2.len and l < w.pos + 60) : (l += 1) if (endOf(ends, st2[l])) |em| {
                    const second: Ride = .{ .svc = w.svc, .dir = w.dir, .from = w.pos, .to = l };
                    const t = walkMin(s.m) + guess_wait + rideMin(d, first) + walkMin(x.m) + guess_wait + transfer_cost + rideMin(d, second) + walkMin(em);
                    try all.append(gpa, .{ .walks = .{ s.m, x.m, em }, .rides = .{ first, second }, .n = 2, .guess = t });
                    break;
                };
            };
        }
    };
    std.mem.sort(Trip, all.items, {}, struct {
        fn lt(_: void, a: Trip, b: Trip) bool {
            return a.guess < b.guess;
        }
    }.lt);
    // One trip per pair of services (the 15 and the 15 a stop on are one).
    var n: usize = 0;
    outer: for (all.items) |t| {
        if (n == out.len) break;
        for (out[0..n]) |o| if (o.n == t.n and samePlan(d, o, t)) continue :outer;
        // Two buses that one would do: drop.
        if (t.n == 2) for (out[0..n]) |o| if (o.n == 1 and same(d, o.rides[0].svc, t.rides[0].svc)) continue :outer;
        out[n] = t;
        n += 1;
    }
    return out[0..n];
}

fn samePlan(d: *const data.Data, a: Trip, b: Trip) bool {
    for (0..a.n) |i| if (!same(d, a.rides[i].svc, b.rides[i].svc)) return false;
    return true;
}

/// The same service, or its variant ("14" and "14e").
fn same(d: *const data.Data, a: u16, b: u16) bool {
    return std.mem.eql(u8, base(d.services[a].no), base(d.services[b].no));
}

fn base(no: []const u8) []const u8 {
    var n = no.len;
    while (n > 0 and std.ascii.isAlphabetic(no[n - 1])) n -= 1;
    return no[0..n];
}

fn endOf(ends: []const f32, stop: u16) ?f64 {
    return if (ends[stop] >= 0) ends[stop] else null;
}

fn nearer(_: void, a: data.Near, b: data.Near) bool {
    return a.m < b.m;
}
