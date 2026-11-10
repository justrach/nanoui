//! Scrolling that comes in whole steps, a wheel's notch or an arrow key, spread
//! over a few frames so the page moves rather than jumps. A trackpad is already
//! smooth and goes straight through; anything else that scrolls takes over.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const dom = @import("dom.zig");
const box = @import("layout/box.zig");
const display = @import("paint/display.zig");
const frames = @import("frames.zig");
const web = @import("web/web.zig");
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

pub fn scrollBy(p: *Page, l: *display.List, i: u32, dx: f32, dy: f32) void {
    p.glide = null;
    moveBy(p, l, i, dx, dy);
}

/// `scrollBy` for a glide, which goes on.
pub fn moveBy(p: *Page, l: *display.List, i: u32, dx: f32, dy: f32) void {
    const c = &l.clips[i];
    const m = l.maxScroll(i);
    const was = [2]f32{ c.scroll_x, c.scroll_y };
    c.scroll_x = std.math.clamp(c.scroll_x + dx, 0, m[0]);
    c.scroll_y = std.math.clamp(c.scroll_y + dy, 0, m[1]);
    p.restore_scroll = 0;
    if (c.scroll_x != was[0] or c.scroll_y != was[1]) {
        l.scroll_rev +%= 1;
        p.hover_held_until = p.engine.now + 0.12;
    }
    const key = if (i == 1) p.doc.node else c.node orelse return;
    p.scrolls.put(p.gpa, key, .{ c.scroll_x, c.scroll_y }) catch {};
    web.scrolled(p, key);
}

/// Goes to a place in the document: a fragment, a found word.
pub fn scrollPageTo(p: *Page, y: f32) void {
    const l = if (p.list) |*x| x else return;
    const c = &l.clips[1];
    scrollBy(p, l, 1, 0, y - c.scroll_y);
}

pub fn clampScrolls(p: *Page, l: *display.List) void {
    _ = p;
    for (l.clips, 0..) |*c, i| {
        if (i == 0) continue;
        const m = l.maxScroll(@intCast(i));
        const sx = std.math.clamp(c.scroll_x, 0, m[0]);
        const sy = std.math.clamp(c.scroll_y, 0, m[1]);
        if (sx != c.scroll_x or sy != c.scroll_y) {
            c.scroll_x = sx;
            c.scroll_y = sy;
            l.scroll_rev +%= 1;
        }
    }
}

/// The keys that move a page when nothing is being typed in.
pub fn keyScroll(p: *Page, c: *ui.Context, l: *display.List, h: f32) void {
    if (c.focus != 0 or !l.clips[1].scrolls) return;
    const step_px: f32 = 48;
    if (c.input.key) |k| switch (k) {
        .up => by(p, c, l, 1, 0, -step_px),
        .down => by(p, c, l, 1, 0, step_px),
        .left => by(p, c, l, 1, -step_px, 0),
        .right => by(p, c, l, 1, step_px, 0),
        .page_up => by(p, c, l, 1, 0, -(h - step_px)),
        .page_down => by(p, c, l, 1, 0, h - step_px),
        .home => by(p, c, l, 1, 0, -1e9),
        .end => by(p, c, l, 1, 0, 1e9),
        else => {},
    };
    if (c.shortcut(.{ .key = ' ' })) by(p, c, l, 1, 0, h - step_px);
    if (c.shortcut(.{ .key = ' ', .shift = true })) by(p, c, l, 1, 0, -(h - step_px));
}

/// A slim bar along the right while there's more page than window.
pub fn scrollbar(c: *ui.Context, l: *const display.List, rect: box.Rect) void {
    const page = l.clips[1];
    if (page.content_h <= rect.h + 1) return;
    const k = rect.h / page.content_h;
    const bar_h = @max(24, rect.h * k);
    const y = (rect.h - bar_h) * page.scroll_y / @max(1, page.content_h - rect.h);
    _ = c.leaf(.{
        .absolute = true,
        .offset = .{ .x = rect.w - 7, .y = y + 2 },
        .width = .{ .px = 5 },
        .height = .{ .px = bar_h - 4 },
        .radius = 2.5,
        .corner_circular = true,
        .background = if (c.theme.dark) ui.Color.white.alpha(0.25) else ui.Color.black.alpha(0.22),
    }, .none, null);
}

/// A wheel over a frame scrolls it while it can, then what holds it.
pub fn wheelThrough(p: *Page, c: *ui.Context, x: f32, y: f32, dx: f32, dy: f32) void {
    const l = if (p.list) |*q| q else return;
    const n = l.hit(x, y);
    if (n) |e| if (e.isTag("iframe")) if (frames.childPage(p, e)) |child| {
        if (child.list != null and child.frame.?.rect.contains(x, y) and canScroll(child, x, y, dx, dy)) return wheelThrough(child, c, x, y, dx, dy);
    };
    wheel(p, c, l, x, y, dx, dy);
}

/// An `<iframe scrolling=no>`: its page stays where it is, with no bar.
pub fn noScrolling(p: *const Page) bool {
    const f = p.frame orelse return false;
    const v = f.node.attr("scrolling") orelse return false;
    const eq = std.ascii.eqlIgnoreCase;
    return eq(v, "no") or eq(v, "noscroll") or eq(v, "off");
}

fn canScroll(p: *Page, x: f32, y: f32, dx: f32, dy: f32) bool {
    if (noScrolling(p)) return false;
    const l = if (p.list) |*q| q else return false;
    const n = l.hit(x, y);
    if (n) |e| if (e.isTag("iframe")) if (frames.childPage(p, e)) |child| {
        if (child.list != null and canScroll(child, x, y, dx, dy)) return true;
    };
    const i = l.scrollerAt(x, y, dx, dy);
    if (i == 1 and !l.clips[1].scrolls) return false;
    return l.canMove(i, dx, dy);
}

fn wheel(p: *Page, c: *ui.Context, l: *display.List, x: f32, y: f32, dx: f32, dy: f32) void {
    const i = l.scrollerAt(x, y, dx, dy);
    if (i == 1 and !l.clips[1].scrolls) return;
    if (c.input.precise) scrollBy(p, l, i, -dx, -dy) else by(p, c, l, i, -dx, -dy);
}
