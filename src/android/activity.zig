//! The entry on Android. NativeActivity loads the app's library and calls
//! `ANativeActivity_onCreate` on its main thread, which is Java's: it can't
//! block there. The app's `main` runs on a thread of its own instead,
//! nanoui's main thread on Android, with a looper (ALooper) for its loop;
//! the activity's callbacks become commands sent to it. Those after which
//! the activity lets go of something (the window, the input queue) wait
//! until the app's thread is done with it. Java calls that must run on
//! Java's thread go there as jobs (`onUiThread`).
//!
//! Arguments and environment come from the intent's extras, and what's
//! written to stdout and stderr goes to the log (`launch.zig`).
const std = @import("std");
const builtin = @import("builtin");
const ndk = @import("ndk.zig");
const jni = @import("jni.zig");
const bars = @import("bars.zig");
const calls = @import("calls.zig");
const launch = @import("launch.zig");
const Config = @import("config.zig").Config;
const Event = @import("event.zig").Event;

/// What the activity tells the app's thread.
pub const Command = union(enum) {
    start,
    resume_,
    pause,
    stop,
    focus: bool,
    window_created: *ndk.ANativeWindow,
    window_resized,
    window_redraw,
    window_destroyed,
    input_created: *ndk.AInputQueue,
    input_destroyed,
    /// What the system covers of the window, in pixels.
    insets: Insets,
    config: Config,
    destroy,
};

/// The system's bars and the display's cutout (top, left, bottom, right),
/// and the keyboard's height, in pixels.
pub const Insets = struct {
    bars: [4]i32 = .{ 0, 0, 0, 0 },
    keyboard: i32 = 0,
};

/// Receives the commands on the app's thread (the App, once made).
pub const Listener = struct {
    ctx: *anyopaque,
    command: *const fn (ctx: *anyopaque, cmd: Command) void,
    /// Whether the app takes an event: told Android before it's handled.
    takes: *const fn (ctx: *anyopaque, event: *const Event) bool,
    /// An event taken.
    input: *const fn (ctx: *anyopaque, event: *const Event) void,
};

/// The activity while it lives; its `clazz` is the NativeActivity.
pub var activity: ?*ndk.ANativeActivity = null;
/// The app's thread's looper, and its Java environment.
pub var looper: ?*ndk.ALooper = null;
pub var env: ?jni.Env = null;
/// What the app's thread has been told last (`Command`s, applied).
pub var window: ?*ndk.ANativeWindow = null;
pub var input_queue: ?*ndk.AInputQueue = null;
pub var insets: Insets = .{};
pub var config: Config = .{};
/// The configuration as Java's thread last read it, for its own use.
pub var ui_config: Config = .{};
/// The app's folders (internalDataPath, externalDataPath), copied: they
/// stay readable from any thread after the activity goes.
pub var files_dir: [512:0]u8 = @splat(0);
pub var external_dir: [512:0]u8 = @splat(0);
pub var resumed: bool = false;
pub var focused: bool = false;
pub var destroying: bool = false;
pub var listener: ?Listener = null;
var app_thread: ?std.Thread.Id = null;

/// The caller runs on the app's thread (nanoui's main thread here).
pub fn onAppThread() bool {
    return app_thread != null and app_thread.? == std.Thread.getCurrentId();
}

extern "c" fn close(fd: c_int) c_int;
extern "c" fn eventfd(initval: c_uint, flags: c_int) c_int;

const EFD_CLOEXEC = 0o2000000;
const EFD_NONBLOCK = 0o4000;

/// The commands sent and not yet handled, each with its ticket, guarded
/// by `mutex`.
var mutex: std.c.pthread_mutex_t = .{};
var cond: std.c.pthread_cond_t = .{};
const Queued = struct { cmd: Command, ticket: u64 };
var queue: [32]Queued = undefined;
var queued: usize = 0;
var sent: u64 = 0;
/// The command Java's thread waits for (0: none), and whether it's done.
var waiting: u64 = 0;
var waited: bool = false;
/// The commands being handled now, outermost first: a dialog's wait inside
/// one handles others. Whether each is a redraw, which a wait lets go.
var applying: [8]struct { ticket: u64, redraw: bool } = undefined;
var applying_len: usize = 0;
var running = false;
/// Wakes the app's thread for commands (an eventfd).
var commands_fd: c_int = -1;
var thread: ?std.Thread = null;
/// Arguments from the intent, as the app's `main` gets them.
var argv: std.ArrayList([*:0]const u8) = .empty;

fn lock() void {
    _ = std.c.pthread_mutex_lock(&mutex);
}

fn unlock() void {
    _ = std.c.pthread_mutex_unlock(&mutex);
}

/// From the activity's thread: queues `cmd` for the app's thread, and
/// when `wait`, waits until it was handled (or the app's thread is gone).
fn send(cmd: Command, wait: bool) void {
    lock();
    defer unlock();
    if (!running) return;
    // Full: the app's thread is stuck; the command waits its turn.
    while (queued == queue.len and running) _ = std.c.pthread_cond_wait(&cond, &mutex);
    if (!running) return;
    sent += 1;
    const ticket = sent;
    queue[queued] = .{ .cmd = cmd, .ticket = ticket };
    queued += 1;
    const one: u64 = 1;
    _ = std.c.write(commands_fd, std.mem.asBytes(&one), 8);
    if (!wait) return;
    waiting = ticket;
    waited = false;
    while (!waited and running) _ = std.c.pthread_cond_wait(&cond, &mutex);
    waiting = 0;
}

/// Under the lock: command `ticket` is done, for Java's thread if it waits.
fn done(ticket: u64) void {
    if (ticket != waiting) return;
    waited = true;
    _ = std.c.pthread_cond_broadcast(&cond);
}

/// The app's thread is about to wait inside a command (a dialog asked for
/// in a redraw's frame): Java's thread, waiting for that redraw, goes on,
/// or neither would.
pub fn beginWait() void {
    lock();
    defer unlock();
    for (applying[0..applying_len]) |c| if (c.redraw) done(c.ticket);
}

/// On the app's thread: handles the commands that came.
fn onCommands() void {
    var n: u64 = 0;
    _ = std.c.read(commands_fd, std.mem.asBytes(&n), 8);
    while (true) {
        lock();
        if (queued == 0) {
            unlock();
            break;
        }
        const q = queue[0];
        std.mem.copyForwards(Queued, queue[0 .. queued - 1], queue[1..queued]);
        queued -= 1;
        // A place in the queue for a command waiting for one.
        _ = std.c.pthread_cond_broadcast(&cond);
        const depth = applying_len;
        if (depth < applying.len) applying[depth] = .{ .ticket = q.ticket, .redraw = q.cmd == .window_redraw };
        applying_len = @min(depth + 1, applying.len);
        unlock();
        apply(q.cmd);
        lock();
        applying_len = depth;
        done(q.ticket);
        unlock();
    }
}

/// Applies a command to what the app's thread knows, then tells the
/// listener; the window and input queue go only after it was told.
fn apply(cmd: Command) void {
    switch (cmd) {
        .window_created => |w| window = w,
        .input_created => |q| {
            input_queue = q;
            ndk.AInputQueue_attachLooper(q, looper.?, ident_input, null, null);
        },
        .insets => |i| insets = i,
        .config => |c| config = c,
        .resume_ => resumed = true,
        .pause => resumed = false,
        .focus => |f| focused = f,
        .destroy => {
            lock();
            destroying = true;
            unlock();
        },
        else => {},
    }
    if (listener) |l| l.command(l.ctx, cmd);
    switch (cmd) {
        .window_destroyed => window = null,
        .input_destroyed => detachInput(),
        else => {},
    }
}

fn detachInput() void {
    const q = input_queue orelse return;
    ndk.AInputQueue_detachLooper(q);
    input_queue = null;
}

/// On the app's thread: the input queue's events, to the listener.
fn onInput() void {
    const q = input_queue orelse return;
    var event: ?*ndk.AInputEvent = null;
    while (ndk.AInputQueue_getEvent(q, &event) >= 0) {
        const e = event orelse continue;
        // The input method sees keys first (a software keyboard's).
        if (ndk.AInputQueue_preDispatchEvent(q, e) != 0) continue;
        // Finished before it's handled (`event.zig`): a copy is.
        const copy = @import("event.zig").read(e);
        const l = listener;
        const taken = copy != null and l != null and l.?.takes(l.?.ctx, &copy.?);
        ndk.AInputQueue_finishEvent(q, e, @intFromBool(taken));
        if (taken) l.?.input(l.?.ctx, &copy.?);
        // The listener may have let go of the queue (a window closed the app).
        if (input_queue != q) break;
    }
}

// The app's thread's loop. Its looper's callbacks can't run the loop
// again (a dialog waiting for its answer would): every source here is
// told apart by its ident instead, and handled once `ALooper_pollOnce` has
// returned, where waiting again is safe.

const ident_commands = 1;
const ident_input = 2;
const ident_source = 3;

/// Something the loop watches: a timer, a pipe, the queue of calls.
pub const Source = struct {
    fire: *const fn (s: *Source, events: c_int) void,
    /// Its number with the looper, once watched.
    id: usize = 0,
};

/// The sources watched, by a number never used again: a response the
/// looper kept for one removed since finds none (not a newer source made
/// where the old one was).
var sources: std.AutoHashMapUnmanaged(usize, *Source) = .empty;
var next_id: usize = 1;

/// Calls `s.fire` on the app's thread whenever `fd` can be read.
pub fn watch(fd: c_int, s: *Source) !void {
    const l = looper orelse return error.NoLooper;
    s.id = next_id;
    next_id += 1;
    try sources.put(std.heap.c_allocator, s.id, s);
    if (ndk.ALooper_addFd(l, fd, ident_source, ndk.LOOPER_EVENT_INPUT, null, @ptrFromInt(s.id)) != 1) {
        _ = sources.remove(s.id);
        return error.LooperFailed;
    }
}

/// Stops watching `fd`; `s` may be freed once this returns.
pub fn unwatch(fd: c_int, s: *Source) void {
    if (looper) |l| _ = ndk.ALooper_removeFd(l, fd);
    _ = sources.remove(s.id);
}

/// The display's next refresh is due (a choreographer's callback, which
/// only marks it): `frame` is called once the looper returns.
pub var frame_due = false;
pub var on_frame: ?*const fn () void = null;

/// Runs the app's thread's loop once: waits up to `timeout_ms` (-1: until
/// something comes), then handles what came.
pub fn poll(timeout_ms: c_int) void {
    var events: c_int = 0;
    var data: ?*anyopaque = null;
    const ident = ndk.ALooper_pollOnce(timeout_ms, null, &events, &data);
    switch (ident) {
        ident_commands => onCommands(),
        ident_input => onInput(),
        ident_source => if (sources.get(@intFromPtr(data))) |s| s.fire(s, events),
        else => {},
    }
    if (frame_due) {
        frame_due = false;
        if (on_frame) |f| f();
    }
}

/// Wakes the app's thread's loop (a flag changed for it).
pub fn wake() void {
    if (looper) |l| ndk.ALooper_wake(l);
}

/// Asks the activity to finish: its window goes, `destroy` follows.
pub fn finish() void {
    if (activity) |a| if (!destroying) ndk.ANativeActivity_finish(a);
}

// Java's thread's jobs.

const Job = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, env: jni.Env) void,
};

var jobs: std.ArrayList(Job) = .empty;
var jobs_fd: c_int = -1;
var ui_looper: ?*ndk.ALooper = null;

/// Calls `func(ctx, env)` on the activity's thread (Java's) soon, from any
/// thread: for Java's classes that must be used there (dialogs, views).
/// Not called if the activity goes first: `func` must then not be needed.
pub fn onUiThread(ctx: ?*anyopaque, func: *const fn (ctx: ?*anyopaque, env: jni.Env) void) bool {
    lock();
    defer unlock();
    if (activity == null or destroying) return false;
    jobs.append(std.heap.c_allocator, .{ .ctx = ctx, .func = func }) catch return false;
    const one: u64 = 1;
    _ = std.c.write(jobs_fd, std.mem.asBytes(&one), 8);
    return true;
}

fn onJobs(fd: c_int, _: c_int, _: ?*anyopaque) callconv(.c) c_int {
    var n: u64 = 0;
    _ = std.c.read(fd, std.mem.asBytes(&n), 8);
    while (true) {
        lock();
        if (jobs.items.len == 0 or activity == null) {
            jobs.clearRetainingCapacity();
            unlock();
            break;
        }
        const job = jobs.orderedRemove(0);
        unlock();
        job.func(job.ctx, activity.?.env);
    }
    return 1;
}

// The activity's callbacks, on its thread.

fn onStart(a: *ndk.ANativeActivity) callconv(.c) void {
    if (a != activity) return;
    send(.start, false);
}

fn onResume(a: *ndk.ANativeActivity) callconv(.c) void {
    if (a != activity) return;
    send(.resume_, false);
}

fn onPause(a: *ndk.ANativeActivity) callconv(.c) void {
    if (a != activity) return;
    send(.pause, false);
}

fn onStop(a: *ndk.ANativeActivity) callconv(.c) void {
    if (a != activity) return;
    send(.stop, false);
}

fn onFocus(a: *ndk.ANativeActivity, has: c_int) callconv(.c) void {
    if (a != activity) return;
    send(.{ .focus = has != 0 }, false);
    updateInsets(a);
}

fn onWindowCreated(a: *ndk.ANativeActivity, w: *ndk.ANativeWindow) callconv(.c) void {
    if (a != activity) return;
    updateInsets(a);
    send(.{ .window_created = w }, false);
}

fn onWindowResized(a: *ndk.ANativeActivity, _: *ndk.ANativeWindow) callconv(.c) void {
    if (a != activity) return;
    updateInsets(a);
    send(.window_resized, false);
}

fn onWindowRedraw(a: *ndk.ANativeActivity, _: *ndk.ANativeWindow) callconv(.c) void {
    if (a != activity) return;
    // Shown once drawn: waits for the frame.
    send(.window_redraw, true);
}

fn onWindowDestroyed(a: *ndk.ANativeActivity, _: *ndk.ANativeWindow) callconv(.c) void {
    if (a != activity) return;
    send(.window_destroyed, true);
}

fn onInputCreated(a: *ndk.ANativeActivity, q: *ndk.AInputQueue) callconv(.c) void {
    if (a != activity) return;
    send(.{ .input_created = q }, false);
}

fn onInputDestroyed(a: *ndk.ANativeActivity, _: *ndk.AInputQueue) callconv(.c) void {
    if (a != activity) return;
    send(.input_destroyed, true);
}

fn onContentRect(a: *ndk.ANativeActivity, _: *const ndk.ARect) callconv(.c) void {
    if (a != activity) return;
    // The bars or the keyboard came or went (`bars.fitContent`).
    updateInsets(a);
}

fn onConfig(a: *ndk.ANativeActivity) callconv(.c) void {
    if (a != activity) return;
    ui_config = @import("config.zig").read(a.env, a.clazz);
    send(.{ .config = ui_config }, false);
    updateInsets(a);
}

fn onDestroy(a: *ndk.ANativeActivity) callconv(.c) void {
    // One retired already, as the next one came (`create`).
    if (a != activity) return;
    retire(a);
}

/// The activity goes: the app's `main` returns first, its thread ends,
/// and what was the activity's is let go.
fn retire(a: *ndk.ANativeActivity) void {
    // A dialog still up goes first (or Android says the activity leaked it).
    @import("dialog.zig").dismissShowing(a.env);
    @import("ime.zig").release(a.env);
    send(.destroy, false);
    // The app's `main` returns, and its thread ends, before the activity
    // (and its Java objects) go.
    if (thread) |t| t.join();
    thread = null;
    if (ui_looper) |l| {
        _ = ndk.ALooper_removeFd(l, jobs_fd);
        ndk.ALooper_release(l);
    }
    ui_looper = null;
    lock();
    jobs.clearAndFree(std.heap.c_allocator);
    activity = null;
    unlock();
    _ = close(jobs_fd);
    _ = close(commands_fd);
    jobs_fd = -1;
    commands_fd = -1;
    if (argv.items.len > 1) for (argv.items[1..]) |arg| std.heap.c_allocator.free(std.mem.span(arg));
    launch.unsetExtras();
    argv.clearAndFree(std.heap.c_allocator);
}

/// Reads what the system covers of the window, and tells the app's
/// thread if it changed.
fn updateInsets(a: *ndk.ANativeActivity) void {
    const now = bars.read(a.env, a.clazz, a.sdkVersion) orelse return;
    if (std.meta.eql(now, last_insets)) return;
    last_insets = now;
    send(.{ .insets = now }, false);
}
var last_insets: Insets = .{};

/// The entry NativeActivity calls, on its thread, once its window is made.
pub fn create(a: *ndk.ANativeActivity) void {
    launch.redirectOutput();
    a.callbacks.* = .{
        .onStart = onStart,
        .onResume = onResume,
        .onSaveInstanceState = null,
        .onPause = onPause,
        .onStop = onStop,
        .onDestroy = onDestroy,
        .onWindowFocusChanged = onFocus,
        .onNativeWindowCreated = onWindowCreated,
        .onNativeWindowResized = onWindowResized,
        .onNativeWindowRedrawNeeded = onWindowRedraw,
        .onNativeWindowDestroyed = onWindowDestroyed,
        .onInputQueueCreated = onInputCreated,
        .onInputQueueDestroyed = onInputDestroyed,
        .onContentRectChanged = onContentRect,
        .onConfigurationChanged = onConfig,
        .onLowMemory = null,
    };
    // A process can host the activity again: after one finished, or before
    // its end came (Android may destroy it once the next is up).
    if (activity) |old| retire(old);
    window = null;
    input_queue = null;
    insets = .{};
    last_insets = .{};
    config = @import("config.zig").read(a.env, a.clazz);
    ui_config = config;
    copyPath(&files_dir, a.internalDataPath);
    copyPath(&external_dir, a.externalDataPath orelse a.internalDataPath);
    resumed = false;
    focused = false;
    destroying = false;
    listener = null;
    queued = 0;
    sent = 0;
    waiting = 0;
    applying_len = 0;
    activity = a;
    // Its colors are nanoui's: four bytes a pixel, not NativeActivity's 565.
    ndk.ANativeActivity_setWindowFormat(a, ndk.WINDOW_FORMAT_RGBA_8888);
    bars.edgeToEdge(a.env, a.clazz, a.sdkVersion);
    launch.readExtras(a.env, a.clazz, &argv);
    commands_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    jobs_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    ui_looper = ndk.ALooper_forThread();
    if (ui_looper) |l| {
        ndk.ALooper_acquire(l);
        _ = ndk.ALooper_addFd(l, jobs_fd, 3, ndk.LOOPER_EVENT_INPUT, onJobs, null);
    }
    running = true;
    thread = std.Thread.spawn(.{ .stack_size = 8 << 20 }, appThread, .{a.vm}) catch {
        running = false;
        ndk.log(ndk.LOG_WARN, "nanoui: no thread for the app");
        ndk.ANativeActivity_finish(a);
        return;
    };
}

fn copyPath(buf: *[512:0]u8, path: ?[*:0]const u8) void {
    const p = std.mem.span(path orelse return);
    const n = @min(p.len, buf.len);
    @memcpy(buf[0..n], p[0..n]);
    buf[n] = 0;
}

/// The app's thread: its looper, then the app's `main`.
fn appThread(vm: jni.VM) void {
    const l = ndk.ALooper_prepare(ndk.LOOPER_PREPARE_ALLOW_NON_CALLBACKS);
    ndk.ALooper_acquire(l);
    looper = l;
    app_thread = std.Thread.getCurrentId();
    _ = ndk.ALooper_addFd(l, commands_fd, ident_commands, ndk.LOOPER_EVENT_INPUT, null, null);
    env = jni.attach(vm);
    calls.start();
    @import("main.zig").run(argv.items);
    // `main` returned: the activity finishes, if it wasn't already.
    listener = null;
    calls.stop();
    finish();
    detachInput();
    _ = ndk.ALooper_removeFd(l, commands_fd);
    sources.clearAndFree(std.heap.c_allocator);
    frame_due = false;
    on_frame = null;
    lock();
    running = false;
    _ = std.c.pthread_cond_broadcast(&cond);
    unlock();
    if (env) |e| {
        @import("dialog.zig").threadEnded(e);
        jni.detach(vm);
    }
    env = null;
    looper = null;
    app_thread = null;
    ndk.ALooper_release(l);
}
