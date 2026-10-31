//! RAPTOR's rounds, and the Pareto choice of what to show (raptor.zig).
const std = @import("std");
const data = @import("data.zig");
const r = @import("raptor.zig");
const Coord = @import("nanoui").map.Coord;

const inf = std.math.inf(f64);

const Label = struct {
    t: f64 = inf,
    /// Meters walked so far.
    walk: f64 = 0,
    kind: enum(u2) { none, origin, ride, foot } = .none,
    /// Ride: the service, its direction and positions; foot: `prev` is the stop walked from.
    svc: u16 = 0,
    dir: u8 = 0,
    from: u16 = 0,
    to: u16 = 0,
    prev: u16 = 0,
    /// The walk this label adds (origin, foot), meters.
    m: f64 = 0,
    wait: f64 = 0,
    live: bool = false,
    ride: f64 = 0,
};

/// Up to `out.len` ways from `from` to `to`, best first.
pub fn plan(d: *const data.Data, gpa: std.mem.Allocator, from: Coord, to: Coord, now: r.Now, out: []r.Option) ![]r.Option {
    const n = d.stops.len;
    var pace = try r.Pace.init(gpa, d, now.obs);
    defer pace.deinit(gpa);
    var labels: [r.rounds + 1][]Label = undefined;
    for (&labels) |*l| {
        l.* = try gpa.alloc(Label, n);
        @memset(l.*, .{});
    }
    defer for (labels) |l| gpa.free(l);
    const marked = try gpa.alloc(bool, n);
    defer gpa.free(marked);
    @memset(marked, false);
    const ndirs = d.services.len * 4;
    const earliest = try gpa.alloc(u16, ndirs);
    defer gpa.free(earliest);
    var improved: std.ArrayList(u16) = .empty;
    defer improved.deinit(gpa);

    var buf: [128]data.Near = undefined;
    for (d.near(from, r.walk_radius, &buf)) |s| {
        labels[0][s.stop] = .{ .t = r.walkMin(s.m), .walk = s.m, .m = s.m, .kind = .origin };
        marked[s.stop] = true;
    }
    var k: usize = 1;
    while (k <= r.rounds) : (k += 1) {
        const prev = labels[k - 1];
        const cur = labels[k];
        @memset(earliest, std.math.maxInt(u16));
        for (marked, 0..) |m, s| if (m) for (d.visits[s]) |v| {
            const key = @as(usize, v.svc) * 4 + @min(v.dir, 3);
            earliest[key] = @min(earliest[key], v.pos);
        };
        @memset(marked, false);
        improved.clearRetainingCapacity();
        for (earliest, 0..) |e, key| if (e != std.math.maxInt(u16)) {
            const svc: u16 = @intCast(key / 4);
            const dir: u8 = @intCast(key % 4);
            if (dir >= d.services[svc].dirs.len) continue;
            const st = d.services[svc].dirs[dir];
            const pace_f: f64 = pace.by_svc[svc];
            var on = false;
            var t: f64 = 0;
            var board_t: f64 = 0;
            var bp: u16 = 0;
            var w: f64 = 0;
            var lv = false;
            var walked: f64 = 0;
            var p: usize = e;
            while (p < st.len) : (p += 1) {
                const s = st[p];
                if (on and p > bp) {
                    t += r.segMin(d, svc, dir, p - 1) * pace_f;
                    if (t < cur[s].t) {
                        cur[s] = .{ .t = t, .walk = walked, .kind = .ride, .svc = svc, .dir = dir, .from = bp, .to = @intCast(p), .prev = st[bp], .wait = w, .live = lv, .ride = t - board_t };
                        if (!marked[s]) try improved.append(gpa, s);
                        marked[s] = true;
                    }
                }
                const l = prev[s];
                if (l.kind == .none or (l.kind == .ride and same(d, l.svc, svc))) continue;
                const ready = l.t + (if (k > 1) transfer_slack else 0);
                const got = r.waitPublic(d, now, s, svc, ready) orelse continue;
                const dep = ready + got.w;
                if (!on or dep < t - 0.01) {
                    on = true;
                    t = dep;
                    board_t = dep;
                    bp = @intCast(p);
                    w = got.w;
                    lv = got.live;
                    walked = l.walk;
                }
            }
        };
        // Walks of up to 300 m to another stop (the other side of the road, round the corner).
        const rode = try gpa.dupe(u16, improved.items);
        defer gpa.free(rode);
        for (rode) |s| {
            const l = cur[s];
            if (l.kind != .ride) continue;
            for (d.near(d.stops[s].at, r.transfer_radius, &buf)) |x| {
                if (x.stop == s) continue;
                const t = l.t + r.walkMin(x.m);
                if (t < cur[x.stop].t) {
                    cur[x.stop] = .{ .t = t, .walk = l.walk + x.m, .m = x.m, .kind = .foot, .prev = s };
                    marked[x.stop] = true;
                }
            }
        }
    }
    return choose(d, gpa, labels, to, out);
}

/// Minutes between getting off and the next bus being catchable.
const transfer_slack: f64 = 1.0;
/// Ranking only: a change counts as this many minutes, a minute on foot as 1.5.
const change_penalty: f64 = 5.0;
const walk_penalty: f64 = 0.5;

/// Every way to a stop near `to`, then the Pareto set, tagged and ranked.
fn choose(d: *const data.Data, gpa: std.mem.Allocator, labels: [r.rounds + 1][]Label, to: Coord, out: []r.Option) ![]r.Option {
    var buf: [128]data.Near = undefined;
    var all: std.ArrayList(r.Option) = .empty;
    defer all.deinit(gpa);
    for (d.near(to, r.walk_radius, &buf)) |e| for (1..r.rounds + 1) |k| {
        if (labels[k][e.stop].kind == .none) continue;
        var o = trace(d, labels, k, e.stop) orelse continue;
        o.walks[o.n] = e.m;
        o.walk_m += e.m;
        o.arrive += r.walkMin(e.m);
        o.score = o.arrive + change_penalty * @as(f64, @floatFromInt(o.n - 1)) + walk_penalty * r.walkMin(o.walk_m);
        // The same services by another stop: keep the better.
        var dup = false;
        for (all.items) |*a| if (samePlan(d, a.*, o)) {
            dup = true;
            if (o.score < a.score) a.* = o;
        };
        if (!dup) try all.append(gpa, o);
    };
    // Pareto: drop a way another beats or ties on arrival, changes and walking.
    var front: std.ArrayList(r.Option) = .empty;
    defer front.deinit(gpa);
    for (all.items, 0..) |a, i| {
        var beaten = false;
        for (all.items, 0..) |b, j| if (i != j and b.arrive <= a.arrive + 0.5 and b.n <= a.n and b.walk_m <= a.walk_m + 20 and
            (b.arrive < a.arrive - 0.5 or b.n < a.n or b.walk_m < a.walk_m - 20 or (j < i and b.score <= a.score)))
        {
            beaten = true;
            break;
        };
        if (!beaten) try front.append(gpa, a);
    }
    const f = front.items;
    if (f.len == 0) return out[0..0];
    var fast: usize = 0;
    var fewest: usize = 0;
    var least: usize = 0;
    for (f, 0..) |o, i| {
        if (o.arrive < f[fast].arrive) fast = i;
        if (o.n < f[fewest].n or (o.n == f[fewest].n and o.arrive < f[fewest].arrive)) fewest = i;
    }
    // Least walking, among ways not much slower than the fastest.
    for (f, 0..) |o, i| if (o.arrive <= f[fast].arrive + 20) {
        if (o.walk_m < f[least].walk_m - 1 or f[least].arrive > f[fast].arrive + 20) least = i;
    };
    f[fast].tags.fastest = true;
    f[fewest].tags.fewest = true;
    f[least].tags.least_walk = true;
    std.mem.sort(r.Option, f, {}, struct {
        fn lt(_: void, a: r.Option, b: r.Option) bool {
            const ta = @as(u8, @bitCast(a.tags)) != 0;
            const tb = @as(u8, @bitCast(b.tags)) != 0;
            if (ta != tb) return ta;
            return a.score < b.score;
        }
    }.lt);
    const m = @min(f.len, out.len);
    @memcpy(out[0..m], f[0..m]);
    std.mem.sort(r.Option, out[0..m], {}, struct {
        fn lt(_: void, a: r.Option, b: r.Option) bool {
            return a.score < b.score;
        }
    }.lt);
    return out[0..m];
}

/// The way that ends with label `k`, `stop`, followed back to the start.
fn trace(d: *const data.Data, labels: [r.rounds + 1][]Label, k0: usize, stop: u16) ?r.Option {
    var o: r.Option = .{};
    var rides: [r.rounds]Label = undefined;
    var walks: [r.rounds + 1]f64 = @splat(0);
    var n: usize = 0;
    var k = k0;
    var s = stop;
    const end = labels[k0][stop];
    var guard: usize = 0;
    while (guard < 16) : (guard += 1) {
        const l = labels[k][s];
        switch (l.kind) {
            .none => return null,
            .origin => {
                walks[n] = l.m;
                break;
            },
            .foot => {
                walks[n] += l.m;
                s = l.prev;
            },
            .ride => {
                if (n == r.rounds) return null;
                rides[n] = l;
                n += 1;
                s = l.prev;
                k -= 1;
            },
        }
    } else return null;
    if (n == 0) return null;
    // Back to front: rides[n-1] is the first bus.
    o.n = @intCast(n);
    o.walks[0] = walks[n];
    var any_express = false;
    var direct = false;
    for (0..n) |i| {
        const l = rides[n - 1 - i];
        o.rides[i] = .{ .svc = l.svc, .dir = l.dir, .from = l.from, .to = l.to };
        o.waits[i] = l.wait;
        o.live[i] = l.live;
        o.ride_min[i] = l.ride;
        if (i > 0) o.walks[i] = walks[n - i];
        const no = d.services[l.svc].no;
        any_express = any_express or r.express(no);
        direct = direct or r.cityDirect(no);
        const st = d.services[l.svc].dirs[l.dir];
        for (l.from..l.to) |p| o.km += data.meters(d.stops[st[p]].at, d.stops[st[p + 1]].at) / 1000;
    }
    o.arrive = end.t;
    o.walk_m = end.walk;
    o.fare = if (direct) null else r.fareCents(o.km, any_express);
    return o;
}

fn samePlan(d: *const data.Data, a: r.Option, b: r.Option) bool {
    if (a.n != b.n) return false;
    for (0..a.n) |i| if (!same(d, a.rides[i].svc, b.rides[i].svc)) return false;
    return true;
}

/// The same service, or its variant ("14" and "14e").
pub fn same(d: *const data.Data, a: u16, b: u16) bool {
    return std.mem.eql(u8, base(d.services[a].no), base(d.services[b].no));
}

fn base(no: []const u8) []const u8 {
    var n = no.len;
    while (n > 0 and std.ascii.isAlphabetic(no[n - 1])) n -= 1;
    return no[0..n];
}
