//! OneMap's public-transport routing (`routingsvc/route`, routeType pt):
//! bus and MRT together, up to three itineraries. It needs an account's
//! token in the Authorization header, so the app asks it only when one
//! is given at run time (ONEMAP_TOKEN in the environment, for a test run;
//! a server of ours, for a shipped app) and never stores or prints it.
//! Without one, or when OneMap answers anything but 200 (a 429 when rate
//! limited), the Journey tab plans by bus on the phone (raptor.zig).
const std = @import("std");
/// Its own (lat, lng), the same as nanoui.map.Coord, so this file tests alone:
/// `zig test examples/sgbus/onemap.zig`.
pub const Coord = struct { lat: f64, lng: f64 };

pub const Mode = enum { walk, bus, subway, tram, other };

pub const Place = struct {
    name: [48]u8 = undefined,
    name_len: u8 = 0,
    code: [8]u8 = undefined,
    code_len: u8 = 0,
    at: ?Coord = null,

    pub fn nameOf(p: *const Place) []const u8 {
        return p.name[0..p.name_len];
    }
    pub fn codeOf(p: *const Place) []const u8 {
        return p.code[0..p.code_len];
    }
};

pub const Leg = struct {
    mode: Mode,
    /// The bus service ("15") or the MRT line ("NE").
    route: [8]u8 = undefined,
    route_len: u8 = 0,
    from: Place = .{},
    to: Place = .{},
    seconds: f64 = 0,
    meters: f64 = 0,

    pub fn routeOf(l: *const Leg) []const u8 {
        return l.route[0..l.route_len];
    }
};

pub const Itinerary = struct {
    /// Riding, walking and waiting from its first leg; the app makes it
    /// door to door (from asking) with `fromAsking`.
    seconds: f64 = 0,
    /// When it gets there, epoch milliseconds (0 if not given).
    end_ms: f64 = 0,
    walk_m: f64 = 0,
    transfers: u32 = 0,
    fare: [8]u8 = undefined,
    fare_len: u8 = 0,
    legs: [10]Leg = undefined,
    n: u8 = 0,

    /// Whether it rides a bus or train at all.
    pub fn rides(it: *const Itinerary) bool {
        for (it.legs[0..it.n]) |l| if (l.mode != .walk) return true;
        return false;
    }

    pub fn fareOf(it: *const Itinerary) []const u8 {
        return it.fare[0..it.fare_len];
    }

    /// Door to door from asking at `asked_ms`: its first leg can start a
    /// few minutes later (a train or bus not yet due), which `duration`
    /// leaves out.
    pub fn fromAsking(it: *Itinerary, asked_ms: f64) void {
        if (it.end_ms > asked_ms) it.seconds = @max(it.seconds, (it.end_ms - asked_ms) / 1000);
    }
};

/// A moment as OneMap's request wants it, in Singapore time (UTC+8).
pub const When = struct {
    /// MM-DD-YYYY.
    date: [10]u8,
    /// HH:MM:SS.
    time: [8]u8,
};

/// `epoch_ms` (Unix milliseconds) as a Singapore date and time.
pub fn when(epoch_ms: i64) When {
    const s = @divFloor(epoch_ms, 1000) + 8 * 3600;
    const days = @divFloor(s, 86400);
    const t: u32 = @intCast(@mod(s, 86400));
    // Days to a civil date (Howard Hinnant's algorithm).
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe: i64 = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const y: u32 = @intCast(yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0));
    var w: When = undefined;
    _ = std.fmt.bufPrint(&w.date, "{d:0>2}-{d:0>2}-{d:0>4}", .{ m, d, y }) catch unreachable;
    _ = std.fmt.bufPrint(&w.time, "{d:0>2}:{d:0>2}:{d:0>2}", .{ t / 3600, t / 60 % 60, t % 60 }) catch unreachable;
    return w;
}

/// The request's URL, for leaving at `date` (MM-DD-YYYY) `time` (HH:MM:SS).
pub fn url(buf: []u8, from: Coord, to: Coord, date: []const u8, time: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "https://www.onemap.gov.sg/api/public/routingsvc/route?start={d:.6},{d:.6}&end={d:.6},{d:.6}&routeType=pt&date={s}&time={s}&mode=TRANSIT&maxWalkDistance=800&numItineraries=3", .{ from.lat, from.lng, to.lat, to.lng, date, time });
}

/// The itineraries in an answer, up to `out.len`.
pub fn parse(gpa: std.mem.Allocator, body: []const u8, out: []Itinerary) ![]Itinerary {
    const p = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer p.deinit();
    const plan = p.value.object.get("plan") orelse return error.NoPlan;
    const list = (plan.object.get("itineraries") orelse return error.NoPlan).array.items;
    var n: usize = 0;
    for (list) |v| {
        if (n == out.len) break;
        var it: Itinerary = .{ .seconds = num(v, "duration"), .end_ms = num(v, "endTime"), .walk_m = num(v, "walkDistance"), .transfers = @intFromFloat(@max(0, num(v, "transfers"))) };
        // A fare only when it is one: OneMap says "info unavailable" for some.
        const fare = str(v, "fare");
        if (std.fmt.parseFloat(f64, fare)) |_| copy(&it.fare, &it.fare_len, fare) else |_| {}
        const legs = (v.object.get("legs") orelse continue).array.items;
        for (legs) |l| {
            if (it.n == it.legs.len) break;
            const m = str(l, "mode");
            var leg: Leg = .{
                .mode = if (eq(m, "WALK")) .walk else if (eq(m, "BUS")) .bus else if (eq(m, "SUBWAY")) .subway else if (eq(m, "TRAM")) .tram else .other,
                .seconds = num(l, "duration"),
                .meters = num(l, "distance"),
            };
            copy(&leg.route, &leg.route_len, str(l, "route"));
            if (l.object.get("from")) |f| leg.from = place(f);
            if (l.object.get("to")) |t| leg.to = place(t);
            it.legs[it.n] = leg;
            it.n += 1;
        }
        // After the last train OneMap answers with a walk the whole way
        // (13 km, 160 minutes): not a way by bus or train.
        if (!it.rides()) continue;
        out[n] = it;
        n += 1;
    }
    return out[0..n];
}

fn place(v: std.json.Value) Place {
    var p: Place = .{};
    copy(&p.name, &p.name_len, str(v, "name"));
    copy(&p.code, &p.code_len, str(v, "stopCode"));
    if (v.object.get("lat") != null and v.object.get("lon") != null) p.at = .{ .lat = num(v, "lat"), .lng = num(v, "lon") };
    return p;
}

fn copy(buf: anytype, len: *u8, s: []const u8) void {
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    len.* = @intCast(n);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn str(v: std.json.Value, k: []const u8) []const u8 {
    const x = v.object.get(k) orelse return "";
    return if (x == .string) x.string else "";
}

fn num(v: std.json.Value, k: []const u8) f64 {
    const x = v.object.get(k) orelse return 0;
    return switch (x) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .string => |s| std.fmt.parseFloat(f64, s) catch 0,
        else => 0,
    };
}

/// An MRT line's colour, by its code (LTA's line colours).
pub fn lineColor(code: []const u8) u24 {
    const lines = [_]struct { []const u8, u24 }{ .{ "EW", 0x009645 }, .{ "CG", 0x009645 }, .{ "NS", 0xD42E12 }, .{ "NE", 0x9900AA }, .{ "CC", 0xFA9E0D }, .{ "CE", 0xFA9E0D }, .{ "DT", 0x005EC4 }, .{ "TE", 0x9D5B25 } };
    for (lines) |l| if (eq(code, l[0])) return l[1];
    return 0x748477; // LRT grey
}

test "parse OneMap's documented sample" {
    var out: [3]Itinerary = undefined;
    const got = try parse(std.testing.allocator, @embedFile("fixtures/onemap-docs-sample.json"), &out);
    try std.testing.expectEqual(1, got.len);
    const it = got[0];
    try std.testing.expectEqual(2238, it.seconds);
    try std.testing.expectEqualStrings("1.77", it.fareOf());
    try std.testing.expectEqual(3, it.n);
    try std.testing.expectEqual(Mode.walk, it.legs[0].mode);
    try std.testing.expectEqual(Mode.subway, it.legs[1].mode);
    try std.testing.expectEqualStrings("NE", it.legs[1].routeOf());
    try std.testing.expectEqualStrings("NE8", it.legs[1].from.codeOf());
    try std.testing.expectEqualStrings("HARBOURFRONT MRT STATION", it.legs[1].to.nameOf());
    try std.testing.expectEqualStrings("CC", it.legs[2].routeOf());
    try std.testing.expect(it.legs[2].to.at == null);
}

test "when: Singapore date and time for OneMap" {
    // 2026-11-03 02:00:00 UTC is 10:00 in Singapore.
    const w = when(1793671200000);
    try std.testing.expectEqualStrings("11-03-2026", &w.date);
    try std.testing.expectEqualStrings("10:00:00", &w.time);
    // 16:30 UTC on 31 Dec is past midnight in Singapore.
    const n = when(1798734600000);
    try std.testing.expectEqualStrings("01-01-2027", &n.date);
    try std.testing.expectEqualStrings("00:30:00", &n.time);
}

test "a fare that is not one is left out, and minutes count from asking" {
    const body =
        \\{"plan":{"itineraries":[{"duration":1200,"endTime":1793672700000,"walkDistance":300.5,"transfers":0,"fare":"info unavailable","legs":[{"mode":"BUS","route":"15","duration":1200,"distance":5000}]}]}}
    ;
    var out: [3]Itinerary = undefined;
    const got = try parse(std.testing.allocator, body, &out);
    try std.testing.expectEqual(0, got[0].fare_len);
    // Asked at 10:00, there at 10:25: 25 minutes, not the 20 it rides.
    got[0].fromAsking(1793671200000);
    try std.testing.expectEqual(1500, got[0].seconds);
}

test "a walk the whole way is not a OneMap way" {
    const body =
        \\{"plan":{"itineraries":[{"duration":9810,"walkDistance":13624,"transfers":0,"fare":"0.00","legs":[{"mode":"WALK","route":"","duration":9810,"distance":13624}]}]}}
    ;
    var out: [3]Itinerary = undefined;
    try std.testing.expectEqual(0, (try parse(std.testing.allocator, body, &out)).len);
}
