//! Watching file descriptors and processes on the app's thread, with its
//! looper: a handler runs when a pipe or pseudo-terminal has bytes to
//! read, or once when a child process exits (its pidfd becomes readable
//! then: Android 12 and later, whose apps may open one). Nothing polls.
const std = @import("std");
const activity = @import("activity.zig");

pub const Handler = *const fn (ctx: ?*anyopaque) callconv(.c) void;

extern "c" fn close(fd: c_int) c_int;

const Source = struct {
    base: activity.Source = .{ .fire = fire },
    fd: c_int,
    ctx: ?*anyopaque,
    handler: Handler,
    /// A process's pidfd: nanoui's, closed with the watch; fires once.
    pidfd: bool = false,
    watched: bool = true,

    fn fire(b: *activity.Source, _: c_int) void {
        const s: *Source = @fieldParentPtr("base", b);
        if (s.pidfd) {
            activity.unwatch(s.fd, &s.base);
            s.watched = false;
        }
        s.handler(s.ctx);
    }
};

/// A source that calls its handler on the app's thread until canceled.
pub const Watch = struct {
    source: *Source,

    pub fn cancel(w: Watch) void {
        const s = w.source;
        if (s.watched) activity.unwatch(s.fd, &s.base);
        if (s.pidfd) _ = close(s.fd);
        std.heap.c_allocator.destroy(s);
    }
};

fn make(fd: c_int, pidfd: bool, ctx: ?*anyopaque, handler: Handler) !Watch {
    const s = try std.heap.c_allocator.create(Source);
    errdefer std.heap.c_allocator.destroy(s);
    s.* = .{ .fd = fd, .ctx = ctx, .handler = handler, .pidfd = pidfd };
    try activity.watch(fd, &s.base);
    return .{ .source = s };
}

/// Calls `handler(ctx)` on the app's thread whenever `fd` can be read
/// (and at end of file). The handler reads what is there.
pub fn readable(fd: std.posix.fd_t, ctx: ?*anyopaque, handler: Handler) !Watch {
    return make(fd, false, ctx, handler);
}

/// Calls `handler(ctx)` on the app's thread when process `pid` exits.
pub fn exited(pid: std.posix.pid_t, ctx: ?*anyopaque, handler: Handler) !Watch {
    // Before Android 12, the system's filter of an app's calls may end the
    // app for pidfd_open rather than refuse it.
    const a = activity.activity orelse return error.ProcessWatchUnsupported;
    if (a.sdkVersion < 31) return error.ProcessWatchUnsupported;
    const r = std.os.linux.pidfd_open(pid, 0);
    if (std.os.linux.errno(r) != .SUCCESS) return error.ProcessWatchUnsupported;
    const fd: c_int = @intCast(r);
    errdefer _ = close(fd);
    return make(fd, true, ctx, handler);
}
