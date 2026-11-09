//! A frame asked for from another thread (a decoder with a new picture):
//! one flag, swapped without a lock, and one hop to the main queue, where
//! the frame is asked for at the display's pace. Asks made before the hop
//! runs are one frame. The surface stays alive while a hop is queued.
const objc = @import("../objc.zig");
const Surface = @import("surface.zig").Surface;
const wake = @import("surface_wake.zig");

/// From any thread, while the window is open.
pub fn request(self: *Surface) void {
    if (self.wake_pending.swap(true, .acq_rel)) return;
    objc.dispatchMain(wake.token(self), onMain);
}

pub fn fromContext(ctx: *anyopaque) void {
    request(@ptrCast(@alignCast(ctx)));
}

/// A frame soon, without the display link (the window hidden, or no link).
pub fn scheduleTick(self: *Surface) void {
    if (self.tick_scheduled) return;
    self.tick_scheduled = true;
    objc.dispatchAfter(@import("std").time.ns_per_s / 120, wake.token(self), tick);
}

fn tick(ptr: ?*anyopaque) callconv(.c) void {
    const self = wake.find(ptr) orelse return;
    self.tick_scheduled = false;
    if (self.dead) return self.finishDestroy();
    self.frame();
}

fn onMain(ptr: ?*anyopaque) callconv(.c) void {
    const self = wake.find(ptr) orelse return;
    self.wake_pending.store(false, .release);
    if (self.dead) return self.finishDestroy();
    self.requestFrame();
}
