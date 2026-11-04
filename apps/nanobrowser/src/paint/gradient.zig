//! A gradient as a small picture: nanoui draws boxes and pictures, so it is
//! worked out on a grid and stretched over its box. Cached by what it is,
//! since the same gradient is usually on many boxes.
const std = @import("std");
const nanoui = @import("nanoui");
const css = @import("../css/style.zig");

const side = 128;

pub const Cache = struct {
    gpa: std.mem.Allocator,
    pngs: std.AutoHashMapUnmanaged(u64, []u8) = .empty,

    pub fn deinit(cache: *Cache) void {
        var it = cache.pngs.valueIterator();
        while (it.next()) |v| cache.gpa.free(v.*);
        cache.pngs.deinit(cache.gpa);
    }

    pub fn get(cache: *Cache, g: css.Gradient) ?[]const u8 {
        if (g.stops.len == 0) return null;
        var h = std.hash.Wyhash.init(g.stops.len);
        h.update(std.mem.asBytes(&g.angle));
        h.update(&.{@intFromEnum(g.shape)});
        for ([_]f32{ g.cx, g.cy, g.rx, g.ry }) |v| h.update(std.mem.asBytes(&v));
        h.update(std.mem.sliceAsBytes(g.stops));
        const k = h.final();
        if (cache.pngs.get(k)) |v| return v;
        const png = render(cache.gpa, g) catch return null;
        cache.pngs.put(cache.gpa, k, png) catch {
            cache.gpa.free(png);
            return null;
        };
        return png;
    }
};

/// The color at `t` along a gradient (0 to 1), premultiplied as it blends.
pub fn colorAt(stops: []const css.GradientStop, t: f32) [4]f32 {
    const first = stops[0];
    if (t <= first.at) return premultiply(first.color);
    var prev = first;
    for (stops[1..]) |s| {
        if (t <= s.at) {
            const span = s.at - prev.at;
            const k = if (span <= 0) 1 else (t - prev.at) / span;
            const a = premultiply(prev.color);
            const b = premultiply(s.color);
            return .{ a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k, a[3] + (b[3] - a[3]) * k };
        }
        prev = s;
    }
    return premultiply(prev.color);
}

fn premultiply(c: css.Color) [4]f32 {
    return .{ c.r * c.a, c.g * c.a, c.b * c.a, c.a };
}

/// The one color of a gradient that is only one (a trick for a second
/// background layer): a fill, with no picture to make.
pub fn solid(g: css.Gradient) ?css.Color {
    if (g.stops.len == 0) return null;
    const c = g.stops[0].color;
    for (g.stops[1..]) |s| if (s.color.r != c.r or s.color.g != c.g or s.color.b != c.b or s.color.a != c.a) return null;
    return c;
}

/// How far along it the point (`fx`, `fy`) is, each 0 to 1 across the box.
fn along(g: css.Gradient, fx: f32, fy: f32, dx: f32, dy: f32) f32 {
    return switch (g.shape) {
        // Corner to corner along the direction, as CSS's gradient line, on a square.
        .linear => ((fx - 0.5) * dx + (fy - 0.5) * dy) / @max(@abs(dx) + @abs(dy), 0.001) + 0.5,
        .radial => blk: {
            const x = (fx - g.cx) / g.rx;
            const y = (fy - g.cy) / g.ry;
            break :blk @sqrt(x * x + y * y);
        },
        .conic => blk: {
            const a = std.math.atan2(fx - g.cx, g.cy - fy) * 180 / std.math.pi - g.angle;
            break :blk @mod(a, 360) / 360;
        },
    };
}

fn render(gpa: std.mem.Allocator, g: css.Gradient) ![]u8 {
    const px = try gpa.alloc(u8, side * side * 4);
    defer gpa.free(px);
    const rad = g.angle * std.math.pi / 180;
    const dx = @sin(rad);
    const dy = -@cos(rad);
    for (0..side) |y| for (0..side) |x| {
        const fx = (@as(f32, @floatFromInt(x)) + 0.5) / side;
        const fy = (@as(f32, @floatFromInt(y)) + 0.5) / side;
        const c = colorAt(g.stops, along(g, fx, fy, dx, dy));
        const at = (y * side + x) * 4;
        px[at] = byte(c[2]);
        px[at + 1] = byte(c[1]);
        px[at + 2] = byte(c[0]);
        px[at + 3] = byte(c[3]);
    };
    return nanoui.ui.png.encode(gpa, .{ .bytes = px, .width = side, .height = side });
}

fn byte(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v, 0, 1) * 255 + 0.5);
}

test "a gradient's colors along its line" {
    const stops = [_]css.GradientStop{ .{ .color = .{ .r = 1, .g = 0, .b = 0 }, .at = 0 }, .{ .color = .{ .r = 0, .g = 0, .b = 1 }, .at = 1 } };
    try std.testing.expectEqual(@as(f32, 1), colorAt(&stops, 0)[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), colorAt(&stops, 0.5)[2], 0.001);
    try std.testing.expectEqual(@as(f32, 1), colorAt(&stops, 1)[2]);
    var cache: Cache = .{ .gpa = std.testing.allocator };
    defer cache.deinit();
    const a = cache.get(.{ .stops = &stops }).?;
    try std.testing.expect(a.ptr == cache.get(.{ .stops = &stops }).?.ptr);
    try std.testing.expect(cache.get(.{ .stops = &.{} }) == null);
    // Another shape of the same stops is another picture.
    try std.testing.expect(a.ptr != cache.get(.{ .stops = &stops, .shape = .radial }).?.ptr);
    try std.testing.expect(solid(.{ .stops = &stops }) == null);
    const one = [_]css.GradientStop{ .{ .color = .{ .g = 1 }, .at = 0 }, .{ .color = .{ .g = 1 }, .at = 1 } };
    try std.testing.expectEqual(@as(f32, 1), solid(.{ .stops = &one }).?.g);
    // At the center a radial is at its start; at a corner, a farthest-corner's end.
    const r: css.Gradient = .{ .stops = &stops, .shape = .radial };
    try std.testing.expectApproxEqAbs(@as(f32, 0), along(r, 0.5, 0.5, 0, 0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), along(r, 1, 1, 0, 0), 0.001);
    // A conic runs clockwise from the top.
    const k: css.Gradient = .{ .stops = &stops, .shape = .conic, .angle = 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), along(k, 1, 0.5, 0, 0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), along(k, 0.5, 1, 0, 0), 0.001);
}
