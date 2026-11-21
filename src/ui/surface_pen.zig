//! A Mac pen's tablet fields into `Input.pen`. A tablet's driver (Wacom's,
//! a pen display's) reports the pen as mouse events whose subtype is a
//! tablet point, with pressure, tilt, rotation and the barrel buttons on
//! the event; pure tablet-point events (pressure changed, no move) and
//! proximity events (the pen came near or left, and which end) come to
//! `tabletPoint:` and `tabletProximity:`.
const objc = @import("../objc.zig");
const input = @import("input.zig");
const pen = @import("pen.zig");
const Surface = @import("surface.zig").Surface;

pub const methods = [_]objc.Method{
    .{ .name = "tabletPoint:", .imp = &tabletPoint, .types = "v@:@" },
    .{ .name = "tabletProximity:", .imp = &tabletProximity, .types = "v@:@" },
};

// NSEventType and NSEventSubtype values.
const tablet_point_type = 23;
const tablet_point_subtype = 1;
const mouse_subtype = 0;
// NSPointingDeviceType.
const eraser_device = 3;

/// Reads a pointer event's pen into `in.pen`, or clears it for a mouse's.
/// Other events (the wheel, a pinch) leave it as it was: `subtype` is only
/// defined for mouse and tablet events.
pub fn read(in: *input.Input, event: objc.Object) void {
    const ty = objc.msg(objc.NSUInteger, event, "type", .{});
    const pointer = switch (ty) {
        1...7, 25...27 => true, // the buttons' downs, ups and drags; moves
        tablet_point_type => true,
        else => false,
    };
    if (!pointer) return;
    if (ty != tablet_point_type) {
        const subtype = objc.msg(i16, event, "subtype", .{});
        if (subtype == mouse_subtype) {
            in.pen = null;
            return;
        }
        if (subtype != tablet_point_subtype) return;
    }
    const tilt = objc.msg(objc.CGPoint, event, "tilt", .{});
    in.pen = pen.fromAppKit(
        objc.msg(f32, event, "pressure", .{}),
        objc.msg(f32, event, "tangentialPressure", .{}),
        @floatCast(tilt.x),
        @floatCast(tilt.y),
        objc.msg(f32, event, "rotation", .{}),
        objc.msg(objc.NSUInteger, event, "buttonMask", .{}),
        in.pen_eraser_near,
    );
}

/// Pressure, tilt or the barrel changed with the pen still: a frame while
/// it presses, so a stroke's width follows.
fn tabletPoint(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    read(&s.ctx.input, event);
    if (s.ctx.input.down or s.ctx.wants_moves) {
        if (s.visible()) s.requestFrame() else s.frame();
    }
}

/// The pen came near (which end: `pointingDeviceType`) or went away.
fn tabletProximity(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    const in = &s.ctx.input;
    if (objc.msg(objc.BOOL, event, "isEnteringProximity", .{}) != objc.NO) {
        in.pen_eraser_near = objc.msg(objc.NSUInteger, event, "pointingDeviceType", .{}) == eraser_device;
        if (in.pen) |*p| p.eraser = in.pen_eraser_near;
    } else {
        in.pen_eraser_near = false;
        in.pen = null;
    }
}
