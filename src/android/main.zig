//! The app's `main` on Android. An app is a library NativeActivity loads,
//! with no start code of its own: nanoui exports the function it calls,
//! and calls `main` on the app's thread (`activity.zig`) with what Zig's
//! start code would give it (`std.process.Init`, or its `Minimal`). The
//! library's root is made by `android.library` (tools/android/apk.zig):
//! the app's `main`, and this file's entry and panic handler.
const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const ndk = @import("ndk.zig");
const activity = @import("activity.zig");
const jni = @import("jni.zig");

/// Calls a boolean method of the NativeActivity subclass on the app thread.
pub fn activityBoolean(name: [*:0]const u8) ?bool {
    if (!activity.onAppThread()) return null;
    const env = activity.env orelse return null;
    const host = activity.activity orelse return null;
    return jni.call(env, host.clazz, name, "()Z", &.{});
}

/// Copies a subclass method's Java string result into allocator-owned UTF-8.
pub fn activityString(gpa: std.mem.Allocator, name: [*:0]const u8) !?[]u8 {
    if (!activity.onAppThread()) return error.ActivityUnavailable;
    const env = activity.env orelse return error.ActivityUnavailable;
    const host = activity.activity orelse return error.ActivityUnavailable;
    const result = jni.call(env, host.clazz, name, "()Ljava/lang/String;", &.{}) orelse
        return error.ActivityCallFailed;
    defer jni.deleteLocal(env, result);
    return jni.fromString(env, gpa, result);
}

comptime {
    // std's signal handlers, as bionic lays them out.
    _ = @import("sigaction.zig");
}

/// NativeActivity's entry, on the activity's thread.
export fn ANativeActivity_onCreate(a: *ndk.ANativeActivity, saved: ?*anyopaque, saved_size: usize) callconv(.c) void {
    _ = saved;
    _ = saved_size;
    activity.create(a);
}

const safe = builtin.mode == .debug or builtin.mode == .safe;

/// Panics go to the log at once, before the process ends (what it writes
/// to stderr may not get there in time), then as Zig's own.
pub fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    var buf: [512]u8 = undefined;
    ndk.log(ndk.LOG_FATAL, std.fmt.bufPrint(&buf, "panic: {s}", .{msg}) catch msg);
    std.debug.defaultPanic(msg, first_trace_addr);
}

pub const Panic = std.debug.FullPanic(panic);

/// Calls the root's `main` with `args` and the process's environment.
pub fn run(args: []const [*:0]const u8) void {
    if (!@hasDecl(root, "main")) @compileError("nanoui on Android calls the root's `pub fn main`");
    var env_count: usize = 0;
    while (std.c.environ[env_count] != null) env_count += 1;
    const environ: std.process.Environ.Block = .{ .slice = std.c.environ[0..env_count :null] };
    const F = @TypeOf(root.main);
    const params = @typeInfo(F).@"fn".param_types;
    if (params.len == 0) return finish(root.main());
    if (params[0].? == std.process.Init.Minimal) return finish(root.main(.{
        .args = .{ .vector = args },
        .environ = .{ .block = environ },
    }));

    var safe_allocator: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer if (safe) {
        _ = safe_allocator.deinit();
    };
    const gpa = if (safe) safe_allocator.allocator() else std.heap.c_allocator;
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(gpa, .{
        .argv0 = .init(.{ .vector = args }),
        .environ = .{ .block = environ },
    });
    defer threaded.deinit();
    var environ_map = std.process.Environ.createMap(.{ .block = environ }, gpa) catch {
        ndk.log(ndk.LOG_WARN, "nanoui: no memory for the environment");
        return;
    };
    defer environ_map.deinit();
    const preopens = std.process.Preopens.init(arena.allocator()) catch return;
    finish(root.main(.{
        .minimal = .{
            .args = .{ .vector = args },
            .environ = .{ .block = environ },
        },
        .arena = &arena,
        .gpa = gpa,
        // Host names looked up by Android (`lookup.zig`), not /etc/resolv.conf's.
        .io = @import("lookup.zig").io(&threaded),
        .environ_map = &environ_map,
        .preopens = preopens,
    }));
}

/// What `main` returned: an error is logged, as Zig's start code does.
fn finish(result: anytype) void {
    const R = @TypeOf(result);
    if (@typeInfo(R) != .error_union) return;
    _ = result catch |err| {
        std.log.err("{t}", .{err});
        if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
    };
}
