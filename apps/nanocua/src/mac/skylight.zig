//! What plain CGEventPostToPid can't do for a window in the background: mouse
//! events an app acts on, and making a window key without raising it or taking
//! the keyboard from the user's app. These are private functions, looked up at run time, so
//! a macOS without them falls back to the public post (and the reply already says
//! a background click isn't confirmed). The recipe follows yabai's focus-without-raise
//! and trycua's cua-driver (MIT).
const std = @import("std");
const cf = @import("cf.zig");

extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
extern "c" fn CGEventPostToPid(pid: i32, ev: *anyopaque) void;
extern "c" fn CGEventSetIntegerValueField(ev: *anyopaque, field: u32, value: i64) void;

const rtld_default: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));
const rtld_lazy: c_int = 1;

const Api = struct {
    post_to_pid: ?*const fn (pid: i32, ev: *anyopaque) callconv(.c) void = null,
    set_window_location: ?*const fn (ev: *anyopaque, at: cf.CGPoint) callconv(.c) void = null,
    post_record: ?*const fn (psn: *const [8]u8, record: *const [record_size]u8) callconv(.c) i32 = null,
    process_for_pid: ?*const fn (pid: i32, psn: *[8]u8) callconv(.c) i32 = null,
};

var api: Api = .{};
var loaded = false;

/// The backend's queue is the only caller, so no lock.
fn get() *const Api {
    if (loaded) return &api;
    loaded = true;
    _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", rtld_lazy);
    api = .{
        .post_to_pid = @ptrCast(@alignCast(dlsym(rtld_default, "SLEventPostToPid"))),
        .set_window_location = @ptrCast(@alignCast(dlsym(rtld_default, "CGEventSetWindowLocation"))),
        .post_record = @ptrCast(@alignCast(dlsym(rtld_default, "SLPSPostEventRecordTo"))),
        .process_for_pid = @ptrCast(@alignCast(dlsym(rtld_default, "GetProcessForPID"))),
    };
    return &api;
}

/// Hands a mouse or scroll event to one app.
pub fn post(pid: i32, ev: *anyopaque) void {
    if (get().post_to_pid) |f| return f(pid, ev);
    CGEventPostToPid(pid, ev);
}

/// Says where in its window an event is, which an app in the background can't
/// work out from the pointer.
pub fn setWindowLocation(ev: *anyopaque, x: f64, y: f64) void {
    if (get().set_window_location) |f| f(ev, .{ .x = x, .y = y });
}

pub fn setField(ev: *anyopaque, field: u32, value: i64) void {
    CGEventSetIntegerValueField(ev, field, value);
}

const record_size = 0xF8;

/// The record that tells a window it has focus: its id little-endian at 0x3c,
/// and the direction at 0x8a (1 gains focus).
pub fn focusRecord(window: u32) [record_size]u8 {
    var r: [record_size]u8 = @splat(0);
    r[0x04] = record_size;
    r[0x08] = 0x0D;
    std.mem.writeInt(u32, r[0x3C..0x40], window, .little);
    r[0x8A] = 0x01;
    return r;
}

/// Makes `window` key inside app `pid`, so its first click isn't spent on that.
/// Goes to that app alone: the user's front app isn't told, and keeps the
/// keyboard. False if macOS has no way to do this, or refused.
pub fn focusWindow(pid: i32, window: u32) bool {
    const a = get();
    const send = a.post_record orelse return false;
    const psn_of = a.process_for_pid orelse return false;
    var psn: [8]u8 = undefined;
    if (psn_of(pid, &psn) != 0) return false;
    const record = focusRecord(window);
    return send(&psn, &record) == 0;
}

test "the focus record" {
    const r = focusRecord(0x11223344);
    try std.testing.expectEqual(@as(u8, 0xF8), r[0x04]);
    try std.testing.expectEqual(@as(u8, 0x0D), r[0x08]);
    try std.testing.expectEqualSlices(u8, &.{ 0x44, 0x33, 0x22, 0x11 }, r[0x3C..0x40]);
    try std.testing.expectEqual(@as(u8, 1), r[0x8A]);
}
