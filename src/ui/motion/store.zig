//! Motion's memory between frames: each animated object's channels, kept
//! in the Context by the id of its box, and forgotten a while after it is
//! last drawn.
const std = @import("std");
const types = @import("../types.zig");
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
};

pub const Clip = struct {
    /// When its keyframes started, and which keyframes they were.
    start: f64 = 0,
    id: u64 = 0,
    seen: u64 = 0,
};

pub const Layout = struct {
    /// Where its box was laid out last, the glide from where it was drawn,
    /// and how it glides (layout animation).
    rect: ?[4]f32 = null,
    ch: [2]Channel = @splat(.{}),
    transition: Transition = .default,
    seen: u64 = 0,
};

pub const Drag = struct {
    /// Drag: the pointer is moving it, and where the grab and the last
    /// sample were, so a release can keep its speed and snap.
    dragging: bool = false,
    moved: bool = false,
    origin: [2]f32 = .{ 0, 0 },
    pointer_origin: [2]f32 = .{ 0, 0 },
    pointer_last: [2]f32 = .{ 0, 0 },
    pointer_time: f64 = 0,
    pointer_vel: [2]f32 = .{ 0, 0 },
    seen: u64 = 0,
};

pub const Roll = struct {
    last_frame: u64 = 0,
    cur_buf: [64]u8 = undefined,
    cur_len: u8 = 0,
    from_buf: [64]u8 = undefined,
    from_len: u8 = 0,
    started: f64 = 0,
    active: bool = false,
    seen: u64 = 0,
};

pub const Store = struct {
    map: types.IdMap(State) = .empty,
    clips: types.IdMap(Clip) = .empty,
    layouts: types.IdMap(Layout) = .empty,
    drags: types.IdMap(Drag) = .empty,
    rolls: types.IdMap(Roll) = .empty,

    pub fn deinit(s: *Store, gpa: std.mem.Allocator) void {
        s.map.deinit(gpa);
        s.clips.deinit(gpa);
        s.layouts.deinit(gpa);
        s.drags.deinit(gpa);
        s.rolls.deinit(gpa);
    }

    pub fn Entry(comptime T: type) type {
        return struct { state: *T, fresh: bool };
    }

    /// The state of `id`, made if new (`fresh` says so).
    pub fn get(s: *Store, gpa: std.mem.Allocator, id: u64, frame: u64) ?Entry(State) {
        return getTyped(State, &s.map, gpa, id, frame);
    }

    pub fn getClip(s: *Store, gpa: std.mem.Allocator, id: u64, frame: u64) ?Entry(Clip) {
        return getTyped(Clip, &s.clips, gpa, id, frame);
    }

    pub fn getLayout(s: *Store, gpa: std.mem.Allocator, id: u64, frame: u64) ?Entry(Layout) {
        return getTyped(Layout, &s.layouts, gpa, id, frame);
    }

    pub fn getDrag(s: *Store, gpa: std.mem.Allocator, id: u64, frame: u64) ?Entry(Drag) {
        return getTyped(Drag, &s.drags, gpa, id, frame);
    }

    pub fn getRoll(s: *Store, gpa: std.mem.Allocator, id: u64, frame: u64) ?Entry(Roll) {
        return getTyped(Roll, &s.rolls, gpa, id, frame);
    }

    fn getTyped(comptime T: type, m: *types.IdMap(T), gpa: std.mem.Allocator, id: u64, frame: u64) ?Entry(T) {
        const gop = m.getOrPut(gpa, id) catch return null;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.seen = frame;
        return .{ .state = gop.value_ptr, .fresh = !gop.found_existing };
    }

    pub fn resetState(_: *Store, _: std.mem.Allocator, st: *State) void {
        st.* = .{};
    }

    pub fn remove(s: *Store, id: u64) void {
        _ = s.map.remove(id);
    }

    /// Forgets what hasn't been drawn for `frames` frames (a few at a time).
    pub fn forget(s: *Store, _: std.mem.Allocator, now: u64, frames: u64) void {
        pruneMap(State, &s.map, now, frames);
        pruneMap(Clip, &s.clips, now, frames);
        pruneMap(Layout, &s.layouts, now, frames);
        pruneMap(Drag, &s.drags, now, frames);
        pruneMap(Roll, &s.rolls, now, frames);
    }

    fn pruneMap(comptime T: type, m: *types.IdMap(T), now: u64, frames: u64) void {
        var stale: [64]u64 = undefined;
        var n: usize = 0;
        var it = m.iterator();
        while (it.next()) |e| {
            if (n == stale.len) break;
            if (now -| e.value_ptr.seen > frames) {
                stale[n] = e.key_ptr.*;
                n += 1;
            }
        }
        for (stale[0..n]) |k| _ = m.remove(k);
    }
};
