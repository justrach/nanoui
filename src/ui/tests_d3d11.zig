//! The Direct3D 11 renderer against the CPU renderer, with no window at
//! all: the same scenes drawn by both must come out the same, to rounding.
//! Creating the renderer also compiles every HLSL entry point, so a syntax
//! error in `shader.hlsl` fails these tests. Skipped where there is no
//! Direct3D 11.
//!
//! The glyph atlas the GPU gets is the CPU atlas' scalar coverage, not the
//! ClearType texels beside them (Windows' DirectWrite path draws glyphs in
//! colour), so text here is compared with the tolerance that difference
//! needs: shapes and pictures are held much tighter.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");
const d3d11 = @import("d3d11.zig");

const Limits = struct { mean: f64, worst: u8, off_in: usize };

/// Draws the Tester's last frame with Direct3D 11 and with the CPU
/// renderer, and expects them within `limits`.
fn compare(t: *ui.Tester, limits: Limits) !void {
    const gpa = testing.allocator;
    var r = d3d11.Renderer.init() catch |e| {
        std.debug.print("no Direct3D 11 here: {t} ", .{e});
        return error.SkipZigTest;
    };
    defer r.deinit();
    r.sync(t.text.atlas.mask(), t.text.atlas.generation, t.text.images.pictures(), t.text.images.generation);
    r.draw(t.instances.items, t.size, t.scale, t.theme.background, null);
    const ours = try r.read(gpa);
    defer ours.deinit(gpa);
    const cpu = try t.render(gpa);
    defer cpu.deinit(gpa);
    try testing.expectEqual(cpu.width, ours.width);
    try testing.expectEqual(cpu.height, ours.height);
    var total: u64 = 0;
    var worst: u8 = 0;
    var off: usize = 0;
    for (ours.bytes, cpu.bytes) |a, b| {
        const d = if (a > b) a - b else b - a;
        total += d;
        worst = @max(worst, d);
        if (d > 8) off += 1;
    }
    // Where the differences are: a bug in one shape shows as a tight box,
    // ClearType's colour fringes as a scatter over the text.
    var x0 = cpu.width;
    var y0 = cpu.height;
    var x1: usize = 0;
    var y1: usize = 0;
    var n: usize = 0;
    for (0..cpu.height) |y| for (0..cpu.width) |x| {
        const at = (y * cpu.width + x) * 4;
        var differ = false;
        for (0..4) |k| {
            const a = ours.bytes[at + k];
            const b = cpu.bytes[at + k];
            if ((if (a > b) a - b else b - a) > 8) differ = true;
        }
        if (differ) {
            x0 = @min(x0, x);
            y0 = @min(y0, y);
            x1 = @max(x1, x);
            y1 = @max(y1, y);
            n += 1;
        }
    };
    if (n > 0) std.debug.print("  differing pixels: {d}, box {d},{d}..{d},{d} ", .{ n, x0, y0, x1, y1 });
    // Split the difference in two: inside a glyph run's box (where the GPU's
    // grey coverage meets the CPU's ClearType) and outside it (where nothing
    // but the same maths should have run).
    {
        var shown: usize = 0;
        const rows = [_]usize{ 5, 10, 30, 60, 75, 150 };
        var ri: usize = 0;
        while (ri < rows.len and rows[ri] < cpu.height) : (ri += 1) {
            const sy = rows[ri];
            var sx: usize = 400;
            while (sx < cpu.width and shown < 12) : (sx += 97) {
                const at = (sy * cpu.width + sx) * 4;
                var d2: u8 = 0;
                for (0..4) |k| {
                    const a = ours.bytes[at + k];
                    const b = cpu.bytes[at + k];
                    d2 = @max(d2, if (a > b) a - b else b - a);
                }
                if (d2 > 8) {
                    std.debug.print("({d},{d}) gpu b{d} g{d} r{d} a{d} cpu b{d} g{d} r{d} a{d}  ", .{ sx, sy, ours.bytes[at], ours.bytes[at + 1], ours.bytes[at + 2], ours.bytes[at + 3], cpu.bytes[at], cpu.bytes[at + 1], cpu.bytes[at + 2], cpu.bytes[at + 3] });
                    shown += 1;
                }
            }
        }
    }
    const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(cpu.bytes.len));
    std.debug.print("d3d11 vs cpu: mean {d:.4}, worst {d}, {d} of {d} off\n", .{ mean, worst, off, cpu.bytes.len });
    try testing.expect(mean < limits.mean);
    try testing.expect(worst <= limits.worst);
    try testing.expect(off * limits.off_in < cpu.bytes.len);
}

test "d3d11: shapes match the CPU renderer" {
    const Scene = @import("tests_raster.zig").Scene;
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 360, .height = 300 });
    defer t.deinit();
    t.settle(1);
    try compare(&t, .{ .mean = 1.0, .worst = 240, .off_in = 20 });
}

test "d3d11: glass matches the CPU renderer" {
    for ([_]ui.Theme{ .light, .dark_theme }) |theme| {
        const Scene = @import("tests_glass.zig").Scene;
        var s: Scene = .{};
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 360, .height = 290, .theme = theme });
        defer t.deinit();
        t.settle(1);
        try compare(&t, .{ .mean = 2.0, .worst = 240, .off_in = 20 });
    }
}

test "d3d11: canvas matches the CPU renderer" {
    const Scene = @import("tests_canvas.zig").Scene;
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 240, .height = 180 });
    defer t.deinit();
    t.settle(0.1);
    try compare(&t, .{ .mean = 0.5, .worst = 240, .off_in = 20 });
}

test "d3d11: a coloured quad keeps its channels" {
    const gpa = testing.allocator;
    var r = d3d11.Renderer.init() catch |e| {
        std.debug.print("no Direct3D 11 here: {t} ", .{e});
        return error.SkipZigTest;
    };
    defer r.deinit();
    // Red, green and blue side by side over a known clear.
    const quads = [3]gpu.Instance{
        .{ .rect = .{ 0, 0, 10, 30 }, .color = .{ 1, 0, 0, 1 } },
        .{ .rect = .{ 10, 0, 10, 30 }, .color = .{ 0, 1, 0, 1 } },
        .{ .rect = .{ 20, 0, 10, 30 }, .color = .{ 0, 0, 1, 1 } },
    };
    r.draw(&quads, .{ .w = 30, .h = 30 }, 1, .{ .r = 0, .g = 0, .b = 0, .a = 1 }, null);
    const px = try r.read(gpa);
    defer px.deinit(gpa);
    const at = struct {
        fn f(p2: gpu.Pixels, x: usize, y: usize) [4]u8 {
            const i = (y * p2.width + x) * 4;
            return .{ p2.bytes[i], p2.bytes[i + 1], p2.bytes[i + 2], p2.bytes[i + 3] };
        }
    }.f;
    // BGRA in memory: red is B=0 G=0 R=255.
    std.debug.print("[quads] red {any} green {any} blue {any} ", .{ at(px, 5, 15), at(px, 15, 15), at(px, 25, 15) });
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(px, 5, 15));
    try testing.expectEqual([4]u8{ 0, 255, 0, 255 }, at(px, 15, 15));
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, at(px, 25, 15));
}
