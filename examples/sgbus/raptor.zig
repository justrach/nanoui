//! The journey planner on the phone: RAPTOR (Delling, Pajor and Werneck,
//! "Round-Based Public Transit Routing", 2012) over the bundled stop
//! lists. Round k finds the earliest arrival at every stop with k rides;
//! between rounds you may walk up to 300 m to another stop. Without a
//! timetable, a bus is boarded at its expected time: the live arrivals
//! at that stop when the app has them (LTA through arrivelah), else half
//! a typical headway. Ride times are modelled per stretch (its length at
//! a road speed for that length, plus a stop's dwell), scaled by how fast
//! the buses really are moving now: each live bus's position and its time
//! to the stop say how long the stretch behind it takes today.
//! The answers are the Pareto set over arrival, changes and walking, with
//! the fastest, the fewest changes and the least walking always kept, and
//! ranked by arrival plus a penalty for each change and each minute on foot.
//! Fares are LTA's distance fares (adult card, from 27 December 2025).
//! Trains (rail.zig) are services too: their stretches are timed from
//! track length, speed and dwell, their waits are half the headway, and
//! you reach a station by walking to its nearest exit, up to 800 m.
const std = @import("std");
const data = @import("data.zig");
pub const rail = @import("rail.zig");
const Coord = @import("nanoui").map.Coord;

pub const walk_radius = 450;
pub const transfer_radius = 300;
pub const rail_radius = 800;
/// Bus, train, train, bus is four.
pub const rounds = 4;
const dwell_min = 0.33;

pub const Ride = struct { svc: u16, dir: u8, from: u16, to: u16 };

pub const Tags = packed struct(u8) { fastest: bool = false, fewest: bool = false, least_walk: bool = false, _: u5 = 0 };

pub const Option = struct {
    /// Walks before, between and after the rides, meters (`walks[i]`
    /// before `rides[i]`, `walks[n]` after the last).
    walks: [rounds + 1]f64 = @splat(0),
    rides: [rounds]Ride = undefined,
    n: u8 = 0,
    /// Minutes waiting for each bus, and whether that came from a live bus.
    waits: [rounds]f64 = @splat(0),
    live: [rounds]bool = @splat(false),
    ride_min: [rounds]f64 = @splat(0),
    /// Minutes from now to the door.
    arrive: f64 = 0,
    walk_m: f64 = 0,
    km: f64 = 0,
    /// Adult card fare, cents; null where it isn't a distance fare (City Direct).
    fare: ?u16 = null,
    score: f64 = 0,
    tags: Tags = .{},
};

/// What the app knows of a service at a stop right now.
pub const Look = union(enum) {
    /// No live board for the stop.
    unknown,
    /// The stop's board is in and the service isn't on it: not running now.
    absent,
    /// Minutes from now to its next buses (null: no more listed).
    seen: [3]?f64,
};

/// A live bus: on its way to `stop`, `eta` minutes out, now at `at`.
pub const Obs = struct { stop: u16, svc: u16, eta: f64, at: Coord };

pub const Now = struct {
    ctx: ?*const anyopaque = null,
    look: ?*const fn (?*const anyopaque, u16, u16) Look = null,
    obs: []const Obs = &.{},
    /// Seconds since midnight, and whether it's a weekday: for peak-only services.
    clock: ?f64 = null,
    weekday: bool = true,
    /// False plans with buses only.
    trains: bool = true,

    fn of(n: Now, stop: u16, svc: u16) Look {
        const f = n.look orelse return .unknown;
        return f(n.ctx, stop, svc);
    }
};

pub fn walkMin(m: f64) f64 {
    // Straight-line meters, 1.3 for the streets' detours, at 80 m a minute.
    return m * 1.3 / 80;
}

/// Modelled minutes from position `p` to `p + 1` of a direction.
pub fn segMin(d: *const data.Data, svc: u16, dir: u8, p: usize) f64 {
    if (d.services[svc].rail) |l| return rail.hopMin(l, l.km[dir][p]);
    const st = d.services[svc].dirs[dir];
    const m = data.meters(d.stops[st[p]].at, d.stops[st[p + 1]].at);
    // Short stretches are town roads; long ones are arterials or expressways.
    const kmh: f64 = if (m < 450) 18 else if (m < 1200) 24 else if (m < 2500) 32 else 45;
    return m / 1000 / kmh * 60 + dwell_min;
}

pub fn stopAt(d: *const data.Data, svc: u16, dir: u8, pos: u16) u16 {
    return d.services[svc].dirs[dir][pos];
}

/// Express (5xx, or an "e" suffix): $1 over the basic fare.
pub fn express(no: []const u8) bool {
    if (no.len > 0 and (no[no.len - 1] == 'e' or no[no.len - 1] == 'E')) return true;
    const n = std.fmt.parseInt(u16, no, 10) catch return false;
    return n >= 500 and n < 600;
}

/// City Direct (6xx in this data: 646 to 684): its own fares, rush hours only.
pub fn cityDirect(no: []const u8) bool {
    const n = std.fmt.parseInt(u16, no, 10) catch return false;
    return n >= 600 and n < 700;
}

fn peakOnly(no: []const u8) bool {
    return cityDirect(no) or (no.len > 1 and no[no.len - 1] == 'e');
}

pub fn isPeak(now: Now) bool {
    const t = now.clock orelse return true;
    const h = t / 3600;
    return now.weekday and ((h >= 6.5 and h < 9.5) or (h >= 17 and h < 20));
}

const basic = [_]u16{ 128, 138, 149, 159, 168, 175, 182, 186, 190, 194, 198, 202, 207, 211, 215, 220, 224, 227, 230, 233, 236, 238, 240, 242, 243, 244, 245, 246, 247, 248, 249, 250, 251, 252, 253, 254, 255, 256, 257 };

/// Tapping in for a train before 7:45am on a weekday: 50 cents off (LTA).
pub const early_rail_off = 50;

/// LTA's adult card fare for a journey of `km` (bus and train, all rides
/// together), cents: up to 3.2 km, then a step each 1 km to over 40.2.
pub fn fareCents(km: f64, is_express: bool) u16 {
    const tenths: u32 = @intFromFloat(@ceil(km * 10 - 1e-6));
    const i: usize = if (tenths <= 32) 0 else @min((tenths - 33) / 10 + 1, basic.len - 1);
    return basic[i] + @as(u16, if (is_express) 100 else 0);
}

pub const Wait = struct { w: f64, live: bool };

pub const waitPublic = waitFor;

/// Minutes from `ready` to the next bus of `svc` at `stop`; null if it isn't running.
fn waitFor(d: *const data.Data, now: Now, stop: u16, svc: u16, ready: f64) ?Wait {
    if (d.services[svc].rail) |l| {
        if (!now.trains) return null;
        if (now.clock) |c| if (!rail.open(@mod(c / 60 + ready, 24 * 60))) return null;
        return .{ .w = rail.headway(l, isPeak(now)) / 2, .live = false };
    }
    const no = d.services[svc].no;
    switch (now.of(stop, svc)) {
        .absent => return null,
        .seen => |etas| {
            var last: ?f64 = null;
            var first: ?f64 = null;
            var count: f64 = 0;
            for (etas) |e| if (e) |m| {
                if (m >= ready - 0.01) return .{ .w = @max(m - ready, 0), .live = true };
                if (first == null) first = m;
                last = m;
                count += 1;
            };
            // Every listed bus comes before you: the next at their spacing.
            const h: f64 = if (count >= 2) @max((last.? - first.?) / (count - 1), 2) else 10;
            const l = last orelse ready;
            return .{ .w = @max(l + h * @ceil((ready - l) / h) - ready, 0), .live = false };
        },
        .unknown => {
            if (peakOnly(no) and !isPeak(now)) return null;
            return .{ .w = if (isPeak(now)) 3.5 else 5, .live = false };
        },
    }
}

/// How much slower (above 1) or faster than the model each service runs
/// now, from the live buses' positions and times; `all` for the rest.
pub const Pace = struct {
    by_svc: []f32,
    all: f32 = 1,
    samples: usize = 0,

    pub fn init(gpa: std.mem.Allocator, d: *const data.Data, obs: []const Obs) !Pace {
        const by = try gpa.alloc(f32, d.services.len);
        @memset(by, 0);
        var p: Pace = .{ .by_svc = by };
        var all: std.ArrayList(f32) = .empty;
        defer all.deinit(gpa);
        var sums = try gpa.alloc([2]f32, d.services.len);
        defer gpa.free(sums);
        @memset(sums, .{ 0, 0 });
        for (obs) |o| for (d.visits[o.stop]) |v| if (v.svc == o.svc) {
            const r = sample(d, v, o) orelse continue;
            try all.append(gpa, r);
            sums[o.svc][0] += r;
            sums[o.svc][1] += 1;
        };
        p.samples = all.items.len;
        if (all.items.len > 0) {
            std.mem.sort(f32, all.items, {}, std.sort.asc(f32));
            p.all = all.items[all.items.len / 2];
        }
        for (sums, 0..) |s, i| by[i] = if (d.services[i].rail != null) 1 else if (s[1] > 0) std.math.clamp(s[0] / s[1], 0.6, 2.0) else p.all;
        return p;
    }

    pub fn deinit(p: *Pace, gpa: std.mem.Allocator) void {
        gpa.free(p.by_svc);
    }

    /// Observed over modelled minutes for the stretch from the stop nearest
    /// the bus to the stop it's due at.
    fn sample(d: *const data.Data, v: data.Visit, o: Obs) ?f32 {
        if (o.eta < 0.5 or (o.at.lat == 0 and o.at.lng == 0)) return null;
        const st = d.services[v.svc].dirs[v.dir];
        var best: f64 = 300;
        var q: ?usize = null;
        var i: usize = if (v.pos > 30) v.pos - 30 else 0;
        while (i < v.pos) : (i += 1) {
            const m = data.meters(d.stops[st[i]].at, o.at);
            if (m < best) {
                best = m;
                q = i;
            }
        }
        const from = q orelse return null;
        var model: f64 = 0;
        for (from..v.pos) |k| model += segMin(d, v.svc, v.dir, k);
        if (model < 1.5) return null;
        return @floatCast(std.math.clamp(o.eta / model, 0.4, 3.0));
    }
};

pub const plan = @import("raptor_plan.zig").plan;
