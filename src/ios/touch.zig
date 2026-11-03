//! Touches as the pointer: one finger presses, drags and releases, as a
//! mouse button would, and leaves no hover behind. A finger that moves
//! mostly up or down over something that scrolls scrolls it instead, and
//! the press it began is canceled; let go moving, it keeps going and slows
//! as iOS's scroll views do (a fling), until a touch stops it or it meets
//! an end. Held past an end, it rubber-bands and springs back when let go.
//! A second finger makes a pinch: the press is canceled, and the
//! fingers' spread and movement come as `input.zoom` and `input.pan`.
const std = @import("std");
const objc = @import("../objc.zig");
const cf = @import("../ui/cf.zig");
const types = @import("../ui/types.zig");
const Surface = @import("surface.zig").Surface;
const keys = @import("keys.zig");

/// How far a finger moves before it scrolls rather than presses, points.
const slop: f32 = 10;
/// UIScrollView's normal deceleration: speed kept per millisecond.
const deceleration: f64 = 0.998;
/// Slower than this, points per second, a fling ends.
const min_speed: f32 = 20;

/// Nowhere: the pointer between touches.
const away: types.Point = .{ .x = -1e6, .y = -1e6 };

pub const State = struct {
    /// The finger followed (the first down).
    finger: ?objc.Object = null,
    /// The second finger down, pinching with the first; a third is ignored.
    second: ?objc.Object = null,
    /// The pinch's last spread and middle.
    spread: f32 = 0,
    middle: types.Point = .{},
    start: types.Point = .{},
    last: types.Point = .{},
    last_time: f64 = 0,
    scrolling: bool = false,
    /// The finger's vertical speed, points per second, smoothed.
    velocity: f32 = 0,
    /// The touch stopped a fling: it presses nothing.
    stopper: bool = false,
    /// A fling: its speed, where it scrolls, and its last step.
    fling: f32 = 0,
    fling_at: types.Point = .{},
    fling_time: f64 = 0,
    fling_offset: ?f32 = null,

    pub fn flinging(st: State) bool {
        return st.fling != 0;
    }

    pub fn stop(st: *State) void {
        st.fling = 0;
        st.fling_offset = null;
    }
};

pub const methods = [_]objc.Method{
    .{ .name = "touchesBegan:withEvent:", .imp = &began, .types = "v@:@@" },
    .{ .name = "touchesMoved:withEvent:", .imp = &moved, .types = "v@:@@" },
    .{ .name = "touchesEnded:withEvent:", .imp = &ended, .types = "v@:@@" },
    .{ .name = "touchesCancelled:withEvent:", .imp = &cancelled, .types = "v@:@@" },
};

/// The followed finger among `touches` (an NSSet), if it is there.
fn followed(s: *Surface, touches: objc.Object) ?objc.Object {
    const f = s.touch.finger orelse return null;
    return if (objc.msg(objc.BOOL, touches, "containsObject:", .{f})) f else null;
}

fn location(s: *Surface, t: objc.Object) types.Point {
    const p = objc.msg(objc.CGPoint, t, "locationInView:", .{s.uiview});
    return .{ .x = @floatCast(p.x), .y = @floatCast(p.y) };
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

/// Scrolls the box under `at` by `dy` points, the finger's way.
fn scrollBy(s: *Surface, at: types.Point, dy: f32) void {
    s.ctx.input.mouse = at;
    _ = s.ctx.applyScroll(dy);
    s.ctx.input.mouse = away;
}

/// The keys held with the touch (a hardware keyboard's Shift, Command):
/// a key's own press set them last, and they may have been let go since.
fn modifiers(s: *Surface, event: ?objc.Object) void {
    const e = event orelse return;
    keys.setModifiers(s, objc.msg(objc.NSInteger, e, "modifierFlags", .{}));
}

/// The finger is up: no hover stays where it was.
fn lift(s: *Surface) void {
    s.ctx.input.mouse = away;
    s.ctx.updateHot();
    s.frame();
}

fn began(obj: objc.Object, _: objc.SEL, touches: objc.Object, event: ?objc.Object) callconv(.c) void {
    const s = Surface.enter(obj) orelse return;
    defer s.leave();
    modifiers(s, event);
    const st = &s.touch;
    if (st.finger) |first| {
        if (st.second == null) pinchStart(s, first, other(touches, first) orelse return);
        return;
    }
    const all = objc.msg(objc.Object, touches, "allObjects", .{});
    const t = objc.msg(objc.Object, all, "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
    const p = location(s, t);
    const was_flinging = st.flinging();
    st.* = .{ .finger = t, .start = p, .last = p, .last_time = cf.CACurrentMediaTime(), .stopper = was_flinging };
    // A touch on a fling stops it, as on iOS, and presses nothing.
    if (st.stopper) return;
    s.ctx.input.mouse = p;
    s.ctx.updateHot();
    s.ctx.input.click_count = @intCast(@max(1, objc.msg(objc.NSUInteger, t, "tapCount", .{})));
    s.ctx.pointerDown();
    s.frame();
    // Two fingers at once: a pinch from the start.
    if (objc.msg(objc.NSUInteger, all, "count", .{}) > 1)
        pinchStart(s, t, objc.msg(objc.Object, all, "objectAtIndex:", .{@as(objc.NSUInteger, 1)}));
}

/// A touch of `touches` other than `t`.
fn other(touches: objc.Object, t: objc.Object) ?objc.Object {
    const all = objc.msg(objc.Object, touches, "allObjects", .{});
    const n = objc.msg(objc.NSUInteger, all, "count", .{});
    var i: objc.NSUInteger = 0;
    while (i < n) : (i += 1) {
        const o = objc.msg(objc.Object, all, "objectAtIndex:", .{i});
        if (o != t) return o;
    }
    return null;
}

fn spreadOf(a: types.Point, b: types.Point) f32 {
    return @sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
}

/// A second finger came: what the first pressed or scrolled is let go.
fn pinchStart(s: *Surface, first: objc.Object, second: objc.Object) void {
    const st = &s.touch;
    const a = location(s, first);
    const b = location(s, second);
    if (!st.scrolling and !st.stopper) {
        s.ctx.input.mouse = away;
        s.ctx.updateHot();
        s.ctx.pointerUp();
        s.frame();
    }
    st.second = second;
    st.scrolling = false;
    s.ctx.scroll_holding = false;
    st.stopper = true;
    st.spread = spreadOf(a, b);
    st.middle = .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
}

/// The fingers moved: by how much they spread, about their middle.
fn pinchMove(s: *Surface, first: objc.Object, second: objc.Object) void {
    const st = &s.touch;
    const a = location(s, first);
    const b = location(s, second);
    const d = spreadOf(a, b);
    const m: types.Point = .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
    const in = &s.ctx.input;
    in.mouse = m;
    in.zoom = if (st.spread > 1 and d > 1) d / st.spread else 1;
    in.pan = .{ .x = m.x - st.middle.x, .y = m.y - st.middle.y };
    st.spread = d;
    st.middle = m;
    s.frame();
    s.ctx.input.mouse = away;
}

/// One of the pinch's fingers went: the other presses nothing until it goes.
fn pinchEnd(s: *Surface, left: objc.Object) void {
    const st = &s.touch;
    const p = location(s, left);
    st.finger = left;
    st.second = null;
    st.start = p;
    st.last = p;
    st.last_time = cf.CACurrentMediaTime();
}

fn moved(obj: objc.Object, _: objc.SEL, touches: objc.Object, event: ?objc.Object) callconv(.c) void {
    const s = Surface.enter(obj) orelse return;
    defer s.leave();
    modifiers(s, event);
    const st = &s.touch;
    if (st.second) |second| return pinchMove(s, st.finger.?, second);
    const t = followed(s, touches) orelse return;
    const p = location(s, t);
    const now = cf.CACurrentMediaTime();
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
            // The press becomes a scroll: released away from what it pressed.
            if (!st.stopper) {
                s.ctx.input.mouse = away;
                s.ctx.updateHot();
                s.ctx.pointerUp();
            }
            dy = ty;
        }
    }
    if (st.scrolling) {
        // Held: past an end the box rubber-bands (and can be pulled to refresh).
        s.ctx.scroll_holding = true;
        scrollBy(s, st.start, dy);
        s.frame();
    } else if (!st.stopper) {
        // A drag: a slider's thumb, a selection.
        s.ctx.input.mouse = p;
        s.ctx.updateHot();
        s.frame();
    }
}

fn ended(obj: objc.Object, _: objc.SEL, touches: objc.Object, event: ?objc.Object) callconv(.c) void {
    const s = Surface.enter(obj) orelse return;
    defer s.leave();
    modifiers(s, event);
    const st = &s.touch;
    if (st.second) |second| {
        const first = st.finger.?;
        const first_up = objc.msg(objc.BOOL, touches, "containsObject:", .{first});
        const second_up = objc.msg(objc.BOOL, touches, "containsObject:", .{second});
        if (first_up and second_up) {
            st.* = .{};
            return lift(s);
        }
        if (first_up) return pinchEnd(s, second);
        if (second_up) return pinchEnd(s, first);
        return;
    }
    const t = followed(s, touches) orelse return;
    st.finger = null;
    if (st.scrolling) {
        st.scrolling = false;
        s.ctx.scroll_holding = false;
        s.requestFrame();
        // Let go moving: a fling. Held still first: none.
        const recent = cf.CACurrentMediaTime() - st.last_time < 0.08;
        if (recent and @abs(st.velocity) > 3 * min_speed) {
            st.fling = st.velocity;
            st.fling_at = st.start;
            st.fling_time = cf.CACurrentMediaTime();
            st.fling_offset = null;
            s.requestFrame();
        }
        return;
    }
    if (st.stopper) return;
    s.ctx.input.mouse = location(s, t);
    s.ctx.updateHot();
    s.ctx.pointerUp();
    s.frame();
    // The tap may have closed the window.
    if (s.dead) return;
    lift(s);
    if (!s.dead) keys.tapped(s);
}

fn cancelled(obj: objc.Object, _: objc.SEL, touches: objc.Object, _: ?objc.Object) callconv(.c) void {
    const s = Surface.enter(obj) orelse return;
    defer s.leave();
    const st = &s.touch;
    const second = st.second != null and objc.msg(objc.BOOL, touches, "containsObject:", .{st.second.?});
    if (followed(s, touches) == null and !second) return;
    const pressing = !st.scrolling and !st.stopper;
    st.* = .{};
    s.ctx.scroll_holding = false;
    // The system took the touch (a gesture, a call): nothing is clicked.
    s.ctx.input.mouse = away;
    s.ctx.updateHot();
    if (pressing) s.ctx.pointerUp();
    s.frame();
}

/// One step of a fling, before the display link's frame.
pub fn fling(s: *Surface) void {
    const st = &s.touch;
    if (st.fling == 0) return;
    const now = cf.CACurrentMediaTime();
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
