//! Main-thread work after the current event, in every run loop mode, on
//! macOS and iOS. A CFRunLoop timer runs outside GCD's main queue, so a
//! dialog it opens can run a nested run loop while main-queue blocks still
//! drain (onMain's block would hold them until the dialog closes).
const std = @import("std");

const cf_soon = struct {
    const Context = extern struct { version: isize = 0, info: ?*anyopaque, retain: ?*const anyopaque = null, release: ?*const anyopaque = null, copyDescription: ?*const anyopaque = null };
    extern "c" fn CFRunLoopTimerCreate(a: ?*anyopaque, fire: f64, interval: f64, flags: usize, order: isize, callout: *const fn (*anyopaque, ?*anyopaque) callconv(.c) void, ctx: *Context) *anyopaque;
    extern "c" fn CFRunLoopAddTimer(rl: *anyopaque, t: *anyopaque, mode: *anyopaque) void;
    extern "c" fn CFRunLoopTimerInvalidate(t: *anyopaque) void;
    extern "c" fn CFRelease(p: *anyopaque) void;
    extern "c" fn CFRunLoopGetMain() *anyopaque;
    extern "c" fn CFAbsoluteTimeGetCurrent() f64;
    extern "c" const kCFRunLoopCommonModes: *anyopaque;
};

/// Calls `func(ctx)` on the main thread once the current event is done.
pub fn soon(ctx: ?*anyopaque, func: *const fn (?*anyopaque) callconv(.c) void) void {
    const Job = struct { ctx: ?*anyopaque, func: *const fn (?*anyopaque) callconv(.c) void };
    const job = std.heap.c_allocator.create(Job) catch return;
    job.* = .{ .ctx = ctx, .func = func };
    var tctx: cf_soon.Context = .{ .info = job };
    const t = cf_soon.CFRunLoopTimerCreate(null, cf_soon.CFAbsoluteTimeGetCurrent(), 0, 0, 0, struct {
        fn fire(timer: *anyopaque, info: ?*anyopaque) callconv(.c) void {
            const j: *Job = @ptrCast(@alignCast(info));
            const f = j.func;
            const c = j.ctx;
            std.heap.c_allocator.destroy(j);
            cf_soon.CFRunLoopTimerInvalidate(timer);
            cf_soon.CFRelease(timer);
            f(c);
        }
    }.fire, &tctx);
    cf_soon.CFRunLoopAddTimer(cf_soon.CFRunLoopGetMain(), t, cf_soon.kCFRunLoopCommonModes);
}
