//! The floats of one block formatting context, in its coordinates: where the
//! next one goes, and how much room they leave a line.
const std = @import("std");
const css = @import("../css/style.zig");
const Allocator = std.mem.Allocator;

/// A float's margin box.
const Entry = struct {
    left: bool,
    x0: f32,
    x1: f32,
    y0: f32,
    y1: f32,
    /// The lowest bottom of this float and all before it, which lets
    /// searches stop early: tops never decrease, so older ones are done with.
    reach: f32,
};

pub const Band = struct { x0: f32, x1: f32 };

pub const Floats = struct {
    list: std.ArrayList(Entry) = .empty,

    pub fn any(f: *const Floats) bool {
        return f.list.items.len > 0;
    }

    /// The room left in the container (`cx`, `cw`) over the heights `y`..`y+h`.
    pub fn band(f: *const Floats, y: f32, h: f32, cx: f32, cw: f32) Band {
        var out: Band = .{ .x0 = cx, .x1 = cx + cw };
        const items = f.list.items;
        var i = items.len;
        const end = y + @max(h, 0.01);
        while (i > 0) {
            i -= 1;
            const e = items[i];
            if (e.reach <= y) break;
            if (e.y1 <= y or e.y0 >= end or e.y1 <= e.y0) continue;
            if (e.left) out.x0 = @max(out.x0, e.x1) else out.x1 = @min(out.x1, e.x0);
        }
        return out;
    }

    /// The next height below `y` at which a float ends, if any does.
    pub fn nextBelow(f: *const Floats, y: f32) ?f32 {
        var best: ?f32 = null;
        const items = f.list.items;
        var i = items.len;
        while (i > 0) {
            i -= 1;
            const e = items[i];
            if (e.reach <= y) break;
            if (e.y1 > y and (best == null or e.y1 < best.?)) best = e.y1;
        }
        return best;
    }

    /// How far down `clear` must go; the lowest bottom of the floats it clears.
    pub fn clearY(f: *const Floats, clear: css.Clear) f32 {
        var y: f32 = -std.math.inf(f32);
        if (clear == .both and f.list.items.len > 0) return f.list.items[f.list.items.len - 1].reach;
        for (f.list.items) |e| {
            const hit = switch (clear) {
                .none => false,
                .left => e.left,
                .right => !e.left,
                .both => true,
            };
            if (hit) y = @max(y, e.y1);
        }
        return y;
    }

    /// The bottom of everything: what a formatting context's auto height holds.
    pub fn bottom(f: *const Floats) f32 {
        if (f.list.items.len == 0) return 0;
        return f.list.items[f.list.items.len - 1].reach;
    }

    /// Finds a margin box of `w` by `h` its place in the container at or
    /// below `top`, and keeps it. The top left of the box comes back.
    pub fn place(f: *Floats, gpa: Allocator, left: bool, clear: css.Clear, w: f32, h: f32, top: f32, cx: f32, cw: f32) Allocator.Error!struct { x: f32, y: f32 } {
        var y = top;
        if (f.list.items.len > 0) y = @max(y, f.list.items[f.list.items.len - 1].y0);
        if (clear != .none) y = @max(y, f.clearY(clear));
        var b = f.band(y, h, cx, cw);
        while (b.x1 - b.x0 < w and (b.x0 > cx or b.x1 < cx + cw)) {
            y = f.nextBelow(y) orelse break;
            b = f.band(y, h, cx, cw);
        }
        const x = if (left) b.x0 else b.x1 - w;
        const prev = if (f.list.items.len > 0) f.list.items[f.list.items.len - 1].reach else -std.math.inf(f32);
        try f.list.append(gpa, .{ .left = left, .x0 = x, .x1 = x + w, .y0 = y, .y1 = y + h, .reach = @max(prev, y + h) });
        return .{ .x = x, .y = y };
    }
};
