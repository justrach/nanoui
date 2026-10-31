//! Where the device is, from Core Location, while the app is in use: ask
//! once, then fixes arrive as the device moves (every 10 m or so). On iOS
//! the app's Info.plist must say why (`location_usage` in the bundle's
//! options), or iOS refuses without asking. Elsewhere `start` fails with
//! `error.Unsupported`.
//!
//!     s.where = try nanoui.location.start(gpa, s, Nearby.moved);
//!     fn moved(s: *Nearby, l: *nanoui.location.Location) void {
//!         if (l.fix) |f| s.sortBy(f.lat, f.lng);
//!     }
const std = @import("std");
const builtin = @import("builtin");
const ios = builtin.os.tag == .ios;
const objc = if (ios) @import("../objc.zig") else struct {};

pub const Fix = struct {
    lat: f64,
    lng: f64,
    /// Radius of uncertainty, meters.
    accuracy: f64,
};

pub const Error = error{ Unsupported, OutOfMemory };

pub const Permission = enum {
    /// Not asked yet, or the answer is on its way.
    undecided,
    allowed,
    /// Refused, or not allowed here (parental controls).
    denied,
};

pub const Location = struct {
    gpa: std.mem.Allocator,
    /// The latest fix, if any yet.
    fix: ?Fix = null,
    permission: Permission = .undecided,
    /// The last failure Core Location reported, as its error code.
    failed: ?i64 = null,
    ctx: *anyopaque,
    changed: *const fn (*anyopaque, *Location) void,
    manager: if (ios) ?objc.Object else void = if (ios) null else {},
    delegate: if (ios) ?objc.Object else void = if (ios) null else {},

    /// Stops the updates and frees it.
    pub fn stop(l: *Location) void {
        if (ios) {
            if (l.manager) |m| {
                objc.msg(void, m, "stopUpdatingLocation", .{});
                objc.msg(void, m, "setDelegate:", .{@as(?objc.Object, null)});
                objc.release(m);
            }
            if (l.delegate) |d| {
                objc.setZig(d, null);
                objc.release(d);
            }
        }
        l.gpa.destroy(l);
    }
};

/// Starts following the device's location: asks for permission the first
/// time, and calls `changed(ctx, location)` on the main thread with each
/// fix and each change of permission.
pub fn start(gpa: std.mem.Allocator, ctx: anytype, comptime changed: fn (@TypeOf(ctx), *Location) void) Error!*Location {
    if (!ios) return error.Unsupported;
    const Ctx = @TypeOf(ctx);
    const Wrap = struct {
        fn call(p: *anyopaque, l: *Location) void {
            changed(@as(Ctx, @ptrCast(@alignCast(p))), l);
        }
    };
    const l = try gpa.create(Location);
    l.* = .{ .gpa = gpa, .ctx = @ptrCast(ctx), .changed = Wrap.call };
    const pool = objc.Pool.push();
    defer pool.pop();
    defineDelegate();
    const d = objc.msg(objc.Object, objc.alloc("NanouiLocationDelegate"), "init", .{});
    objc.setZig(d, l);
    const m = objc.new("CLLocationManager");
    l.delegate = d;
    l.manager = m;
    objc.msg(void, m, "setDelegate:", .{d});
    objc.msg(void, m, "setDesiredAccuracy:", .{@as(f64, 10)});
    objc.msg(void, m, "setDistanceFilter:", .{@as(f64, 10)});
    readPermission(l, m);
    if (l.permission == .undecided) objc.msg(void, m, "requestWhenInUseAuthorization", .{});
    objc.msg(void, m, "startUpdatingLocation", .{});
    return l;
}

const Coordinate = extern struct { lat: f64, lng: f64 };

fn defineDelegate() void {
    _ = objc.defineClass(.{
        .name = "NanouiLocationDelegate",
        .protocols = &.{"CLLocationManagerDelegate"},
        .methods = &.{
            .{ .name = "locationManager:didUpdateLocations:", .imp = &updated, .types = "v@:@@" },
            .{ .name = "locationManagerDidChangeAuthorization:", .imp = &authorization, .types = "v@:@" },
            .{ .name = "locationManager:didFailWithError:", .imp = &failed, .types = "v@:@@" },
        },
    });
}

fn readPermission(l: *Location, m: objc.Object) void {
    l.permission = switch (objc.msg(c_int, m, "authorizationStatus", .{})) {
        0 => .undecided,
        3, 4 => .allowed,
        else => .denied,
    };
}

fn updated(obj: objc.Object, _: objc.SEL, _: objc.Object, locations: objc.Object) callconv(.c) void {
    const l = objc.getZig(Location, obj) orelse return;
    const last = objc.msg(?objc.Object, locations, "lastObject", .{}) orelse return;
    const c = objc.msg(Coordinate, last, "coordinate", .{});
    l.fix = .{ .lat = c.lat, .lng = c.lng, .accuracy = objc.msg(f64, last, "horizontalAccuracy", .{}) };
    l.failed = null;
    l.changed(l.ctx, l);
}

fn authorization(obj: objc.Object, _: objc.SEL, manager: objc.Object) callconv(.c) void {
    const l = objc.getZig(Location, obj) orelse return;
    const was = l.permission;
    readPermission(l, manager);
    if (l.permission != was) l.changed(l.ctx, l);
}

fn failed(obj: objc.Object, _: objc.SEL, _: objc.Object, err: objc.Object) callconv(.c) void {
    const l = objc.getZig(Location, obj) orelse return;
    l.failed = objc.msg(objc.NSInteger, err, "code", .{});
    l.changed(l.ctx, l);
}

test "no Core Location here: start says so" {
    if (ios) return error.SkipZigTest;
    const S = struct {
        fn moved(_: *u8, _: *Location) void {}
    };
    var x: u8 = 0;
    try std.testing.expectError(error.Unsupported, start(std.testing.allocator, &x, S.moved));
}
