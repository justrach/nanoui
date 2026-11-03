//! MKDirections for `nanoui.directions` on iOS: a walking request from a
//! placemark to a placemark; MapKit calls the completion block on the
//! main thread, where the first route's polyline and steps are copied.
const std = @import("std");
const objc = @import("../objc.zig");
const api = @import("../basics/directions.zig");
const Coord = @import("../basics/map.zig").Coord;

const Coordinate = extern struct { lat: f64, lng: f64 };
const NSRange = extern struct { location: objc.NSUInteger, length: objc.NSUInteger };
/// MKDirectionsTransportType.walking.
const walking_type: objc.NSUInteger = 1 << 1;

const Pending = struct {
    gpa: std.mem.Allocator,
    ctx: *anyopaque,
    done: *const fn (*anyopaque, ?api.Route) void,
    directions: objc.Object,

    fn answered(p: *Pending, response: ?objc.Object, err: ?objc.Object) void {
        _ = err;
        const pool = objc.Pool.push();
        defer pool.pop();
        const r = if (response) |res| read(p.gpa, res) else null;
        objc.release(p.directions);
        const ctx = p.ctx;
        const done = p.done;
        p.gpa.destroy(p);
        done(ctx, r);
    }
};

fn item(at: Coord) objc.Object {
    const c: Coordinate = .{ .lat = at.lat, .lng = at.lng };
    const pm = objc.msg(objc.Object, objc.alloc("MKPlacemark"), "initWithCoordinate:", .{c});
    defer objc.release(pm);
    const it = objc.msg(objc.Object, objc.alloc("MKMapItem"), "initWithPlacemark:", .{pm});
    objc.autorelease(it);
    return it;
}

pub fn walking(gpa: std.mem.Allocator, from: Coord, to: Coord, ctx: *anyopaque, done: *const fn (*anyopaque, ?api.Route) void) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const req = objc.new("MKDirectionsRequest");
    defer objc.release(req);
    objc.msg(void, req, "setSource:", .{item(from)});
    objc.msg(void, req, "setDestination:", .{item(to)});
    objc.msg(void, req, "setTransportType:", .{walking_type});
    objc.msg(void, req, "setRequestsAlternateRoutes:", .{objc.NO});
    const p = gpa.create(Pending) catch return done(ctx, null);
    const dirs = objc.msg(objc.Object, objc.alloc("MKDirections"), "initWithRequest:", .{req});
    p.* = .{ .gpa = gpa, .ctx = ctx, .done = done, .directions = dirs };
    // MapKit copies the block (and with it `p`).
    var block = objc.Block(Pending, &.{ ?objc.Object, ?objc.Object }).init(p, Pending.answered);
    objc.msg(void, dirs, "calculateDirectionsWithCompletionHandler:", .{@as(*anyopaque, @ptrCast(&block))});
}

fn coords(gpa: std.mem.Allocator, poly: objc.Object) ![]Coord {
    const n = objc.msg(objc.NSUInteger, poly, "pointCount", .{});
    const raw = try gpa.alloc(Coordinate, n);
    defer gpa.free(raw);
    objc.msg(void, poly, "getCoordinates:range:", .{ @as(*anyopaque, @ptrCast(raw.ptr)), NSRange{ .location = 0, .length = n } });
    const out = try gpa.alloc(Coord, n);
    for (raw, out) |c, *o| o.* = .{ .lat = c.lat, .lng = c.lng };
    return out;
}

fn read(gpa: std.mem.Allocator, res: objc.Object) ?api.Route {
    const routes = objc.msg(objc.Object, res, "routes", .{});
    if (objc.msg(objc.NSUInteger, routes, "count", .{}) == 0) return null;
    const route = objc.msg(objc.Object, routes, "firstObject", .{});
    const points = coords(gpa, objc.msg(objc.Object, route, "polyline", .{})) catch return null;
    defer gpa.free(points);
    const list = objc.msg(objc.Object, route, "steps", .{});
    const n = objc.msg(objc.NSUInteger, list, "count", .{});
    var steps: std.ArrayList(api.Step) = .empty;
    defer {
        for (steps.items) |st| gpa.free(st.text);
        steps.deinit(gpa);
    }
    for (0..n) |i| {
        const st = objc.msg(objc.Object, list, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
        const pts = coords(gpa, objc.msg(objc.Object, st, "polyline", .{})) catch return null;
        defer gpa.free(pts);
        if (pts.len == 0) continue;
        // UTF8String's bytes can go with the next autorelease: copy them now.
        const words = gpa.dupe(u8, objc.fromNSString(objc.msg(?objc.Object, st, "instructions", .{}))) catch return null;
        steps.append(gpa, .{
            .text = words,
            .meters = objc.msg(f64, st, "distance", .{}),
            .at = pts[0],
            .end = pts[pts.len - 1],
        }) catch {
            gpa.free(words);
            return null;
        };
    }
    return api.build(gpa, points, steps.items, objc.msg(f64, route, "expectedTravelTime", .{})) catch null;
}
