//! Flexbox layout in two passes: `measure` sizes boxes from their content,
//! bottom up; `arrange` places them, top down, sharing the free room among
//! the boxes that grow.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const none = ctx_mod.none;
const text = @import("text.zig");
const rich = text.rich;

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
    if (index == 0) c.building = false;
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
            if (!c.text_warmed) {
                text.warmCaches(c.text);
                c.text_warmed = true;
            }
            const lh = c.text.lineHeight(t.style);
            if (t.style.wrap) {
                flexible = true;
                t.lines = c.text.wrapAttributed(t.str, t.style, t.spans, inner_w);
                // At most `max_lines`; `arrange` ends the last in "…" (`truncate.zig`).
                if (t.style.max_lines > 0 and t.lines.len > t.style.max_lines) t.lines = t.lines[0..t.style.max_lines];
                for (t.lines) |l| content.w = @max(content.w, l.width);
                content.h = lh * @as(f32, @floatFromInt(t.lines.len));
            } else {
                const w = if (rich.styled(t.spans)) rich.layout(c.text, t.str, t.style, t.spans, 0).width else c.text.width(t.str, t.style);
                content.w = @ceil(w);
                content.h = lh;
                // Cut to fit (`truncate.zig`): a row may shrink it.
                flexible = t.style.cuts();
            }
        },
        .icon => |ic| {
            if (c.text.atlas.symbol(ic.name, ic.size, @intFromEnum(ic.weight))) |sp| {
                content = .{ .w = sp.w + 2 * sp.x, .h = sp.h + 2 * sp.y };
            } else content = .{ .w = ic.size, .h = ic.size };
        },
        // Sized by its style (the widget gives the size).
        .image, .texture, .canvas => {},
        .none => {
            var child = n.first_child;
            var count: f32 = 0;
            while (child != none) : (child = c.node(child).next) {
                // A box that scrolls sideways lays its children out at their own widths.
                const s = measure(c, child, if (st.scroll_x) std.math.inf(f32) else inner_w);
                if (c.node(child).style.absolute) continue;
                if (!st.scroll_x) flexible = flexible or c.node(child).flexible;
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
    if (st.scroll_x and st.max_width == std.math.inf(f32)) content.w = 0;
    var size: types.Size = .{
        .w = content.w + st.padding.horizontal(),
        .h = content.h + st.padding.vertical(),
    };
    if (st.width == .px) size.w = st.width.px;
    if (st.height == .px) size.h = st.height.px;
    // Truncating text is no wider than the room it is given.
    if (n.content == .text and n.content.text.style.cuts()) size.w = @min(size.w, box_w);
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
    // Where its parent puts it, its ancestors' moves aside: moved since the
    // last layout, a `settle_y` box springs there from where it was shown.
    const carried = c.motion.carried;
    defer c.motion.carried = carried;
    var dy = st.offset.y;
    if (st.settle_y) |s| dy += @import("motion.zig").settleY(c, n.id, rect_in.y - carried, s);
    c.motion.carried = carried + dy;
    rect.x += st.offset.x;
    rect.y += dy;
    n.rect = rect;
    if (n.content == .text and n.content.text.style.cuts()) text.fit(c, index, rect.w);
    if (n.content == .text and n.content.text.style.max_lines > 0) text.fitLines(c, index, rect.w);
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

    const scroll_y: f32 = if (st.scroll) @import("scroll.zig").arrangeScrollY(c, n, inner_main, used) else 0;

    var scroll_x: f32 = 0;
    if (st.scroll_x) {
        var content_w = used;
        if (dir == .column) {
            content_w = 0;
            child = n.first_child;
            while (child != none) : (child = c.node(child).next) {
                if (!c.node(child).style.absolute) content_w = @max(content_w, c.node(child).measured.w);
            }
        }
        // Moved by the wheel's x before the view was built (`scroll_x.zig`).
        if (c.scroll_x.getPtr(n.id)) |s| {
            s.* = std.math.clamp(s.*, 0, @max(0, content_w - inner.w));
            scroll_x = s.*;
        }
    }

    // Scrolling moves the children without moving their places.
    c.motion.carried -= scroll_y;
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
            arrange(c, child, .{ .x = inner.x - scroll_x, .y = inner.y - scroll_y, .w = w, .h = h });
            continue;
        }
        const len = mainLen(dir, ch.style);
        const grows = growOf(dir, ch.style) > 0;
        var m = if (len == .fill) 0 else main(dir, ch.measured);
        if (free > 0 and grow_total > 0) m += free * growOf(dir, ch.style) / grow_total;
        // Too little room in a row: boxes of wrapping text give it back.
        if (free < 0 and shrink_total > 0 and dir == .row and ch.flexible and !st.scroll_x)
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
            .{ .x = inner.x + pos - scroll_x, .y = inner.y + cpos, .w = m, .h = x }
        else
            .{ .x = inner.x + cpos - scroll_x, .y = inner.y + pos - scroll_y, .w = x, .h = m };
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

test "truncate and max_lines share string and width without cache collision" {
    const ui = @import("ui.zig");
    const View = struct {
        label_idx: u32 = 0,
        wrap_idx: u32 = 0,
        fn build(s: *@This(), c: *Context) void {
            ui.column(c, .{ .width = .{ .px = 120 } });
            defer ui.end(c);
            s.label_idx = @intCast(c.nodes.items.len);
            ui.text(c, "First line", .{ .size = 13, .truncate = true });
            s.wrap_idx = @intCast(c.nodes.items.len);
            ui.text(c, "First line\nSecond line dropped", .{ .size = 13, .wrap = true, .max_lines = 1 });
        }
    };
    var v: View = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&v, View.build), .{});
    defer t.deinit();
    t.frame();
    try std.testing.expectEqualStrings("First line", t.ctx.node(v.label_idx).content.text.str);
    try std.testing.expect(std.mem.endsWith(u8, t.ctx.node(v.wrap_idx).content.text.str, "…"));
}
