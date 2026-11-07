//! Scrolling that comes in whole steps, a wheel's notch or an arrow key, spread
//! over a few frames so the page moves rather than jumps. A trackpad is already
//! smooth and goes straight through; anything else that scrolls takes over.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const dom = @import("dom.zig");
const display = @import("paint/display.zig");
const view = @import("page_view.zig");
const Page = @import("page.zig").Page;

/// How quickly it closes the distance: about 95% of it in three of these.
const seconds: f32 = 0.05;
/// Closer than this, in pixels, it arrives.
const near: f32 = 0.5;

pub const Glide = struct {
    /// The scroller, by what outlives a rebuilt list. The document's node for the page.
    key: *dom.Node,
    left: [2]f32,
};

/// Adds a step to scroller `i`: where it is going, kept within what it can reach.
pub fn by(p: *Page, c: *ui.Context, l: *display.List, i: u32, dx: f32, dy: f32) void {
    const clip = &l.clips[i];
    const key = if (i == 1) p.doc.node else clip.node orelse return view.scrollBy(p, l, i, dx, dy);
    const had = if (p.glide) |g| (if (g.key == key) g.left else [2]f32{ 0, 0 }) else [2]f32{ 0, 0 };
    const m = l.maxScroll(i);
    const left = [2]f32{
        std.math.clamp(clip.scroll_x + had[0] + dx, 0, m[0]) - clip.scroll_x,
        std.math.clamp(clip.scroll_y + had[1] + dy, 0, m[1]) - clip.scroll_y,
    };
    p.glide = if (left[0] == 0 and left[1] == 0) null else .{ .key = key, .left = left };
    if (p.glide != null) c.animationFrame();
}

/// One frame's part of what's left.
pub fn step(p: *Page, c: *ui.Context, l: *display.List) void {
    const g = p.glide orelse return;
    const i = indexOf(p, l, g.key) orelse {
        p.glide = null;
        return;
    };
    const k = 1 - @exp(-@max(c.dt, 0) / seconds);
    var move = [2]f32{ g.left[0] * k, g.left[1] * k };
    var rest = [2]f32{ g.left[0] - move[0], g.left[1] - move[1] };
    if (@abs(rest[0]) < near and @abs(rest[1]) < near) {
        move = g.left;
        rest = .{ 0, 0 };
    }
    view.moveBy(p, l, i, move[0], move[1]);
    if (rest[0] == 0 and rest[1] == 0) {
        p.glide = null;
    } else {
        p.glide = .{ .key = g.key, .left = rest };
        c.animationFrame();
    }
}

fn indexOf(p: *const Page, l: *const display.List, key: *dom.Node) ?u32 {
    if (key == p.doc.node) return 1;
    for (l.clips, 0..) |*c, i| if (c.node == key) return @intCast(i);
    return null;
}
