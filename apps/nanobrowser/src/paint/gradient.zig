//! A gradient as a picture: nanoui draws boxes and pictures, so it is worked out
//! at the size of what it fills. A smooth one needs few pixels and is stretched;
//! one with hard edges, or that repeats, gets a pixel for every pixel it covers,
//! as far as a picture can be large. Cached by what it is and its size, since the
//! same one is usually on many boxes; the whole cache goes when it grows too big.
const std = @import("std");
const nanoui = @import("nanoui");
const css = @import("../css/style.zig");

/// The longest side of a picture nanoui keeps.
const max_side: f32 = 1024;
/// What a smooth gradient is worked out at.
const smooth_side: f32 = 256;
const max_cached_bytes = 48 * 1024 * 1024;

pub const Cache = struct {
    gpa: std.mem.Allocator,
    pngs: std.AutoHashMapUnmanaged(u64, []u8) = .empty,
    bytes: usize = 0,

    pub fn deinit(cache: *Cache) void {
        cache.clear();
        cache.pngs.deinit(cache.gpa);
    }

    fn clear(cache: *Cache) void {
        var it = cache.pngs.valueIterator();
        while (it.next()) |v| cache.gpa.free(v.*);
        cache.pngs.clearRetainingCapacity();
        cache.bytes = 0;
    }

    /// A frame starts: nothing of the last one is still being read.
    pub fn beginFrame(cache: *Cache) void {
        if (cache.bytes > max_cached_bytes) cache.clear();
    }

    /// The picture of `tiles` of `g`, each `w` × `h` points, at `scale` pixels a point.
    pub fn get(cache: *Cache, g: css.Gradient, w: f32, h: f32, nx: u32, ny: u32, scale: f32) ?[]const u8 {
        if (g.stops.len == 0 or w <= 0 or h <= 0) return null;
        const size = pixelSize(g, w, h, nx, ny, scale);
        var hasher = std.hash.Wyhash.init(g.stops.len);
        hasher.update(std.mem.asBytes(&g.angle));
        hasher.update(&.{ @intFromEnum(g.shape), @intFromBool(g.repeating), @intFromEnum(g.extent), @intFromBool(g.circle) });
        hasher.update(std.mem.asBytes(&g.to_x));
        hasher.update(std.mem.asBytes(&g.to_y));
        for ([_]f32{ g.cx, g.cy, g.cx_px, g.cy_px, g.rx, g.ry, w, h }) |v| hasher.update(std.mem.asBytes(&v));
        if (g.size_x) |l| hasher.update(std.mem.asBytes(&l));
        if (g.size_y) |l| hasher.update(std.mem.asBytes(&l));
        hasher.update(std.mem.sliceAsBytes(g.stops));
        hasher.update(std.mem.asBytes(&nx));
        hasher.update(std.mem.asBytes(&ny));
        hasher.update(std.mem.asBytes(&size));
        const k = hasher.final();
        if (cache.pngs.get(k)) |v| return v;
        const png = render(cache.gpa, g, w, h, nx, ny, size[0], size[1]) catch return null;
        cache.pngs.put(cache.gpa, k, png) catch {
            cache.gpa.free(png);
            return null;
        };
        cache.bytes += png.len;
        return png;
    }
};

/// Whether stretching a small picture of it shows the same thing.
pub fn isSmooth(g: css.Gradient) bool {
    if (g.repeating or g.has_px) return false;
    var prev = g.stops[0];
    for (g.stops[1..]) |s| {
        if (s.at - prev.at < 0.004 and !sameColor(s.color, prev.color)) return false;
        prev = s;
    }
    return true;
}

fn sameColor(a: css.Color, b: css.Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

/// Pixels to work a gradient out at.
fn pixelSize(g: css.Gradient, w: f32, h: f32, nx: u32, ny: u32, scale: f32) [2]u32 {
    const full_w = w * @as(f32, @floatFromInt(nx));
    const full_h = h * @as(f32, @floatFromInt(ny));
    var pw = @max(1, @ceil(full_w * scale));
    var ph = @max(1, @ceil(full_h * scale));
    if (isSmooth(g) and nx == 1 and ny == 1) {
        // Along one axis it only changes one way.
        const straight = g.shape == .linear and g.to_x == 0 and g.to_y == 0;
        const a = @mod(g.angle, 180);
        if (straight and a == 0) pw = 2;
        if (straight and a == 90) ph = 2;
        pw = @min(pw, smooth_side);
        ph = @min(ph, smooth_side);
    }
    const k = @min(1, max_side / @max(pw, ph));
    return .{ @intFromFloat(@max(1, @ceil(pw * k))), @intFromFloat(@max(1, @ceil(ph * k))) };
}

/// A gradient's stops placed on its line, for its length in pixels.
fn placed(a: std.mem.Allocator, g: css.Gradient, length: f32) ![]css.GradientStop {
    const out = try a.dupe(css.GradientStop, g.stops);
    if (!g.has_px) return out;
    const n = out.len;
    for (out) |*s| {
        s.at += s.px / @max(length, 0.001);
        s.px = 0;
    }
    if (!out[0].known) {
        out[0].at = 0;
        out[0].known = true;
    }
    if (!out[n - 1].known) {
        out[n - 1].at = 1;
        out[n - 1].known = true;
    }
    var high = out[0].at;
    for (out) |*s| if (s.known) {
        if (s.at < high) s.at = high;
        high = s.at;
    };
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (out[i].known) continue;
        var e = i;
        while (!out[e].known) e += 1;
        const start = out[i - 1].at;
        const gap = (out[e].at - start) / @as(f32, @floatFromInt(e - i + 1));
        var j = i;
        while (j < e) : (j += 1) {
            out[j].at = start + gap * @as(f32, @floatFromInt(j - i + 1));
            out[j].known = true;
        }
    }
    return out;
}

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

/// Where a gradient lies in a box of `w` × `h`: all a point needs to find itself.
pub const Line = struct {
    g: css.Gradient,
    w: f32,
    h: f32,
    dx: f32 = 0,
    dy: f32 = 1,
    /// The line's length; a radial's along its x, in pixels.
    length: f32 = 1,
    cx: f32 = 0,
    cy: f32 = 0,
    rx: f32 = 1,
    ry: f32 = 1,

    pub fn of(g: css.Gradient, w: f32, h: f32) Line {
        var l: Line = .{ .g = g, .w = w, .h = h };
        l.cx = g.cx * w + g.cx_px;
        l.cy = g.cy * h + g.cy_px;
        switch (g.shape) {
            .linear => {
                var dx: f32 = @sin(g.angle * std.math.pi / 180);
                var dy: f32 = -@cos(g.angle * std.math.pi / 180);
                // A corner: the middle runs through the other two.
                if (g.to_x != 0 and g.to_y != 0) {
                    const x = @as(f32, @floatFromInt(g.to_x)) * h;
                    const y = @as(f32, @floatFromInt(g.to_y)) * w;
                    const n = @max(@sqrt(x * x + y * y), 0.001);
                    dx = x / n;
                    dy = y / n;
                }
                l.dx = dx;
                l.dy = dy;
                l.length = @max(@abs(w * dx) + @abs(h * dy), 0.001);
            },
            .radial => {
                const radii = l.radial();
                l.rx = @max(radii[0], 0.001);
                l.ry = @max(radii[1], 0.001);
                l.length = l.rx;
            },
            .conic => {},
        }
        return l;
    }

    fn radial(l: *const Line) [2]f32 {
        const g = l.g;
        const near_x = @min(@abs(l.cx), @abs(l.w - l.cx));
        const far_x = @max(@abs(l.cx), @abs(l.w - l.cx));
        const near_y = @min(@abs(l.cy), @abs(l.h - l.cy));
        const far_y = @max(@abs(l.cy), @abs(l.h - l.cy));
        if (g.size_x) |x| if (g.size_y) |y| {
            return .{ x.resolve(l.w, 0), y.resolve(l.h, 0) };
        };
        const closest = g.extent == .closest_side or g.extent == .closest_corner;
        const corner = g.extent == .closest_corner or g.extent == .farthest_corner;
        const side_x = if (closest) near_x else far_x;
        const side_y = if (closest) near_y else far_y;
        if (g.circle) {
            const r = if (corner) @sqrt(side_x * side_x + side_y * side_y) else if (closest) @min(side_x, side_y) else @max(side_x, side_y);
            return .{ r, r };
        }
        if (!corner) return .{ side_x, side_y };
        // An ellipse through the corner, of the sides' proportions.
        return .{ side_x * std.math.sqrt2, side_y * std.math.sqrt2 };
    }

    /// How far along it the point is.
    pub fn at(l: *const Line, x: f32, y: f32) f32 {
        return switch (l.g.shape) {
            .linear => ((x - l.w / 2) * l.dx + (y - l.h / 2) * l.dy) / l.length + 0.5,
            .radial => blk: {
                const a = (x - l.cx) / l.rx;
                const b = (y - l.cy) / l.ry;
                break :blk @sqrt(a * a + b * b);
            },
            .conic => blk: {
                const a = std.math.atan2(x - l.cx, l.cy - y) * 180 / std.math.pi - l.g.angle;
                break :blk @mod(a, 360) / 360;
            },
        };
    }
};

/// A gradient to read colors from, one point at a time.
pub const Sampler = struct {
    line: Line,
    stops: []const css.GradientStop,

    pub fn init(a: std.mem.Allocator, g: css.Gradient, w: f32, h: f32) !Sampler {
        const line = Line.of(g, w, h);
        return .{ .line = line, .stops = try placed(a, g, line.length) };
    }

    /// Premultiplied, at a point of its box.
    pub fn at(s: *const Sampler, x: f32, y: f32) [4]f32 {
        var t = s.line.at(x, y);
        if (s.line.g.repeating) {
            const first = s.stops[0].at;
            const period = s.stops[s.stops.len - 1].at - first;
            if (period > 0) t = first + @mod(t - first, period);
        }
        return colorAt(s.stops, t);
    }
};

fn render(gpa: std.mem.Allocator, g: css.Gradient, w: f32, h: f32, nx: u32, ny: u32, pw: u32, ph: u32) ![]u8 {
    const px = try gpa.alloc(u8, @as(usize, pw) * ph * 4);
    defer gpa.free(px);
    const line = Line.of(g, w, h);
    const stops = try placed(gpa, g, line.length);
    defer gpa.free(stops);
    const first = stops[0].at;
    const period = stops[stops.len - 1].at - first;
    const fw = w * @as(f32, @floatFromInt(nx)) / @as(f32, @floatFromInt(pw));
    const fh = h * @as(f32, @floatFromInt(ny)) / @as(f32, @floatFromInt(ph));
    const tiled = nx > 1 or ny > 1;
    var at: usize = 0;
    for (0..ph) |y| {
        var fy = (@as(f32, @floatFromInt(y)) + 0.5) * fh;
        if (tiled) fy = @mod(fy, h);
        for (0..pw) |x| {
            var fx = (@as(f32, @floatFromInt(x)) + 0.5) * fw;
            if (tiled) fx = @mod(fx, w);
            var t = line.at(fx, fy);
            if (g.repeating and period > 0) t = first + @mod(t - first, period);
            const c = colorAt(stops, t);
            px[at] = byte(c[2]);
            px[at + 1] = byte(c[1]);
            px[at + 2] = byte(c[0]);
            px[at + 3] = byte(c[3]);
            at += 4;
        }
    }
    return nanoui.ui.png.encode(gpa, .{ .bytes = px, .width = pw, .height = ph });
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
    const a = cache.get(.{ .stops = &stops }, 100, 100, 1, 1, 1).?;
    try std.testing.expect(a.ptr == cache.get(.{ .stops = &stops }, 100, 100, 1, 1, 1).?.ptr);
    try std.testing.expect(cache.get(.{ .stops = &.{} }, 100, 100, 1, 1, 1) == null);
    // Another shape of the same stops is another picture.
    try std.testing.expect(a.ptr != cache.get(.{ .stops = &stops, .shape = .radial }, 100, 100, 1, 1, 1).?.ptr);
    try std.testing.expect(solid(.{ .stops = &stops }) == null);
    const one = [_]css.GradientStop{ .{ .color = .{ .g = 1 }, .at = 0 }, .{ .color = .{ .g = 1 }, .at = 1 } };
    try std.testing.expectEqual(@as(f32, 1), solid(.{ .stops = &one }).?.g);
    // At the center a radial is at its start; at a corner, a farthest-corner's end.
    const r = Line.of(.{ .stops = &stops, .shape = .radial }, 100, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.at(50, 50), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), r.at(100, 100), 0.001);
    // A conic runs clockwise from the top.
    const k = Line.of(.{ .stops = &stops, .shape = .conic, .angle = 0 }, 100, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), k.at(100, 50), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), k.at(50, 100), 0.001);
}

test "a linear gradient's line fits its box, whatever its shape" {
    const stops = [_]css.GradientStop{ .{ .color = .{}, .at = 0 }, .{ .color = .{}, .at = 1 } };
    // Top to bottom: nothing to do with width.
    const down = Line.of(.{ .stops = &stops }, 300, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 0), down.at(10, 0), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 1), down.at(290, 100), 1e-3);
    // 45 degrees: the far corners are its ends.
    const diag = Line.of(.{ .stops = &stops, .angle = 45 }, 300, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 0), diag.at(0, 100), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 1), diag.at(300, 0), 1e-3);
    // To a corner: the other two corners are on its middle.
    const corner = Line.of(.{ .stops = &stops, .to_x = 1, .to_y = -1 }, 300, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), corner.at(0, 0), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), corner.at(300, 100), 1e-3);
}

test "stops in pixels are placed by the line's length, and unplaced ones spread" {
    const raw = [_]css.GradientStop{
        .{ .color = .{}, .at = 0 },
        .{ .color = .{}, .at = 0, .px = 10 },
        .{ .color = .{}, .at = 0, .known = false },
        .{ .color = .{}, .at = 1 },
    };
    const out = try placed(std.testing.allocator, .{ .stops = &raw, .has_px = true }, 100);
    defer std.testing.allocator.free(out);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), out[1].at, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), out[2].at, 1e-4);
}

test "smooth or not" {
    const soft = [_]css.GradientStop{ .{ .color = .{ .r = 1 }, .at = 0 }, .{ .color = .{ .b = 1 }, .at = 1 } };
    const hard = [_]css.GradientStop{ .{ .color = .{ .r = 1 }, .at = 0 }, .{ .color = .{ .r = 1 }, .at = 0.5 }, .{ .color = .{ .b = 1 }, .at = 0.5 }, .{ .color = .{ .b = 1 }, .at = 1 } };
    try std.testing.expect(isSmooth(.{ .stops = &soft }));
    try std.testing.expect(!isSmooth(.{ .stops = &hard }));
    try std.testing.expect(!isSmooth(.{ .stops = &soft, .repeating = true }));
    // Smooth and straight: few pixels; hard: one for each it covers.
    try std.testing.expectEqual([2]u32{ 2, 256 }, pixelSize(.{ .stops = &soft }, 800, 600, 1, 1, 2));
    try std.testing.expectEqual([2]u32{ 800, 600 }, pixelSize(.{ .stops = &hard }, 400, 300, 1, 1, 2));
    try std.testing.expectEqual([2]u32{ 1024, 512 }, pixelSize(.{ .stops = &hard }, 2000, 1000, 1, 1, 2));
}
