//! A frame wanted later (`Context.frameIn`, as a caret's blink asks) on the
//! Mac. The display link isn't slowed to that pace: a slow link hands out a
//! drawable presented at its own target, up to a whole interval after it was
//! drawn, so a frame drawn sooner for a key pressed meanwhile showed first and
//! was then covered by the older one (a deleted letter came back, a list's
//! selection went back a row). The link is paused instead, and run again at
//! the display's pace a refresh before the frame is due.
const std = @import("std");
const objc = @import("../objc.zig");
const cf = @import("cf.zig");
const Surface = @import("surface.zig").Surface;

pub const Wake = struct {
    /// When the link is to run again (`CACurrentMediaTime`); 0: never.
    due: f64 = 0,
    /// Wakes still to fire: the surface outlives them (`finishDestroy`).
    pending: u32 = 0,
};

/// Pauses `s`'s display link until about `due`. Only the latest wake counts.
pub fn at(s: *Surface, due: f64) void {
    s.setPaced(false);
    s.wake.due = due;
    const wait = @max(0, due - lead(s) - cf.CACurrentMediaTime());
    s.wake.pending += 1;
    objc.dispatchAfter(@intFromFloat(wait * std.time.ns_per_s), s, fire);
}

/// A refresh: the link's next target then lands on the frame's due time.
fn lead(s: *const Surface) f64 {
    return if (s.link_duration > 0) s.link_duration else 1.0 / 60.0;
}

fn fire(ptr: ?*anyopaque) callconv(.c) void {
    const s: *Surface = @ptrCast(@alignCast(ptr));
    s.wake.pending -= 1;
    if (s.dead) return s.finishDestroy();
    // None wanted, or this one was overtaken by a later wake.
    if (s.wake.due == 0 or cf.CACurrentMediaTime() < s.wake.due - lead(s) - 0.002) return;
    s.wake.due = 0;
    // Hidden: the frame is owed for when it shows (`occlusionChanged`), or a
    // caret would come back frozen in one phase until the next input.
    if (!s.visible()) {
        s.pending = true;
        return;
    }
    s.setRate(null);
    s.setPaced(true);
}
