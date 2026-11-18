//! A pen on a tablet or a pen display: what the pointer's latest event said
//! about the pen beyond its position (`Input.pen`). The hosts read their
//! own tablet fields (AppKit's `NSEvent`, Windows' `POINTER_PEN_INFO`, the
//! browser's `PointerEvent`) and convert them here, so every platform
//! reports the same units: the W3C Pointer Events conventions.
const std = @import("std");

pub const Pen = struct {
    /// Tip pressure, 0..1; 0 while the pen hovers.
    pressure: f32 = 0,
    /// The airbrush finger wheel or a barrel control, -1..1.
    tangential_pressure: f32 = 0,
    /// Degrees from upright, -90..90: positive `tilt_x` leans right,
    /// positive `tilt_y` toward the user.
    tilt_x: f32 = 0,
    tilt_y: f32 = 0,
    /// Clockwise rotation about the pen's own axis, 0..360 degrees.
    twist: f32 = 0,
    /// The pen's eraser end is the one in use.
    eraser: bool = false,
    /// The first barrel switch is held.
    barrel: bool = false,
    /// The second barrel switch is held (macOS).
    barrel2: bool = false,
    /// The tip (or the eraser) touches the surface.
    contact: bool = false,
};

/// AppKit scales tilt to -1..1 over the pen's range; a Wacom pen leans
/// about 60 degrees either way, the scale Qt's Cocoa backend uses too.
pub const appkit_max_tilt: f32 = 60;

/// `NSEventButtonMask`'s pen bits.
pub const appkit_tip: u64 = 1;
pub const appkit_lower_side: u64 = 2;
pub const appkit_upper_side: u64 = 4;

/// From an AppKit tablet event's `pressure`, `tangentialPressure`, `tilt`,
/// `rotation` (degrees, counter-clockwise) and `buttonMask`. AppKit's tilt
/// y grows away from the user, so it is flipped.
pub fn fromAppKit(pressure: f32, tangential: f32, tilt_x: f32, tilt_y: f32, rotation: f32, button_mask: u64, eraser: bool) Pen {
    return .{
        .pressure = unit(pressure),
        .tangential_pressure = clampNaN(tangential, -1, 1),
        .tilt_x = clampNaN(tilt_x, -1, 1) * appkit_max_tilt,
        .tilt_y = -clampNaN(tilt_y, -1, 1) * appkit_max_tilt,
        .twist = degrees(360 - rotation),
        .eraser = eraser,
        .barrel = button_mask & appkit_lower_side != 0,
        .barrel2 = button_mask & appkit_upper_side != 0,
        .contact = button_mask & appkit_tip != 0,
    };
}

/// `PEN_FLAG_*` and `POINTER_FLAG_INCONTACT`.
pub const win_barrel: u32 = 0x1;
pub const win_inverted: u32 = 0x2;
pub const win_eraser: u32 = 0x4;
pub const win_in_contact: u32 = 0x4;
/// `POINTER_PEN_INFO.pressure`'s full scale.
pub const win_max_pressure: u32 = 1024;

/// From Windows' `POINTER_PEN_INFO`: `penFlags`, `pressure` (0..1024),
/// `rotation` (degrees clockwise), `tiltX`/`tiltY` (degrees, the Pointer
/// Events directions), and its `pointerInfo.pointerFlags`.
pub fn fromWindows(pen_flags: u32, pointer_flags: u32, pressure: u32, rotation: u32, tilt_x: i32, tilt_y: i32) Pen {
    return .{
        .pressure = @as(f32, @floatFromInt(@min(pressure, win_max_pressure))) / @as(f32, @floatFromInt(win_max_pressure)),
        .tilt_x = @floatFromInt(std.math.clamp(tilt_x, -90, 90)),
        .tilt_y = @floatFromInt(std.math.clamp(tilt_y, -90, 90)),
        .twist = degrees(@floatFromInt(rotation % 360)),
        .eraser = pen_flags & (win_inverted | win_eraser) != 0,
        .barrel = pen_flags & win_barrel != 0,
        .contact = pointer_flags & win_in_contact != 0,
    };
}

/// `PointerEvent.buttons`' pen bits.
pub const web_tip: u32 = 1;
pub const web_barrel: u32 = 2;
pub const web_eraser: u32 = 32;

/// From a `PointerEvent` whose `pointerType` is "pen": its fields already
/// use these conventions.
pub fn fromWeb(pressure: f32, tangential: f32, tilt_x: f32, tilt_y: f32, twist: f32, buttons: u32) Pen {
    return .{
        .pressure = unit(pressure),
        .tangential_pressure = clampNaN(tangential, -1, 1),
        .tilt_x = clampNaN(tilt_x, -90, 90),
        .tilt_y = clampNaN(tilt_y, -90, 90),
        .twist = degrees(twist),
        .eraser = buttons & web_eraser != 0,
        .barrel = buttons & web_barrel != 0,
        // The eraser end in contact sets its own bit, not the tip's.
        .contact = buttons & (web_tip | web_eraser) != 0,
    };
}

fn unit(v: f32) f32 {
    return clampNaN(v, 0, 1);
}

fn clampNaN(v: f32, lo: f32, hi: f32) f32 {
    if (std.math.isNan(v)) return 0;
    return std.math.clamp(v, lo, hi);
}

fn degrees(v: f32) f32 {
    if (!std.math.isFinite(v)) return 0;
    const r = @mod(v, 360);
    return if (r >= 360) 0 else r;
}

const testing = std.testing;

test "AppKit pens flip tilt y and turn rotation clockwise" {
    const p = fromAppKit(0.5, 0.25, 0.5, 0.5, 90, appkit_tip | appkit_upper_side, false);
    try testing.expectEqual(@as(f32, 0.5), p.pressure);
    try testing.expectEqual(@as(f32, 0.25), p.tangential_pressure);
    try testing.expectApproxEqAbs(@as(f32, 30), p.tilt_x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -30), p.tilt_y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 270), p.twist, 1e-4);
    try testing.expect(p.contact and !p.barrel and p.barrel2 and !p.eraser);
    try testing.expectEqual(@as(f32, 0), fromAppKit(0, 0, 0, 0, 0, 0, true).twist);
    try testing.expect(fromAppKit(2, 0, 0, 0, 0, 0, true).eraser);
    try testing.expectEqual(@as(f32, 1), fromAppKit(2, 0, 0, 0, 0, 0, true).pressure);
}

test "Windows pens scale pressure and read the eraser and contact flags" {
    const p = fromWindows(win_barrel, win_in_contact, 512, 370, 100, -20);
    try testing.expectEqual(@as(f32, 0.5), p.pressure);
    try testing.expectEqual(@as(f32, 90), p.tilt_x);
    try testing.expectEqual(@as(f32, -20), p.tilt_y);
    try testing.expectEqual(@as(f32, 10), p.twist);
    try testing.expect(p.contact and p.barrel and !p.eraser);
    const flipped = fromWindows(win_inverted, 0, 5000, 0, 0, 0);
    try testing.expect(flipped.eraser and !flipped.contact);
    try testing.expectEqual(@as(f32, 1), flipped.pressure);
}

test "browser pens pass through, the eraser counting as contact" {
    const p = fromWeb(0.25, -2, -15, 45, 359, web_eraser);
    try testing.expectEqual(@as(f32, 0.25), p.pressure);
    try testing.expectEqual(@as(f32, -1), p.tangential_pressure);
    try testing.expectEqual(@as(f32, -15), p.tilt_x);
    try testing.expectEqual(@as(f32, 359), p.twist);
    try testing.expect(p.eraser and p.contact);
    try testing.expect(fromWeb(0.1, 0, 0, 0, 0, web_tip | web_barrel).barrel);
    try testing.expectEqual(@as(f32, 0), fromWeb(std.math.nan(f32), 0, 0, 0, 720, 0).pressure);
    try testing.expectEqual(@as(f32, 0), fromWeb(0, 0, 0, 0, 720, 0).twist);
}
