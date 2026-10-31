//! A service from a stop: its line on the map with the next three buses
//! on it where LTA last saw them (they glide to each new place), and the
//! stops before this one with each bus marked where it is: how far off it
//! is, at a glance.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const map = nanoui.map;
const data = @import("data.zig");
const live = @import("live.zig");
const cards = @import("cards.zig");
const App = @import("main.zig").App;

pub const Route = struct { svc: u16, dir: u8, pos: u16, stop: u16 };

/// The direction of service `no` that calls at `stop` (the first, for a loop).
pub fn find(d: *const data.Data, stop: u16, no: []const u8) ?Route {
    const svc = d.service(no) orelse return null;
    for (d.visits[stop]) |v| if (v.svc == svc) return .{ .svc = svc, .dir = v.dir, .pos = v.pos, .stop = stop };
    return null;
}

/// The pins: this stop, and each live bus as "15 · 3 min".
pub fn pins(s: *App, c: *ui.Context, r: Route, out: []map.Pin) []map.Pin {
    var n: usize = 0;
    const st = s.d.stops[r.stop];
    out[n] = .{ .id = r.stop, .at = st.at, .label = st.code, .selected = true };
    n += 1;
    const b = s.live.want(st.code) orelse return out[0..n];
    const sv = b.find(s.d.services[r.svc].no) orelse return out[0..n];
    for (sv.buses, 0..) |nb, i| if (nb) |bus| {
        if (bus.lat == 0 or n == out.len) continue;
        const m = b.minutes(bus);
        const label = if (m <= 0) c.print("{s} · Arr", .{sv.no()}) else c.print("{s} · {d} min", .{ sv.no(), m });
        out[n] = .{ .id = 100000 + i, .at = .{ .lat = bus.lat, .lng = bus.lng }, .label = label[0..@min(label.len, 15)], .style = .bus };
        n += 1;
    };
    return out[0..n];
}

/// Where the camera looks: the stop, wide enough for the nearest bus.
pub fn camera(s: *App, r: Route) map.Camera {
    const at = s.d.stops[r.stop].at;
    var span: f64 = 0.012;
    if (s.live.want(s.d.stops[r.stop].code)) |b| if (b.find(s.d.services[r.svc].no)) |sv| if (sv.buses[0]) |bus| if (bus.lat != 0) {
        span = @max(span, 2.4 * @max(@abs(bus.lat - at.lat), @abs(bus.lng - at.lng)));
    };
    return .{ .center = at, .span = @min(span, 0.08) };
}

pub fn panel(s: *App, c: *ui.Context, r: Route) void {
    const svc = s.d.services[r.svc];
    const stops = svc.dirs[r.dir];
    const st = s.d.stops[r.stop];
    const last = s.d.stops[stops[stops.len - 1]];
    {
        const head = ui.div(c).row().wFull().gap(12).itemsCenter();
        defer head.end();
        cards.badge(c, svc.no);
        const t = ui.div(c).column().grow();
        ui.text(c, c.print("to {s}", .{last.name}), .{ .size = 28, .weight = .semibold, .color = cards.ink, .wrap = true });
        ui.text(c, c.print("from {s} ({s})", .{ st.name, st.code }), .{ .size = 13, .color = cards.gray, .truncate = .ellipsis });
        t.end();
    }
    const b = s.live.want(st.code);
    const sv = if (b) |x| x.find(svc.no) else null;
    {
        const card = ui.div(c).row().wFull().rounded(22).bg(.white).p(16).gap(10);
        defer card.end();
        if (sv) |x| {
            for (x.buses, 0..) |nb, i| {
                c.next_key_int = i;
                const col = ui.div(c).column().grow().gap(4);
                defer col.end();
                const bus = nb orelse {
                    ui.text(c, "-", .{ .size = 28, .weight = .semibold, .color = cards.gray });
                    continue;
                };
                const m = b.?.minutes(bus);
                const row = ui.div(c).row().gap(4).itemsCenter();
                ui.motion.roll(c, c.print("r{d}", .{i}), cards.mins(c, m, bus.monitored), .{ .size = 28, .weight = .semibold, .color = if (m <= 0) cards.green else if (bus.monitored) cards.ink else cards.gray }, .{});
                if (m > 0) ui.text(c, "min", .{ .size = 13, .color = cards.gray });
                row.end();
                const tags = ui.div(c).row().gap(6).itemsCenter();
                cards.loadBars(c, bus.load);
                ui.text(c, if (bus.kind[0] == 'D') "2 deck" else if (bus.kind[0] == 'B') "bendy" else "1 deck", .{ .size = 13, .color = cards.gray });
                tags.end();
            }
        } else ui.text(c, if (b != null and b.?.state == .loading) "Getting times..." else "No bus now leh", .{ .size = 17, .color = cards.gray });
    }
    ui.text(c, "Coming your way", .{ .size = 17, .weight = .semibold, .color = cards.ink });
    // The stops before this one, nearest last: a dot where each bus is.
    const from = r.pos -| 9;
    const track = ui.div(c).column().wFull().rounded(22).bg(.white).px(16).py(8);
    defer track.end();
    var i: usize = from;
    while (i <= r.pos) : (i += 1) {
        c.next_key_int = i;
        const at = s.d.stops[stops[i]];
        const row = ui.div(c).row().wFull().gap(12).itemsCenter().py(7);
        defer row.end();
        const here = i == r.pos;
        const bus_here = if (sv) |x| busNear(s.d, stops, from, r.pos, x, i) else false;
        const dot = ui.div(c).size(14, 14).roundedFull().bg(if (here) cards.yellow else if (bus_here) cards.ink else .hex(0xD8D8DC));
        if (here) _ = dot.border(cards.ink).borderW(2);
        dot.end();
        const words = ui.div(c).column().grow();
        ui.text(c, at.name, .{ .size = 17, .weight = if (here) .semibold else .regular, .color = cards.ink, .truncate = .ellipsis });
        if (bus_here) ui.text(c, "Bus here", .{ .size = 13, .color = cards.gray });
        words.end();
        ui.text(c, at.code, .{ .size = 13, .color = cards.gray, .tabular = true });
    }
}

/// Whether a live bus of `sv` is nearest stop `i` of the stops `from` to `to`.
fn busNear(d: *const data.Data, stops: []const u16, from: usize, to: usize, sv: *const live.Svc, i: usize) bool {
    for (sv.buses) |nb| if (nb) |bus| {
        if (bus.lat == 0) continue;
        const p: map.Coord = .{ .lat = bus.lat, .lng = bus.lng };
        var best: usize = from;
        var bm: f64 = 1e12;
        for (from..to + 1) |k| {
            const m = data.meters(p, d.stops[stops[k]].at);
            if (m < bm) {
                bm = m;
                best = k;
            }
        }
        if (best == i and bm < 600) return true;
    };
    return false;
}
