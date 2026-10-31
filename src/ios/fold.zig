//! A foldable's screen on iOS 27.1 (the iPhone Duo): the bands and
//! cut-outs UIKit reserves, from `-[UIView reservedRegionsOfKind:options:]`
//! (`UIViewReservedRegionKind.divisionRegionKind` for the fold,
//! `.occlusionRegionKind` for a camera or the system strip), and the hinge,
//! from a `UIHingeInteraction` whose update handler gives a `UIHinge`'s
//! `status` and `angle`. On an older iOS the classes are missing and the
//! device stays `.none`. Read into `Context.device` (`ui/device.zig`).
const std = @import("std");
const objc = @import("../objc.zig");
const types = @import("../ui/types.zig");
const device = @import("../ui/device.zig");
const Surface = @import("surface.zig").Surface;

extern "c" fn objc_getClass(name: [*:0]const u8) ?objc.Class;

const Insets = extern struct { top: f64, left: f64, bottom: f64, right: f64 };

/// `UIViewReservedRegionQueryOptionIncludeInactive`.
const include_inactive: objc.NSUInteger = 1 << 0;

fn rect(r: objc.CGRect) types.Rect {
    return .{ .x = @floatCast(r.origin.x), .y = @floatCast(r.origin.y), .w = @floatCast(r.size.width), .h = @floatCast(r.size.height) };
}

fn sizeClass(v: objc.NSInteger) device.SizeClass {
    return switch (v) {
        1 => .compact,
        2 => .regular,
        else => .unspecified,
    };
}

/// Reads the regions, size classes and orientation (with the view's
/// geometry: a resize, a rotation, a fold or a tilt).
pub fn read(s: *Surface) void {
    const d = &s.ctx.device;
    const before = d.orientation;
    const traits = objc.msg(objc.Object, s.uiview, "traitCollection", .{});
    d.horizontal = sizeClass(objc.msg(objc.NSInteger, traits, "horizontalSizeClass", .{}));
    d.vertical = sizeClass(objc.msg(objc.NSInteger, traits, "verticalSizeClass", .{}));
    d.size = s.size;
    d.orientation = if (s.size.w > s.size.h) .landscape else .portrait;
    d.region_count = 0;
    if (objc_getClass("UIViewReservedRegionKind")) |kinds| {
        if (objc.msg(objc.BOOL, s.uiview, "respondsToSelector:", .{objc.sel("reservedRegionsOfKind:options:")})) {
            d.foldable = d.foldable or d.hinge != .unknown;
            add(s, objc.msg(objc.Object, kinds, "divisionRegionKind", .{}), .division);
            add(s, objc.msg(objc.Object, kinds, "occlusionRegionKind", .{}), .occlusion);
        }
    }
    d.settle(before);
}

fn add(s: *Surface, kind: objc.Object, as: @FieldType(device.Region, "kind")) void {
    const d = &s.ctx.device;
    const list = objc.msg(?objc.Object, s.uiview, "reservedRegionsOfKind:options:", .{ kind, include_inactive }) orelse return;
    const n = objc.msg(objc.NSUInteger, list, "count", .{});
    var i: objc.NSUInteger = 0;
    while (i < n and d.region_count < device.max_regions) : (i += 1) {
        const r = objc.msg(objc.Object, list, "objectAtIndex:", .{i});
        const m = objc.msg(Insets, r, "margins", .{});
        d.regions[d.region_count] = .{
            .kind = as,
            .rect = rect(objc.msg(objc.CGRect, r, "frame", .{})),
            .margins = .{ .top = @floatCast(m.top), .left = @floatCast(m.left), .bottom = @floatCast(m.bottom), .right = @floatCast(m.right) },
            .active = objc.msg(objc.BOOL, r, "isActive", .{}),
        };
        d.region_count += 1;
    }
}

/// Attaches a `UIHingeInteraction` to the surface's view (iOS 27.1 and on).
pub fn attach(s: *Surface) ?objc.Object {
    const cls = objc_getClass("UIHingeInteraction") orelse return null;
    const Handler = objc.Block(Surface, &.{ objc.Object, objc.Object });
    var block = Handler.init(s, hingeMoved);
    const it = objc.msg(objc.Object, objc.msg(objc.Object, cls, "alloc", .{}), "initWithUpdateHandler:", .{&block});
    objc.msg(void, s.uiview, "addInteraction:", .{it});
    return it;
}

pub fn detach(s: *Surface, it: objc.Object) void {
    objc.msg(void, s.uiview, "removeInteraction:", .{it});
    objc.release(it);
}

fn hingeMoved(s: *Surface, _: objc.Object, update: objc.Object) void {
    if (s.dead) return;
    const d = &s.ctx.device;
    if (objc.msg(?objc.Object, update, "hinge", .{})) |hinge| {
        const st = objc.msg(objc.NSInteger, hinge, "status", .{});
        d.hinge = @enumFromInt(@as(u8, @intCast(std.math.clamp(st, 0, 3))));
        // UIHinge's angle is in radians; Device keeps degrees.
        d.hinge_angle = @floatCast(std.math.radiansToDegrees(objc.msg(f64, hinge, "angle", .{})));
        d.foldable = true;
    } else {
        d.hinge = .unknown;
        d.hinge_angle = null;
    }
    s.depth += 1;
    defer s.leave();
    s.hingeMoved();
}
