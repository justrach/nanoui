//! The one pointer press in flight, as the macOS and Windows hosts keep
//! it. A press of another button while one is held is ignored, and so is
//! that button's release: a middle press during a left drag (or a left
//! one during a middle pan) never starts a second gesture, never changes
//! `input.button` under the first, and never ends it.
const std = @import("std");
const input = @import("input.zig");

/// The buttons the system says are held as a press arrives, its own
/// among them (macOS: `+[NSEvent pressedMouseButtons]`; Windows: the
/// MK_ flags a button message carries).
pub const Held = packed struct(u8) {
    left: bool = false,
    right: bool = false,
    middle: bool = false,
    _: u5 = 0,

    pub fn has(h: Held, b: input.Button) bool {
        return switch (b) {
            .left => h.left,
            .right => h.right,
            .middle => h.middle,
        };
    }

    pub fn set(h: *Held, b: input.Button) void {
        switch (b) {
            .left => h.left = true,
            .right => h.right = true,
            .middle => h.middle = true,
        }
    }
};

/// Whether a press of `button` starts a press. It does when none is in
/// flight; when the same button went down again, or the one in flight is
/// no longer held, its release went where this view never saw it (a
/// menu's loop, another window), so the press in flight is stale and the
/// new one replaces it. A press of another button while the one in
/// flight is still held is ignored.
pub fn starts(in: *const input.Input, button: input.Button, held: Held) bool {
    if (!in.down) return true;
    return button == in.button or !held.has(in.button);
}

/// Whether a release of `button` ends the press in flight: only its own
/// button's, and only while it is down.
pub fn ends(in: *const input.Input, button: input.Button) bool {
    return in.down and in.button == button;
}

/// The press in flight ended where no release will say so (Windows: the
/// capture went to another window, focus was lost mid-drag). `down` goes
/// up with no `released` edge, so a drag ends where it is and nothing
/// takes it as a click. Returns whether a press was in flight.
pub fn cancel(in: *input.Input) bool {
    if (!in.down) return false;
    in.down = false;
    return true;
}

const testing = std.testing;

fn inFlight(b: input.Button) input.Input {
    return .{ .down = true, .button = b };
}

test "pointer press: with none in flight every button starts one" {
    const idle: input.Input = .{};
    for ([_]input.Button{ .left, .right, .middle }) |b| try testing.expect(starts(&idle, b, .{}));
    try testing.expect(!ends(&idle, .left) and !ends(&idle, .middle));
}

test "pointer press: a second button while one is held is ignored, its release too" {
    const left = inFlight(.left);
    try testing.expect(!starts(&left, .middle, .{ .left = true, .middle = true }));
    try testing.expect(!starts(&left, .right, .{ .left = true, .right = true }));
    try testing.expect(!ends(&left, .middle) and !ends(&left, .right));
    try testing.expect(ends(&left, .left));
    const middle = inFlight(.middle);
    try testing.expect(!starts(&middle, .left, .{ .left = true, .middle = true }));
    try testing.expect(!ends(&middle, .left));
    try testing.expect(ends(&middle, .middle));
}

test "pointer press: a stale press (its button no longer held, or pressed again) is replaced" {
    const middle = inFlight(.middle);
    try testing.expect(starts(&middle, .left, .{ .left = true }));
    try testing.expect(starts(&middle, .middle, .{ .middle = true }));
    const left = inFlight(.left);
    try testing.expect(starts(&left, .left, .{ .left = true }));
    // Held again (its release is still on its way): the new press waits.
    var h: Held = .{ .middle = true };
    h.set(.left);
    try testing.expect(h.has(.left) and h.has(.middle) and !h.has(.right));
    try testing.expect(!starts(&left, .middle, h));
}

test "pointer press: cancel lets the press go with no release edge" {
    var in = inFlight(.middle);
    try testing.expect(cancel(&in));
    try testing.expect(!in.down and !in.released);
    try testing.expect(!cancel(&in));
    try testing.expect(!ends(&in, .middle));
}
