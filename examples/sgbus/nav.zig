//! Turn by turn, after Go: our planner's trip (raptor.zig) for the bus and
//! train legs, and Apple Maps' walking directions (nanoui.directions) for
//! every walk: to the first stop, between stops or stations, and from the
//! last one to the door. One card says what to do now, with how far to
//! go; the next step waits under it. Steps move on as you get to where
//! each one ends. If Apple Maps can't route a walk, it is a straight line
//! with our own estimate, and the card says so.
//!
//! SGBUS_NAV_SIM="walk,ride" (meters a second) walks the way itself, for
//! the Simulator and screen recordings: `here` moves along the walks and
//! rides instead of following Core Location.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const map = nanoui.map;
const directions = nanoui.directions;
const data = @import("data.zig");
const raptor = @import("raptor.zig");
const cards = @import("cards.zig");
const App = @import("main.zig").App;

const ink = cards.ink;
const gray = cards.gray;
pub const walk_blue: ui.Color = .hex(0x1A73E8);
const legs_max = raptor.rounds + 1;

pub const Kind = enum { turn, to_stop, ride, arrive };

pub const Step = struct {
    kind: Kind,
    /// Apple's words for a turn; else unused.
    buf: [96]u8 = undefined,
    len: u8 = 0,
    at: map.Coord,
    /// The walk (turn, to_stop) or ride it belongs to.
    leg: u8 = 0,
    /// The walk is Apple's, not a straight line.
    apple: bool = true,

    pub fn text(st: *const Step) []const u8 {
        return st.buf[0..st.len];
    }
};

/// A run of `Nav.path`: a walk (dotted) or a ride (its line's colour).
pub const Seg = struct { start: u32, len: u32, ride: bool, color: ui.Color };

pub const Sim = struct { walk: f64 = 15, ride: f64 = 350, i: usize = 0, at: map.Coord = .{ .lat = 0, .lng = 0 }, hold: f64 = 0 };

const Req = struct { nav: *Nav, leg: u8, gen: u32 };

pub const Nav = struct {
    on: bool = false,
    app: *App = undefined,
    trip: raptor.Option = .{},
    from: map.Coord = .{ .lat = 0, .lng = 0 },
    dest: map.Coord = .{ .lat = 0, .lng = 0 },
    dest_buf: [64]u8 = undefined,
    dest_len: u8 = 0,
    gen: u32 = 0,
    walks: [legs_max]?directions.Route = @splat(null),
    waiting: u8 = 0,
    steps: std.ArrayList(Step) = .empty,
    cur: usize = 0,
    done: bool = false,
    path: std.ArrayList(map.Coord) = .empty,
    segs: std.ArrayList(Seg) = .empty,
    /// Points of `path` that are rides, for the simulated walk's pace.
    riding: std.ArrayList(bool) = .empty,
    sim_speeds: ?[2]f64 = null,
    sim: ?Sim = null,

    pub fn destName(nv: *const Nav) []const u8 {
        return nv.dest_buf[0..nv.dest_len];
    }

    /// Go: asks Apple Maps for each walk, then lays out the steps.
    pub fn start(nv: *Nav, t: raptor.Option, dest: map.Coord, name: []const u8) void {
        const s = nv.app;
        nv.stop();
        nv.on = true;
        nv.trip = t;
        nv.from = s.here;
        nv.dest = dest;
        nv.dest_len = @intCast(@min(name.len, nv.dest_buf.len));
        @memcpy(nv.dest_buf[0..nv.dest_len], name[0..nv.dest_len]);
        nv.waiting = 0;
        if (s.live.jump) |j| s.live.setClock(j);
        for (0..t.n + 1) |i| {
            const e = nv.ends(i);
            if (data.meters(e[0], e[1]) < 20) continue;
            const r = s.gpa.create(Req) catch continue;
            r.* = .{ .nav = nv, .leg = @intCast(i), .gen = nv.gen };
            nv.waiting += 1;
            directions.walking(s.gpa, e[0], e[1], r, gotWalk);
        }
        if (nv.waiting == 0) nv.build();
    }

    pub fn stop(nv: *Nav) void {
        const gpa = nv.app.gpa;
        nv.gen +%= 1;
        nv.on = false;
        nv.done = false;
        nv.sim = null;
        nv.cur = 0;
        nv.waiting = 0;
        for (&nv.walks) |*w| if (w.*) |*r| {
            r.deinit(gpa);
            w.* = null;
        };
        nv.steps.clearRetainingCapacity();
        nv.path.clearRetainingCapacity();
        nv.segs.clearRetainingCapacity();
        nv.riding.clearRetainingCapacity();
    }

    pub fn deinit(nv: *Nav) void {
        nv.stop();
        nv.steps.deinit(nv.app.gpa);
        nv.path.deinit(nv.app.gpa);
        nv.segs.deinit(nv.app.gpa);
        nv.riding.deinit(nv.app.gpa);
    }

    /// Still asking Apple Maps.
    pub fn asking(nv: *const Nav) bool {
        return nv.on and nv.waiting > 0;
    }

    fn gotWalk(r: *Req, route: ?directions.Route) void {
        const nv = r.nav;
        const gpa = nv.app.gpa;
        defer gpa.destroy(r);
        var got = route;
        if (r.gen != nv.gen or !nv.on) {
            if (got) |*g| g.deinit(gpa);
            return;
        }
        nv.walks[r.leg] = got;
        nv.waiting -|= 1;
        if (nv.waiting == 0) nv.build();
        if (nv.app.window) |w| w.redraw();
    }

    /// Where walk `i` starts and ends: here or the last ride's stop, to the
    /// next ride's stop (a station's nearest exit) or the place.
    pub fn ends(nv: *const Nav, i: usize) [2]map.Coord {
        const d = nv.app.d;
        const t = nv.trip;
        const a = if (i == 0) nv.from else d.stops[alightStop(nv, i - 1)].at;
        const b = if (i == t.n) nv.dest else entry(d, boardStop(nv, i), a);
        return .{ if (i == 0) a else entry(d, alightStop(nv, i - 1), b), b };
    }

    pub fn boardStop(nv: *const Nav, i: usize) u16 {
        const r = nv.trip.rides[i];
        return raptor.stopAt(nv.app.d, r.svc, r.dir, r.from);
    }

    pub fn alightStop(nv: *const Nav, i: usize) u16 {
        const r = nv.trip.rides[i];
        return raptor.stopAt(nv.app.d, r.svc, r.dir, r.to);
    }

    fn build(nv: *Nav) void {
        const s = nv.app;
        const gpa = s.gpa;
        const t = nv.trip;
        nv.steps.clearRetainingCapacity();
        nv.path.clearRetainingCapacity();
        nv.segs.clearRetainingCapacity();
        nv.riding.clearRetainingCapacity();
        for (0..t.n + 1) |i| {
            const e = nv.ends(i);
            const leg: u8 = @intCast(i);
            var apple = true;
            if (nv.walks[i]) |r| {
                nv.seg(&.{e[0]}, false, walk_blue, true);
                nv.seg(r.points, false, walk_blue, false);
                nv.seg(&.{e[1]}, false, walk_blue, false);
                for (r.steps, 0..) |st, k| {
                    // The start ("Proceed to the route"), Apple's "Arrive at
                    // the destination", and turns at the leg's ends.
                    if (k == 0 or k + 1 == r.steps.len or st.text.len == 0 or data.meters(st.at, e[1]) < 15 or data.meters(st.at, e[0]) < 8) continue;
                    var step: Step = .{ .kind = .turn, .at = st.at, .leg = leg };
                    step.len = @intCast(@min(st.text.len, step.buf.len));
                    @memcpy(step.buf[0..step.len], st.text[0..step.len]);
                    nv.steps.append(gpa, step) catch {};
                }
            } else if (data.meters(e[0], e[1]) >= 20) {
                apple = false;
                nv.seg(&.{ e[0], e[1] }, false, walk_blue, true);
            }
            if (i < t.n) {
                nv.steps.append(gpa, .{ .kind = .to_stop, .at = e[1], .leg = leg, .apple = apple }) catch {};
                nv.steps.append(gpa, .{ .kind = .ride, .at = s.d.stops[nv.alightStop(i)].at, .leg = leg }) catch {};
                const r = t.rides[i];
                var pts: [80]map.Coord = undefined;
                var n: usize = 0;
                for (s.d.services[r.svc].dirs[r.dir][r.from .. r.to + 1]) |st| if (n < pts.len) {
                    pts[n] = s.d.stops[st].at;
                    n += 1;
                };
                const col: ui.Color = if (s.d.services[r.svc].rail) |l| .hex(l.color) else cards.green;
                nv.seg(pts[0..n], true, col, true);
            } else nv.steps.append(gpa, .{ .kind = .arrive, .at = nv.dest, .leg = leg, .apple = apple }) catch {};
        }
        nv.cur = 0;
        if (nv.sim_speeds) |sp| {
            nv.sim = .{ .walk = sp[0], .ride = sp[1], .at = if (nv.path.items.len > 0) nv.path.items[0] else nv.from };
            nanoui.App.after(sim_ms, nv, simTick);
        }
    }

    /// Adds points to the path: a new run when `fresh`, else onto the last.
    fn seg(nv: *Nav, pts: []const map.Coord, ride: bool, color: ui.Color, fresh: bool) void {
        const gpa = nv.app.gpa;
        if (pts.len == 0) return;
        if (fresh or nv.segs.items.len == 0) {
            // A ride's line starts where the walk before it ended.
            const from = nv.path.items.len;
            nv.segs.append(gpa, .{ .start = @intCast(from), .len = 0, .ride = ride, .color = color }) catch return;
        }
        const last = &nv.segs.items[nv.segs.items.len - 1];
        for (pts) |p| {
            nv.path.append(gpa, p) catch return;
            nv.riding.append(gpa, ride) catch return;
            last.len += 1;
        }
    }

    /// The map's lines: walks dotted blue, rides in their colour.
    pub fn mapLines(nv: *const Nav, out: []map.Line) []map.Line {
        var n: usize = 0;
        for (nv.segs.items) |sg| {
            if (n == out.len or sg.len < 2) continue;
            out[n] = .{ .points = nv.path.items[sg.start .. sg.start + sg.len], .color = sg.color, .width = if (sg.ride) 6 else 5, .dashed = !sg.ride };
            n += 1;
        }
        return out[0..n];
    }

    /// Moves on past each step you've got to.
    pub fn update(nv: *Nav, here: map.Coord) void {
        if (!nv.on or nv.waiting > 0 or nv.done) return;
        while (nv.cur < nv.steps.items.len) {
            const st = nv.steps.items[nv.cur];
            const radius: f64 = switch (st.kind) {
                .turn => 12,
                .to_stop => 20,
                .ride => 50,
                .arrive => 20,
            };
            if (data.meters(here, st.at) > radius) break;
            if (st.kind == .arrive) {
                nv.done = true;
                nanoui.haptics.notify(.success);
                break;
            }
            nv.cur += 1;
            nanoui.haptics.impact(if (st.kind == .turn) .light else .medium);
            // Time on screen, in the simulated walk, for the bus or train
            // to come, and to get off.
            if (nv.sim) |*sm| sm.hold = if (st.kind == .to_stop) 2.5 else if (st.kind == .ride) 1.5 else 0;
        }
    }

    /// Stops left to `alight` on ride `i`, from where you are.
    pub fn stopsLeft(nv: *const Nav, i: usize, here: map.Coord) u16 {
        const d = nv.app.d;
        const r = nv.trip.rides[i];
        const list = d.services[r.svc].dirs[r.dir][r.from .. r.to + 1];
        var best: usize = 0;
        var best_m: f64 = std.math.inf(f64);
        for (list, 0..) |st, k| {
            const m = data.meters(here, d.stops[st].at);
            if (m < best_m) {
                best_m = m;
                best = k;
            }
        }
        return @intCast(list.len - 1 - best);
    }

    /// On board: moved away from the stop you got on at.
    pub fn onBoard(nv: *const Nav, i: usize, here: map.Coord) bool {
        return data.meters(here, nv.app.d.stops[nv.boardStop(i)].at) > 80;
    }

    const sim_ms = 66;

    fn simTick(ctx: ?*anyopaque) callconv(.c) void {
        const nv: *Nav = @ptrCast(@alignCast(ctx));
        const sm = if (nv.sim) |*x| x else return;
        if (!nv.on or nv.done) return;
        var dt: f64 = @as(f64, sim_ms) / 1000;
        if (sm.hold > 0) {
            sm.hold -= dt;
            dt = 0;
        }
        const pts = nv.path.items;
        while (dt > 0 and sm.i + 1 < pts.len) {
            const to = pts[sm.i + 1];
            const v = if (nv.riding.items[sm.i + 1] and nv.riding.items[sm.i]) sm.ride else sm.walk;
            const left = data.meters(sm.at, to);
            const go = @min(left, @min(v * dt, 8));
            if (left < 0.01) {
                sm.i += 1;
                continue;
            }
            const f = go / left;
            sm.at = .{ .lat = sm.at.lat + (to.lat - sm.at.lat) * f, .lng = sm.at.lng + (to.lng - sm.at.lng) * f };
            dt -= go / v;
            nv.app.here = sm.at;
            nv.update(sm.at);
            if (sm.hold > 0) break;
        }
        if (sm.i + 1 >= pts.len) nv.update(nv.dest);
        if (nv.app.window) |w| w.redraw();
        if (!nv.done) nanoui.App.after(sim_ms, nv, simTick);
    }
};

/// Where a walk meets a stop: its own spot, or a station's exit nearest `from`.
fn entry(d: *const data.Data, stop: u16, from: map.Coord) map.Coord {
    const st = d.stops[stop];
    var best = st.at;
    var best_m: f64 = std.math.inf(f64);
    for (st.exits) |e| {
        const m = data.meters(from, e);
        if (m < best_m) {
            best_m = m;
            best = e;
        }
    }
    return best;
}

/// "SGBUS_NAV_SIM=15,350": the simulated walk's and ride's meters a second.
pub fn parseSim(v: []const u8) ?[2]f64 {
    var it = std.mem.splitScalar(u8, v, ',');
    const w = std.fmt.parseFloat(f64, it.next() orelse return null) catch return null;
    const r = if (it.next()) |x| std.fmt.parseFloat(f64, x) catch return null else w * 20;
    if (w <= 0 or r <= 0) return null;
    return .{ w, r };
}

pub const view = @import("nav_view.zig").view;
