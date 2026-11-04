//! List items: what a counter reads as, and an outside marker's place beside
//! the item's first line.
const std = @import("std");
const box = @import("box.zig");
const css = @import("../css/style.zig");
const ctx = @import("ctx.zig");
const Box = box.Box;
const Ctx = ctx.Ctx;
const Error = ctx.Error;

/// A counter's text with its period, or null for the bullet shapes and `none`.
pub fn counterText(a: std.mem.Allocator, kind: css.ListStyle, value: i64) Error!?[]const u8 {
    switch (kind) {
        .none, .disc, .circle, .square => return null,
        .decimal => return try std.fmt.allocPrint(a, "{d}.", .{value}),
        .lower_alpha, .upper_alpha => {
            if (value <= 0) return try std.fmt.allocPrint(a, "{d}.", .{value});
            return try alpha(a, value, kind == .upper_alpha);
        },
        .lower_roman, .upper_roman => {
            if (value <= 0 or value >= 4000) return try std.fmt.allocPrint(a, "{d}.", .{value});
            return try roman(a, value, kind == .upper_roman);
        },
    }
}

fn alpha(a: std.mem.Allocator, value: i64, upper: bool) Error![]const u8 {
    var buf: [16]u8 = undefined;
    var i: usize = buf.len;
    i -= 1;
    buf[i] = '.';
    var v = value;
    while (v > 0 and i > 0) {
        v -= 1;
        i -= 1;
        buf[i] = @intCast((if (upper) @as(i64, 'A') else @as(i64, 'a')) + @rem(v, 26));
        v = @divTrunc(v, 26);
    }
    return a.dupe(u8, buf[i..]);
}

fn roman(a: std.mem.Allocator, value: i64, upper: bool) Error![]const u8 {
    const table = [_]struct { v: i64, s: []const u8 }{
        .{ .v = 1000, .s = "m" }, .{ .v = 900, .s = "cm" }, .{ .v = 500, .s = "d" }, .{ .v = 400, .s = "cd" },
        .{ .v = 100, .s = "c" },  .{ .v = 90, .s = "xc" },  .{ .v = 50, .s = "l" },  .{ .v = 40, .s = "xl" },
        .{ .v = 10, .s = "x" },   .{ .v = 9, .s = "ix" },   .{ .v = 5, .s = "v" },   .{ .v = 4, .s = "iv" },
        .{ .v = 1, .s = "i" },
    };
    var out: std.ArrayList(u8) = .empty;
    var v = value;
    for (table) |t| while (v >= t.v) : (v -= t.v) try out.appendSlice(a, t.s);
    try out.append(a, '.');
    if (upper) _ = std.ascii.upperString(out.items, out.items);
    return out.items;
}

/// The size of a bullet, and the room between a marker and the content.
pub fn bulletSize(s: *const css.Style) f32 {
    return ctx.clean(s.font_size) * 0.35;
}

fn gapOf(s: *const css.Style) f32 {
    return ctx.clean(s.font_size) * 0.5;
}

/// Places an outside marker. Runs and rects are relative to the item's border box.
pub fn place(c: *Ctx, b: *Box) Error!void {
    const s = b.style;
    const font = box.fontOf(s);
    const m = c.metrics(font);
    const left = ctx.bpLeft(b);
    const half = (c.lineHeight(s) - m.ascent - m.descent) / 2;
    const base = b.lay.first_baseline orelse ctx.bpTop(b) + half + m.ascent;
    if (b.lay.marker_text.len > 0) {
        const w = c.width(b.lay.marker_text, font);
        const run: box.TextRun = .{
            .text = b.lay.marker_text,
            .x = left - w - gapOf(s),
            .baseline = base,
            .w = w,
            .font = font,
            .style = s,
            .line_top = base - m.ascent - half,
            .line_h = c.lineHeight(s),
        };
        const out = try c.arena.alloc(box.TextRun, b.runs.len + 1);
        out[0] = run;
        @memcpy(out[1..], b.runs);
        b.runs = out;
    } else {
        const size = bulletSize(s);
        b.marker = .{ .x = left - size - gapOf(s), .y = base - m.ascent * 0.5 - size / 2, .w = size, .h = size };
    }
}
