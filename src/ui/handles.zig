//! A selection's handles on a touch screen: where its two ends are, a bar with
//! a knob at each, and which one a finger landed on. The focused field's
//! selection if it has one, else the page's (`selection.zig`). Which fingers do
//! what is the platform's (`ios/selecting.zig`); this part has no platform in it.
const std = @import("std");
const types = @import("types.zig");
const gpu = @import("gpu.zig");
const Context = @import("context.zig").Context;

pub const Which = enum { start, end };

/// The line-tall rects of the selection's ends; null for an end out of view.
pub const Ends = struct { start: ?types.Rect = null, end: ?types.Rect = null };

const bar_width: f32 = 2;
const knob: f32 = 10;
/// How far from a handle a finger still takes it: Apple's 44-point target.
const reach_x: f32 = 22;
const reach_y: f32 = 14;

pub fn ends(c: *const Context) ?Ends {
    if (c.focused_text) |f| if (f.ends) |e| return .{ .start = e[0], .end = e[1] };
    const s = &c.selection;
    if (s.start_rect == null and s.end_rect == null) return null;
    return .{ .start = s.start_rect, .end = s.end_rect };
}

/// The handle under `p`, if any: the nearer, when both reach it.
pub fn at(e: Ends, p: types.Point) ?Which {
    const near = struct {
        fn f(rect: ?types.Rect, q: types.Point) ?f32 {
            const r = rect orelse return null;
            const dx = @abs(q.x - r.x);
            if (dx > reach_x or q.y < r.y - reach_y or q.y > r.y + r.h + reach_y) return null;
            return dx;
        }
    }.f;
    const a = near(e.start, p);
    const b = near(e.end, p);
    if (a != null and b != null) return if (a.? < b.?) .start else .end;
    if (a != null) return .start;
    return if (b != null) .end else null;
}

/// What the finger should press to move a handle: the middle of its line,
/// wherever on the handle it landed.
pub fn grip(e: Ends, which: Which) ?types.Point {
    const r = (if (which == .start) e.start else e.end) orelse return null;
    return .{ .x = r.x, .y = r.y + r.h / 2 };
}

/// The handles, over everything else in the frame.
pub fn paint(gpa: std.mem.Allocator, out: *std.ArrayList(gpu.Instance), c: *const Context) void {
    const e = ends(c) orelse return;
    const color = gpu.color4(c.theme.accent);
    if (e.start) |r| one(gpa, out, r, r.y - knob + 1, color);
    if (e.end) |r| one(gpa, out, r, r.y + r.h - 1, color);
}

fn one(gpa: std.mem.Allocator, out: *std.ArrayList(gpu.Instance), r: types.Rect, knob_y: f32, color: [4]f32) void {
    out.append(gpa, .{ .rect = .{ r.x - bar_width / 2, r.y, bar_width, r.h }, .color = color, .radius = 1, .kind = gpu.Kind.quad }) catch {};
    out.append(gpa, .{ .rect = .{ r.x - knob / 2, knob_y, knob, knob }, .color = color, .radius = knob / 2, .kind = gpu.Kind.quad }) catch {};
}
