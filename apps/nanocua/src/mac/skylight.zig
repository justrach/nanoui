//! What plain CGEventPostToPid can't do for a window in the background: mouse
//! events an app acts on. These are private functions, looked up at run time, so
//! a macOS without them falls back to the public post (and the reply already says
//! a background click isn't confirmed). The recipe follows trycua's cua-driver (MIT).
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
