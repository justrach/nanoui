//! From here to a place: the To field searches OneMap's places (and the
//! bundled stop names), then up to three ways there by bus, each with the
//! waits for its buses from live arrivals, and a trip's legs on the map.
//!
//! Ways there come from this app's own bus planner (raptor.zig), which
//! needs no network but the live boards, merged with OneMap's bus and MRT
//! ways when a token is given at run time (onemap.zig), and all ranked
//! the same way: arrival, plus a penalty per change and per minute walked.
//! As live boards for the boarding stops come in, it plans again.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const map = nanoui.map;
const data = @import("data.zig");
const raptor = @import("raptor.zig");
const cards = @import("cards.zig");
const onemap = @import("onemap.zig");
const live = @import("live.zig");
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

/// One entry of the merged list: one of ours, or OneMap's way `i`.
pub const Way = struct { om: bool, i: u8, score: f64, tag: ?[]const u8 = null };

pub const Journey = struct {
    to: ui.TextBuffer = .{},
    asked: [64]u8 = undefined,
    asked_len: usize = 0,
    inflight: bool = false,
    places: [6]Place = undefined,
    n_places: usize = 0,
    dest: ?Place = null,
    trips: [4]raptor.Option = undefined,
    /// `Live.answers` when it last planned.
    planned: u32 = 0,
    obs: [192]raptor.Obs = undefined,
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

    pub fn trip(j: *const Journey) ?raptor.Option {
        if (j.om_chosen != null) return null;
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
        j.replan();
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

    /// The clock, the day and the live boards, for the planner.
    pub fn planNow(j: *const Journey) raptor.Now {
        const s = j.app;
        var n: raptor.Now = .{ .ctx = s, .look = look, .clock = s.live.clock() };
        if (s.live.date) |d| n.weekday = weekday(&d);
        return n;
    }

    /// Plans again with the live boards as they are now.
    pub fn replan(j: *Journey) void {
        const s = j.app;
        const dest = j.dest orelse return;
        j.planned = s.live.answers;
        const kept = if (j.chosen) |i| j.trips[i] else null;
        var now = j.planNow();
        now.obs = j.observe();
        const got = raptor.plan(s.d, s.gpa, s.here, dest.at, now, &j.trips) catch j.trips[0..0];
        j.n_trips = got.len;
        // The way you opened stays open, with its new numbers.
        if (kept) |k| {
            j.chosen = null;
            for (got, 0..) |t, i| if (samePlan(t, k)) {
                j.chosen = i;
            };
        }
    }

    /// Each frame on the Journey tab: keeps the boarding stops' boards
    /// coming, and plans again when one answers.
    pub fn keep(j: *Journey) void {
        const s = j.app;
        if (j.dest == null) return;
        for (j.trips[0..j.n_trips]) |t| for (0..t.n) |i| {
            const r = t.rides[i];
            // Trains have no live board.
            if (s.d.services[r.svc].rail != null) continue;
            _ = s.live.want(s.d.stops[raptor.stopAt(s.d, r.svc, r.dir, r.from)].code);
        };
        if (s.live.answers != j.planned) j.replan();
    }

    /// Ours and OneMap's ways in one list, best first.
    pub fn ways(j: *const Journey, out: []Way) []Way {
        var n: usize = 0;
        for (j.trips[0..j.n_trips], 0..) |t, i| {
            if (n == out.len) break;
            const tag: ?[]const u8 = if (t.tags.fastest) "Fastest leh" else if (t.tags.fewest) "Fewest changes" else if (t.tags.least_walk) "Least walking" else null;
            out[n] = .{ .om = false, .i = @intCast(i), .score = t.score, .tag = tag };
            n += 1;
        }
        if (j.usingOneMap()) for (j.om[0..j.n_om], 0..) |it, i| {
            if (n == out.len) break;
            // OneMap's minutes already count its waits and walks.
            const mins = it.seconds / 60;
            out[n] = .{ .om = true, .i = @intCast(i), .score = mins + 5 * @as(f64, @floatFromInt(it.transfers)) + 0.5 * raptor.walkMin(it.walk_m / 1.3) };
            n += 1;
        };
        std.mem.sort(Way, out[0..n], {}, struct {
            fn lt(_: void, a: Way, b: Way) bool {
                return a.score < b.score;
            }
        }.lt);
        // A OneMap way faster than all of ours takes the "Fastest" tag.
        if (n > 0 and out[0].om) for (out[1..n]) |*w| {
            if (w.tag != null and std.mem.eql(u8, w.tag.?, "Fastest leh")) w.tag = null;
        };
        if (n > 0 and out[0].om) out[0].tag = "Fastest leh";
        return out[0..n];
    }

    /// The live buses on the boards in, for the planner's pace.
    fn observe(j: *Journey) []const raptor.Obs {
        const s = j.app;
        var n: usize = 0;
        for (s.live.boards.items) |b| if (b.state == .ok) {
            const stop = s.d.find(b.code()) orelse continue;
            for (b.svcs.items) |*sv| {
                const svc = s.d.service(sv.no()) orelse continue;
                for (sv.buses) |nb| if (nb) |bus| if (n < j.obs.len and bus.lat != 0) {
                    j.obs[n] = .{ .stop = stop, .svc = svc, .eta = etaMin(s, b, bus), .at = .{ .lat = bus.lat, .lng = bus.lng } };
                    n += 1;
                };
            }
        };
        return j.obs[0..n];
    }

    /// The trip's line: here, the stops it rides through, the place.
    pub fn line(j: *const Journey, t: raptor.Option, out: *std.ArrayList(map.Coord)) void {
        const s = j.app;
        out.clearRetainingCapacity();
        out.append(s.gpa, s.here) catch return;
        for (0..t.n) |i| {
            const r = t.rides[i];
            for (s.d.services[r.svc].dirs[r.dir][r.from .. r.to + 1]) |st| out.append(s.gpa, s.d.stops[st].at) catch return;
        }
        out.append(s.gpa, j.dest.?.at) catch return;
    }

    pub fn pins(j: *const Journey, t: raptor.Option, out: []map.Pin) []map.Pin {
        const s = j.app;
        var n: usize = 0;
        for (0..t.n) |i| {
            const r = t.rides[i];
            for ([2]u16{ r.from, r.to }) |pos| {
                const st = raptor.stopAt(s.d, r.svc, r.dir, pos);
                out[n] = .{ .id = st, .at = s.d.stops[st].at, .label = raptor.rail.codeOn(s.d, st, r.svc), .selected = i == 0 and pos == r.from };
                n += 1;
            }
        }
        out[n] = .{ .id = 200000, .at = j.dest.?.at, .label = "To here", .style = .bus };
        return out[0 .. n + 1];
    }

    /// The route line's colour: the line of the longest train ride, else bus green.
    pub fn lineColor(j: *const Journey, t: raptor.Option) nanoui.ui.Color {
        var best: f64 = 0;
        var col: nanoui.ui.Color = cards.green;
        for (0..t.n) |i| if (j.app.d.services[t.rides[i].svc].rail) |l| if (t.ride_min[i] > best) {
            best = t.ride_min[i];
            col = .hex(l.color);
        };
        return col;
    }

    pub fn camera(j: *const Journey) map.Camera {
        const a = j.app.here;
        const b = j.dest.?.at;
        const span = @max(@abs(a.lat - b.lat), @abs(a.lng - b.lng)) * 1.5 + 0.006;
        return .{ .center = .{ .lat = (a.lat + b.lat) / 2, .lng = (a.lng + b.lng) / 2 }, .span = span };
    }
};

fn samePlan(a: raptor.Option, b: raptor.Option) bool {
    if (a.n != b.n) return false;
    for (0..a.n) |i| if (a.rides[i].svc != b.rides[i].svc) return false;
    return true;
}

fn etaMin(s: *const App, b: *const live.Board, bus: live.Bus) f64 {
    return (@as(f64, @floatFromInt(bus.ms)) / 1000 - (s.live.now - b.at)) / 60;
}

/// The planner asks what the live board says of a service at a stop.
fn look(ctx: ?*const anyopaque, stop: u16, svc: u16) raptor.Look {
    const s: *const App = @ptrCast(@alignCast(ctx.?));
    const code = s.d.stops[stop].code;
    for (s.live.boards.items) |b| if (std.mem.eql(u8, b.code(), code)) {
        if (b.state != .ok) return .unknown;
        const sv = b.find(s.d.services[svc].no) orelse return .absent;
        var etas: [3]?f64 = .{ null, null, null };
        for (sv.buses, 0..) |nb, i| if (nb) |bus| {
            etas[i] = etaMin(s, b, bus);
        };
        return .{ .seen = etas };
    };
    return .unknown;
}

/// Monday to Friday, from "MM-DD-YYYY" (Sakamoto's method).
fn weekday(date: *const [10]u8) bool {
    const m = std.fmt.parseInt(u32, date[0..2], 10) catch return true;
    const d = std.fmt.parseInt(u32, date[3..5], 10) catch return true;
    var y = std.fmt.parseInt(u32, date[6..10], 10) catch return true;
    const t = [_]u32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    if (m < 3) y -= 1;
    const dow = (y + y / 4 - y / 100 + y / 400 + t[(m - 1) % 12] + d) % 7;
    return dow != 0 and dow != 6;
}

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
