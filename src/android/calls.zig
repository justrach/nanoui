//! Calls on the app's thread, asked for from any thread: now (`onMain`)
//! or after a while (`after`, a timerfd each), in the order asked. They
//! go through one queue, which an eventfd wakes the loop for; timers are
//! made on the app's thread as their calls come out of it.
const std = @import("std");
const activity = @import("activity.zig");

pub const Func = *const fn (?*anyopaque) callconv(.c) void;

const Call = struct { ms: u64, ctx: ?*anyopaque, func: Func };

var mutex: std.c.pthread_mutex_t = .{};
var queue: std.ArrayList(Call) = .empty;
var fd: c_int = -1;
var source: activity.Source = .{ .fire = drain };

extern "c" fn eventfd(initval: c_uint, flags: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn timerfd_create(clock: c_int, flags: c_int) c_int;
extern "c" fn timerfd_settime(fd: c_int, flags: c_int, new: *const ItimerSpec, old: ?*ItimerSpec) c_int;
const ItimerSpec = extern struct { interval: std.c.timespec, value: std.c.timespec };
const CLOCK_MONOTONIC = 1;
const O_NONBLOCK = 0o4000;
const O_CLOEXEC = 0o2000000;

/// On the app's thread, as its loop starts: the queue's wake-up.
pub fn start() void {
    fd = eventfd(0, O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return;
    activity.watch(fd, &source) catch {
        _ = close(fd);
        fd = -1;
    };
}

/// On the app's thread, as its loop ends: calls not made are dropped,
/// timers too.
pub fn stop() void {
    // No call can be asked for once the descriptor is taken.
    _ = std.c.pthread_mutex_lock(&mutex);
    const old = fd;
    fd = -1;
    queue.clearAndFree(std.heap.c_allocator);
    _ = std.c.pthread_mutex_unlock(&mutex);
    if (old < 0) return;
    activity.unwatch(old, &source);
    _ = close(old);
    while (timers.items.len > 0) {
        const t = timers.items[timers.items.len - 1];
        activity.unwatch(t.fd, &t.source);
        t.done();
    }
    timers.clearAndFree(std.heap.c_allocator);
}

/// The timers waiting, on the app's thread.
var timers: std.ArrayList(*Timer) = .empty;

/// Calls `func(ctx)` on the app's thread after `ms` milliseconds (0: as
/// soon as its loop runs), from any thread. Dropped when there is no loop.
pub fn after(ms: u64, ctx: ?*anyopaque, func: Func) void {
    _ = std.c.pthread_mutex_lock(&mutex);
    defer _ = std.c.pthread_mutex_unlock(&mutex);
    if (fd < 0) return;
    queue.append(std.heap.c_allocator, .{ .ms = ms, .ctx = ctx, .func = func }) catch return;
    const one: u64 = 1;
    _ = std.c.write(fd, std.mem.asBytes(&one), 8);
}

fn drain(_: *activity.Source, _: c_int) void {
    var n: u64 = 0;
    _ = std.c.read(fd, std.mem.asBytes(&n), 8);
    // The calls there now; those they ask for wait for the next round.
    _ = std.c.pthread_mutex_lock(&mutex);
    var batch = queue;
    queue = .empty;
    _ = std.c.pthread_mutex_unlock(&mutex);
    defer batch.deinit(std.heap.c_allocator);
    for (batch.items) |c| {
        if (c.ms == 0) c.func(c.ctx) else Timer.start(c);
    }
}

/// A call waiting for its time, which frees itself once made.
const Timer = struct {
    source: activity.Source = .{ .fire = fire },
    fd: c_int,
    call: Call,

    fn start(c: Call) void {
        const tfd = timerfd_create(CLOCK_MONOTONIC, O_NONBLOCK | O_CLOEXEC);
        if (tfd < 0) return c.func(c.ctx);
        const t = std.heap.c_allocator.create(Timer) catch {
            _ = close(tfd);
            return;
        };
        t.* = .{ .fd = tfd, .call = c };
        const spec: ItimerSpec = .{
            .interval = .{ .sec = 0, .nsec = 0 },
            .value = .{ .sec = @intCast(c.ms / 1000), .nsec = @intCast((c.ms % 1000) * std.time.ns_per_ms) },
        };
        if (timerfd_settime(tfd, 0, &spec, null) != 0) return t.done();
        timers.append(std.heap.c_allocator, t) catch return t.done();
        activity.watch(tfd, &t.source) catch return t.done();
    }

    fn fire(s: *activity.Source, _: c_int) void {
        const t: *Timer = @fieldParentPtr("source", s);
        activity.unwatch(t.fd, &t.source);
        const c = t.call;
        t.done();
        c.func(c.ctx);
    }

    fn done(t: *Timer) void {
        for (timers.items, 0..) |x, i| if (x == t) {
            _ = timers.swapRemove(i);
            break;
        };
        _ = close(t.fd);
        std.heap.c_allocator.destroy(t);
    }
};
