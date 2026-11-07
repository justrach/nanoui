//! A frame wanted later (`Context.frameIn`, as a caret's blink asks) on the
//! Mac. The display link isn't slowed to that pace: a slow link hands out a
//! drawable presented at its own target, up to a whole interval after it was
//! drawn, so a frame drawn sooner for a key pressed meanwhile showed first and
//! was then covered by the older one (a deleted letter came back, a list's
//! selection went back a row). The link is paused instead, and run again at
//! the display's pace a refresh before the frame is due.
//!
//! Also a running link that gives no frames. On macOS 14 and 15 a
//! CAMetalDisplayLink can stop after a few frames and stay stopped, for many
//! seconds, until something else on the screen's layers changes: seen on CI's
//! Macs, where a query stopped drawing as soon as a key no longer resized the
//! panel. Keys were handled, and nothing showed. `watch` looks after it for as
//! long as a frame is wanted, and invalidating the window's shadow, which leaves
//! nothing changed, has had it running again within 40 ms each time.
//!
//! A link that does run can still leave a presented frame off the screen: a
//! word typed showed only 1.25 s later, once another key's nudge came. So every
//! present is followed by the same nudge (`presented`), and with it neither
//! has been seen on macOS 14, 15 or 26.
//!
//! Ticks and wakes are queued with `dispatch_after`, which can't take back
//! what it was given: they carry a surface's id, not the surface, and find
//! it among the surfaces open (`register`, `find`). A surface closed with
//! some still queued waits for them to free it (`Surface.finishDestroy`);
//! if the app stops first they never run, and `sweep` frees it. Any that
//! do run after a surface was freed find nothing.
const std = @import("std");
const objc = @import("../objc.zig");
const cf = @import("cf.zig");
const Surface = @import("surface.zig").Surface;

pub const Wake = struct {
    /// What a tick or a wake queued for the surface carries (`token`).
    id: usize = 0,
    /// The next surface in `open`.
    next: ?*Surface = null,
    /// When the link is to run again (`CACurrentMediaTime`); 0: never.
    due: f64 = 0,
    /// Wakes still to fire: the surface outlives them (`finishDestroy`).
    pending: u32 = 0,
    /// The link's last frame (`CACurrentMediaTime`).
    last_tick: f64 = 0,
    /// `check` is due; since when; and how many nudges went unanswered.
    watching: bool = false,
    watched_from: f64 = 0,
    nudges: u8 = 0,
};

/// The surfaces made and not yet freed, newest first. All on the main
/// thread, as the ticks and wakes that look in it.
var open: ?*Surface = null;
var last_id: usize = 0;

pub fn register(s: *Surface) void {
    last_id += 1;
    s.wake.id = last_id;
    s.wake.next = open;
    open = s;
}

pub fn unregister(s: *Surface) void {
    var link = &open;
    while (link.*) |o| : (link = &o.wake.next) if (o == s) {
        link.* = s.wake.next;
        return;
    };
}

/// Frees `s`, torn down (`Surface.finishDestroy`).
pub fn free(s: *Surface) void {
    unregister(s);
    s.gpa.destroy(s);
}

/// What to queue for `s`: its id, never 0.
pub fn token(s: *const Surface) ?*anyopaque {
    return @ptrFromInt(s.wake.id);
}

/// The surface a queued `token` names, if it hasn't been freed.
pub fn find(ptr: ?*anyopaque) ?*Surface {
    const id = @intFromPtr(ptr);
    var it = open;
    while (it) |s| : (it = s.wake.next) if (s.wake.id == id) return s;
    return null;
}

/// Frees the surfaces closed while ticks or wakes were still queued for
/// them, which won't run now that the app has stopped (`App.destroy`).
pub fn sweep() void {
    var it = open;
    while (it) |s| {
        it = s.wake.next;
        if (s.torn_down) free(s);
    }
}

/// How long a running link may give no frame: more than one interval at its
/// slowest pace (1/24 s), and a healthy link's start takes about 20 ms.
const patience = 0.05;
/// Then it's left until a frame is next wanted: a sleeping display gives no
/// frames either, and nothing here should go on running for that.
const max_nudges = 5;

/// Pauses `s`'s display link until about `due`. Only the latest wake counts.
pub fn at(s: *Surface, due: f64) void {
    s.setPaced(false);
    s.wake.due = due;
    const wait = @max(0, due - lead(s) - cf.CACurrentMediaTime());
    s.wake.pending += 1;
    objc.dispatchAfter(@intFromFloat(wait * std.time.ns_per_s), token(s), fire);
}

/// A refresh: the link's next target then lands on the frame's due time.
fn lead(s: *const Surface) f64 {
    return if (s.link_duration > 0) s.link_duration else 1.0 / 60.0;
}

fn fire(ptr: ?*anyopaque) callconv(.c) void {
    const s = find(ptr) orelse return;
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

/// A frame has just gone to the screen: has the window server look. Not while
/// another is on its way, which covers one left off the screen a refresh later:
/// at 60 fps the nudge took about 5% of a core in the window server.
pub fn presented(s: *Surface) void {
    if (s.ctx.animating or s.ctx.time_driven != .none) return;
    objc.msg(void, s.window.nswindow, "invalidateShadow", .{});
}

/// A frame is wanted from the link: sees that it comes. Not a poll: it stops
/// as the link is paused, which it is whenever nothing is wanted.
pub fn watch(s: *Surface) void {
    if (s.display_link == null) return;
    s.wake.nudges = 0;
    arm(s);
}

fn arm(s: *Surface) void {
    if (s.wake.watching) return;
    s.wake.watching = true;
    s.wake.watched_from = cf.CACurrentMediaTime();
    s.wake.pending += 1;
    objc.dispatchAfter(@intFromFloat(patience * std.time.ns_per_s), token(s), check);
}

const Look = enum { stop, again, nudge };

fn look(wanted: bool, ticked: bool, nudges: u8) Look {
    if (!wanted) return .stop;
    if (ticked) return .again;
    return if (nudges < max_nudges) .nudge else .stop;
}

fn check(ptr: ?*anyopaque) callconv(.c) void {
    const s = find(ptr) orelse return;
    s.wake.pending -= 1;
    s.wake.watching = false;
    if (s.dead) return s.finishDestroy();
    const ticked = s.wake.last_tick >= s.wake.watched_from;
    switch (look(s.paced and s.visible(), ticked, s.wake.nudges)) {
        .stop => return,
        .again => s.wake.nudges = 0,
        .nudge => {
            s.wake.nudges += 1;
            objc.msg(void, s.window.nswindow, "invalidateShadow", .{});
        },
    }
    arm(s);
}

test "a link that gives no frames is nudged, and not for ever" {
    const t = std.testing;
    try t.expectEqual(Look.again, look(true, true, 0));
    try t.expectEqual(Look.nudge, look(true, false, 0));
    try t.expectEqual(Look.nudge, look(true, false, max_nudges - 1));
    // A sleeping display: the next frame wanted looks again.
    try t.expectEqual(Look.stop, look(true, false, max_nudges));
    // Paused or out of sight: no frames are wanted, so nothing runs.
    try t.expectEqual(Look.stop, look(false, false, 0));
    try t.expectEqual(Look.stop, look(false, true, 0));
}
