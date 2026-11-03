//! Icons where there are no SF Symbols (Linux, Windows, Android): the symbols
//! nanoui's widgets and apps name, drawn as line icons on a 24-unit grid
//! in the manner of Lucide — strokes with round ends, a few filled shapes,
//! and cut-outs for the filled ones — by the TrueType rasterizer.
const std = @import("std");
const Raster = @import("tt/raster.zig").Raster;

pub const Op = union(enum) {
    /// A stroked open polyline.
    line: []const [2]f32,
    /// A stroked closed polygon.
    loop: []const [2]f32,
    /// A filled polygon.
    fill: []const [2]f32,
    /// A stroked polyline cut out of what is drawn before it.
    cut: []const [2]f32,
    circle: [3]f32,
    disc: [3]f32,
    /// x, y, w, h, corner radius: stroked, or filled.
    box: [5]f32,
    solid: [5]f32,
    /// A stroked arc: cx, cy, r, from and to (degrees, clockwise from +x).
    arc: [5]f32,
};

pub const Icon = struct { name: []const u8, ops: []const Op };

fn star(comptime cx: f32, comptime cy: f32, comptime outer: f32, comptime inner: f32, comptime n: usize) [2 * n][2]f32 {
    var pts: [2 * n][2]f32 = undefined;
    for (0..2 * n) |i| {
        const a = -std.math.pi / 2.0 + std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        const r = if (i % 2 == 0) outer else inner;
        pts[i] = .{ cx + r * @cos(a), cy + r * @sin(a) };
    }
    return pts;
}

const sq = [5]f32{ 3, 3, 18, 18, 3.5 };
const win = [5]f32{ 3, 4, 18, 16, 2.5 };

pub const all = [_]Icon{
    .{ .name = "checkmark", .ops = &.{.{ .line = &.{ .{ 5, 12.5 }, .{ 10, 17.5 }, .{ 19, 7 } } }} },
    .{ .name = "xmark", .ops = &.{ .{ .line = &.{ .{ 6, 6 }, .{ 18, 18 } } }, .{ .line = &.{ .{ 18, 6 }, .{ 6, 18 } } } } },
    .{ .name = "sidebar.left", .ops = &.{ .{ .loop = &.{ .{ 3, 5 }, .{ 21, 5 }, .{ 21, 19 }, .{ 3, 19 } } }, .{ .line = &.{ .{ 9.5, 5 }, .{ 9.5, 19 } } } } },
    .{ .name = "plus", .ops = &.{ .{ .line = &.{ .{ 12, 5 }, .{ 12, 19 } } }, .{ .line = &.{ .{ 5, 12 }, .{ 19, 12 } } } } },
    .{ .name = "minus", .ops = &.{.{ .line = &.{ .{ 5, 12 }, .{ 19, 12 } } }} },
    .{ .name = "chevron.down", .ops = &.{.{ .line = &.{ .{ 6, 9 }, .{ 12, 15 }, .{ 18, 9 } } }} },
    .{ .name = "chevron.up", .ops = &.{.{ .line = &.{ .{ 6, 15 }, .{ 12, 9 }, .{ 18, 15 } } }} },
    .{ .name = "chevron.right", .ops = &.{.{ .line = &.{ .{ 9, 6 }, .{ 15, 12 }, .{ 9, 18 } } }} },
    .{ .name = "chevron.up.chevron.down", .ops = &.{ .{ .line = &.{ .{ 8, 9 }, .{ 12, 5 }, .{ 16, 9 } } }, .{ .line = &.{ .{ 8, 15 }, .{ 12, 19 }, .{ 16, 15 } } } } },
    .{ .name = "arrow.right", .ops = &.{ .{ .line = &.{ .{ 5, 12 }, .{ 19, 12 } } }, .{ .line = &.{ .{ 13, 6 }, .{ 19, 12 }, .{ 13, 18 } } } } },
    .{ .name = "arrow.clockwise", .ops = &.{ .{ .arc = .{ 12, 12, 7.5, -60, 230 } }, .{ .line = &.{ .{ 16, 3.5 }, .{ 16.2, 6.5 }, .{ 19.2, 6.7 } } } } },
    .{ .name = "magnifyingglass", .ops = &.{ .{ .circle = .{ 10.5, 10.5, 6.5 } }, .{ .line = &.{ .{ 15.5, 15.5 }, .{ 20, 20 } } } } },
    .{ .name = "circle", .ops = &.{.{ .circle = .{ 12, 12, 9 } }} },
    .{ .name = "circle.dotted", .ops = &.{ .{ .disc = .{ 12, 3, 1.3 } }, .{ .disc = .{ 18.4, 5.6, 1.3 } }, .{ .disc = .{ 21, 12, 1.3 } }, .{ .disc = .{ 18.4, 18.4, 1.3 } }, .{ .disc = .{ 12, 21, 1.3 } }, .{ .disc = .{ 5.6, 18.4, 1.3 } }, .{ .disc = .{ 3, 12, 1.3 } }, .{ .disc = .{ 5.6, 5.6, 1.3 } } } },
    .{ .name = "checkmark.circle.fill", .ops = &.{ .{ .disc = .{ 12, 12, 10 } }, .{ .cut = &.{ .{ 7.5, 12.5 }, .{ 10.5, 15.5 }, .{ 16.5, 9 } } } } },
    .{ .name = "stop.circle", .ops = &.{ .{ .circle = .{ 12, 12, 9 } }, .{ .solid = .{ 9, 9, 6, 6, 1 } } } },
    .{ .name = "play.fill", .ops = &.{.{ .fill = &.{ .{ 7, 4.5 }, .{ 19.5, 12 }, .{ 7, 19.5 } } }} },
    .{ .name = "star.fill", .ops = &.{.{ .fill = &star(12, 12.8, 10.5, 4.4, 5) }} },
    .{ .name = "sparkles", .ops = &.{ .{ .fill = &star(10, 13.5, 8, 2, 4) }, .{ .fill = &star(18.5, 5.5, 3.8, 1, 4) } } },
    .{ .name = "wand.and.stars", .ops = &.{ .{ .line = &.{ .{ 4, 20 }, .{ 15, 9 } } }, .{ .fill = &star(18, 5, 3.5, 1, 4) }, .{ .fill = &star(20, 12, 2.5, 0.8, 4) }, .{ .fill = &star(11.5, 3.5, 2.5, 0.8, 4) } } },
    .{ .name = "person.fill", .ops = &.{ .{ .disc = .{ 12, 7.5, 4.2 } }, .{ .fill = &.{ .{ 4, 21 }, .{ 4.6, 17.6 }, .{ 6.4, 15.2 }, .{ 9, 13.8 }, .{ 12, 13.4 }, .{ 15, 13.8 }, .{ 17.6, 15.2 }, .{ 19.4, 17.6 }, .{ 20, 21 } } } } },
    .{ .name = "photo", .ops = &.{ .{ .box = .{ 3, 4, 18, 16, 2.5 } }, .{ .circle = .{ 8.5, 9.5, 1.8 } }, .{ .line = &.{ .{ 3.5, 17 }, .{ 9, 12.5 }, .{ 13, 16 }, .{ 16, 13.5 }, .{ 20.5, 17.5 } } } } },
    .{ .name = "doc.richtext", .ops = &.{ .{ .loop = &.{ .{ 6, 3 }, .{ 14, 3 }, .{ 19, 8 }, .{ 19, 21 }, .{ 6, 21 } } }, .{ .line = &.{ .{ 9, 10 }, .{ 13, 10 } } }, .{ .line = &.{ .{ 9, 14 }, .{ 16, 14 } } }, .{ .line = &.{ .{ 9, 17.5 }, .{ 16, 17.5 } } } } },
    .{ .name = "chevron.left.forwardslash.chevron.right", .ops = &.{ .{ .line = &.{ .{ 7, 7 }, .{ 2.5, 12 }, .{ 7, 17 } } }, .{ .line = &.{ .{ 17, 7 }, .{ 21.5, 12 }, .{ 17, 17 } } }, .{ .line = &.{ .{ 14, 5 }, .{ 10, 19 } } } } },
    .{ .name = "doc", .ops = &.{.{ .loop = &.{ .{ 6, 3 }, .{ 14, 3 }, .{ 19, 8 }, .{ 19, 21 }, .{ 6, 21 } } }} },
    .{ .name = "doc.text", .ops = &.{ .{ .loop = &.{ .{ 6, 3 }, .{ 14, 3 }, .{ 19, 8 }, .{ 19, 21 }, .{ 6, 21 } } }, .{ .line = &.{ .{ 9.5, 12 }, .{ 15.5, 12 } } }, .{ .line = &.{ .{ 9.5, 16 }, .{ 15.5, 16 } } } } },
    .{ .name = "doc.on.doc", .ops = &.{ .{ .box = .{ 8.5, 8.5, 12, 12.5, 2 } }, .{ .line = &.{ .{ 4.5, 16 }, .{ 4.5, 5.5 }, .{ 5.5, 4.5 }, .{ 15.5, 4.5 } } } } },
    .{ .name = "folder", .ops = &.{.{ .loop = &.{ .{ 3, 5.5 }, .{ 9, 5.5 }, .{ 11, 8 }, .{ 21, 8 }, .{ 21, 19 }, .{ 3, 19 } } }} },
    .{ .name = "trash", .ops = &.{ .{ .line = &.{ .{ 4, 7 }, .{ 20, 7 } } }, .{ .line = &.{ .{ 9, 7 }, .{ 9, 4 }, .{ 15, 4 }, .{ 15, 7 } } }, .{ .line = &.{ .{ 6, 7 }, .{ 7, 20 }, .{ 17, 20 }, .{ 18, 7 } } } } },
    .{ .name = "pencil", .ops = &.{.{ .loop = &.{ .{ 4, 20 }, .{ 5, 15.5 }, .{ 16, 4.5 }, .{ 19.5, 8 }, .{ 8.5, 19 } } }} },
    .{ .name = "paperclip", .ops = &.{ .{ .line = &.{ .{ 15.5, 7 }, .{ 15.5, 16 } } }, .{ .arc = .{ 12, 16, 3.5, 0, 180 } }, .{ .line = &.{ .{ 8.5, 16 }, .{ 8.5, 6 } } }, .{ .arc = .{ 10.75, 6, 2.25, 180, 360 } }, .{ .line = &.{ .{ 13, 6 }, .{ 13, 15.5 } } } } },
    .{ .name = "globe", .ops = &.{ .{ .circle = .{ 12, 12, 9 } }, .{ .line = &.{ .{ 3, 12 }, .{ 21, 12 } } }, .{ .line = &.{ .{ 12, 3 }, .{ 15, 7 }, .{ 16, 12 }, .{ 15, 17 }, .{ 12, 21 } } }, .{ .line = &.{ .{ 12, 3 }, .{ 9, 7 }, .{ 8, 12 }, .{ 9, 17 }, .{ 12, 21 } } } } },
    .{ .name = "terminal", .ops = &.{ .{ .box = win }, .{ .line = &.{ .{ 7, 9 }, .{ 10, 12 }, .{ 7, 15 } } }, .{ .line = &.{ .{ 12.5, 15 }, .{ 16.5, 15 } } } } },
    .{ .name = "terminal.fill", .ops = &.{ .{ .solid = win }, .{ .cut = &.{ .{ 7, 9 }, .{ 10, 12 }, .{ 7, 15 } } }, .{ .cut = &.{ .{ 12.5, 15 }, .{ 16.5, 15 } } } } },
    .{ .name = "command", .ops = &.{ .{ .circle = .{ 7, 7, 2.5 } }, .{ .circle = .{ 17, 7, 2.5 } }, .{ .circle = .{ 7, 17, 2.5 } }, .{ .circle = .{ 17, 17, 2.5 } }, .{ .box = .{ 9.5, 9.5, 5, 5, 0 } } } },
    .{ .name = "cpu", .ops = &.{ .{ .box = .{ 6, 6, 12, 12, 2 } }, .{ .solid = .{ 9.5, 9.5, 5, 5, 1 } }, .{ .line = &.{ .{ 9.5, 3 }, .{ 9.5, 6 } } }, .{ .line = &.{ .{ 14.5, 3 }, .{ 14.5, 6 } } }, .{ .line = &.{ .{ 9.5, 18 }, .{ 9.5, 21 } } }, .{ .line = &.{ .{ 14.5, 18 }, .{ 14.5, 21 } } }, .{ .line = &.{ .{ 3, 9.5 }, .{ 6, 9.5 } } }, .{ .line = &.{ .{ 3, 14.5 }, .{ 6, 14.5 } } }, .{ .line = &.{ .{ 18, 9.5 }, .{ 21, 9.5 } } }, .{ .line = &.{ .{ 18, 14.5 }, .{ 21, 14.5 } } } } },
    .{ .name = "brain", .ops = &.{ .{ .circle = .{ 8.5, 9, 4 } }, .{ .circle = .{ 15.5, 9, 4 } }, .{ .circle = .{ 8.5, 15, 4 } }, .{ .circle = .{ 15.5, 15, 4 } } } },
    .{ .name = "wrench.and.screwdriver", .ops = &.{ .{ .line = &.{ .{ 4.5, 19.5 }, .{ 12.5, 11.5 } } }, .{ .arc = .{ 15.5, 8.5, 4, 120, 400 } }, .{ .line = &.{ .{ 19.5, 19.5 }, .{ 13, 13 } } }, .{ .line = &.{ .{ 4, 4 }, .{ 9, 9 } } } } },
    .{ .name = "exclamationmark.triangle", .ops = &.{ .{ .loop = &.{ .{ 12, 3.5 }, .{ 21, 19.5 }, .{ 3, 19.5 } } }, .{ .line = &.{ .{ 12, 9.5 }, .{ 12, 13.5 } } }, .{ .disc = .{ 12, 16.6, 1.15 } } } },
    .{ .name = "questionmark.circle", .ops = &.{ .{ .circle = .{ 12, 12, 9 } }, .{ .line = &.{ .{ 9.3, 9.6 }, .{ 9.9, 8 }, .{ 12, 7.2 }, .{ 14.1, 8 }, .{ 14.6, 9.8 }, .{ 12.9, 11.4 }, .{ 12, 12.6 }, .{ 12, 13.4 } } }, .{ .disc = .{ 12, 16.6, 1.15 } } } },
    .{ .name = "network", .ops = &.{ .{ .circle = .{ 12, 12, 9 } }, .{ .line = &.{ .{ 3, 12 }, .{ 21, 12 } } }, .{ .line = &.{ .{ 12, 3 }, .{ 15, 7 }, .{ 16, 12 }, .{ 15, 17 }, .{ 12, 21 } } }, .{ .line = &.{ .{ 12, 3 }, .{ 9, 7 }, .{ 8, 12 }, .{ 9, 17 }, .{ 12, 21 } } } } },
    .{ .name = "square.grid.2x2", .ops = &.{ .{ .box = .{ 3.5, 3.5, 7, 7, 1.5 } }, .{ .box = .{ 13.5, 3.5, 7, 7, 1.5 } }, .{ .box = .{ 3.5, 13.5, 7, 7, 1.5 } }, .{ .box = .{ 13.5, 13.5, 7, 7, 1.5 } } } },
    .{ .name = "square.grid.3x3", .ops = &.{ .{ .solid = .{ 3.5, 3.5, 4.5, 4.5, 1 } }, .{ .solid = .{ 9.75, 3.5, 4.5, 4.5, 1 } }, .{ .solid = .{ 16, 3.5, 4.5, 4.5, 1 } }, .{ .solid = .{ 3.5, 9.75, 4.5, 4.5, 1 } }, .{ .solid = .{ 9.75, 9.75, 4.5, 4.5, 1 } }, .{ .solid = .{ 16, 9.75, 4.5, 4.5, 1 } }, .{ .solid = .{ 3.5, 16, 4.5, 4.5, 1 } }, .{ .solid = .{ 9.75, 16, 4.5, 4.5, 1 } }, .{ .solid = .{ 16, 16, 4.5, 4.5, 1 } } } },
    .{ .name = "memorychip", .ops = &.{ .{ .box = .{ 3, 6.5, 18, 11, 2 } }, .{ .line = &.{ .{ 7, 3 }, .{ 7, 6.5 } } }, .{ .line = &.{ .{ 12, 3 }, .{ 12, 6.5 } } }, .{ .line = &.{ .{ 17, 3 }, .{ 17, 6.5 } } }, .{ .line = &.{ .{ 7, 17.5 }, .{ 7, 21 } } }, .{ .line = &.{ .{ 12, 17.5 }, .{ 12, 21 } } }, .{ .line = &.{ .{ 17, 17.5 }, .{ 17, 21 } } } } },
    .{ .name = "cube", .ops = &.{ .{ .loop = &.{ .{ 12, 2.5 }, .{ 20.5, 7 }, .{ 20.5, 17 }, .{ 12, 21.5 }, .{ 3.5, 17 }, .{ 3.5, 7 } } }, .{ .line = &.{ .{ 3.5, 7 }, .{ 12, 11.5 }, .{ 20.5, 7 } } }, .{ .line = &.{ .{ 12, 11.5 }, .{ 12, 21.5 } } } } },
    .{ .name = "internaldrive", .ops = &.{ .{ .box = .{ 2.5, 7, 19, 10, 2.5 } }, .{ .disc = .{ 17, 12, 1.2 } }, .{ .line = &.{ .{ 6, 12 }, .{ 11, 12 } } } } },
    .{ .name = "desktopcomputer", .ops = &.{ .{ .box = .{ 2.5, 3.5, 19, 13, 2 } }, .{ .line = &.{ .{ 12, 16.5 }, .{ 12, 20.5 } } }, .{ .line = &.{ .{ 8.5, 20.5 }, .{ 15.5, 20.5 } } } } },
    .{ .name = "waveform.path.ecg", .ops = &.{.{ .line = &.{ .{ 2, 12 }, .{ 7, 12 }, .{ 9, 6 }, .{ 12, 18 }, .{ 14.5, 9 }, .{ 16, 12 }, .{ 22, 12 } } }} },
    .{ .name = "pause.fill", .ops = &.{ .{ .solid = .{ 6, 4.5, 4, 15, 1 } }, .{ .solid = .{ 14, 4.5, 4, 15, 1 } } } },
    .{ .name = "gauge.with.dots.needle.33percent", .ops = &.{ .{ .arc = .{ 12, 15, 8.5, 180, 360 } }, .{ .line = &.{ .{ 12, 15 }, .{ 8, 10 } } }, .{ .disc = .{ 12, 15, 1.4 } } } },
    .{ .name = "flame", .ops = &.{.{ .loop = &.{ .{ 12, 2.5 }, .{ 16.5, 8 }, .{ 18, 13 }, .{ 16.5, 18.5 }, .{ 12, 21.5 }, .{ 7.5, 18.5 }, .{ 6, 13 }, .{ 8, 9 }, .{ 10, 11 } } }} },
    .{ .name = "square.and.pencil", .ops = &.{ .{ .line = &.{ .{ 11, 5 }, .{ 5.5, 5 }, .{ 3.5, 7 }, .{ 3.5, 18.5 }, .{ 5.5, 20.5 }, .{ 17, 20.5 }, .{ 19, 18.5 }, .{ 19, 13 } } }, .{ .line = &.{ .{ 10, 14 }, .{ 20, 4 } } } } },
    .{ .name = "xmark.octagon", .ops = &.{ .{ .loop = &.{ .{ 8.3, 3 }, .{ 15.7, 3 }, .{ 21, 8.3 }, .{ 21, 15.7 }, .{ 15.7, 21 }, .{ 8.3, 21 }, .{ 3, 15.7 }, .{ 3, 8.3 } } }, .{ .line = &.{ .{ 9, 9 }, .{ 15, 15 } } }, .{ .line = &.{ .{ 15, 9 }, .{ 9, 15 } } } } },
    .{ .name = "info.circle", .ops = &.{ .{ .circle = .{ 12, 12, 9 } }, .{ .line = &.{ .{ 12, 11 }, .{ 12, 16.5 } } }, .{ .disc = .{ 12, 7.8, 1.15 } } } },
    .{ .name = "ellipsis.circle", .ops = &.{ .{ .circle = .{ 12, 12, 9 } }, .{ .disc = .{ 8, 12, 1.2 } }, .{ .disc = .{ 12, 12, 1.2 } }, .{ .disc = .{ 16, 12, 1.2 } } } },
    .{ .name = "hand.raised", .ops = &.{ .{ .line = &.{ .{ 8, 13 }, .{ 8, 6 } } }, .{ .line = &.{ .{ 11, 12 }, .{ 11, 4 } } }, .{ .line = &.{ .{ 14, 12 }, .{ 14, 4.5 } } }, .{ .line = &.{ .{ 17, 13 }, .{ 17, 7.5 } } }, .{ .loop = &.{ .{ 7, 12 }, .{ 18, 12 }, .{ 18, 16 }, .{ 15, 20.5 }, .{ 9.5, 20.5 }, .{ 5, 15 } } } } },
    .{ .name = "list.bullet", .ops = &.{ .{ .disc = .{ 5, 7, 1.4 } }, .{ .disc = .{ 5, 12, 1.4 } }, .{ .disc = .{ 5, 17, 1.4 } }, .{ .line = &.{ .{ 9.5, 7 }, .{ 20, 7 } } }, .{ .line = &.{ .{ 9.5, 12 }, .{ 20, 12 } } }, .{ .line = &.{ .{ 9.5, 17 }, .{ 20, 17 } } } } },
    .{ .name = "sun.max", .ops = &.{ .{ .circle = .{ 12, 12, 4 } }, .{ .line = &.{ .{ 12, 2.5 }, .{ 12, 4.5 } } }, .{ .line = &.{ .{ 12, 19.5 }, .{ 12, 21.5 } } }, .{ .line = &.{ .{ 2.5, 12 }, .{ 4.5, 12 } } }, .{ .line = &.{ .{ 19.5, 12 }, .{ 21.5, 12 } } }, .{ .line = &.{ .{ 5.3, 5.3 }, .{ 6.7, 6.7 } } }, .{ .line = &.{ .{ 17.3, 17.3 }, .{ 18.7, 18.7 } } }, .{ .line = &.{ .{ 5.3, 18.7 }, .{ 6.7, 17.3 } } }, .{ .line = &.{ .{ 17.3, 6.7 }, .{ 18.7, 5.3 } } } } },
    .{ .name = "moon", .ops = &.{ .{ .arc = .{ 12, 12, 8, 300, 240 } }, .{ .arc = .{ 16.5, 7.5, 6.5, 125, 205 } } } },
    .{ .name = "circle.lefthalf.filled", .ops = &.{ .{ .circle = .{ 12, 12, 8 } }, .{ .disc = .{ 12, 12, 8 } }, .{ .cut = &.{ .{ 12, 2 }, .{ 12, 22 } } } } },
    .{ .name = "arrow.up", .ops = &.{ .{ .line = &.{ .{ 12, 19 }, .{ 12, 5 } } }, .{ .line = &.{ .{ 6, 11 }, .{ 12, 5 }, .{ 18, 11 } } } } },
    .{ .name = "chart.bar.xaxis", .ops = &.{ .{ .line = &.{ .{ 3, 20 }, .{ 21, 20 } } }, .{ .line = &.{ .{ 6.5, 16.5 }, .{ 6.5, 12 } } }, .{ .line = &.{ .{ 12, 16.5 }, .{ 12, 5 } } }, .{ .line = &.{ .{ 17.5, 16.5 }, .{ 17.5, 9 } } } } },
    .{ .name = "checklist", .ops = &.{ .{ .line = &.{ .{ 3.5, 7 }, .{ 5.5, 9 }, .{ 9, 5 } } }, .{ .line = &.{ .{ 3.5, 15 }, .{ 5.5, 17 }, .{ 9, 13 } } }, .{ .line = &.{ .{ 12.5, 7.5 }, .{ 20.5, 7.5 } } }, .{ .line = &.{ .{ 12.5, 15.5 }, .{ 20.5, 15.5 } } } } },
    .{ .name = "equal.square", .ops = &.{ .{ .box = sq }, .{ .line = &.{ .{ 8, 10 }, .{ 16, 10 } } }, .{ .line = &.{ .{ 8, 14 }, .{ 16, 14 } } } } },
    .{ .name = "plus.square", .ops = &.{ .{ .box = sq }, .{ .line = &.{ .{ 12, 8 }, .{ 12, 16 } } }, .{ .line = &.{ .{ 8, 12 }, .{ 16, 12 } } } } },
    .{ .name = "xmark.square", .ops = &.{ .{ .box = sq }, .{ .line = &.{ .{ 9, 9 }, .{ 15, 15 } } }, .{ .line = &.{ .{ 15, 9 }, .{ 9, 15 } } } } },
    .{ .name = "arrow.right.square", .ops = &.{ .{ .box = sq }, .{ .line = &.{ .{ 7.5, 12 }, .{ 16, 12 } } }, .{ .line = &.{ .{ 12.5, 8.5 }, .{ 16, 12 }, .{ 12.5, 15.5 } } } } },
    .{ .name = "rectangle.split.2x1", .ops = &.{ .{ .box = win }, .{ .line = &.{ .{ 12, 4 }, .{ 12, 20 } } } } },
    .{ .name = "rectangle.split.1x2", .ops = &.{ .{ .box = win }, .{ .line = &.{ .{ 3, 12 }, .{ 21, 12 } } } } },
    .{ .name = "rectangle.on.rectangle", .ops = &.{ .{ .box = .{ 7.5, 7.5, 13.5, 11, 2 } }, .{ .line = &.{ .{ 3.5, 14 }, .{ 3.5, 5 }, .{ 4.5, 4 }, .{ 16.5, 4 } } } } },
    .{ .name = "arrow.up.left.and.arrow.down.right", .ops = &.{ .{ .line = &.{ .{ 5, 5 }, .{ 10.5, 10.5 } } }, .{ .line = &.{ .{ 5, 10 }, .{ 5, 5 }, .{ 10, 5 } } }, .{ .line = &.{ .{ 19, 19 }, .{ 13.5, 13.5 } } }, .{ .line = &.{ .{ 19, 14 }, .{ 19, 19 }, .{ 14, 19 } } } } },
    .{ .name = "arrow.triangle.branch", .ops = &.{ .{ .circle = .{ 6.5, 5.5, 2.2 } }, .{ .circle = .{ 6.5, 18.5, 2.2 } }, .{ .circle = .{ 17.5, 7.5, 2.2 } }, .{ .line = &.{ .{ 6.5, 7.7 }, .{ 6.5, 16.3 } } }, .{ .line = &.{ .{ 17.5, 9.7 }, .{ 17.5, 11 }, .{ 15.5, 13 }, .{ 8.5, 15 } } } } },
    .{ .name = "slider.horizontal.3", .ops = &.{ .{ .line = &.{ .{ 3, 6 }, .{ 21, 6 } } }, .{ .line = &.{ .{ 3, 12 }, .{ 21, 12 } } }, .{ .line = &.{ .{ 3, 18 }, .{ 21, 18 } } }, .{ .disc = .{ 8, 6, 2.4 } }, .{ .disc = .{ 15, 12, 2.4 } }, .{ .disc = .{ 10, 18, 2.4 } } } },
    .{ .name = "text.cursor", .ops = &.{ .{ .line = &.{ .{ 12, 4.5 }, .{ 12, 19.5 } } }, .{ .line = &.{ .{ 9, 4 }, .{ 15, 4 } } }, .{ .line = &.{ .{ 9, 20 }, .{ 15, 20 } } } } },
    .{ .name = "textformat", .ops = &.{ .{ .line = &.{ .{ 3, 19 }, .{ 8.5, 5 }, .{ 14, 19 } } }, .{ .line = &.{ .{ 5, 14 }, .{ 12, 14 } } }, .{ .circle = .{ 18, 15.5, 3 } }, .{ .line = &.{ .{ 21, 12 }, .{ 21, 19 } } } } },
    .{ .name = "code", .ops = &.{ .{ .line = &.{ .{ 8, 7 }, .{ 3, 12 }, .{ 8, 17 } } }, .{ .line = &.{ .{ 16, 7 }, .{ 21, 12 }, .{ 16, 17 } } } } },
    .{ .name = "clear", .ops = &.{ .{ .loop = &.{ .{ 21, 5 }, .{ 9, 5 }, .{ 3, 12 }, .{ 9, 19 }, .{ 21, 19 } } }, .{ .line = &.{ .{ 12, 9 }, .{ 17, 15 } } }, .{ .line = &.{ .{ 17, 9 }, .{ 12, 15 } } } } },
};

pub fn find(name: []const u8) ?*const Icon {
    for (&all) |*i| if (std.mem.eql(u8, i.name, name)) return i;
    return null;
}

/// Draws `icon` into `r`: grid units × `k` pixels, offset by `off`, its
/// strokes `sw` units wide.
pub fn draw(icon: *const Icon, r: *Raster, k: f32, off: f32, sw: f32) void {
    const p: Pen = .{ .r = r, .k = k, .off = off, .half = sw / 2 };
    for (icon.ops) |op| switch (op) {
        .line => |pts| p.stroke(pts, false, 1),
        .cut => |pts| p.stroke(pts, false, -1),
        .loop => |pts| p.stroke(pts, true, 1),
        .fill => |pts| p.poly(pts, 1),
        .circle => |c| {
            p.ellipse(c[0], c[1], c[2] + p.half, 1);
            if (c[2] - p.half > 0) p.ellipse(c[0], c[1], c[2] - p.half, -1);
        },
        .disc => |c| p.ellipse(c[0], c[1], c[2], 1),
        .box => |b| {
            p.roundRect(b[0] - p.half, b[1] - p.half, b[2] + 2 * p.half, b[3] + 2 * p.half, b[4] + p.half, 1);
            p.roundRect(b[0] + p.half, b[1] + p.half, b[2] - 2 * p.half, b[3] - 2 * p.half, @max(0, b[4] - p.half), -1);
        },
        .solid => |b| p.roundRect(b[0], b[1], b[2], b[3], b[4], 1),
        .arc => |a| {
            if (a[3] == a[4]) continue;
            var pts: [33][2]f32 = undefined;
            for (&pts, 0..) |*pt, i| {
                const t = (a[3] + (a[4] - a[3]) * @as(f32, @floatFromInt(i)) / 32) * std.math.pi / 180;
                pt.* = .{ a[0] + a[2] * @cos(t), a[1] + a[2] * @sin(t) };
            }
            p.stroke(&pts, false, 1);
        },
    };
}

const Pen = struct {
    r: *Raster,
    k: f32,
    off: f32,
    half: f32,

    /// A filled polygon, wound positive (adds ink) or negative (cuts).
    fn poly(p: Pen, pts: []const [2]f32, sign: f32) void {
        if (pts.len < 3) return;
        var area: f32 = 0;
        for (pts, 0..) |a, i| {
            const b = pts[(i + 1) % pts.len];
            area += a[0] * b[1] - b[0] * a[1];
        }
        const forward = (area > 0) == (sign > 0);
        const n = pts.len;
        for (0..n) |i| {
            const pt = pts[if (forward) i else n - 1 - i];
            const x = p.off + pt[0] * p.k;
            const y = p.off + pt[1] * p.k;
            if (i == 0) p.r.moveTo(x, y) else p.r.lineToPoint(x, y);
        }
        p.r.closePath();
    }

    fn ellipse(p: Pen, cx: f32, cy: f32, rad: f32, sign: f32) void {
        var pts: [40][2]f32 = undefined;
        for (&pts, 0..) |*pt, i| {
            const t = std.math.tau * @as(f32, @floatFromInt(i)) / 40;
            pt.* = .{ cx + rad * @cos(t), cy + rad * @sin(t) };
        }
        p.poly(&pts, sign);
    }

    fn roundRect(p: Pen, x: f32, y: f32, w: f32, h: f32, rad_in: f32, sign: f32) void {
        if (w <= 0 or h <= 0) return;
        const rad = @min(rad_in, @min(w, h) / 2);
        var pts: [36][2]f32 = undefined;
        const corners = [4][3]f32{ .{ x + w - rad, y + rad, -90 }, .{ x + w - rad, y + h - rad, 0 }, .{ x + rad, y + h - rad, 90 }, .{ x + rad, y + rad, 180 } };
        for (corners, 0..) |c, ci| for (0..9) |j| {
            const t = (c[2] + 90 * @as(f32, @floatFromInt(j)) / 8) * std.math.pi / 180;
            pts[ci * 9 + j] = .{ c[0] + rad * @cos(t), c[1] + rad * @sin(t) };
        };
        p.poly(&pts, sign);
    }

    /// A polyline stroked as one polygon (mitered joins, so its parts do
    /// not overlap), with round ends.
    fn stroke(p: Pen, pts: []const [2]f32, closed: bool, sign: f32) void {
        if (pts.len < 2) return;
        if (closed) {
            // A closed outline: the outer and inner offsets, as a ring.
            var outer: [64][2]f32 = undefined;
            var inner: [64][2]f32 = undefined;
            const n = @min(pts.len, 64);
            for (0..n) |i| {
                const m = miter(pts[(i + n - 1) % n], pts[i], pts[(i + 1) % n], p.half);
                outer[i] = .{ pts[i][0] + m[0], pts[i][1] + m[1] };
                inner[i] = .{ pts[i][0] - m[0], pts[i][1] - m[1] };
            }
            p.poly(outer[0..n], sign);
            p.poly(inner[0..n], -sign);
            return;
        }
        var ring: [130][2]f32 = undefined;
        const n = @min(pts.len, 64);
        for (0..n) |i| {
            const prev = if (i == 0) extend(pts[1], pts[0]) else pts[i - 1];
            const next = if (i == n - 1) extend(pts[n - 2], pts[n - 1]) else pts[i + 1];
            const m = miter(prev, pts[i], next, p.half);
            ring[i] = .{ pts[i][0] + m[0], pts[i][1] + m[1] };
            ring[2 * n - 1 - i] = .{ pts[i][0] - m[0], pts[i][1] - m[1] };
        }
        p.poly(ring[0 .. 2 * n], sign);
        if (sign > 0) {
            p.ellipse(pts[0][0], pts[0][1], p.half, 1);
            p.ellipse(pts[n - 1][0], pts[n - 1][1], p.half, 1);
        }
    }
};

/// The point past `b` continuing from `a`.
fn extend(a: [2]f32, b: [2]f32) [2]f32 {
    return .{ 2 * b[0] - a[0], 2 * b[1] - a[1] };
}

/// The offset from `b` to one side of a stroke `half` wide through a, b, c.
fn miter(a: [2]f32, b: [2]f32, c: [2]f32, half: f32) [2]f32 {
    const n1 = normal(a, b);
    const n2 = normal(b, c);
    var mx = n1[0] + n2[0];
    var my = n1[1] + n2[1];
    const len = @sqrt(mx * mx + my * my);
    if (len < 1e-3) return .{ n1[0] * half, n1[1] * half };
    mx /= len;
    my /= len;
    // Sharp corners would spike: the miter is limited to twice the width.
    const cos_half = @max(0.5, mx * n1[0] + my * n1[1]);
    return .{ mx * half / cos_half, my * half / cos_half };
}

fn normal(a: [2]f32, b: [2]f32) [2]f32 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len = @max(1e-6, @sqrt(dx * dx + dy * dy));
    return .{ -dy / len, dx / len };
}

test "every icon draws ink" {
    const gpa = std.testing.allocator;
    for (&all) |*icon| {
        var r = try Raster.init(gpa, 26, 26);
        defer r.deinit(gpa);
        draw(icon, &r, 1, 1, 2);
        var px: [26 * 26]u8 = undefined;
        r.coverage(&px);
        var ink: usize = 0;
        for (px) |v| ink += @intFromBool(v > 100);
        if (ink < 12) {
            std.log.err("icon {s} drew {d} pixels", .{ icon.name, ink });
            return error.TestUnexpectedResult;
        }
    }
}
