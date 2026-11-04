//! Input as the hardware would make it, posted either into one app, which
//! leaves the user's pointer and keyboard alone, or to the HID event tap, the
//! real thing: clicks (single, double, right), keys with modifiers, text typed
//! as Unicode, scrolling by lines, and moving the pointer.
const std = @import("std");
const keys = @import("../keys.zig");
const cf = @import("cf.zig");

const CGEventRef = *opaque {};
extern "c" fn CGEventCreateMouseEvent(source: ?*anyopaque, kind: u32, at: cf.CGPoint, button: u32) ?CGEventRef;
extern "c" fn CGEventCreateKeyboardEvent(source: ?*anyopaque, code: u16, down: bool) ?CGEventRef;
extern "c" fn CGEventCreateScrollWheelEvent2(source: ?*anyopaque, units: u32, count: u32, wheel1: i32, wheel2: i32, wheel3: i32) ?CGEventRef;
extern "c" fn CGEventKeyboardSetUnicodeString(ev: CGEventRef, len: c_ulong, chars: [*]const u16) void;
extern "c" fn CGEventSetFlags(ev: CGEventRef, flags: u64) void;
extern "c" fn CGEventSetLocation(ev: CGEventRef, at: cf.CGPoint) void;
extern "c" fn CGEventSetIntegerValueField(ev: CGEventRef, field: u32, value: i64) void;
extern "c" fn CGEventPost(tap: u32, ev: CGEventRef) void;
extern "c" fn CGEventPostToPid(pid: i32, ev: CGEventRef) void;
extern "c" fn usleep(us: c_uint) c_int;

const hid_tap: u32 = 0;
const field_click_state: u32 = 1;
const field_window_under_pointer: u32 = 91;
const field_window_handling: u32 = 92;
const mouse_moved: u32 = 5;

pub const Button = enum { left, right };

/// Where events go.
pub const Target = union(enum) {
    /// The real pointer and keyboard.
    hid,
    /// Into one app. `window` is what a mouse event says it is over (0: unknown).
    app: struct { pid: i32, window: u32 = 0 },

    fn post(t: Target, ev: ?CGEventRef) void {
        const e = ev orelse return;
        switch (t) {
            .hid => CGEventPost(hid_tap, e),
            .app => |a| CGEventPostToPid(a.pid, e),
        }
        cf.CFRelease(e);
    }

    /// A mouse event at x, y, saying which window it is over: an app in the
    /// background otherwise goes by where the real pointer is.
    fn mouse(t: Target, kind: u32, x: f64, y: f64, button: u32) ?CGEventRef {
        const ev = CGEventCreateMouseEvent(null, kind, .{ .x = x, .y = y }, button) orelse return null;
        if (t == .app and t.app.window != 0) {
            CGEventSetIntegerValueField(ev, field_window_under_pointer, t.app.window);
            CGEventSetIntegerValueField(ev, field_window_handling, t.app.window);
        }
        return ev;
    }
};

pub fn move(t: Target, x: f64, y: f64) void {
    t.post(t.mouse(mouse_moved, x, y, 0));
}

/// Clicks `count` times at x, y (a double click is two, the second with
/// click state 2, as the system makes it).
pub fn click(t: Target, x: f64, y: f64, button: Button, count: u32) void {
    const down: u32, const up: u32, const b: u32 = switch (button) {
        .left => .{ 1, 2, 0 },
        .right => .{ 3, 4, 1 },
    };
    move(t, x, y);
    _ = usleep(15_000);
    for (1..@min(count, 3) + 1) |n| {
        for ([_]u32{ down, up }) |kind| {
            const ev = t.mouse(kind, x, y, b) orelse continue;
            CGEventSetIntegerValueField(ev, field_click_state, @intCast(n));
            t.post(ev);
            _ = usleep(8_000);
        }
    }
}

/// Presses and releases a combo; false if its key has no code.
pub fn press(t: Target, combo: keys.Combo) bool {
    const code = keys.macCode(combo.key) orelse return false;
    const flags = keys.macFlags(combo.mods);
    for ([_]bool{ true, false }) |down| {
        const ev = CGEventCreateKeyboardEvent(null, code, down) orelse return false;
        CGEventSetFlags(ev, flags);
        t.post(ev);
        _ = usleep(10_000);
    }
    return true;
}

/// Types `s` as Unicode one character per event, whatever the layout, with no
/// modifiers held: apps that read keys one by one (games, terminals) see each.
/// Stops as soon as `stopped` is set; returns the characters typed.
pub fn typeText(t: Target, s: []const u8, stopped: *const std.atomic.Value(bool)) usize {
    var typed: usize = 0;
    var units: [2]u16 = undefined;
    var it = std.unicode.Utf8View.initUnchecked(if (std.unicode.utf8ValidateSlice(s)) s else "").iterator();
    while (it.nextCodepoint()) |cp| {
        if (stopped.load(.acquire)) break;
        typed += 1;
        if (cp == '\n') {
            _ = press(t, .{ .key = "enter" });
            continue;
        }
        unicode(t, units[0..utf16(&units, cp)]);
    }
    return typed;
}

/// `cp` in UTF-16; the units it took.
fn utf16(units: *[2]u16, cp: u21) usize {
    if (cp < 0x10000) {
        units[0] = @intCast(cp);
        return 1;
    }
    const v = cp - 0x10000;
    units[0] = @intCast(0xD800 + (v >> 10));
    units[1] = @intCast(0xDC00 + (v & 0x3ff));
    return 2;
}

fn unicode(t: Target, units: []const u16) void {
    for ([_]bool{ true, false }) |down| {
        const ev = CGEventCreateKeyboardEvent(null, 0, down) orelse continue;
        CGEventSetFlags(ev, 0);
        CGEventKeyboardSetUnicodeString(ev, @intCast(units.len), units.ptr);
        t.post(ev);
    }
    _ = usleep(4_000);
}

/// Scrolls at x, y: `dy` lines down, `dx` lines right.
pub fn scroll(t: Target, x: f64, y: f64, dx: f64, dy: f64) void {
    if (t == .hid) {
        move(t, x, y);
        _ = usleep(15_000);
    }
    const clamp = struct {
        fn f(v: f64) i32 {
            return @intFromFloat(std.math.clamp(@round(v), -200, 200));
        }
    }.f;
    // Wheel 1 is vertical, positive up; wheel 2 horizontal, positive left.
    const ev = CGEventCreateScrollWheelEvent2(null, 1, 2, -clamp(dy), -clamp(dx), 0) orelse return;
    CGEventSetLocation(ev, .{ .x = x, .y = y });
    t.post(ev);
}

test "characters in UTF-16" {
    var u: [2]u16 = undefined;
    try std.testing.expectEqual(@as(usize, 1), utf16(&u, 'é'));
    try std.testing.expectEqual(@as(u16, 0xe9), u[0]);
    try std.testing.expectEqual(@as(usize, 2), utf16(&u, 0x1F600));
    try std.testing.expectEqual(@as(u16, 0xD83D), u[0]);
    try std.testing.expectEqual(@as(u16, 0xDE00), u[1]);
}
