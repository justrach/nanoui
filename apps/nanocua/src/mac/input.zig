//! Input as the hardware would make it, posted either into one app, which
//! leaves the user's pointer and keyboard alone, or to the HID event tap, the
//! real thing: clicks (single, double, right), keys with modifiers, text typed
//! as Unicode, scrolling by lines, and moving the pointer.
const std = @import("std");
const keys = @import("../keys.zig");
const cf = @import("cf.zig");
const skylight = @import("skylight.zig");

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
const mouse_moved: u32 = 5;
// CGEvent's fields. Those without a public name are what WindowServer stamps on
// an event it routes itself, and an app in the background goes by them.
const field_click_state: u32 = 1;
const field_button: u32 = 3;
const field_subtype: u32 = 7;
const field_target_pid: u32 = 40;
const field_window_number: u32 = 51;
const field_click_group: u32 = 58;
const field_window_under_pointer: u32 = 91;
const field_window_handling: u32 = 92;
const subtype_touch: i64 = 3;
/// A scroll event carries at most this many lines: more arrive coalesced or not at all.
const lines_per_event: i32 = 10;

pub const Button = enum { left, right };

/// One app's window, where mouse events land.
pub const App = struct {
    pid: i32,
    /// The window under the event, and its top-left in screen points.
    window: u32 = 0,
    origin: [2]f64 = .{ 0, 0 },
    /// Ties the events of one gesture together.
    group: i64 = 0,
};

/// Where events go.
pub const Target = union(enum) {
    /// The real pointer and keyboard.
    hid,
    /// Into one app.
    app: App,

    fn post(t: Target, ev: ?CGEventRef) void {
        const e = ev orelse return;
        switch (t) {
            .hid => CGEventPost(hid_tap, e),
            .app => |a| CGEventPostToPid(a.pid, e),
        }
        cf.CFRelease(e);
    }

    /// Posts a mouse or scroll event, with what an app in the background needs
    /// to act on it at x, y.
    fn postPointer(t: Target, ev: ?CGEventRef, x: f64, y: f64, state: i64, button: i64) void {
        const e = ev orelse return;
        defer cf.CFRelease(e);
        const a = switch (t) {
            .hid => return CGEventPost(hid_tap, e),
            .app => |app| app,
        };
        // Exactly no modifiers: an event otherwise inherits what the user holds.
        CGEventSetFlags(e, 0);
        skylight.setField(e, field_target_pid, a.pid);
        if (a.window != 0) {
            // Relative to the window: the live test missed with screen points or none.
            skylight.setWindowLocation(e, x - a.origin[0], y - a.origin[1]);
            skylight.setField(e, field_click_state, state);
            skylight.setField(e, field_button, button);
            skylight.setField(e, field_subtype, subtype_touch);
            skylight.setField(e, field_window_number, a.window);
            skylight.setField(e, field_click_group, a.group);
            skylight.setField(e, field_window_under_pointer, a.window);
            skylight.setField(e, field_window_handling, a.window);
        }
        skylight.post(a.pid, e);
    }
};

/// A mouse event's type and button number.
fn press_kinds(button: Button) struct { down: u32, up: u32, number: u32 } {
    return switch (button) {
        .left => .{ .down = 1, .up = 2, .number = 0 },
        .right => .{ .down = 3, .up = 4, .number = 1 },
    };
}

pub fn move(t: Target, x: f64, y: f64) void {
    t.postPointer(CGEventCreateMouseEvent(null, mouse_moved, .{ .x = x, .y = y }, 0), x, y, 0, 0);
}

/// Gestures so far. Only the backend's queue sends events.
var next_group: i64 = 0;

/// Starts a gesture: makes the window key, without raising it, or the app spends
/// the click on that; then a move, so an app in the background knows where the
/// pointer now is before a press arrives.
fn prepare(t: Target, x: f64, y: f64) Target {
    var out = t;
    if (out == .app) {
        next_group += 1;
        out.app.group = next_group;
        if (out.app.window != 0 and skylight.focusWindow(out.app.pid, out.app.window)) _ = usleep(50_000);
    }
    move(out, x, y);
    _ = usleep(15_000);
    return out;
}

/// Clicks `count` times at x, y (a double click is two, the second with
/// click state 2, as the system makes it).
pub fn click(t: Target, x: f64, y: f64, button: Button, count: u32) void {
    const k = press_kinds(button);
    const at: cf.CGPoint = .{ .x = x, .y = y };
    const ready = prepare(t, x, y);
    for (1..@min(count, 3) + 1) |n| {
        const state: i64 = @intCast(n);
        const down = CGEventCreateMouseEvent(null, k.down, at, k.number);
        if (ready == .hid) if (down) |d| CGEventSetIntegerValueField(d, field_click_state, state);
        ready.postPointer(down, x, y, state, k.number);
        // A control's tracking loop polls for the release: too soon and it's missed.
        _ = usleep(28_000);
        const up = CGEventCreateMouseEvent(null, k.up, at, k.number);
        if (ready == .hid) if (up) |u| CGEventSetIntegerValueField(u, field_click_state, state);
        ready.postPointer(up, x, y, state, k.number);
        _ = usleep(30_000);
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

/// The next wheel event's share of `left` lines.
pub fn wheelStep(left: i32) i32 {
    return std.math.clamp(left, -lines_per_event, lines_per_event);
}

/// Scrolls at x, y: `dy` lines down, `dx` lines right.
pub fn scroll(t: Target, x: f64, y: f64, dx: f64, dy: f64) void {
    const ready = prepare(t, x, y);
    const whole = struct {
        fn f(v: f64) i32 {
            return @intFromFloat(std.math.clamp(@round(v), -200, 200));
        }
    }.f;
    var down = whole(dy);
    var right = whole(dx);
    while (down != 0 or right != 0) {
        const sy = wheelStep(down);
        const sx = wheelStep(right);
        down -= sy;
        right -= sx;
        // Wheel 1 is vertical, positive up; wheel 2 horizontal, positive left.
        const ev = CGEventCreateScrollWheelEvent2(null, 1, 2, -sy, -sx, 0);
        if (ev) |e| CGEventSetLocation(e, .{ .x = x, .y = y });
        ready.postPointer(ev, x, y, 0, 0);
        _ = usleep(30_000);
    }
}

test "characters in UTF-16" {
    var u: [2]u16 = undefined;
    try std.testing.expectEqual(@as(usize, 1), utf16(&u, 'é'));
    try std.testing.expectEqual(@as(u16, 0xe9), u[0]);
    try std.testing.expectEqual(@as(usize, 2), utf16(&u, 0x1F600));
    try std.testing.expectEqual(@as(u16, 0xD83D), u[0]);
    try std.testing.expectEqual(@as(u16, 0xDE00), u[1]);
}

test "a long scroll goes out in steps" {
    try std.testing.expectEqual(@as(i32, 10), wheelStep(40));
    try std.testing.expectEqual(@as(i32, -10), wheelStep(-40));
    try std.testing.expectEqual(@as(i32, 3), wheelStep(3));
    try std.testing.expectEqual(@as(i32, 0), wheelStep(0));
}
