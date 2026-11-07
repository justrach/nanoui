//! CSS counters as box generation walks the document: `counter-reset`,
//! `counter-increment` and `counter-set` in tree order, and the text `counter()`
//! and `counters()` come to. A counter lasts as long as the element that made it,
//! its following siblings and what is in them.
const std = @import("std");
const css = @import("../css/style.zig");
const list = @import("list.zig");
const Allocator = std.mem.Allocator;

const Entry = struct { name: []const u8, value: i32, depth: u32 };

pub const Counters = struct {
    entries: std.ArrayList(Entry) = .empty,

    fn innermost(c: *Counters, name: []const u8) ?*Entry {
        var i = c.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, c.entries.items[i].name, name)) return &c.entries.items[i];
        }
        return null;
    }

    /// A new counter at this depth; a sibling's of the same name makes way.
    pub fn reset(c: *Counters, a: Allocator, name: []const u8, value: i32, depth: u32) Allocator.Error!void {
        var i = c.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = &c.entries.items[i];
            if (e.depth < depth) break;
            if (e.depth == depth and std.mem.eql(u8, e.name, name)) {
                e.value = value;
                return;
            }
        }
        try c.entries.append(a, .{ .name = name, .value = value, .depth = depth });
    }

    pub fn increment(c: *Counters, a: Allocator, name: []const u8, by: i32, depth: u32) Allocator.Error!void {
        if (c.innermost(name)) |e| {
            e.value +%= by;
            return;
        }
        try c.entries.append(a, .{ .name = name, .value = by, .depth = depth });
    }

    pub fn set(c: *Counters, a: Allocator, name: []const u8, value: i32, depth: u32) Allocator.Error!void {
        if (c.innermost(name)) |e| {
            e.value = value;
            return;
        }
        try c.entries.append(a, .{ .name = name, .value = value, .depth = depth });
    }

    /// What a style asks of the counters, in the order CSS applies it.
    pub fn apply(c: *Counters, a: Allocator, s: *const css.Style, depth: u32) Allocator.Error!void {
        for (s.counter_reset) |op| try c.reset(a, op.name, op.value, depth);
        for (s.counter_increment) |op| try c.increment(a, op.name, op.value, depth);
        for (s.counter_set) |op| try c.set(a, op.name, op.value, depth);
    }

    /// The element at `depth` is over: what its children made is gone.
    pub fn leave(c: *Counters, depth: u32) void {
        while (c.entries.items.len > 0 and c.entries.items[c.entries.items.len - 1].depth > depth) c.entries.items.len -= 1;
    }

    /// `content`'s text now, with its counters' present values.
    pub fn contentText(c: *Counters, a: Allocator, parts: []const css.ContentPart) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (parts) |p| switch (p) {
            .text => |t| try out.appendSlice(a, t),
            .counter => |k| try c.counterText(a, k, &out),
        };
        return out.items;
    }

    fn counterText(c: *Counters, a: Allocator, k: css.ContentPart.Counter, out: *std.ArrayList(u8)) Allocator.Error!void {
        const sep = k.sep orelse {
            const v: i32 = if (c.innermost(k.name)) |e| e.value else 0;
            return out.appendSlice(a, try list.valueText(a, k.kind, v));
        };
        var any = false;
        for (c.entries.items) |e| if (std.mem.eql(u8, e.name, k.name)) {
            if (any) try out.appendSlice(a, sep);
            try out.appendSlice(a, try list.valueText(a, k.kind, e.value));
            any = true;
        };
        if (!any) try out.appendSlice(a, try list.valueText(a, k.kind, 0));
    }
};
