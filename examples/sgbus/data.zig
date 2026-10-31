//! The static data, bundled: every bus stop, every service's stops in
//! each direction, and each direction's line, from busrouter.sg's
//! data.busrouter.sg/v1 (itself from LTA DataMall), parsed once at start.
const std = @import("std");
const nanoui = @import("nanoui");
const Coord = nanoui.map.Coord;

pub const Stop = struct { code: []const u8, name: []const u8, road: []const u8, at: Coord };

pub const Service = struct {
    no: []const u8,
    name: []const u8,
    /// Each direction's stops, as indices into `stops`.
    dirs: []const []const u16,
    /// Each direction's line, Google-encoded.
    lines: []const []const u8,
};

/// A service calling at a stop: which, in which direction, how far along.
pub const Visit = struct { svc: u16, dir: u8, pos: u16 };

pub const Data = struct {
    arena: std.heap.ArenaAllocator,
    stops: []Stop,
    services: []Service,
    /// Per stop, the services that call there.
    visits: []const []const Visit,
    /// Stops by grid cell (`cell` degrees, about 450 m), for `near`.
    grid: std.AutoHashMapUnmanaged(u32, std.ArrayList(u16)) = .empty,

    pub fn load(gpa: std.mem.Allocator) !*Data {
        const d = try gpa.create(Data);
        d.arena = .init(gpa);
        const a = d.arena.allocator();
        const sj = try std.json.parseFromSliceLeaky(std.json.Value, a, @embedFile("data/stops.min.json"), .{});
        const keys = sj.object.keys();
        d.stops = try a.alloc(Stop, keys.len);
        var by_code: std.StringHashMapUnmanaged(u16) = .empty;
        for (keys, sj.object.values(), 0..) |k, v, i| {
            const f = v.array.items;
            d.stops[i] = .{ .code = k, .name = f[2].string, .road = f[3].string, .at = .{ .lat = num(f[1]), .lng = num(f[0]) } };
            try by_code.put(a, k, @intCast(i));
        }
        const vj = try std.json.parseFromSliceLeaky(std.json.Value, a, @embedFile("data/services.min.json"), .{});
        const lj = try std.json.parseFromSliceLeaky(std.json.Value, a, @embedFile("data/routes.min.json"), .{});
        d.services = try a.alloc(Service, vj.object.count());
        const lists = try a.alloc(std.ArrayList(Visit), d.stops.len);
        @memset(lists, .empty);
        for (vj.object.keys(), vj.object.values(), 0..) |no, v, si| {
            const routes = v.object.get("routes").?.array.items;
            const dirs = try a.alloc([]const u16, routes.len);
            for (routes, 0..) |r, di| {
                const out = try a.alloc(u16, r.array.items.len);
                var n: usize = 0;
                for (r.array.items) |code| if (by_code.get(code.string)) |idx| {
                    out[n] = idx;
                    try lists[idx].append(a, .{ .svc = @intCast(si), .dir = @intCast(di), .pos = @intCast(n) });
                    n += 1;
                };
                dirs[di] = out[0..n];
            }
            var lines: []const []const u8 = &.{};
            if (lj.object.get(no)) |l| {
                const ls = try a.alloc([]const u8, l.array.items.len);
                for (l.array.items, 0..) |p, i| ls[i] = p.string;
                lines = ls;
            }
            d.services[si] = .{ .no = no, .name = v.object.get("name").?.string, .dirs = dirs, .lines = lines };
        }
        const visits = try a.alloc([]const Visit, d.stops.len);
        for (lists, 0..) |l, i| visits[i] = l.items;
        d.visits = visits;
        d.grid = .empty;
        for (d.stops, 0..) |st, i| {
            const g = try d.grid.getOrPut(a, cellOf(st.at, 0, 0));
            if (!g.found_existing) g.value_ptr.* = .empty;
            try g.value_ptr.append(a, @intCast(i));
        }
        return d;
    }

    pub fn deinit(d: *Data, gpa: std.mem.Allocator) void {
        d.arena.deinit();
        gpa.destroy(d);
    }

    pub fn find(d: *const Data, code: []const u8) ?u16 {
        // Codes are sorted in the file; a linear pass is quick enough.
        for (d.stops, 0..) |s, i| if (std.mem.eql(u8, s.code, code)) return @intCast(i);
        return null;
    }

    pub fn service(d: *const Data, no: []const u8) ?u16 {
        for (d.services, 0..) |s, i| if (std.mem.eql(u8, s.no, no)) return @intCast(i);
        return null;
    }

    /// The `out.len` nearest stops within `radius` meters, nearest first.
    pub fn nearest(d: *const Data, at: Coord, radius: f64, out: []u16) []u16 {
        var dist: [32]f64 = undefined;
        var n: usize = 0;
        for (d.stops, 0..) |s, i| {
            const m = meters(at, s.at);
            if (m > radius) continue;
            var j = n;
            if (n < out.len) n += 1 else if (m >= dist[n - 1]) continue else j = n - 1;
            while (j > 0 and dist[j - 1] > m) : (j -= 1) {
                dist[j] = dist[j - 1];
                out[j] = out[j - 1];
            }
            dist[j] = m;
            out[j] = @intCast(i);
        }
        return out[0..n];
    }

    /// Stops within `radius` meters (at most a cell, ~450 m), unordered.
    pub fn near(d: *const Data, at: Coord, radius: f64, out: []Near) []Near {
        var n: usize = 0;
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const list = d.grid.get(cellOf(at, dy, dx)) orelse continue;
                for (list.items) |i| {
                    const m = meters(at, d.stops[i].at);
                    if (m > radius or n == out.len) continue;
                    out[n] = .{ .stop = i, .m = m };
                    n += 1;
                }
            }
        }
        return out[0..n];
    }

    /// Stops whose name has `q` in it (any case), up to `out.len`.
    pub fn search(d: *const Data, q: []const u8, out: []u16) []u16 {
        var n: usize = 0;
        if (q.len < 2) return out[0..0];
        for (d.stops, 0..) |s, i| {
            if (n == out.len) break;
            if (contains(s.name, q)) {
                out[n] = @intCast(i);
                n += 1;
            }
        }
        return out[0..n];
    }
};

fn contains(hay: []const u8, q: []const u8) bool {
    if (q.len > hay.len) return false;
    for (0..hay.len - q.len + 1) |i| if (std.ascii.eqlIgnoreCase(hay[i..][0..q.len], q)) return true;
    return false;
}

pub const Near = struct { stop: u16, m: f64 };

const cell = 0.004;

fn cellOf(at: Coord, dy: i32, dx: i32) u32 {
    const y: i32 = @as(i32, @intFromFloat(@floor((at.lat + 5) / cell))) + dy;
    const x: i32 = @as(i32, @intFromFloat(@floor(at.lng / cell))) + dx;
    return @bitCast(y *% 100000 +% x);
}

fn num(v: std.json.Value) f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => 0,
    };
}

/// Meters between two points (flat earth: fine across a city).
pub fn meters(a: Coord, b: Coord) f64 {
    const r = std.math.pi / 180.0;
    const x = (b.lng - a.lng) * r * @cos((a.lat + b.lat) / 2 * r);
    const y = (b.lat - a.lat) * r;
    return 6371000 * @sqrt(x * x + y * y);
}

/// Decodes a Google-encoded polyline (precision 1e5) into `out`.
pub fn decode(gpa: std.mem.Allocator, line: []const u8, out: *std.ArrayList(Coord)) !void {
    out.clearRetainingCapacity();
    var i: usize = 0;
    var lat: i64 = 0;
    var lng: i64 = 0;
    while (i < line.len) {
        lat += varint(line, &i) orelse return;
        lng += varint(line, &i) orelse return;
        try out.append(gpa, .{ .lat = @as(f64, @floatFromInt(lat)) / 1e5, .lng = @as(f64, @floatFromInt(lng)) / 1e5 });
    }
}

fn varint(s: []const u8, i: *usize) ?i64 {
    var result: i64 = 0;
    var shift: u6 = 0;
    while (i.* < s.len) {
        const b: i64 = @as(i64, s[i.*]) - 63;
        i.* += 1;
        result |= (b & 0x1f) << shift;
        if (b < 0x20) return if (result & 1 != 0) ~(result >> 1) else result >> 1;
        shift += 5;
        if (shift > 60) return null;
    }
    return null;
}

test "decode" {
    var out: std.ArrayList(Coord) = .empty;
    defer out.deinit(std.testing.allocator);
    try decode(std.testing.allocator, "_p~iF~ps|U_ulLnnqC_mqNvxq`@", &out);
    try std.testing.expectEqual(3, out.items.len);
    try std.testing.expectApproxEqAbs(38.5, out.items[0].lat, 1e-6);
    try std.testing.expectApproxEqAbs(-120.2, out.items[0].lng, 1e-6);
    try std.testing.expectApproxEqAbs(43.252, out.items[2].lat, 1e-6);
}
