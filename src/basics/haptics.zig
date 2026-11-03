//! Taps of the haptic engine, as UIKit's feedback generators make them:
//! an impact (a card snapping into place, a pull passing its threshold),
//! a selection tick (a picker, a star toggled) and a notification (done,
//! a warning, a failure). Nothing on platforms without one.
const std = @import("std");
const builtin = @import("builtin");
const ios = builtin.os.tag == .ios;
const objc = if (ios) @import("../objc.zig") else struct {};

pub const Impact = enum(c_long) { light = 0, medium = 1, heavy = 2, soft = 3, rigid = 4 };
pub const Notice = enum(c_long) { success = 0, warning = 1, failure = 2 };

/// A physical tap of `weight`.
pub fn impact(weight: Impact) void {
    if (!ios) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const g = objc.msg(objc.Object, objc.alloc("UIImpactFeedbackGenerator"), "initWithStyle:", .{@as(objc.NSInteger, @intFromEnum(weight))});
    defer objc.release(g);
    objc.msg(void, g, "impactOccurred", .{});
}

/// The light tick of a selection changing.
pub fn selection() void {
    if (!ios) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const g = objc.new("UISelectionFeedbackGenerator");
    defer objc.release(g);
    objc.msg(void, g, "selectionChanged", .{});
}

/// A task's outcome: success, a warning, a failure.
pub fn notify(n: Notice) void {
    if (!ios) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const g = objc.new("UINotificationFeedbackGenerator");
    defer objc.release(g);
    objc.msg(void, g, "notificationOccurred:", .{@as(objc.NSInteger, @intFromEnum(n))});
}

test "no haptic engine: calls do nothing" {
    if (ios) return error.SkipZigTest;
    impact(.medium);
    selection();
    notify(.success);
}
