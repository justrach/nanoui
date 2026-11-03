//! An input event, copied out of the input queue's. An event is finished
//! (Android told whether the app took it) before nanoui handles it: what
//! it does may wait (a dialog waits for its answer inside the frame of the
//! tap that asked for it), and Android calls an app that keeps an event
//! five seconds unresponsive. The queue's event is gone once finished.
const std = @import("std");
const ndk = @import("ndk.zig");

/// Fingers followed at most.
pub const max_pointers = 10;

pub const Motion = struct {
    /// The action without its pointer index (`MOTION_EVENT_ACTION_*`).
    action: i32,
    /// The pointer that went down or up (POINTER_DOWN, POINTER_UP).
    index: usize,
    count: usize,
    ids: [max_pointers]i32 = undefined,
    /// In pixels.
    xs: [max_pointers]f32 = undefined,
    ys: [max_pointers]f32 = undefined,
    tool: i32,
    buttons: i32,
    meta: i32,
    /// Seconds (CLOCK_MONOTONIC's).
    time: f64,
    /// A wheel's notches, up positive.
    vscroll: f32,

    pub fn indexOf(m: *const Motion, id: i32) ?usize {
        for (m.ids[0..m.count], 0..) |p, i| if (p == id) return i;
        return null;
    }
};

pub const Key = struct {
    action: i32,
    code: i32,
    meta: i32,
    repeat: i32,
    device: i32,
};

pub const Event = union(enum) {
    motion: Motion,
    key: Key,
};

/// A copy of `e`, or null for a kind nanoui doesn't take.
pub fn read(e: *const ndk.AInputEvent) ?Event {
    switch (ndk.AInputEvent_getType(e)) {
        ndk.INPUT_EVENT_TYPE_MOTION => {
            const raw = ndk.AMotionEvent_getAction(e);
            const count = @min(ndk.AMotionEvent_getPointerCount(e), max_pointers);
            var m: Motion = .{
                .action = raw & ndk.MOTION_EVENT_ACTION_MASK,
                .index = @intCast((raw >> ndk.MOTION_EVENT_ACTION_POINTER_INDEX_SHIFT) & 0xff),
                .count = count,
                .tool = ndk.AMotionEvent_getToolType(e, 0),
                .buttons = ndk.AMotionEvent_getButtonState(e),
                .meta = ndk.AMotionEvent_getMetaState(e),
                .time = @as(f64, @floatFromInt(ndk.AMotionEvent_getEventTime(e))) / 1e9,
                .vscroll = ndk.AMotionEvent_getAxisValue(e, ndk.MOTION_EVENT_AXIS_VSCROLL, 0),
            };
            for (0..count) |i| {
                m.ids[i] = ndk.AMotionEvent_getPointerId(e, i);
                m.xs[i] = ndk.AMotionEvent_getX(e, i);
                m.ys[i] = ndk.AMotionEvent_getY(e, i);
            }
            // A pointer past the ones followed: as if none.
            if (m.index >= count) m.index = 0;
            return .{ .motion = m };
        },
        ndk.INPUT_EVENT_TYPE_KEY => return .{ .key = .{
            .action = ndk.AKeyEvent_getAction(e),
            .code = ndk.AKeyEvent_getKeyCode(e),
            .meta = ndk.AKeyEvent_getMetaState(e),
            .repeat = ndk.AKeyEvent_getRepeatCount(e),
            .device = ndk.AInputEvent_getDeviceId(e),
        } },
        else => return null,
    }
}
