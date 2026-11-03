//! Walking directions: on iOS, MapKit's (MKDirections with a walking
//! transport type), as a line along the paths and the turns to take,
//! each with Apple's words ("Turn left onto Jurong Gateway Rd") and how
//! far it runs. Elsewhere, or when MapKit can't route, `done` gets null
//! and the app falls back to its own estimate.
//!
//!     nanoui.directions.walking(gpa, here, stop, s, gotWalk);
//!     fn gotWalk(s: *Trip, r: ?nanoui.directions.Route) void { ... }
//!
//! The route is the caller's: `deinit` it with the same allocator.
const std = @import("std");
const builtin = @import("builtin");
const Coord = @import("map.zig").Coord;
const ios = builtin.os.tag == .ios;
const native = if (ios) @import("../ios/directions.zig") else struct {};

pub const Step = struct {
    /// Apple's words for the turn; empty for the first step (the start).
    text: []const u8,
    /// Meters walked on this step.
    meters: f64,
    /// Where the step starts (the turn) and ends.
    at: Coord,
    end: Coord,
};

pub const Route = struct {
    /// The whole walk, start to end, along paths.
    points: []Coord,
    steps: []Step,
    meters: f64,
    /// Apple's walking time.
    seconds: f64,

    pub fn deinit(r: *Route, gpa: std.mem.Allocator) void {
        for (r.steps) |st| gpa.free(st.text);
        gpa.free(r.steps);
        gpa.free(r.points);
        r.* = undefined;
    }
};

/// Asks for a walk from `from` to `to`, and calls `done(ctx, route)` on
/// the main thread with it, or with null if there is none.
pub fn walking(gpa: std.mem.Allocator, from: Coord, to: Coord, ctx: anytype, comptime done: fn (@TypeOf(ctx), ?Route) void) void {
    const Ctx = @TypeOf(ctx);
    const Wrap = struct {
        fn call(p: *anyopaque, r: ?Route) void {
            done(@as(Ctx, @ptrCast(@alignCast(p))), r);
        }
    };
    if (!ios) return done(ctx, null);
    native.walking(gpa, from, to, @ptrCast(ctx), Wrap.call);
}

/// A route from `points` and `steps` as MapKit gives them, owned by `gpa`
/// (shared with the iOS side, and testable here).
pub fn build(gpa: std.mem.Allocator, points: []const Coord, steps: []const Step, seconds: f64) !Route {
    const pts = try gpa.dupe(Coord, points);
    errdefer gpa.free(pts);
    const out = try gpa.alloc(Step, steps.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |st| gpa.free(st.text);
        gpa.free(out);
    }
    var meters: f64 = 0;
    for (steps) |st| {
        out[n] = st;
        out[n].text = try gpa.dupe(u8, st.text);
        n += 1;
        meters += st.meters;
    }
    return .{ .points = pts, .steps = out, .meters = meters, .seconds = seconds };
}

test "no MapKit here: walking says there is no route" {
    if (ios) return error.SkipZigTest;
    const S = struct {
        var got: ?bool = null;
        fn done(_: *u8, r: ?Route) void {
            got = r != null;
        }
    };
    var x: u8 = 0;
    walking(std.testing.allocator, .{ .lat = 1.3, .lng = 103.8 }, .{ .lat = 1.31, .lng = 103.81 }, &x, S.done);
    try std.testing.expectEqual(@as(?bool, false), S.got);
}

test "a built route owns its words and sums its meters" {
    const gpa = std.testing.allocator;
    var words = "Turn left onto Jurong Gateway Rd".*;
    const pts = [_]Coord{ .{ .lat = 1.333, .lng = 103.742 }, .{ .lat = 1.334, .lng = 103.743 } };
    const steps = [_]Step{
        .{ .text = "", .meters = 0, .at = pts[0], .end = pts[0] },
        .{ .text = &words, .meters = 120, .at = pts[0], .end = pts[1] },
    };
    var r = try build(gpa, &pts, &steps, 90);
    defer r.deinit(gpa);
    words[0] = 'X';
    try std.testing.expectEqualStrings("Turn left onto Jurong Gateway Rd", r.steps[1].text);
    try std.testing.expectEqual(@as(f64, 120), r.meters);
}
