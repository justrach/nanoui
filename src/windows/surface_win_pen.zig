//! A Windows pen's pressure, tilt and buttons into `Input.pen`.
//!
//! A pen (Windows Ink, a Wacom in Windows Ink mode, a Surface pen) sends
//! WM_POINTER messages first. The surface reads the pen's
//! `POINTER_PEN_INFO` here and leaves the message to DefWindowProc, which
//! promotes it to the mouse messages the surface already handles; so the
//! pen is read before the move or press it belongs to. A mouse message
//! that did not come from a pen or a finger (`GetMessageExtraInfo` lacks
//! the pen-or-touch signature) clears it.
const w = @import("win32.zig");
const input = @import("../ui/input.zig");
const pen = @import("../ui/pen.zig");
const Surface = @import("surface.zig").Surface;

pub const WM_POINTERUPDATE = 0x0245;
pub const WM_POINTERDOWN = 0x0246;
pub const WM_POINTERUP = 0x0247;
pub const WM_POINTERENTER = 0x0249;
pub const WM_POINTERLEAVE = 0x024A;

const PT_PEN: u32 = 3;
// PEN_MASK_*: which of `POINTER_PEN_INFO`'s fields the pen reports.
const mask_pressure: u32 = 0x1;
const mask_rotation: u32 = 0x2;
const mask_tilt_x: u32 = 0x4;
const mask_tilt_y: u32 = 0x8;

pub const POINTER_INFO = extern struct {
    pointerType: u32 = 0,
    pointerId: u32 = 0,
    frameId: u32 = 0,
    pointerFlags: u32 = 0,
    sourceDevice: ?*anyopaque = null,
    hwndTarget: ?w.HWND = null,
    ptPixelLocation: w.POINT = .{},
    ptHimetricLocation: w.POINT = .{},
    ptPixelLocationRaw: w.POINT = .{},
    ptHimetricLocationRaw: w.POINT = .{},
    dwTime: u32 = 0,
    historyCount: u32 = 0,
    InputData: i32 = 0,
    dwKeyStates: u32 = 0,
    PerformanceCount: u64 = 0,
    ButtonChangeType: i32 = 0,
};

pub const POINTER_PEN_INFO = extern struct {
    pointerInfo: POINTER_INFO = .{},
    penFlags: u32 = 0,
    penMask: u32 = 0,
    pressure: u32 = 0,
    rotation: u32 = 0,
    tiltX: i32 = 0,
    tiltY: i32 = 0,
};

extern "user32" fn GetPointerType(pointer_id: u32, kind: *u32) callconv(.winapi) w.BOOL;
extern "user32" fn GetPointerPenInfo(pointer_id: u32, info: *POINTER_PEN_INFO) callconv(.winapi) w.BOOL;
extern "user32" fn GetMessageExtraInfo() callconv(.winapi) w.LPARAM;

/// The pen a `POINTER_PEN_INFO` describes, its unreported fields zero.
pub fn penOf(info: POINTER_PEN_INFO) input.Pen {
    const m = info.penMask;
    return pen.fromWindows(
        info.penFlags,
        info.pointerInfo.pointerFlags,
        if (m & mask_pressure != 0) info.pressure else 0,
        if (m & mask_rotation != 0) info.rotation else 0,
        if (m & mask_tilt_x != 0) info.tiltX else 0,
        if (m & mask_tilt_y != 0) info.tiltY else 0,
    );
}

/// WM_POINTER*: reads the pen (or clears it for a finger) and always
/// answers null, so DefWindowProc still makes the mouse messages.
pub fn pointerMessage(self: *Surface, msg: u32, wp: w.WPARAM) ?w.LRESULT {
    const id: u32 = @truncate(wp & 0xffff);
    var kind: u32 = 0;
    const in = &self.ctx.input;
    if (GetPointerType(id, &kind) == 0 or kind != PT_PEN) {
        in.pen = null;
        return null;
    }
    if (msg == WM_POINTERLEAVE) {
        in.pen = null;
        return null;
    }
    var info: POINTER_PEN_INFO = .{};
    if (GetPointerPenInfo(id, &info) == 0) return null;
    const before = in.pen;
    in.pen = penOf(info);
    // Pressure or tilt changed with the pen still: no mouse move follows,
    // so the stroke's frame is asked for here.
    if (msg == WM_POINTERUPDATE and in.down) {
        if (before == null or before.?.pressure != in.pen.?.pressure or
            before.?.tilt_x != in.pen.?.tilt_x or before.?.tilt_y != in.pen.?.tilt_y)
            self.requestFrame();
    }
    return null;
}

/// `GetMessageExtraInfo`'s mark on a mouse message Windows made from a pen
/// or a finger (MI_WP_SIGNATURE, under the low byte's flags).
pub fn fromPenOrTouch(extra: w.LPARAM) bool {
    const low: u32 = @truncate(@as(usize, @bitCast(extra)));
    return low & 0xFFFFFF00 == 0xFF515700;
}

/// A mouse message: a real mouse's clears the pen.
pub fn mouseMessage(self: *Surface) void {
    if (self.ctx.input.pen != null and !fromPenOrTouch(GetMessageExtraInfo())) self.ctx.input.pen = null;
}

const testing = @import("std").testing;

test "a pen message's unreported fields read as zero" {
    var info: POINTER_PEN_INFO = .{ .penFlags = 0x1, .penMask = mask_pressure | mask_tilt_x, .pressure = 256, .rotation = 45, .tiltX = 30, .tiltY = 40 };
    info.pointerInfo.pointerFlags = pen.win_in_contact;
    const p = penOf(info);
    try testing.expectEqual(@as(f32, 0.25), p.pressure);
    try testing.expectEqual(@as(f32, 30), p.tilt_x);
    try testing.expectEqual(@as(f32, 0), p.tilt_y);
    try testing.expectEqual(@as(f32, 0), p.twist);
    try testing.expect(p.barrel and p.contact);
}

test "the pen-or-touch signature is recognised under its flag byte" {
    try testing.expect(fromPenOrTouch(@bitCast(@as(usize, 0xFF515780))));
    try testing.expect(fromPenOrTouch(@bitCast(@as(usize, 0xFF515700))));
    try testing.expect(!fromPenOrTouch(0));
}

test "POINTER_PEN_INFO has the Win32 layout" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try testing.expectEqual(@as(usize, 96), @sizeOf(POINTER_INFO));
    try testing.expectEqual(@as(usize, 120), @sizeOf(POINTER_PEN_INFO));
}
