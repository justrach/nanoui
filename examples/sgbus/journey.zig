//! From here to a place: the To field searches OneMap's places (and the
//! bundled stop names), then up to three ways there by bus, each with the
//! waits for its buses from live arrivals, and a trip's legs on the map.
//!
//! Ways there come from OneMap's transit routing, bus and MRT, when a
//! token is given at run time (onemap.zig). Without one, or when OneMap
//! fails or rate-limits, they come from this app's own bus-only planner
//! (router.zig), which needs no network but the live waits.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const map = nanoui.map;
const data = @import("data.zig");
const router = @import("router.zig");
const cards = @import("cards.zig");
const onemap = @import("onemap.zig");
const App = @import("main.zig").App;

pub const Place = struct {
    buf: [64]u8 = undefined,
    len: u8 = 0,
    at: map.Coord,
    stop: ?u16 = null,

    pub fn name(p: *const Place) []const u8 {
        return p.buf[0..p.len];
    }
    pub fn init(n: []const u8, at: map.Coord, stop: ?u16) Place {
        var p: Place = .{ .at = at, .stop = stop };
        p.len = @intCast(@min(n.len, p.buf.len));
        @memcpy(p.buf[0..p.len], n[0..p.len]);
        return p;
    }
};

/// A trip as of now: waits from live arrivals where there are some.
pub const Eval = struct {
    total: f64,
    waits: [2]f64 = .{ 0, 0 },
    live: [2]bool = .{ false, false },
    rides: [2]f64 = .{ 0, 0 },
};

pub const Journey = struct {
    to: ui.TextBuffer = .{},
    asked: [64]u8 = undefined,
    asked_len: usize = 0,
    inflight: bool = false,
    places: [6]Place = undefined,
    n_places: usize = 0,
    dest: ?Place = null,
    trips: [3]router.Trip = undefined,
    n_trips: usize = 0,
    chosen: ?usize = null,
    going: bool = false,
    app: *App = undefined,
    /// OneMap's token, from the environment, held in memory only.
    token: ?[]const u8 = null,
    /// Show OneMap's documented sample answer instead of asking (a demo of
    /// the MRT views without a token; labelled as a sample on screen).
    sample: bool = false,
    om: [3]onemap.Itinerary = undefined,
    n_om: usize = 0,
    om_state: enum { off, asking, ok, failed, sample } = .off,
    om_status: u16 = 0,
    om_chosen: ?usize = null,

    pub fn trip(j: *const Journey) ?router.Trip {
        if (j.usingOneMap()) return null;
        const i = j.chosen orelse return null;
        return j.trips[i];
    }

    pub fn search(j: *Journey, gpa: std.mem.Allocator, q: []const u8) void {
        if (j.inflight or q.len < 3 or std.mem.eql(u8, q, j.asked[0..j.asked_len])) return;
        j.asked_len = @min(q.len, j.asked.len);
        @memcpy(j.asked[0..j.asked_len], q[0..j.asked_len]);
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.writeAll("https://www.onemap.gov.sg/api/common/elastic/search?returnGeom=Y&getAddrDetails=N&pageNum=1&searchVal=") catch return;
        for (j.asked[0..j.asked_len]) |ch| {
            if (std.ascii.isAlphanumeric(ch)) w.writeByte(ch) catch return else w.print("%{X:0>2}", .{ch}) catch return;
        }
        j.inflight = true;
        nanoui.http.fetch(gpa, .{ .url = w.buffered(), .timeout = 10 }, j, found);
    }

    fn found(j: *Journey, r: nanoui.http.Response) void {
        j.inflight = false;
        defer if (j.app.window) |w| w.redraw();
        if (r.status != 200) return;
        const p = std.json.parseFromSlice(std.json.Value, j.app.gpa, r.body, .{}) catch return;
        defer p.deinit();
        const list = (p.value.object.get("results") orelse return).array.items;
        j.n_places = 0;
        for (list) |v| {
            if (j.n_places == 4) break;
            const n = str(v, "SEARCHVAL");
            const lat = std.fmt.parseFloat(f64, str(v, "LATITUDE")) catch continue;
            const lng = std.fmt.parseFloat(f64, str(v, "LONGITUDE")) catch continue;
            j.places[j.n_places] = .init(n, .{ .lat = lat, .lng = lng }, null);
            j.n_places += 1;
        }
    }

    pub fn go(j: *Journey, p: Place) void {
        const s = j.app;
        j.dest = p;
        j.chosen = null;
        j.going = false;
        j.om_chosen = null;
        const got = router.plan(s.d, s.gpa, s.here, p.at, &j.trips) catch &.{};
        j.n_trips = got.len;
        nanoui.haptics.selection();
        j.n_om = 0;
        j.om_state = .off;
        if (j.sample) {
            const sample = onemap.parse(s.gpa, @embedFile("fixtures/onemap-docs-sample.json"), &j.om) catch j.om[0..0];
            j.n_om = sample.len;
            j.om_state = .sample;
        } else if (j.token) |token| {
            const date = s.live.date orelse return;
            const now = s.live.clock() orelse return;
            const t: u32 = @intFromFloat(now);
            var tb: [8]u8 = undefined;
            const time = std.fmt.bufPrint(&tb, "{d:0>2}:{d:0>2}:{d:0>2}", .{ t / 3600, t / 60 % 60, t % 60 }) catch return;
            var ub: [320]u8 = undefined;
            const u = onemap.url(&ub, .{ .lat = s.here.lat, .lng = s.here.lng }, .{ .lat = p.at.lat, .lng = p.at.lng }, &date, time) catch return;
            j.om_state = .asking;
            nanoui.http.fetch(s.gpa, .{ .url = u, .headers = &.{.{ .name = "Authorization", .value = token }}, .timeout = 15 }, j, routed);
        }
    }

    fn routed(j: *Journey, r: nanoui.http.Response) void {
        defer if (j.app.window) |w| w.redraw();
        j.om_status = r.status;
        if (r.status != 200) {
            j.om_state = .failed;
            return;
        }
        j.n_om = (onemap.parse(j.app.gpa, r.body, &j.om) catch {
            j.om_state = .failed;
            return;
        }).len;
        j.om_state = if (j.n_om > 0) .ok else .failed;
    }

    /// OneMap's ways are shown (asked and answered, or the sample).
    pub fn usingOneMap(j: *const Journey) bool {
        return (j.om_state == .ok or j.om_state == .sample) and j.n_om > 0;
    }

    /// The chosen OneMap way.
    pub fn omTrip(j: *const Journey) ?*const onemap.Itinerary {
        if (!j.usingOneMap()) return null;
        const i = j.om_chosen orelse return null;
        return &j.om[i];
    }

    /// Minutes for `t`, with each bus's wait from live arrivals.
    pub fn evaluate(j: *const Journey, t: router.Trip) Eval {
        const s = j.app;
        var e: Eval = .{ .total = router.walkMin(t.walks[0]) };
        for (0..t.n) |i| {
            const r = t.rides[i];
            const code = s.d.stops[router.stopAt(s.d, r.svc, r.dir, r.from)].code;
            e.waits[i] = 8;
            if (s.live.want(code)) |b| if (b.find(s.d.services[r.svc].no)) |sv| for (sv.buses) |nb| if (nb) |bus| {
                const at = (@as(f64, @floatFromInt(bus.ms)) / 1000 - (s.live.now - b.at)) / 60;
                if (at >= e.total - 0.01) {
                    e.waits[i] = at - e.total;
                    e.live[i] = bus.monitored;
                    break;
                }
            };
            e.rides[i] = router.rideMin(s.d, r);
            e.total += e.waits[i] + e.rides[i] + router.walkMin(t.walks[i + 1]);
        }
        return e;
    }

    /// The trip's line: here, the stops it rides through, the place.
    pub fn line(j: *const Journey, t: router.Trip, out: *std.ArrayList(map.Coord)) void {
        const s = j.app;
        out.clearRetainingCapacity();
        out.append(s.gpa, s.here) catch return;
        for (0..t.n) |i| {
            const r = t.rides[i];
            for (s.d.services[r.svc].dirs[r.dir][r.from .. r.to + 1]) |st| out.append(s.gpa, s.d.stops[st].at) catch return;
        }
        out.append(s.gpa, j.dest.?.at) catch return;
    }

    pub fn pins(j: *const Journey, t: router.Trip, out: []map.Pin) []map.Pin {
        const s = j.app;
        var n: usize = 0;
        for (0..t.n) |i| {
            const r = t.rides[i];
            for ([2]u16{ r.from, r.to }) |pos| {
                const st = router.stopAt(s.d, r.svc, r.dir, pos);
                out[n] = .{ .id = st, .at = s.d.stops[st].at, .label = s.d.stops[st].code, .selected = i == 0 and pos == r.from };
                n += 1;
            }
        }
        out[n] = .{ .id = 200000, .at = j.dest.?.at, .label = "To here", .style = .bus };
        return out[0 .. n + 1];
    }

    pub fn camera(j: *const Journey) map.Camera {
        const a = j.app.here;
        const b = j.dest.?.at;
        const span = @max(@abs(a.lat - b.lat), @abs(a.lng - b.lng)) * 1.5 + 0.006;
        return .{ .center = .{ .lat = (a.lat + b.lat) / 2, .lng = (a.lng + b.lng) / 2 }, .span = span };
    }
};

fn str(v: std.json.Value, k: []const u8) []const u8 {
    const x = v.object.get(k) orelse return "";
    return if (x == .string) x.string else "";
}

pub fn clockText(c: *ui.Context, s: *App, after_min: f64) ?[]const u8 {
    const now = s.live.clock() orelse return null;
    const t: u32 = @intFromFloat(@mod(now + after_min * 60, 86400));
    return c.print("{d:0>2}:{d:0>2}", .{ t / 3600, t / 60 % 60 });
}

pub const view = @import("journey_view.zig").view;
