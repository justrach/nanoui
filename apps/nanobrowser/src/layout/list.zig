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
        .decimal_leading_zero => return try std.fmt.allocPrint(a, "{s}{d}.", .{ if (value >= 0 and value < 10) "0" else "", value }),
        .lower_greek => {
            if (value <= 0 or value > 24) return try std.fmt.allocPrint(a, "{d}.", .{value});
            var buf: [4]u8 = undefined;
            const cp: u21 = @intCast(0x3B1 + value - 1 + @as(i64, if (value >= 18) 1 else 0));
            const n = std.unicode.utf8Encode(cp, &buf) catch 0;
            return try std.fmt.allocPrint(a, "{s}.", .{buf[0..n]});
        },
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

/// What `counter()` shows: as a list's, without the period.
pub fn valueText(a: std.mem.Allocator, kind: css.ListStyle, value: i64) Error![]const u8 {
    switch (kind) {
        .none => return "",
        .disc => return "\u{2022}",
        .circle => return "\u{25E6}",
        .square => return "\u{25AA}",
        else => {},
    }
    const t = (try counterText(a, kind, value)) orelse return "";
    return t[0 .. t.len - 1];
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
    const owner = b.style;
    const s = b.lay.marker_style orelse owner;
    const font = box.fontOf(s);
    const m = c.metrics(font);
    const left = ctx.bpLeft(b);
    const half = (c.lineHeight(s) - m.ascent - m.descent) / 2;
    const base = b.lay.first_baseline orelse ctx.bpTop(b) + half + m.ascent;
    const gap: f32 = if (b.lay.marker_no_gap) 0 else gapOf(owner);
    if (b.lay.marker_text.len > 0) {
        const w = c.width(b.lay.marker_text, font);
        const run: box.TextRun = .{
            .text = b.lay.marker_text,
            .x = left - w - gap,
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
        b.marker = .{ .x = left - size - gap, .y = base - m.ascent * 0.5 - size / 2, .w = size, .h = size };
    }
}
