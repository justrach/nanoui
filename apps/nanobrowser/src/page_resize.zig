//! A window being dragged to a new size. Drawing what's laid out takes a millisecond
//! and laying a long page out a hundred, so while a drag goes on the page is laid out
//! only as often as it can afford, and the window follows the pointer in between. What
//! was laid out stays put for those frames, as in other browsers; the drag's end lays
//! it out at once.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Page = @import("page.zig").Page;

/// What a layout may cost, in seconds, and still run at every change of size.
const affordable: f64 = 0.008;
/// The longest the page waits to catch up with a drag, in seconds.
const longest_wait: f64 = 0.25;

pub fn now() f64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const t = std.Io.Clock.awake.now(io);
    return @as(f64, @floatFromInt(t.toNanoseconds())) / std.time.ns_per_s;
}

/// Whether a new size should be laid out in this frame. If not, a frame is asked for
/// when it should be.
pub fn due(p: *const Page, c: *ui.Context) bool {
    if (!c.live_resizing or p.list == null or p.resize_cost < affordable) return true;
    const left = p.resized_at + @min(p.resize_cost * 2, longest_wait) - now();
    if (left <= 0) return true;
    c.frameIn(@floatCast(left));
    return false;
}

/// A new size was laid out, starting at `from`.
pub fn done(p: *Page, from: f64) void {
    p.resized_at = now();
    p.resize_cost = p.resized_at - from;
}
