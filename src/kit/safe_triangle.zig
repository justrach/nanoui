//! The submenu "safe triangle": a point-in-triangle test from the cursor
//! to the submenu's near corners, so aiming at an open submenu does not
//! switch rows on the way. Pure geometry; no UI.
//!
//! The triangle's apex is the cursor. The other two vertices are the
//! submenu's near top and bottom corners (top-left and bottom-left when
//! the submenu sits to the right of its parent; top-right and bottom-right
//! when it sits to the left). Degenerate (zero-area) triangles contain
//! nothing. A small pad inflates the triangle; a direction check drops
//! the hold when the pointer moves away; an idle limit drops it after
//! the pointer rests inside.
const std = @import("std");
const ui = @import("../ui/ui.zig");

pub const Point = ui.Point;
pub const Rect = ui.Rect;

/// Seconds of no movement inside the triangle before hover switching resumes.
pub const default_idle: f32 = 0.3;
/// Extra space around the triangle, in points.
pub const default_pad: f32 = 4;
/// Displacement below this, in points, counts as still.
pub const default_move_eps: f32 = 0.5;

/// Which side of the parent the submenu sits on.
pub const Side = enum { left, right };

/// Cursor plus the submenu's near top and bottom corners.
pub const Triangle = struct {
    apex: Point,
    near_top: Point,
    near_bottom: Point,
};

/// The submenu's near edge of `submenu` as seen from `cursor`.
pub fn triangle(cursor: Point, submenu: Rect, side: Side) Triangle {
    return switch (side) {
        .right => .{
            .apex = cursor,
            .near_top = .{ .x = submenu.x, .y = submenu.y },
            .near_bottom = .{ .x = submenu.x, .y = submenu.y + submenu.h },
        },
        .left => .{
            .apex = cursor,
            .near_top = .{ .x = submenu.x + submenu.w, .y = submenu.y },
            .near_bottom = .{ .x = submenu.x + submenu.w, .y = submenu.y + submenu.h },
        },
    };
}

/// Which side `submenu` sits on relative to `parent`.
pub fn sideOf(parent: Rect, submenu: Rect) Side {
    const parent_mid = parent.x + parent.w * 0.5;
    const sub_mid = submenu.x + submenu.w * 0.5;
    return if (sub_mid >= parent_mid) .right else .left;
}

/// Same-side cross product of edge `a`→`b` against `p`.
fn cross(a: Point, b: Point, p: Point) f32 {
    return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
}

fn area(t: Triangle) f32 {
    return cross(t.apex, t.near_top, t.near_bottom);
}

fn pushOut(p: Point, cx: f32, cy: f32, pad: f32) Point {
    const dx = p.x - cx;
    const dy = p.y - cy;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 1e-6) return p;
    const s = (len + pad) / len;
    return .{ .x = cx + dx * s, .y = cy + dy * s };
}

/// Inflate each vertex away from the centroid by `pad`.
pub fn inflate(t: Triangle, pad: f32) Triangle {
    if (pad <= 0) return t;
    const cx = (t.apex.x + t.near_top.x + t.near_bottom.x) / 3;
    const cy = (t.apex.y + t.near_top.y + t.near_bottom.y) / 3;
    return .{
        .apex = pushOut(t.apex, cx, cy, pad),
        .near_top = pushOut(t.near_top, cx, cy, pad),
        .near_bottom = pushOut(t.near_bottom, cx, cy, pad),
    };
}

/// Whether `p` is inside `t`, edges included. A zero-area triangle
/// contains nothing. `pad` inflates the triangle first.
pub fn contains(t: Triangle, p: Point, pad: f32) bool {
    const u = inflate(t, pad);
    const a = area(u);
    if (@abs(a) < 1e-4) return false;
    const d1 = cross(u.apex, u.near_top, p);
    const d2 = cross(u.near_top, u.near_bottom, p);
    const d3 = cross(u.near_bottom, u.apex, p);
    // Same sign as the area (or zero: on an edge).
    return d1 * a >= 0 and d2 * a >= 0 and d3 * a >= 0;
}

/// The step from `from` to `to` heads at the submenu's near-edge centre.
pub fn headingToward(from: Point, to: Point, submenu: Rect, side: Side) bool {
    const vx = to.x - from.x;
    const vy = to.y - from.y;
    const tx = switch (side) {
        .right => submenu.x,
        .left => submenu.x + submenu.w,
    };
    const ty = submenu.y + submenu.h * 0.5;
    const dx = tx - to.x;
    const dy = ty - to.y;
    return vx * dx + vy * dy > 0;
}

pub const Sample = struct {
    cursor: Point,
    prev: Point,
    submenu: Rect,
    parent_row: ?Rect = null,
    idle: f32 = 0,
    idle_limit: f32 = default_idle,
    pad: f32 = default_pad,
    move_eps: f32 = default_move_eps,
};

/// Why a submenu stays open, or why hover switching should resume.
pub const Decision = enum {
    /// Pointer is in the submenu: the triangle is off.
    inside_submenu,
    /// Pointer is on the row that opened it.
    inside_parent,
    /// Inside the triangle and still aiming at the submenu.
    hold,
    /// Outside, moving away, or idle past the limit.
    release,
};

fn dist2(a: Point, b: Point) f32 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return dx * dx + dy * dy;
}

/// Hold the open submenu, or fall through to normal hover switching.
///
/// The overlay triangle is drawn from the current cursor; the hit test
/// uses the previous cursor as apex so a step that stays in that cone
/// (a diagonal toward the submenu) is a hold, and a step that leaves it
/// (straight down onto another row) is a release.
pub fn decide(s: Sample, side: Side) Decision {
    if (s.submenu.contains(s.cursor)) return .inside_submenu;
    if (s.parent_row) |row| if (row.contains(s.cursor)) return .inside_parent;
    const tri = triangle(s.prev, s.submenu, side);
    if (!contains(tri, s.cursor, s.pad)) return .release;
    const moving = dist2(s.prev, s.cursor) >= s.move_eps * s.move_eps;
    if (moving) {
        if (!headingToward(s.prev, s.cursor, s.submenu, side)) return .release;
        return .hold;
    }
    if (s.idle >= s.idle_limit) return .release;
    return .hold;
}

/// True when this decision should keep the current submenu open.
pub fn holds(d: Decision) bool {
    return d != .release;
}

test "a point inside a right-hand triangle is in, one outside is not" {
    const sub: Rect = .{ .x = 200, .y = 10, .w = 120, .h = 180 };
    const cursor: Point = .{ .x = 40, .y = 40 };
    const t = triangle(cursor, sub, .right);
    try std.testing.expectEqual(@as(f32, 200), t.near_top.x);
    try std.testing.expectEqual(@as(f32, 10), t.near_top.y);
    try std.testing.expectEqual(@as(f32, 200), t.near_bottom.x);
    try std.testing.expectEqual(@as(f32, 190), t.near_bottom.y);
    // Along the median, well inside.
    try std.testing.expect(contains(t, .{ .x = 120, .y = 80 }, 0));
    try std.testing.expect(contains(t, cursor, 0));
    try std.testing.expect(contains(t, t.near_top, 0));
    try std.testing.expect(contains(t, t.near_bottom, 0));
    // Above the top edge, or left of the apex.
    try std.testing.expect(!contains(t, .{ .x = 120, .y = 0 }, 0));
    try std.testing.expect(!contains(t, .{ .x = 20, .y = 40 }, 0));
}

test "a left-hand submenu uses the right-edge corners" {
    const sub: Rect = .{ .x = 10, .y = 20, .w = 80, .h = 100 };
    const cursor: Point = .{ .x = 200, .y = 70 };
    const t = triangle(cursor, sub, .left);
    try std.testing.expectEqual(@as(f32, 90), t.near_top.x);
    try std.testing.expectEqual(@as(f32, 90), t.near_bottom.x);
    try std.testing.expect(contains(t, .{ .x = 140, .y = 70 }, 0));
    try std.testing.expect(!contains(t, .{ .x = 50, .y = 70 }, 0));
}

test "sideOf follows the submenu's midpoint" {
    const parent: Rect = .{ .x = 100, .y = 10, .w = 80, .h = 30 };
    try std.testing.expectEqual(Side.right, sideOf(parent, .{ .x = 190, .y = 10, .w = 100, .h = 80 }));
    try std.testing.expectEqual(Side.left, sideOf(parent, .{ .x = 0, .y = 10, .w = 90, .h = 80 }));
}

test "a degenerate triangle contains nothing" {
    const p: Point = .{ .x = 10, .y = 10 };
    const flat = Triangle{ .apex = p, .near_top = p, .near_bottom = p };
    try std.testing.expect(!contains(flat, p, 0));
    try std.testing.expect(!contains(flat, .{ .x = 11, .y = 10 }, 4));
    const collinear = Triangle{
        .apex = .{ .x = 0, .y = 0 },
        .near_top = .{ .x = 10, .y = 0 },
        .near_bottom = .{ .x = 20, .y = 0 },
    };
    try std.testing.expect(!contains(collinear, .{ .x = 10, .y = 0 }, 0));
}

test "padding includes a point just outside the unpadded triangle" {
    const t = triangle(.{ .x = 0, .y = 50 }, .{ .x = 100, .y = 0, .w = 50, .h = 100 }, .right);
    // Top edge from (0, 50) to (100, 0): at x=50 the edge is y=25.
    const just_out: Point = .{ .x = 50, .y = 23 };
    try std.testing.expect(!contains(t, just_out, 0));
    try std.testing.expect(contains(t, just_out, 6));
}

test "headingToward is true toward the submenu and false away" {
    const right: Rect = .{ .x = 200, .y = 0, .w = 80, .h = 100 };
    try std.testing.expect(headingToward(.{ .x = 40, .y = 40 }, .{ .x = 60, .y = 45 }, right, .right));
    try std.testing.expect(!headingToward(.{ .x = 60, .y = 40 }, .{ .x = 40, .y = 40 }, right, .right));
    const left: Rect = .{ .x = 10, .y = 0, .w = 80, .h = 100 };
    try std.testing.expect(headingToward(.{ .x = 180, .y = 50 }, .{ .x = 160, .y = 50 }, left, .left));
    try std.testing.expect(!headingToward(.{ .x = 160, .y = 50 }, .{ .x = 180, .y = 50 }, left, .left));
}

test "decide: inside the submenu, on the parent row, hold, idle, and away" {
    const sub: Rect = .{ .x = 200, .y = 10, .w = 120, .h = 180 };
    const row: Rect = .{ .x = 20, .y = 30, .w = 160, .h = 30 };
    const base = Sample{
        .cursor = .{ .x = 80, .y = 45 },
        .prev = .{ .x = 70, .y = 40 },
        .submenu = sub,
        .parent_row = row,
        .idle = 0,
    };
    try std.testing.expectEqual(Decision.inside_submenu, decide(.{
        .cursor = .{ .x = 220, .y = 40 },
        .prev = .{ .x = 210, .y = 40 },
        .submenu = sub,
    }, .right));
    try std.testing.expectEqual(Decision.inside_parent, decide(base, .right));
    // A diagonal from the parent row toward the submenu stays in the cone: hold.
    try std.testing.expectEqual(Decision.hold, decide(.{
        .cursor = .{ .x = 140, .y = 70 },
        .prev = .{ .x = 80, .y = 45 },
        .submenu = sub,
        .parent_row = row,
    }, .right));
    // Same point, idle past the limit: release.
    try std.testing.expectEqual(Decision.release, decide(.{
        .cursor = .{ .x = 100, .y = 80 },
        .prev = .{ .x = 100, .y = 80 },
        .submenu = sub,
        .parent_row = row,
        .idle = 0.35,
    }, .right));
    // Still idle, but under the limit: hold.
    try std.testing.expectEqual(Decision.hold, decide(.{
        .cursor = .{ .x = 100, .y = 80 },
        .prev = .{ .x = 100, .y = 80 },
        .submenu = sub,
        .parent_row = row,
        .idle = 0.1,
    }, .right));
    // Moving away, even inside the triangle: release.
    try std.testing.expectEqual(Decision.release, decide(.{
        .cursor = .{ .x = 70, .y = 80 },
        .prev = .{ .x = 100, .y = 80 },
        .submenu = sub,
        .parent_row = row,
    }, .right));
    // Outside the triangle: release.
    try std.testing.expectEqual(Decision.release, decide(.{
        .cursor = .{ .x = 100, .y = 300 },
        .prev = .{ .x = 80, .y = 50 },
        .submenu = sub,
        .parent_row = row,
    }, .right));
}

test "holds is false only for release" {
    try std.testing.expect(holds(.inside_submenu));
    try std.testing.expect(holds(.inside_parent));
    try std.testing.expect(holds(.hold));
    try std.testing.expect(!holds(.release));
}

test "a flipped (left) placement holds while aiming left" {
    const sub: Rect = .{ .x = 10, .y = 20, .w = 90, .h = 160 };
    const row: Rect = .{ .x = 200, .y = 40, .w = 140, .h = 30 };
    try std.testing.expectEqual(Decision.hold, decide(.{
        .cursor = .{ .x = 150, .y = 70 },
        .prev = .{ .x = 180, .y = 55 },
        .submenu = sub,
        .parent_row = row,
    }, .left));
    try std.testing.expectEqual(Decision.release, decide(.{
        .cursor = .{ .x = 180, .y = 90 },
        .prev = .{ .x = 160, .y = 90 },
        .submenu = sub,
        .parent_row = row,
    }, .left));
}
