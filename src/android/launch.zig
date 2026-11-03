//! What an app starts with on Android, which has no command line: the
//! arguments and environment come from the intent's extras, and stdout
//! and stderr (std.log, std.debug.print) go to the log under the tag
//! "nanoui" (`adb logcat -s nanoui`). Each argument is an extra of its
//! own, exactly as given (`tools/android/run.sh` passes them so):
//!
//!     am start -n <id>/android.app.NativeActivity --es nanoui.arg.0 --nanoui-dark --es nanoui.env.0 NANOUI_DEBUG=1
//!
//! or, typed by hand, string arrays (am splits them at commas):
//! `--esa nanoui.args --nanoui-dark --esa nanoui.env NANOUI_DEBUG=1`.
//! Only a debuggable build reads them: in a release, any app could.
const std = @import("std");
const ndk = @import("ndk.zig");
const jni = @import("jni.zig");

extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// The variables an intent set: unset as its activity goes, so the next
/// launch in this process starts without them.
var set: std.ArrayList([:0]u8) = .empty;

pub fn unsetExtras() void {
    for (set.items) |name| {
        _ = unsetenv(name);
        std.heap.c_allocator.free(name);
    }
    set.clearAndFree(std.heap.c_allocator);
}

/// The intent's arguments, after "nanoui" (as argv[0]), into `argv`
/// (C strings of the C allocator's), and its environment variables set.
pub fn readExtras(env: jni.Env, act: jni.Object, argv: *std.ArrayList([*:0]const u8)) void {
    const gpa = std.heap.c_allocator;
    argv.clearRetainingCapacity();
    argv.append(gpa, "nanoui") catch return;
    const frame = jni.Frame.push(env, 64);
    defer frame.pop();
    const intent = jni.call(env, act, "getIntent", "()Landroid/content/Intent;", &.{}) orelse return;
    // Any app may start the launcher activity with any extras: only a
    // debuggable build (a debug APK, adb's) takes them, so another app
    // can't play steps in a release build's window or set its environment.
    if (!debuggable(env, act)) {
        if (hasExtras(env, intent)) ndk.log(ndk.LOG_WARN, "nanoui: a release build ignores the intent's arguments and variables, which any app could send: build for debug to pass them");
    } else for ([_]bool{ true, false }) |args| {
        // String arrays first, then one extra each.
        const k = jni.string(env, if (args) "nanoui.args" else "nanoui.env");
        const array = jni.call(env, intent, "getStringArrayExtra", "(Ljava/lang/String;)[Ljava/lang/String;", &.{jni.ref(k)}) orelse null;
        if (array != null) for (0..@intCast(jni.arrayLength(env, array))) |i| {
            take(env, jni.arrayElement(env, array, @intCast(i)), args, argv);
        };
        var i: usize = 0;
        while (i < 1000) : (i += 1) {
            var buf: [32]u8 = undefined;
            const key = std.fmt.bufPrint(&buf, "nanoui.{s}.{d}", .{ if (args) "arg" else "env", i }) catch break;
            const name = jni.string(env, key);
            defer jni.deleteLocal(env, name);
            const value = jni.call(env, intent, "getStringExtra", "(Ljava/lang/String;)Ljava/lang/String;", &.{jni.ref(name)}) orelse null;
            if (value == null) break;
            defer jni.deleteLocal(env, value);
            take(env, value, args, argv);
        }
    }
    // Where temporary files go: the app's cache (Android sets no TMPDIR).
    if (getenv("TMPDIR") == null) if (cacheDir(env, act)) |dir| {
        defer gpa.free(dir);
        const z = gpa.dupeSentinel(u8, dir, 0) catch return;
        defer gpa.free(z);
        _ = setenv("TMPDIR", z, 1);
    };
}

/// One extra's string: an argument, or NAME=VALUE set in the environment.
fn take(env: jni.Env, str: jni.Object, arg: bool, argv: *std.ArrayList([*:0]const u8)) void {
    const gpa = std.heap.c_allocator;
    const value = (jni.fromString(env, gpa, str) catch null) orelse return;
    defer gpa.free(value);
    const z = gpa.dupeSentinel(u8, value, 0) catch return;
    if (arg) {
        argv.append(gpa, z) catch gpa.free(z);
        return;
    }
    defer gpa.free(z);
    const eq = std.mem.indexOfScalar(u8, z, '=') orelse return;
    z[eq] = 0;
    if (setenv(z[0..eq :0], z[eq + 1 ..], 1) != 0) return;
    const name = gpa.dupeSentinel(u8, z[0..eq], 0) catch return;
    set.append(gpa, name) catch gpa.free(name);
}

fn cacheDir(env: jni.Env, act: jni.Object) ?[]u8 {
    const file = jni.call(env, act, "getCacheDir", "()Ljava/io/File;", &.{}) orelse return null;
    const path = jni.call(env, file, "getAbsolutePath", "()Ljava/lang/String;", &.{}) orelse return null;
    return jni.fromString(env, std.heap.c_allocator, path) catch null;
}

/// Whether the intent carries arguments or variables for nanoui.
fn hasExtras(env: jni.Env, intent: jni.Object) bool {
    for ([_][]const u8{ "nanoui.args", "nanoui.env", "nanoui.arg.0", "nanoui.env.0" }) |key| {
        const k = jni.string(env, key);
        defer jni.deleteLocal(env, k);
        if (jni.call(env, intent, "hasExtra", "(Ljava/lang/String;)Z", &.{jni.ref(k)}) orelse false) return true;
    }
    return false;
}

/// Whether the app is debuggable (ApplicationInfo.FLAG_DEBUGGABLE).
fn debuggable(env: jni.Env, act: jni.Object) bool {
    const info = jni.call(env, act, "getApplicationInfo", "()Landroid/content/pm/ApplicationInfo;", &.{}) orelse return false;
    const flags = jni.intField(env, info, "flags") orelse return false;
    return flags & 0x2 != 0;
}

/// stdout and stderr to the log, a line at a time, from a thread that
/// reads them (once a process).
pub fn redirectOutput() void {
    const S = struct {
        var done = false;
        fn pump(fd: c_int) void {
            var buf: [4096]u8 = undefined;
            var len: usize = 0;
            while (true) {
                const n = std.c.read(fd, buf[len..].ptr, buf.len - len);
                if (n <= 0) return;
                len += @intCast(n);
                var start: usize = 0;
                while (std.mem.indexOfScalarPos(u8, buf[0..len], start, '\n')) |nl| {
                    ndk.log(ndk.LOG_INFO, buf[start..nl]);
                    start = nl + 1;
                }
                // A line longer than the buffer goes as it is.
                if (start == 0 and len == buf.len) {
                    ndk.log(ndk.LOG_INFO, buf[0..len]);
                    len = 0;
                    continue;
                }
                std.mem.copyForwards(u8, buf[0 .. len - start], buf[start..len]);
                len -= start;
            }
        }
    };
    if (S.done) return;
    S.done = true;
    var fds: [2]c_int = undefined;
    if (pipe(&fds) != 0) return;
    _ = std.c.dup2(fds[1], 1);
    _ = std.c.dup2(fds[1], 2);
    _ = close(fds[1]);
    const t = std.Thread.spawn(.{}, S.pump, .{fds[0]}) catch return;
    t.detach();
}
