//! Motion's memory between frames: each animated object's channels, kept
//! in the Context by the id of its box, and forgotten a while after it is
//! last drawn.
const std = @import("std");
const Channel = @import("channel.zig").Channel;
const Transition = @import("channel.zig").Transition;

/// The channels of a target: x, y, scale, opacity, width, height, radius,
/// the background's red, green, blue and alpha, then rotation and turn.
pub const channels = 13;

pub const State = struct {
    ch: [channels]Channel = @splat(.{}),
    /// The channels that have had a value.
    has: u16 = 0,
    /// The frame it was last used in.
    seen: u64 = 0,
    /// Shown (or leaving, until its exit settles): presence.
    mounted: bool = false,
    exiting: bool = false,
    /// When its keyframes started, and which keyframes they were.
    clip_start: f64 = 0,
    clip_id: u64 = 0,
    /// Where its box was laid out last, the glide from where it was drawn,
    /// and how it glides (layout animation).
    rect: ?[4]f32 = null,
    layout: [2]Channel = @splat(.{}),
    layout_transition: Transition = .default,
    /// Drag: the pointer is moving it, and where the grab and the last
    /// sample were, so a release can keep its speed and snap.
    dragging: bool = false,
    drag_moved: bool = false,
    drag_origin: [2]f32 = .{ 0, 0 },
    pointer_origin: [2]f32 = .{ 0, 0 },
    pointer_last: [2]f32 = .{ 0, 0 },
    pointer_time: f64 = 0,
    pointer_vel: [2]f32 = .{ 0, 0 },
};

pub const Store = struct {
    map: std.AutoHashMapUnmanaged(u64, State) = .empty,

    pub fn deinit(s: *Store, gpa: std.mem.Allocator) void {
        s.map.deinit(gpa);
    }

    /// The state of `id`, made if new (`fresh` says so).
    pub fn get(s: *Store, gpa: std.mem.Allocator, id: u64, frame: u64) ?struct { state: *State, fresh: bool } {
        const gop = s.map.getOrPut(gpa, id) catch return null;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.seen = frame;
        return .{ .state = gop.value_ptr, .fresh = !gop.found_existing };
    }

    /// Forgets what hasn't been drawn for `frames` frames (a few at a time).
    pub fn forget(s: *Store, now: u64, frames: u64) void {
        var stale: [64]u64 = undefined;
        var n: usize = 0;
        var it = s.map.iterator();
        while (it.next()) |e| {
            if (n == stale.len) break;
            if (now - e.value_ptr.seen > frames) {
                stale[n] = e.key_ptr.*;
                n += 1;
            }
        }
        for (stale[0..n]) |k| _ = s.map.remove(k);
    }
};
