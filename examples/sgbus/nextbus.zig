//! The next buses and trains in turn by turn, as plain numbers so they
//! can be tested: which bus you can still catch from how long the walk
//! to the stop is, the words for the next few, and whether trains run at
//! a time of day (the phone's clock, not a live board's).
const std = @import("std");
const rail = @import("rail.zig");
const data = @import("data.zig");

/// Up to three buses, minutes away now (null: not listed).
pub const Mins = [3]?f64;

/// The first bus still there when you get to the stop `walk` minutes
/// from now; null if every listed bus leaves before then.
pub fn catchable(m: Mins, walk: f64) ?usize {
    for (m, 0..) |x, i| if (x) |v| if (v >= walk - 0.25) return i;
    return null;
}

/// How many listed buses (still to come) there are.
pub fn count(m: Mins) usize {
    var n: usize = 0;
    for (m) |x| if (x) |v| {
        if (v > -1) n += 1;
    };
    return n;
}

/// "Arriving" at a minute or less, else "3 min".
pub fn one(buf: []u8, v: f64) []const u8 {
    if (v <= 1) return "Arriving";
    return std.fmt.bufPrint(buf, "{d} min", .{@as(u32, @intFromFloat(@floor(v)))}) catch "";
}

/// "133 in 3 min, then 11 min, 19 min"; "133 Arriving, then 9 min".
pub fn line(buf: []u8, no: []const u8, m: Mins) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var n: usize = 0;
    for (m) |x| if (x) |v| {
        if (v <= -1) continue;
        var b: [16]u8 = undefined;
        const t = one(&b, v);
        if (n == 0) {
            if (v <= 1) w.print("{s} arriving", .{no}) catch break else w.print("{s} in {s}", .{ no, t }) catch break;
        } else w.print("{s}{s}", .{ if (n == 1) ", then " else ", ", t }) catch break;
        n += 1;
    };
    return w.buffered();
}

/// What a missed bus and the one to catch say: "The 3 min bus leaves
/// before you get there (5 min walk). Catch the 11 min one."
pub fn missLine(buf: []u8, m: Mins, walk: f64) ?[]const u8 {
    const first = for (m) |x| {
        if (x) |v| if (v > -1) break v;
    } else return null;
    if (first >= walk - 0.25) return null;
    var a: [16]u8 = undefined;
    const walk_m: u32 = @intFromFloat(@ceil(walk));
    const k = catchable(m, walk) orelse
        return std.fmt.bufPrint(buf, "The listed buses leave before you get there ({d} min walk)", .{walk_m}) catch null;
    var b: [16]u8 = undefined;
    return std.fmt.bufPrint(buf, "The {s} bus leaves before you get there ({d} min walk). Catch the {s} one", .{ lower(&a, one(&a, first)), walk_m, lower(&b, one(&b, m[k].?)) }) catch null;
}

fn lower(buf: []u8, t: []const u8) []const u8 {
    if (std.mem.eql(u8, t, "Arriving")) return "arriving";
    _ = buf;
    return t;
}

/// The wall clock in Singapore (UTC+8, no daylight saving) from epoch
/// seconds: seconds since midnight, and whether it's a weekday.
pub const Clock = struct { secs: f64, weekday: bool };

pub fn sgClock(epoch_s: f64) Clock {
    const local = epoch_s + 8 * 3600;
    const days = @floor(local / 86400);
    // 1 January 1970 was a Thursday (0 = Sunday).
    const dow: u32 = @intFromFloat(@mod(days + 4, 7));
    return .{ .secs = local - days * 86400, .weekday = dow != 0 and dow != 6 };
}

/// "HH:MM" or "H:MM": seconds since midnight.
pub fn parseHm(t: []const u8) ?f64 {
    const i = std.mem.indexOfScalar(u8, t, ':') orelse return null;
    const h = std.fmt.parseInt(u32, t[0..i], 10) catch return null;
    const m = std.fmt.parseInt(u32, t[i + 1 ..], 10) catch return null;
    if (h > 23 or m > 59) return null;
    return @floatFromInt(h * 3600 + m * 60);
}

/// Trains at a time of day (seconds since midnight): running, about
/// every `every` minutes, or not until the first train.
pub const Trains = union(enum) {
    every: f64,
    closed: f64,
};

pub fn trains(l: *const data.Line, secs: f64, peak: bool) Trains {
    const min = @mod(secs / 60, 24 * 60);
    if (!rail.open(min)) return .{ .closed = rail.first_min };
    return .{ .every = rail.headway(l, peak) };
}

/// "05:30" for minutes since midnight.
pub fn hm(buf: []u8, min: f64) []const u8 {
    const t: u32 = @intFromFloat(@mod(@round(min), 24 * 60));
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ t / 60, t % 60 }) catch "";
}

const testing = std.testing;

test "the bus you can catch: the first still there when you get there" {
    try testing.expectEqual(@as(?usize, 0), catchable(.{ 3, 11, 19 }, 2));
    try testing.expectEqual(@as(?usize, 1), catchable(.{ 3, 11, 19 }, 5));
    try testing.expectEqual(@as(?usize, 2), catchable(.{ 3, 11, 19 }, 15));
    try testing.expectEqual(@as(?usize, null), catchable(.{ 3, 11, 19 }, 25));
    try testing.expectEqual(@as(?usize, 1), catchable(.{ 3, 6, null }, 5));
    try testing.expectEqual(@as(?usize, null), catchable(.{ null, null, null }, 1));
}

test "next buses in words" {
    var b: [96]u8 = undefined;
    try testing.expectEqualStrings("133 in 3 min, then 11 min, 19 min", line(&b, "133", .{ 3.4, 11.9, 19 }));
    try testing.expectEqualStrings("133 arriving, then 9 min", line(&b, "133", .{ 0.6, 9.2, null }));
    try testing.expectEqualStrings("66 in 4 min", line(&b, "66", .{ 4, null, null }));
    try testing.expectEqualStrings("", line(&b, "66", .{ null, null, null }));
    var m: [128]u8 = undefined;
    try testing.expectEqualStrings("The 3 min bus leaves before you get there (5 min walk). Catch the 11 min one", missLine(&m, .{ 3, 11, 19 }, 4.2).?);
    try testing.expect(missLine(&m, .{ 6, 11, 19 }, 4.2) == null);
    try testing.expectEqualStrings("The listed buses leave before you get there (25 min walk)", missLine(&m, .{ 3, 11, 19 }, 25).?);
}

test "the phone's clock in Singapore time" {
    // 2026-11-01T02:30:00Z is 10:30 on a Sunday in Singapore.
    const sun = sgClock(1793500200);
    try testing.expectEqual(@as(f64, 10 * 3600 + 30 * 60), sun.secs);
    try testing.expect(!sun.weekday);
    // 2026-11-01T19:00:00Z is 03:00 on Monday 2 November.
    const mon = sgClock(1793559600);
    try testing.expectEqual(@as(f64, 3 * 3600), mon.secs);
    try testing.expect(mon.weekday);
    try testing.expectEqual(@as(?f64, 3 * 3600), parseHm("03:00"));
    try testing.expectEqual(@as(?f64, 23 * 3600 + 50 * 60), parseHm("23:50"));
    try testing.expect(parseHm("25:00") == null and parseHm("3") == null);
}

test "no trains between the last and first train" {
    const l: data.Line = .{ .id = "EWL", .name = "East West Line", .color = 0x009645, .vmax = 80, .km = &.{} };
    try testing.expectEqual(Trains{ .every = 5 }, trains(&l, 10 * 3600, false));
    try testing.expectEqual(Trains{ .every = 2.5 }, trains(&l, 8 * 3600, true));
    try testing.expectEqual(Trains{ .closed = rail.first_min }, trains(&l, 3 * 3600, false));
    try testing.expectEqual(Trains{ .closed = rail.first_min }, trains(&l, 23 * 3600 + 50 * 60, false));
    try testing.expectEqual(Trains{ .every = 5 }, trains(&l, 5 * 3600 + 30 * 60, false));
    var b: [8]u8 = undefined;
    try testing.expectEqualStrings("05:30", hm(&b, rail.first_min));
}
