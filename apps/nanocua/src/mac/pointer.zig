//! Whether the click nanocua's window is handling came from a person's mouse
//! or trackpad. Turning a switch on only counts for a real click, so a program
//! that posts mouse events can't press Allow. It's a watch, not a filter: Stop
//! and the off positions work however they're clicked. Assistive tools that post
//! their own clicks (Switch Control, Voice Control) count as programs here.
const std = @import("std");
const objc = @import("nanoui").objc;

extern "c" fn CGEventGetIntegerValueField(ev: *anyopaque, field: u32) i64;

const field_source_pid: u32 = 41;
const field_source_state: u32 = 45;
/// kCGEventSourceStateHIDSystemState: the hardware's own state.
const hid_state: i64 = 1;

const left_down: usize = 1 << 1;
const left_up: usize = 1 << 2;
const type_left_down: usize = 1;

/// What a real click looked like in the live test: posted by no process, in
/// the hardware's state. Anything posted by a program names its process.
pub fn isHardware(source_pid: i64, source_state: i64) bool {
    return source_pid == 0 and source_state == hid_state;
}

var down_real = false;
var up_real = false;

/// Whether the press and the release just handled were both real. Main thread.
pub fn real() bool {
    return down_real and up_real;
}

fn note(event: objc.Object) void {
    const cg = objc.msg(?*anyopaque, event, "CGEvent", .{});
    const is_real = if (cg) |e| isHardware(CGEventGetIntegerValueField(e, field_source_pid), CGEventGetIntegerValueField(e, field_source_state)) else false;
    if (objc.msg(usize, event, "type", .{}) == type_left_down) {
        down_real = is_real;
        up_real = false;
    } else up_real = is_real;
}

const Descriptor = extern struct { reserved: usize = 0, size: usize };

/// A block returning the event: objc.Block's return nothing, and this API
/// drops an event its handler returns nothing for.
const Monitor = extern struct {
    isa: *anyopaque,
    flags: i32 = 0,
    reserved: i32 = 0,
    invoke: *const fn (*const Monitor, objc.Object) callconv(.c) objc.Object,
    descriptor: *const Descriptor,
};

const descriptor: Descriptor = .{ .size = @sizeOf(Monitor) };
extern "c" var _NSConcreteStackBlock: opaque {};

fn seen(_: *const Monitor, event: objc.Object) callconv(.c) objc.Object {
    note(event);
    return event;
}

/// Starts watching this process's clicks, before its windows handle them.
pub fn watch() void {
    var block: Monitor = .{ .isa = @ptrCast(&_NSConcreteStackBlock), .invoke = seen, .descriptor = &descriptor };
    // AppKit copies the block and holds the monitor for the life of the app.
    const monitor = objc.msg(?objc.Object, objc.class("NSEvent"), "addLocalMonitorForEventsMatchingMask:handler:", .{ left_down | left_up, @as(*anyopaque, @ptrCast(&block)) });
    if (monitor) |m| _ = objc.retain(m);
}

test "only an event no process posted, in the hardware's state, is real" {
    try std.testing.expect(isHardware(0, 1));
    try std.testing.expect(!isHardware(4242, 1));
    try std.testing.expect(!isHardware(0, 0));
    try std.testing.expect(!isHardware(4242, 0));
}

test "nothing has clicked yet: not real" {
    try std.testing.expect(!real());
}
