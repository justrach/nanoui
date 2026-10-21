//! Flexbox layout in two passes: `measure` sizes boxes from their content,
//! bottom up; `arrange` places them, top down, sharing the free room among
//! the boxes that grow.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const none = ctx_mod.none;
const rich = @import("text.zig").rich;

fn main(d: types.Direction, s: types.Size) f32 {
    return if (d == .row) s.w else s.h;
}

fn cross(d: types.Direction, s: types.Size) f32 {
    return if (d == .row) s.h else s.w;
}

fn mainLen(d: types.Direction, st: types.Style) types.Length {
    return if (d == .row) st.width else st.height;
}

fn crossLen(d: types.Direction, st: types.Style) types.Length {
    return if (d == .row) st.height else st.width;
}

/// Sizes box `index` and its children, given `avail_w` points of width.
pub fn measure(c: *Context, index: u32, avail_w: f32) types.Size {
    const n = c.node(index);
    const st = n.style;
    var box_w = switch (st.width) {
        .px => |v| v,
        else => avail_w,
    };
    box_w = @min(box_w, st.max_width);
    const inner_w = @max(0, box_w - st.padding.horizontal());

    var content: types.Size = .{};
    var flexible = false;
    switch (n.content) {
        .text => |*t| {
            const lh = c.text.lineHeight(t.style);
            if (t.style.wrap) {
                flexible = true;
                t.lines = c.text.wrapAttributed(t.str, t.style, t.spans, inner_w);
                for (t.lines) |l| content.w = @max(content.w, l.width);
                content.h = lh * @as(f32, @floatFromInt(t.lines.len));
            } else {
                const w = if (rich.styled(t.spans)) rich.layout(c.text, t.str, t.style, t.spans, 0).width else c.text.width(t.str, t.style);
                content.w = @ceil(w);
                content.h = lh;
            }
        },
        .icon => |ic| {
            if (c.text.atlas.symbol(ic.name, ic.size, @intFromEnum(ic.weight))) |sp| {
                content = .{ .w = sp.w + 2 * sp.x, .h = sp.h + 2 * sp.y };
            } else content = .{ .w = ic.size, .h = ic.size };
        },
        // Sized by its style (the widget gives the size).
        .image, .texture => {},
        .none => {
            var child = n.first_child;
            var count: f32 = 0;
            while (child != none) : (child = c.node(child).next) {
                const s = measure(c, child, inner_w);
                if (c.node(child).style.absolute) continue;
                flexible = flexible or c.node(child).flexible;
                const dir = st.direction;
                const m = main(dir, s);
                const x = cross(dir, s);
                if (dir == .row) {
                    content.w += m;
                    content.h = @max(content.h, x);
                } else {
                    content.h += m;
                    content.w = @max(content.w, x);
                }
                count += 1;
            }
            if (count > 1) {
                if (st.direction == .row) content.w += st.gap * (count - 1) else content.h += st.gap * (count - 1);
            }
            if (st.direction == .row and flexible) content.h = fitRow(c, n.first_child, st.gap, inner_w);
        },
    }

    // A scrolling box takes the room it is given, not its content's height
    // (CSS's `min-height: 0`): its content scrolls instead.
    if (st.scroll and st.max_height == std.math.inf(f32)) content.h = 0;
    var size: types.Size = .{
        .w = content.w + st.padding.horizontal(),
        .h = content.h + st.padding.vertical(),
    };
    if (st.width == .px) size.w = st.width.px;
    if (st.height == .px) size.h = st.height.px;
    size.w = std.math.clamp(size.w, st.min_width, @max(st.min_width, st.max_width));
    size.h = std.math.clamp(size.h, st.min_height, @max(st.min_height, st.max_height));
    c.node(index).measured = size;
    c.node(index).flexible = flexible and st.width != .px;
    return size;
}

/// Places box `index` in `rect` and its children inside it.
pub fn arrange(c: *Context, index: u32, rect_in: types.Rect) void {
    const n = c.node(index);
    const st = n.style;
    var rect = rect_in;
    rect.x += st.offset.x;
    rect.y += st.offset.y;
    n.rect = rect;
    if (n.first_child == none) return;

    const dir = st.direction;
    const inner = rect.inset(st.padding);
    const inner_main = if (dir == .row) inner.w else inner.h;
    const inner_cross = if (dir == .row) inner.h else inner.w;

    // Base sizes along the main axis, and the total share of growth.
    var used: f32 = 0;
    var grow_total: f32 = 0;
    var shrink_total: f32 = 0;
    var count: f32 = 0;
    var child = n.first_child;
    while (child != none) : (child = c.node(child).next) {
        const ch = c.node(child);
        if (ch.style.absolute) continue;
        const len = mainLen(dir, ch.style);
        used += if (len == .fill) 0 else main(dir, ch.measured);
        grow_total += growOf(dir, ch.style);
        if (dir == .row and ch.flexible) shrink_total += main(dir, ch.measured);
        count += 1;
    }
    used += st.gap * @max(0, count - 1);
    const free = inner_main - used;

    var pos: f32 = 0;
    var spacing = st.gap;
    if (grow_total == 0 and free > 0) switch (st.justify) {
        .start => {},
        .center => pos = free / 2,
        .end => pos = free,
        .space_between => if (count > 1) {
            spacing += free / (count - 1);
        },
    };

    var scroll_y: f32 = 0;
    if (st.scroll) {
        const content_h = used;
        const max_scroll = @max(0, content_h - inner_main);
        if (st.follow_end) {
            // It follows its end while the reader left it there: the
            // decision is made when the offset is moved (a wheel, a jump),
            // never because shrinking content pulled the offset to the end.
            const prev_max = c.scroll_max.get(n.id) orelse 0;
            const gop = c.scroll.getOrPut(c.gpa, n.id) catch null;
            if (gop) |g| {
                var follow = c.scroll_follow.get(n.id) orelse true;
                if (!g.found_existing) {
                    follow = true;
                } else if (c.scroll_seen.get(n.id)) |seen| {
                    if (g.value_ptr.* != seen) {
                        follow = g.value_ptr.* >= prev_max - 1;
                        c.scroll_moved.put(c.gpa, n.id, {}) catch {};
                    }
                }
                if (follow) {
                    const want = if (c.scroll_cap.get(n.id)) |cap| @min(max_scroll, cap) else max_scroll;
                    // Moved by following: what reads the last layout (a
                    // pinned header, a pill) needs one more frame.
                    if (g.value_ptr.* != want) c.animating = true;
                    g.value_ptr.* = want;
                }
                c.scroll_follow.put(c.gpa, n.id, follow) catch {};
            }
        }
        // Every scroller, not only follow_end: scroll-linked motion reads it.
        c.scroll_max.put(c.gpa, n.id, max_scroll) catch {};
        if (c.scroll.getPtr(n.id)) |s| {
            s.* = @min(s.*, max_scroll);
            scroll_y = s.*;
            if (st.follow_end) c.scroll_seen.put(c.gpa, n.id, s.*) catch {};
        }
    }

    child = n.first_child;
    while (child != none) : (child = c.node(child).next) {
        const ch = c.node(child);
        if (ch.style.absolute) {
            if (ch.style.fixed) {
                // From the window's corner, whatever scrolls.
                const w = if (ch.style.width == .fill) c.size.w else ch.measured.w;
                const h = if (ch.style.height == .fill) c.size.h else ch.measured.h;
                arrange(c, child, .{ .x = 0, .y = 0, .w = w, .h = h });
                continue;
            }
            const w = if (ch.style.width == .fill) inner.w else ch.measured.w;
            const h = if (ch.style.height == .fill) inner.h else ch.measured.h;
            arrange(c, child, .{ .x = inner.x, .y = inner.y - scroll_y, .w = w, .h = h });
            continue;
        }
        const len = mainLen(dir, ch.style);
        const grows = growOf(dir, ch.style) > 0;
        var m = if (len == .fill) 0 else main(dir, ch.measured);
        if (free > 0 and grow_total > 0) m += free * growOf(dir, ch.style) / grow_total;
        // Too little room in a row: boxes of wrapping text give it back.
        if (free < 0 and shrink_total > 0 and dir == .row and ch.flexible)
            m = @max(ch.style.min_width, m + free * m / shrink_total);

        const clen = crossLen(dir, ch.style);
        const stretch = clen == .fill or (st.align_items == .stretch and clen == .auto);
        var x = if (stretch) inner_cross else cross(dir, ch.measured);
        if (dir == .row) m = @min(m, ch.style.max_width) else x = @min(x, ch.style.max_width);

        // A box whose final width differs from the width it was measured
        // at (a growing child of a row, a stretched child of a column) is
        // measured again: wrapped text needs more or fewer lines.
        const final_w = if (dir == .row) m else x;
        // Only wrapping text depends on its width: other boxes keep theirs.
        if (ch.flexible and @abs(final_w - ch.measured.w) > 0.5 and ch.style.width != .px) {
            const s = measure(c, child, final_w);
            if (dir == .row and !stretch) x = s.h;
            if (dir == .column and len != .fill and !grows) m = s.h;
        }
        if (dir == .column) m = @min(m, ch.style.max_height) else x = @min(x, ch.style.max_height);

        const cpos: f32 = switch (st.align_items) {
            .start, .stretch => 0,
            .center => (inner_cross - x) / 2,
            .end => inner_cross - x,
        };
        const r: types.Rect = if (dir == .row)
            .{ .x = inner.x + pos, .y = inner.y + cpos, .w = m, .h = x }
        else
            .{ .x = inner.x + cpos, .y = inner.y + pos - scroll_y, .w = x, .h = m };
        arrange(c, child, r);
        pos += m + spacing;
    }
}

/// A row's height once its wrapping text has the widths `arrange` will
/// give it: measured at the row's whole width, text beside a fixed box (a
/// list's marker) fits on fewer lines than it gets, and the row would be
/// too short for it. The same shares of free room as `arrange`'s.
fn fitRow(c: *Context, first: u32, gap: f32, inner_w: f32) f32 {
    var used: f32 = 0;
    var grow_total: f32 = 0;
    var shrink_total: f32 = 0;
    var count: f32 = 0;
    var child = first;
    while (child != none) : (child = c.node(child).next) {
        const ch = c.node(child);
        if (ch.style.absolute) continue;
        used += if (ch.style.width == .fill) 0 else ch.measured.w;
        grow_total += growOf(.row, ch.style);
        if (ch.flexible) shrink_total += ch.measured.w;
        count += 1;
    }
    used += gap * @max(0, count - 1);
    const free = inner_w - used;
    var h: f32 = 0;
    child = first;
    while (child != none) : (child = c.node(child).next) {
        const ch = c.node(child);
        if (ch.style.absolute) continue;
        var ch_h = ch.measured.h;
        if (ch.flexible and ch.style.width != .px) {
            var m = if (ch.style.width == .fill) 0 else ch.measured.w;
            if (free > 0 and grow_total > 0) m += free * growOf(.row, ch.style) / grow_total;
            if (free < 0 and shrink_total > 0) m = @max(ch.style.min_width, m + free * m / shrink_total);
            m = @min(m, ch.style.max_width);
            if (@abs(m - ch.measured.w) > 0.5) ch_h = measure(c, child, m).h;
        }
        h = @max(h, ch_h);
    }
    return h;
}

fn growOf(dir: types.Direction, st: types.Style) f32 {
    if (st.grow > 0) return st.grow;
    return if (mainLen(dir, st) == .fill) 1 else 0;
}

test "row with a growing child" {
    var ts: @import("text.zig").TextSystem = undefined;
    var c = Context.init(std.testing.allocator, &ts);
    defer c.deinit();
    c.size = .{ .w = 300, .h = 100 };
    c.begin();
    _ = c.open(.{ .direction = .row, .width = .fill, .height = .fill, .gap = 10, .padding = .all(10) }, null);
    const a = c.leaf(.{ .width = .{ .px = 50 }, .height = .{ .px = 20 } }, .none, null);
    const b = c.leaf(.{ .grow = 1, .height = .{ .px = 20 } }, .none, null);
    const d = c.leaf(.{ .width = .{ .px = 30 }, .height = .{ .px = 20 } }, .none, null);
    c.end();
    _ = measure(&c, 0, 300);
    arrange(&c, 0, .{ .w = 300, .h = 100 });
    try std.testing.expectEqual(@as(f32, 10), c.node(a).rect.x);
    try std.testing.expectEqual(@as(f32, 70), c.node(b).rect.x);
    try std.testing.expectEqual(@as(f32, 180), c.node(b).rect.w);
    try std.testing.expectEqual(@as(f32, 260), c.node(d).rect.x);
}

test "centered column" {
    var ts: @import("text.zig").TextSystem = undefined;
    var c = Context.init(std.testing.allocator, &ts);
    defer c.deinit();
    c.size = .{ .w = 200, .h = 200 };
    c.begin();
    _ = c.open(.{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .gap = 10 }, null);
    const a = c.leaf(.{ .width = .{ .px = 40 }, .height = .{ .px = 40 } }, .none, null);
    const b = c.leaf(.{ .width = .{ .px = 80 }, .height = .{ .px = 40 } }, .none, null);
    c.end();
    _ = measure(&c, 0, 200);
    arrange(&c, 0, .{ .w = 200, .h = 200 });
    try std.testing.expectEqual(@as(f32, 80), c.node(a).rect.x);
    try std.testing.expectEqual(@as(f32, 55), c.node(a).rect.y);
    try std.testing.expectEqual(@as(f32, 60), c.node(b).rect.x);
    try std.testing.expectEqual(@as(f32, 105), c.node(b).rect.y);
}
