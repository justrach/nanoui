//! A virtualized list, in the manner of GPUI's `uniform_list`: rows of one
//! height, of which only those in view (and a few around) are built, so a
//! list of a hundred thousand rows costs what a screenful does.
//!
//!     var rows = ui.list(c, .{ .count = items.len, .row_height = 28 });
//!     while (rows.next()) |i| {
//!         ui.row(c, .{ .height = .{ .px = 28 }, .align_items = .center });
//!         defer ui.end(c);
//!         ui.text(c, items[i].name, .{});
//!     }
//!     rows.end();
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;

pub const Options = struct {
    count: usize,
    row_height: f32,
    width: types.Length = .fill,
    height: types.Length = .fill,
    gap: f32 = 0,
    padding: types.Edges = .{},
    /// Rows built beyond each edge of the view, for smooth scrolling.
    overscan: usize = 4,
    /// Scrolls the list to this offset (points) in this frame.
    scroll_to: ?f32 = null,
};

pub const Rows = struct {
    c: *Context,
    opts: Options,
    next_index: usize,
    last: usize,

    /// The index of the next row to build, or null when the view is full.
    pub fn next(r: *Rows) ?usize {
        if (r.next_index >= r.last) return null;
        const i = r.next_index;
        r.next_index += 1;
        // Rows keep their identity (hover, animations) as the list scrolls.
        r.c.next_key_int = i;
        return i;
    }

    /// Closes the list: the room of the rows after the view, then the box.
    pub fn end(r: *Rows) void {
        const pitch = r.opts.row_height + r.opts.gap;
        const after = r.opts.count - r.last;
        if (after > 0) _ = r.c.leaf(.{ .height = .{ .px = pitch * @as(f32, @floatFromInt(after)) - r.opts.gap } }, .none, "list-after");
        r.c.end();
    }
};

pub fn list(c: *Context, opts: Options) Rows {
    c.retain.virtual_list = true;
    const id = c.peekId(null);
    if (opts.scroll_to) |y| c.scroll.put(c.gpa, id, @max(0, y)) catch {};
    const i = c.open(.{
        .direction = .column,
        .width = opts.width,
        .height = opts.height,
        .padding = opts.padding,
        .scroll = true,
    }, null);
    std.debug.assert(c.node(i).id == id);
    const pitch = opts.row_height + opts.gap;
    // The view's height as the last frame laid it out; a screenful at first.
    const view_h = if (c.rects.get(id)) |r| r.h else c.size.h;
    // The list knows its height: keep the offset inside it before building
    // the spacers that make it, which layout would otherwise clamp too late.
    const content_h = pitch * @as(f32, @floatFromInt(opts.count)) - opts.gap + opts.padding.vertical();
    const max_scroll = @max(0, content_h - view_h);
    if (c.scroll.getPtr(id)) |sc| sc.* = std.math.clamp(sc.*, 0, max_scroll);
    const offset = @max(0, (c.scroll.get(id) orelse 0) - opts.padding.top);
    const first_visible: usize = @intFromFloat(@floor(offset / pitch));
    const visible: usize = @intFromFloat(@ceil(view_h / pitch) + 1);
    const first = first_visible -| opts.overscan;
    const last = @min(opts.count, first_visible + visible + opts.overscan);
    if (first > 0) _ = c.leaf(.{ .height = .{ .px = pitch * @as(f32, @floatFromInt(first)) - opts.gap } }, .none, "list-before");
    // The spacers stand for rows and their gaps: the gap between them and
    // the first row built is the column's own.
    c.node(i).style.gap = opts.gap;
    return .{ .c = c, .opts = opts, .next_index = @min(first, last), .last = last };
}
