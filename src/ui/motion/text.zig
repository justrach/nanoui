//! Staggered, animated text: a string split into letters or words, each
//! entering from `enter` after the last, as Motion's and gpui-motion's
//! text units do. No allocations beyond the frame arena (keys, slices).
const std = @import("std");
const Context = @import("../context.zig").Context;
const types = @import("../types.zig");
const motion = @import("motion.zig");
const widgets = @import("../widgets.zig");
const utf8 = @import("../utf8.zig");
const div_mod = @import("../div.zig");

pub const Unit = enum { whole, words, letters };

pub const Options = struct {
    unit: Unit = .letters,
    enter: motion.Target = .{ .y = 10, .opacity = 0 },
    stagger_each: f32 = 0.03,
    transition: motion.Transition = .default,
};

/// Draws `str` as staggered units that enter. Call it where `ui.text` would go.
pub fn text(c: *Context, str: []const u8, style: types.TextStyle, opts: Options) void {
    const row = div_mod.div(c).row().itemsCenter();
    defer row.end();
    var i: usize = 0;
    var n: usize = 0;
    while (i < str.len) : (n += 1) {
        const piece = next(str, i, opts.unit);
        c.next_key = c.print("mt{d}", .{n});
        const f = motion.frame(c, .{
            .initial = opts.enter,
            .delay = motion.stagger(n, opts.stagger_each),
            .transition = opts.transition,
        });
        const cell = div_mod.div(c).motion(f);
        defer cell.end();
        widgets.text(c, piece.slice, style);
        i = piece.end;
    }
}

const Piece = struct { slice: []const u8, end: usize };

fn next(str: []const u8, start: usize, unit: Unit) Piece {
    if (start >= str.len) return .{ .slice = str[start..], .end = str.len };
    return switch (unit) {
        .whole => .{ .slice = str[start..], .end = str.len },
        .letters => blk: {
            const n = utf8.seqLen(str[start]);
            const end = @min(start + n, str.len);
            break :blk .{ .slice = str[start..end], .end = end };
        },
        .words => blk: {
            var i = start;
            while (i < str.len and str[i] != ' ') i += 1;
            while (i < str.len and str[i] == ' ') i += 1;
            if (i == start) i = @min(start + 1, str.len);
            break :blk .{ .slice = str[start..i], .end = i };
        },
    };
}

test "letters and words split a string without leftover bytes" {
    var i: usize = 0;
    var n: usize = 0;
    while (i < "Hi".len) : (n += 1) {
        const p = next("Hi", i, .letters);
        i = p.end;
    }
    try std.testing.expectEqual(@as(usize, 2), n);
    i = 0;
    n = 0;
    const s = "two words";
    while (i < s.len) : (n += 1) {
        const p = next(s, i, .words);
        i = p.end;
    }
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(usize, 3), next("all", 0, .whole).end);
}
