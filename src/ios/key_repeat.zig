//! When a held key repeats. UIKit tells a view a hardware key went down and
//! came up, and nothing between: text it types into a field repeats by itself,
//! but the keys a view takes (the caret's arrows, a list's) stay at one press
//! unless something presses them again. No system setting for the pace can be
//! read, so this keeps the Mac's defaults. Only a held key costs anything: the
//! surface's display link runs for it, and stops when it's let go.
const std = @import("std");

/// Seconds held before the first repeat, and between repeats after it.
pub const delay: f64 = 0.5;
pub const interval: f64 = 0.09;

/// UIKeyboardHIDUsage: Return and Enter, Escape. Held, these would send or
/// dismiss again and again, which no one holding them wants.
fn once(code: isize) bool {
    return code == 0x28 or code == 0x58 or code == 0x29;
}

/// Control, Shift, Option and Command, left and right.
fn modifier(code: isize) bool {
    return code >= 0xE0 and code <= 0xE7;
}

/// A combination is a command (⌘N shouldn't open a window a tenth of a second).
pub fn repeats(code: isize, cmd: bool, ctrl: bool) bool {
    return !cmd and !ctrl and !once(code) and !modifier(code);
}

pub const Timer = struct {
    code: isize = 0,
    next: f64 = 0,

    pub fn start(t: *Timer, code: isize, now: f64) void {
        t.* = .{ .code = code, .next = now + delay };
    }

    /// `code` let go. A key pressed since took over from it, as on the Mac.
    pub fn release(t: *Timer, code: isize) bool {
        if (t.code != code) return false;
        t.* = .{};
        return true;
    }

    pub fn running(t: Timer) bool {
        return t.code != 0;
    }

    /// Whether to press again now. Once at most, however late: a stall doesn't
    /// come back as a burst of arrows.
    pub fn due(t: *Timer, now: f64) bool {
        if (!t.running() or now < t.next) return false;
        t.next = now + interval;
        return true;
    }
};

const testing = std.testing;

test "a held key repeats after the delay, at the interval" {
    var t: Timer = .{};
    try testing.expect(!t.running());
    try testing.expect(!t.due(10));
    t.start(0x50, 10);
    try testing.expect(t.running());
    try testing.expect(!t.due(10.4));
    try testing.expect(t.due(10.5));
    try testing.expect(!t.due(10.55));
    try testing.expect(t.due(10.6));
}

test "a stall doesn't come back as a burst" {
    var t: Timer = .{};
    t.start(0x50, 0);
    try testing.expect(t.due(5));
    try testing.expect(!t.due(5.01));
}

test "letting go stops only the key that repeats" {
    var t: Timer = .{};
    t.start(0x50, 0);
    t.start(0x4F, 0.1);
    try testing.expect(!t.release(0x50));
    try testing.expect(t.running());
    try testing.expect(t.release(0x4F));
    try testing.expect(!t.running());
    try testing.expect(!t.due(99));
}

test "arrows and characters repeat; commands, Return and Escape don't" {
    try testing.expect(repeats(0x50, false, false));
    try testing.expect(repeats(0x04, false, false));
    try testing.expect(!repeats(0x50, true, false));
    try testing.expect(!repeats(0x50, false, true));
    try testing.expect(!repeats(0x28, false, false));
    try testing.expect(!repeats(0x58, false, false));
    try testing.expect(!repeats(0x29, false, false));
    try testing.expect(!repeats(0xE1, false, false));
}
