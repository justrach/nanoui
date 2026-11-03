//! Zig 0.17.0's std lays `struct sigaction` out as glibc does on Linux
//! (the handler first); Android's C library has its own (the flags first,
//! on 64-bit targets). Every handler std sets would set the default
//! action instead: Io.Threaded's for SIGIO, which interrupts a blocked
//! call it cancels (an HTTP request racing its timeout), and for SIGPIPE,
//! which keeps a closed socket from ending the app. So nanoui's library
//! has a `sigaction` of its own in front of the C library's, which std's
//! calls bind to: it translates, and calls bionic's `sigaction64`. Hidden,
//! so nothing outside the library sees it.
const std = @import("std");
const builtin = @import("builtin");

const Zig = std.c.Sigaction;

/// Bionic's `struct sigaction` on LP64.
const Bionic = extern struct {
    flags: c_int,
    handler: ?*const anyopaque,
    mask: c_ulong,
    restorer: ?*const anyopaque,
};

extern "c" fn sigaction64(sig: c_int, act: ?*const Bionic, old: ?*Bionic) c_int;

fn sigaction(sig: c_int, act: ?*const Zig, old: ?*Zig) callconv(.c) c_int {
    var b: Bionic = undefined;
    var ob: Bionic = undefined;
    const in: ?*const Bionic = if (act) |a| blk: {
        b = .{ .flags = @bitCast(a.flags), .handler = @ptrCast(a.handler.handler), .mask = a.mask[0], .restorer = @ptrCast(a.restorer) };
        break :blk &b;
    } else null;
    const r = sigaction64(sig, in, if (old != null) &ob else null);
    if (old) |o| if (r == 0) {
        o.* = .{ .handler = .{ .handler = @ptrCast(ob.handler) }, .mask = @splat(0), .flags = @bitCast(ob.flags), .restorer = @ptrCast(@alignCast(ob.restorer)) };
        o.mask[0] = ob.mask;
    };
    return r;
}

comptime {
    // The 32-bit targets' layouts differ again: those aren't nanoui's.
    if (builtin.abi.isAndroid() and @sizeOf(usize) == 8 and @sizeOf(Zig) != @sizeOf(Bionic))
        @export(&sigaction, .{ .name = "sigaction", .visibility = .hidden });
}

test "a handler set comes back as set" {
    if (!builtin.abi.isAndroid()) return error.SkipZigTest;
    const S = struct {
        fn nothing(_: std.posix.SIG) callconv(.c) void {}
    };
    const act: std.posix.Sigaction = .{ .handler = .{ .handler = S.nothing }, .mask = std.posix.sigemptyset(), .flags = 0 };
    var old: std.posix.Sigaction = undefined;
    std.posix.sigaction(.USR2, &act, &old);
    defer std.posix.sigaction(.USR2, &old, null);
    var now: Bionic = undefined;
    _ = sigaction64(@backingInt(std.posix.SIG.USR2), null, &now);
    try std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(&S.nothing)), now.handler);
}
