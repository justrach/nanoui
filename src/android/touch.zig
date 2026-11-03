//! Touches as the pointer, as on iOS (`ios/touch.zig`): one finger presses,
//! drags and releases, as a mouse button would, and leaves no hover
//! behind. A finger that moves mostly up or down over something that
//! scrolls scrolls it instead, and the press it began is let go; let go
//! moving, it keeps going and slows (a fling), until a touch stops it or
//! it meets an end. A second finger makes a pinch: the press is let go,
//! and the fingers' spread and movement come as `input.zoom` and
//! `input.pan`. A mouse (a Chromebook's, a tablet's) is a desktop's: it
//! hovers, clicks and scrolls with its wheel.
const std = @import("std");
const ndk = @import("ndk.zig");
const types = @import("../ui/types.zig");
const Surface = @import("surface.zig").Surface;
const keys = @import("keys.zig");
const Motion = @import("event.zig").Motion;

/// How far a finger moves before it scrolls rather than presses, points
/// (Android's touch slop).
const slop: f32 = 8;
/// The fling's deceleration, as iOS's scroll views: speed kept per millisecond.
const deceleration: f64 = 0.998;
/// Slower than this, points per second, a fling ends.
const min_speed: f32 = 20;
/// A tap this soon after the last, this near it, counts on: double, triple.
const multi_tap_s: f64 = 0.3;
const multi_tap_pt: f32 = 24;

const away: types.Point = .{ .x = -1e6, .y = -1e6 };

pub const State = struct {
    /// The finger followed (the first down), by pointer id.
    finger: ?i32 = null,
    /// The second finger down, pinching with the first; a third is ignored.
    second: ?i32 = null,
    spread: f32 = 0,
    middle: types.Point = .{},
    start: types.Point = .{},
    last: types.Point = .{},
    last_time: f64 = 0,
    scrolling: bool = false,
    /// The finger's vertical speed, points per second, smoothed.
    velocity: f32 = 0,
    /// The touch stopped a fling, or was a pinch's: it presses nothing.
    stopper: bool = false,
    fling: f32 = 0,
    fling_at: types.Point = .{},
    fling_time: f64 = 0,
    fling_offset: ?f32 = null,
    /// The last tap: where, when, and how many in a row.
    tap_at: types.Point = away,
    tap_time: f64 = 0,
    taps: u32 = 0,

    pub fn flinging(st: State) bool {
        return st.fling != 0;
    }

    pub fn stop(st: *State) void {
        st.fling = 0;
        st.fling_offset = null;
    }
};

fn at(s: *Surface, m: *const Motion, index: usize) types.Point {
    return .{ .x = m.xs[index] / s.scale, .y = m.ys[index] / s.scale };
}

/// A motion event for the surface.
pub fn handle(s: *Surface, m: *const Motion) void {
    _ = s.enter();
    defer s.leave();
    keys.setModifiers(s, m.meta);
    if (m.tool == ndk.MOTION_EVENT_TOOL_TYPE_MOUSE) return mouse(s, m);
    if (m.count == 0) return;
    switch (m.action) {
        ndk.MOTION_EVENT_ACTION_DOWN => began(s, m, m.index),
        ndk.MOTION_EVENT_ACTION_POINTER_DOWN => {
            const st = &s.touch;
            if (st.finger) |first| if (st.second == null) if (m.indexOf(first)) |fi| pinchStart(s, m, fi, m.index);
        },
        ndk.MOTION_EVENT_ACTION_MOVE => moved(s, m),
        ndk.MOTION_EVENT_ACTION_UP, ndk.MOTION_EVENT_ACTION_POINTER_UP => ended(s, m, m.index),
        ndk.MOTION_EVENT_ACTION_CANCEL => cancelled(s),
        else => {},
    }
}

/// The scrolling box under `p`, from the last frame, if any.
fn scrollerAt(s: *Surface, p: types.Point) ?u64 {
    const hits = s.ctx.hits.items;
    var i = hits.len;
    while (i > 0) {
        i -= 1;
        if (hits[i].scroll and hits[i].rect.contains(p)) return hits[i].id;
    }
    return null;
}

/// Scrolls the box under `p` by `dy` points, the finger's way.
fn scrollBy(s: *Surface, p: types.Point, dy: f32) void {
    s.ctx.input.mouse = p;
    _ = s.ctx.applyScroll(dy);
    s.ctx.input.mouse = away;
}

/// The finger is up: no hover stays where it was.
fn lift(s: *Surface) void {
    s.ctx.input.mouse = away;
    s.ctx.updateHot();
    s.frame();
}

fn began(s: *Surface, m: *const Motion, index: usize) void {
    const st = &s.touch;
    const p = at(s, m, index);
    const now = m.time;
    const was_flinging = st.flinging();
    const near = @abs(p.x - st.tap_at.x) < multi_tap_pt and @abs(p.y - st.tap_at.y) < multi_tap_pt;
    const taps: u32 = if (near and now - st.tap_time < multi_tap_s) st.taps + 1 else 1;
    st.* = .{
        .finger = m.ids[index],
        .start = p,
        .last = p,
        .last_time = now,
        .stopper = was_flinging,
        .tap_at = st.tap_at,
        .tap_time = st.tap_time,
        .taps = taps,
    };
    // A touch on a fling stops it, and presses nothing.
    if (st.stopper) return;
    s.ctx.input.mouse = p;
    s.ctx.updateHot();
    s.ctx.input.click_count = taps;
    s.ctx.pointerDown();
    s.frame();
}

fn spreadOf(a: types.Point, b: types.Point) f32 {
    return @sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
}

/// A second finger came: what the first pressed or scrolled is let go.
fn pinchStart(s: *Surface, m: *const Motion, first: usize, second: usize) void {
    const st = &s.touch;
    const a = at(s, m, first);
    const b = at(s, m, second);
    if (!st.scrolling and !st.stopper) {
        s.ctx.input.mouse = away;
        s.ctx.updateHot();
        s.ctx.pointerUp();
        s.frame();
        if (s.dead) return;
    }
    st.second = m.ids[second];
    st.scrolling = false;
    st.stopper = true;
    st.spread = spreadOf(a, b);
    st.middle = .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
}

/// The fingers moved: by how much they spread, about their middle.
fn pinchMove(s: *Surface, m: *const Motion, first: usize, second: usize) void {
    const st = &s.touch;
    const a = at(s, m, first);
    const b = at(s, m, second);
    const d = spreadOf(a, b);
    const mid: types.Point = .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
    const in = &s.ctx.input;
    in.mouse = mid;
    in.zoom = if (st.spread > 1 and d > 1) d / st.spread else 1;
    in.pan = .{ .x = mid.x - st.middle.x, .y = mid.y - st.middle.y };
    st.spread = d;
    st.middle = mid;
    s.frame();
    if (!s.dead) s.ctx.input.mouse = away;
}

fn moved(s: *Surface, m: *const Motion) void {
    const st = &s.touch;
    const id = st.finger orelse return;
    const fi = m.indexOf(id) orelse return;
    if (st.second) |second| {
        const si = m.indexOf(second) orelse return;
        return pinchMove(s, m, fi, si);
    }
    const p = at(s, m, fi);
    const now = m.time;
    const dt: f32 = @floatCast(now - st.last_time);
    if (dt > 0) st.velocity = 0.8 * ((p.y - st.last.y) / dt) + 0.2 * st.velocity;
    var dy = p.y - st.last.y;
    st.last = p;
    st.last_time = now;
    if (!st.scrolling) {
        const ty = p.y - st.start.y;
        const tx = p.x - st.start.x;
        if (@abs(ty) > slop and @abs(ty) > @abs(tx) and scrollerAt(s, st.start) != null) {
            st.scrolling = true;
            // The press becomes a scroll: let go away from what it pressed.
            if (!st.stopper) {
                s.ctx.input.mouse = away;
                s.ctx.updateHot();
                s.ctx.pointerUp();
            }
            dy = ty;
        }
    }
    if (st.scrolling) {
        scrollBy(s, st.start, dy);
        s.frame();
    } else if (!st.stopper) {
        // A drag: a slider's thumb, a selection.
        s.ctx.input.mouse = p;
        s.ctx.updateHot();
        s.frame();
    }
}

fn ended(s: *Surface, m: *const Motion, index: usize) void {
    const st = &s.touch;
    const up = m.ids[index];
    if (st.second) |second| {
        const first = st.finger.?;
        // One of the pinch's fingers went: the other presses nothing.
        const left = if (up == first) second else if (up == second) first else return;
        const li = m.indexOf(left) orelse return;
        const p = at(s, m, li);
        st.finger = left;
        st.second = null;
        st.start = p;
        st.last = p;
        st.last_time = m.time;
        return;
    }
    if (st.finger != up) return;
    st.finger = null;
    if (st.scrolling) {
        st.scrolling = false;
        // Let go moving: a fling. Held still first: none.
        const recent = m.time - st.last_time < 0.08;
        if (recent and @abs(st.velocity) > 3 * min_speed) {
            st.fling = st.velocity;
            st.fling_at = st.start;
            st.fling_time = @import("../ui/clock.zig").now();
            st.fling_offset = null;
            s.requestFrame();
        }
        return;
    }
    if (st.stopper) return;
    const p = at(s, m, index);
    st.tap_at = p;
    st.tap_time = m.time;
    s.ctx.input.mouse = p;
    s.ctx.updateHot();
    s.ctx.pointerUp();
    s.frame();
    // The tap may have closed the window.
    if (s.dead) return;
    lift(s);
    if (!s.dead) keys.tapped(s);
}

fn cancelled(s: *Surface) void {
    const st = &s.touch;
    if (st.finger == null) return;
    const pressing = !st.scrolling and !st.stopper;
    st.* = .{};
    // The system took the touch (a gesture): nothing is clicked.
    s.ctx.input.mouse = away;
    s.ctx.updateHot();
    if (pressing) s.ctx.pointerUp();
    s.frame();
}

/// One step of a fling, before the refresh's frame.
pub fn fling(s: *Surface) void {
    const st = &s.touch;
    if (st.fling == 0) return;
    const now = @import("../ui/clock.zig").now();
    const dt = @min(now - st.fling_time, 0.05);
    st.fling_time = now;
    // At an end, layout kept the offset where the last step left it.
    const id = scrollerAt(s, st.fling_at) orelse return st.stop();
    const offset = s.ctx.scroll.get(id) orelse 0;
    if (st.fling_offset) |prev| if (prev == offset) return st.stop();
    st.fling_offset = offset;
    scrollBy(s, st.fling_at, st.fling * @as(f32, @floatCast(dt)));
    st.fling *= @floatCast(std.math.pow(f64, deceleration, dt * 1000));
    if (@abs(st.fling) < min_speed) st.stop();
}

/// A mouse: hover, the primary button, the wheel.
fn mouse(s: *Surface, m: *const Motion) void {
    const c = &s.ctx;
    const action = m.action;
    const p = at(s, m, 0);
    switch (action) {
        ndk.MOTION_EVENT_ACTION_HOVER_MOVE, ndk.MOTION_EVENT_ACTION_MOVE => {
            c.input.mouse = p;
            const before = c.hot;
            c.updateHot();
            if (c.input.down or c.hot != before or c.wants_moves) s.frame();
        },
        ndk.MOTION_EVENT_ACTION_DOWN => {
            // The primary button (or none named, as some mice and adb send).
            if (m.buttons != 0 and m.buttons & ndk.MOTION_EVENT_BUTTON_PRIMARY == 0) return;
            const st = &s.touch;
            const now = m.time;
            const near = @abs(p.x - st.tap_at.x) < 4 and @abs(p.y - st.tap_at.y) < 4;
            st.taps = if (near and now - st.tap_time < multi_tap_s) st.taps + 1 else 1;
            st.tap_at = p;
            st.tap_time = now;
            c.input.mouse = p;
            c.updateHot();
            c.input.click_count = st.taps;
            c.pointerDown();
            s.frame();
        },
        ndk.MOTION_EVENT_ACTION_UP => {
            if (!c.input.down) return;
            c.input.mouse = p;
            c.updateHot();
            c.pointerUp();
            s.frame();
        },
        ndk.MOTION_EVENT_ACTION_HOVER_EXIT => {
            c.input.mouse = away;
            if (c.hot != 0) {
                c.updateHot();
                s.frame();
            }
        },
        ndk.MOTION_EVENT_ACTION_SCROLL => {
            c.input.mouse = p;
            // A notch is one; up is positive, as nanoui's deltas.
            const delta = m.vscroll * 48;
            if (c.applyScroll(delta)) {
                s.frame();
                if (!s.dead) c.updateHot();
            } else if (c.wants_wheel) {
                c.input.scroll = .{ .y = delta };
                s.frame();
            }
        },
        else => {},
    }
}
