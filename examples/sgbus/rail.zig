//! The MRT and LRT network as more stops and services on `data.Data`,
//! from `data/rail.min.json` (built by tools/build_rail.py from
//! cheeaun/sgraildata: LTA DataMall station exits, CityMapper and OSM
//! track). A station is one stop, interchanges included, with its exits;
//! each line is a service whose directions are station lists. Run times,
//! headways and access times are below, sources in routing.md.

const std = @import("std");
const data = @import("data.zig");

/// Gates to platform, and platform to street, minutes.
pub const entry_min: f64 = 2.0;
pub const exit_min: f64 = 1.5;
/// Changing lines inside one station, minutes (walk between platforms).
pub const interchange_min: f64 = 3.0;
/// Trains run 5:30am to about midnight (LTA).
pub const first_min: f64 = 5 * 60 + 30;
pub const last_min: f64 = 23 * 60 + 45;

pub fn extend(d: *data.Data, a: std.mem.Allocator) !void {
    const j = try std.json.parseFromSliceLeaky(std.json.Value, a, @embedFile("data/rail.min.json"), .{});
    const st = j.object.get("stations").?.array.items;
    const ln = j.object.get("lines").?.array.items;
    const n0 = d.stops.len;
    const s0 = d.services.len;

    const stops = try a.alloc(data.Stop, n0 + st.len);
    @memcpy(stops[0..n0], d.stops);
    for (st, n0..) |v, i| {
        const f = v.array.items;
        const codes = f[1].string;
        const first = std.mem.indexOfScalar(u8, codes, ' ') orelse codes.len;
        const ex = try a.alloc(data.Coord, f[4].array.items.len);
        for (f[4].array.items, 0..) |e, k| ex[k] = .{ .lat = num(e.array.items[0]), .lng = num(e.array.items[1]) };
        stops[i] = .{ .code = codes[0..first], .name = f[0].string, .road = codes, .at = .{ .lat = num(f[2]), .lng = num(f[3]) }, .exits = ex };
    }

    const lists = try a.alloc(std.ArrayList(data.Visit), st.len);
    @memset(lists, .empty);
    const services = try a.alloc(data.Service, s0 + ln.len);
    @memcpy(services[0..s0], d.services);
    for (ln, s0..) |v, si| {
        const o = v.object;
        const dj = o.get("dirs").?.array.items;
        const kj = o.get("km").?.array.items;
        const dirs = try a.alloc([]const u16, dj.len);
        const km = try a.alloc([]const f32, dj.len);
        for (dj, kj, 0..) |dv, kv, di| {
            const seq = try a.alloc(u16, dv.array.items.len);
            for (dv.array.items, 0..) |x, p| {
                const local: usize = @intCast(x.integer);
                seq[p] = @intCast(n0 + local);
                // A loop's hub is first and last: board it only at the start.
                if (p > 0 and p == seq.len - 1 and seq[p] == seq[0]) continue;
                try lists[local].append(a, .{ .svc = @intCast(si), .dir = @intCast(di), .pos = @intCast(p) });
            }
            const hops = try a.alloc(f32, kv.array.items.len);
            for (kv.array.items, 0..) |x, p| hops[p] = @floatCast(num(x));
            dirs[di] = seq;
            km[di] = hops;
        }
        const line = try a.create(data.Line);
        line.* = .{
            .id = o.get("id").?.string,
            .name = o.get("name").?.string,
            .color = try std.fmt.parseInt(u24, o.get("color").?.string, 16),
            .vmax = @floatCast(num(o.get("vmax").?)),
            .km = km,
        };
        services[si] = .{ .no = line.id, .name = line.name, .dirs = dirs, .lines = &.{}, .rail = line };
    }

    const visits = try a.alloc([]const data.Visit, n0 + st.len);
    @memcpy(visits[0..n0], d.visits);
    for (lists, n0..) |l, i| visits[i] = l.items;
    d.stops = stops;
    d.services = services;
    d.visits = visits;
}

fn num(v: std.json.Value) f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => 0,
    };
}

pub fn isLrt(l: *const data.Line) bool {
    return l.vmax < 70;
}

/// Minutes from leaving one station to leaving the next: accelerate at
/// `accel`, cruise at 85% of top speed (trains rarely hold it), brake,
/// then dwell. Fitted to TransitLink's SimplyGo eGuide travel times for
/// 14 MRT trips (journey/eval.md): mean error 1.1 min, worst 3.3 (TEL).
pub fn hopMin(l: *const data.Line, km: f32) f64 {
    const accel: f64 = 0.8; // m/s²
    const v: f64 = @as(f64, l.vmax) / 3.6 * 0.85;
    const dist: f64 = @as(f64, km) * 1000;
    const run = if (dist > v * v / accel) dist / v + v / accel else 2 * @sqrt(dist / accel);
    const dwell: f64 = if (isLrt(l)) 20 else 45;
    return (run + dwell) / 60;
}

/// Minutes between trains (LTA: 2 to 3 min at peak, 5 to 7 off-peak;
/// TEL about 6 off-peak; LRT a little longer).
pub fn headway(l: *const data.Line, peak: bool) f64 {
    if (isLrt(l)) return if (peak) 3.5 else 6;
    if (std.mem.eql(u8, l.id, "TEL")) return if (peak) 3 else 6;
    if (std.mem.eql(u8, l.id, "CGL")) return if (peak) 5 else 8;
    return if (peak) 2.5 else 5;
}

/// The station code of `stop` on `svc`'s line ("DT14" for Bugis on the
/// Downtown Line), else its first code.
pub fn codeOn(d: *const data.Data, stop: u16, svc: u16) []const u8 {
    const st = d.stops[stop];
    const l = d.services[svc].rail orelse return st.code;
    const pre = prefix(l.id);
    var it = std.mem.tokenizeScalar(u8, st.road, ' ');
    while (it.next()) |c| if (std.mem.startsWith(u8, c, pre) and c.len > pre.len and std.ascii.isDigit(c[pre.len])) return c;
    return st.code;
}

fn prefix(id: []const u8) []const u8 {
    const map = [_][2][]const u8{ .{ "NSL", "NS" }, .{ "EWL", "EW" }, .{ "CGL", "CG" }, .{ "NEL", "NE" }, .{ "CCL", "CC" }, .{ "DTL", "DT" }, .{ "TEL", "TE" }, .{ "BPL", "BP" }, .{ "SKE", "SE" }, .{ "SKW", "SW" }, .{ "PGE", "PE" }, .{ "PGW", "PW" } };
    for (map) |m| if (std.mem.eql(u8, m[0], id)) return m[1];
    return id;
}

/// The shortest track km between two stations over every line, which is
/// what LTA charges a train trip by, whichever way it actually went.
pub fn shortestKm(d: *const data.Data, from: u16, to: u16) f32 {
    const max = 256;
    const n = d.stops.len - d.n_bus;
    std.debug.assert(n <= max);
    var dist: [max]f32 = @splat(std.math.inf(f32));
    var done: [max]bool = @splat(false);
    dist[from - d.n_bus] = 0;
    while (true) {
        var u: ?usize = null;
        for (0..n) |i| if (!done[i] and (u == null or dist[i] < dist[u.?])) {
            u = i;
        };
        const at = u orelse break;
        if (dist[at] == std.math.inf(f32)) break;
        if (at == to - d.n_bus) return dist[at];
        done[at] = true;
        const stop: u16 = @intCast(at + d.n_bus);
        for (d.visits[stop]) |v| {
            const line = d.services[v.svc].rail orelse continue;
            const seq = d.services[v.svc].dirs[v.dir];
            // Along the line and back, so a loop's hub counts both ways.
            if (v.pos + 1 < seq.len) relax(&dist, seq[v.pos + 1] - d.n_bus, dist[at] + line.km[v.dir][v.pos]);
            if (v.pos > 0) relax(&dist, seq[v.pos - 1] - d.n_bus, dist[at] + line.km[v.dir][v.pos - 1]);
        }
    }
    return dist[to - d.n_bus];
}

fn relax(dist: []f32, i: usize, km: f32) void {
    if (km < dist[i]) dist[i] = km;
}

pub fn open(clock: f64) bool {
    return clock >= first_min and clock <= last_min;
}
