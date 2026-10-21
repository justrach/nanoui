//! The renderer on the CPU: the instances `shader.metal` draws, drawn to
//! the same pixels in memory (BGRA, premultiplied, sRGB-encoded values
//! blended as the GPU blends them). Windows present them where nanoui has
//! no GPU renderer, and the Tester renders with it there. A test proves it
//! matches the Metal renderer.
const std = @import("std");
const types = @import("types.zig");
const gpu = @import("gpu.zig");
const glass = @import("glass.zig");
pub const shadows = @import("raster_shadow.zig");

/// The glyph atlas, as the shader samples it: one byte per texel.
pub const Mask = struct {
    pixels: []const u8,
    size: u32,
};

/// The image atlas: BGRA premultiplied, `size` × `size` (empty: none).
pub const Pictures = struct {
    pixels: []const u8 = &.{},
    size: u32 = 0,
    /// The frame's textures (`ui.texture`): their `bgra` is drawn.
    textures: []const gpu.Texture = &.{},
};

/// Draws `instances` over `clear` into `out` (sized `out.width` ×
/// `out.height` pixels, `scale` pixels a point).
pub fn draw(out: gpu.Pixels, instances: []const gpu.Instance, mask: Mask, pictures: Pictures, scale: f32, clear: types.Color) void {
    drawRegion(out, instances, mask, pictures, scale, clear, .{ 0, 0, out.width, out.height });
}

/// `draw`, only within `region` (pixels: x0, y0, x1, y1); the rest of
/// `out` is kept. Over the pixels of an earlier frame, with the `damage`
/// between the two, it makes the same pixels as drawing it all.
pub fn drawRegion(out: gpu.Pixels, instances: []const gpu.Instance, mask: Mask, pictures: Pictures, scale: f32, clear: types.Color, region: [4]usize) void {
    const px: [4]u8 = .{ unit(clear.b), unit(clear.g), unit(clear.r), 255 };
    var job: Band = .{ .out = out, .instances = instances, .mask = mask, .pictures = pictures, .scale = scale, .clear = @bitCast(px), .region = region };
    // Glass reads what's drawn beyond its band: the bands meet before each
    // pane, which one thread draws.
    var start: usize = 0;
    while (true) {
        var end = start;
        while (end < instances.len and instances[end].kind != gpu.Kind.glass) end += 1;
        job.instances = instances[start..end];
        job.share();
        job.clear = null;
        if (end == instances.len) break;
        drawOne(out, &instances[end], mask, pictures, scale, region);
        start = end + 1;
    }
}

/// The most threads a region is drawn on; 1 draws it on the caller's
/// alone (tests compare the two).
pub var threads: usize = Band.thread_limit;

/// Instances drawn into some of a region's rows. A pixel's color depends
/// only on the instances over it, so bands of rows drawn on threads of
/// their own make the pixels one thread would.
const Band = struct {
    out: gpu.Pixels,
    instances: []const gpu.Instance,
    mask: Mask,
    pictures: Pictures,
    scale: f32,
    /// The pixel the rows are cleared to first, if they are.
    clear: ?u32,
    region: [4]usize,

    const thread_limit = 16;
    /// Fewer pixels than this a thread: not worth starting one.
    const min_pixels = 1 << 17;

    fn rows(job: Band, y0: usize, y1: usize) void {
        const r: [4]usize = .{ job.region[0], y0, job.region[2], y1 };
        if (job.clear) |px| {
            const words: []u32 = @alignCast(std.mem.bytesAsSlice(u32, job.out.bytes[0 .. job.out.width * job.out.height * 4]));
            for (y0..y1) |y| @memset(words[y * job.out.width + r[0] .. y * job.out.width + r[2]], px);
        }
        for (job.instances) |*i| drawOne(job.out, i, job.mask, job.pictures, job.scale, r);
    }

    /// Draws the region's rows, shared among threads when there are many.
    fn share(job: Band) void {
        const height = job.region[3] - job.region[1];
        const cpus = std.Thread.getCpuCount() catch 1;
        const n = @max(1, @min(threads, thread_limit, cpus, height * (job.region[2] - job.region[0]) / min_pixels));
        var started: [thread_limit]?std.Thread = @splat(null);
        for (1..n) |k| {
            const y0 = job.region[1] + height * k / n;
            const y1 = job.region[1] + height * (k + 1) / n;
            started[k] = std.Thread.spawn(.{}, Band.rows, .{ job, y0, y1 }) catch blk: {
                job.rows(y0, y1);
                break :blk null;
            };
        }
        job.rows(job.region[1], job.region[1] + height / n);
        for (started[1..n]) |t| if (t) |th| th.join();
    }
};

/// The pixels (x0, y0, x1, y1) in which a frame of `new` instances differs
/// from one of `old`, both drawn `width` × `height` with the same atlases;
/// null when none do. The instances both frames start and end with are
/// the same; between them, those that changed cover what changed. Glass
/// reads what's behind it from beyond its bounds: with glass, all of it.
pub fn damage(width: usize, height: usize, old: []const gpu.Instance, new: []const gpu.Instance, scale: f32) ?[4]usize {
    const out: gpu.Pixels = .{ .bytes = &.{}, .width = width, .height = height };
    for (new) |*i| if (i.kind == gpu.Kind.glass) return .{ 0, 0, width, height };
    var start: usize = 0;
    while (start < old.len and start < new.len and same(&old[start], &new[start])) start += 1;
    var old_end = old.len;
    var new_end = new.len;
    while (old_end > start and new_end > start and same(&old[old_end - 1], &new[new_end - 1])) {
        old_end -= 1;
        new_end -= 1;
    }
    const before = old[start..old_end];
    const after = new[start..new_end];
    var region: ?[4]usize = null;
    if (before.len == after.len) {
        // The same number in between: only the pairs that differ.
        for (before, after) |*a, *b| if (!same(a, b)) {
            cover(&region, bounds(out, a, scale));
            cover(&region, bounds(out, b, scale));
        };
    } else {
        for (before) |*a| cover(&region, bounds(out, a, scale));
        for (after) |*b| cover(&region, bounds(out, b, scale));
    }
    return region;
}

fn same(a: *const gpu.Instance, b: *const gpu.Instance) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

fn cover(region: *?[4]usize, b: ?[4]usize) void {
    const add = b orelse return;
    region.* = if (region.*) |r| .{ @min(r[0], add[0]), @min(r[1], add[1]), @max(r[2], add[2]), @max(r[3], add[3]) } else add;
}

fn unit(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

/// The pixels an instance covers: its quad (grown for a shadow's blur),
/// within its clip and the frame.
fn bounds(out: gpu.Pixels, i: *const gpu.Instance, scale: f32) ?[4]usize {
    const grow: f32 = if (i.kind == gpu.Kind.shadow) i.border_width * 3 else 0;
    const x0 = @max(i.rect[0] - grow, i.clip[0]);
    const y0 = @max(i.rect[1] - grow, i.clip[1]);
    const x1 = @min(i.rect[0] + i.rect[2] + grow, i.clip[2]);
    const y1 = @min(i.rect[1] + i.rect[3] + grow, i.clip[3]);
    if (x1 <= x0 or y1 <= y0) return null;
    const w: f32 = @floatFromInt(out.width);
    const h: f32 = @floatFromInt(out.height);
    // A pixel is drawn when its center is inside, as the GPU rasterizes.
    const px0 = std.math.clamp(@round(x0 * scale), 0, w);
    const py0 = std.math.clamp(@round(y0 * scale), 0, h);
    const px1 = std.math.clamp(@round(x1 * scale), 0, w);
    const py1 = std.math.clamp(@round(y1 * scale), 0, h);
    if (px1 <= px0 or py1 <= py0) return null;
    return .{ @intFromFloat(px0), @intFromFloat(py0), @intFromFloat(px1), @intFromFloat(py1) };
}

fn drawOne(out: gpu.Pixels, i: *const gpu.Instance, mask: Mask, pictures: Pictures, scale: f32, region: [4]usize) void {
    const all = bounds(out, i, scale) orelse return;
    const b: [4]usize = .{ @max(all[0], region[0]), @max(all[1], region[1]), @min(all[2], region[2]), @min(all[3], region[3]) };
    if (b[2] <= b[0] or b[3] <= b[1]) return;
    if (i.kind == gpu.Kind.text) return glyph(out, i, mask, scale, b);
    if (i.kind == gpu.Kind.image) return picture(out, i, .atlas(pictures), scale, b);
    if (i.kind == gpu.Kind.texture) {
        const slot: usize = @intFromFloat(i.border_width);
        if (slot < pictures.textures.len) picture(out, i, .texture(pictures.textures[slot]), scale, b);
        return;
    }
    if (i.kind == gpu.Kind.shadow) return shadows.draw(out, i, scale, b, clipCover);
    if (i.kind == gpu.Kind.glass) return pane(out, i, scale, b);
    quad(out, i, scale, b);
}

/// Blends a premultiplied color over the pixel at byte `at`.
inline fn blend(bytes: []u8, at: usize, r: f32, g: f32, bl: f32, a: f32) void {
    if (a <= 0) return;
    const inv = 1 - a;
    const d = bytes[at..][0..4];
    d[0] = @intFromFloat(@min(255, bl * 255 + @as(f32, @floatFromInt(d[0])) * inv + 0.5));
    d[1] = @intFromFloat(@min(255, g * 255 + @as(f32, @floatFromInt(d[1])) * inv + 0.5));
    d[2] = @intFromFloat(@min(255, r * 255 + @as(f32, @floatFromInt(d[2])) * inv + 0.5));
    d[3] = @intFromFloat(@min(255, a * 255 + @as(f32, @floatFromInt(d[3])) * inv + 0.5));
}

fn smoothstep(e0: f32, e1: f32, x: f32) f32 {
    const t = std.math.clamp((x - e0) / (e1 - e0), 0, 1);
    return t * t * (3 - 2 * t);
}

/// The signed distance to a rounded box centered at 0, and the sum of the
/// absolute values of its gradient (what `fwidth` measures per pixel).
fn roundedBox(px: f32, py: f32, hw: f32, hh: f32, r: f32) [2]f32 {
    const qx = @abs(px) - hw + r;
    const qy = @abs(py) - hh + r;
    const mx = @max(qx, 0);
    const my = @max(qy, 0);
    const len = @sqrt(mx * mx + my * my);
    const d = len + @min(@max(qx, qy), 0) - r;
    const grad: f32 = if (len > 0) (mx + my) / len else 1;
    return .{ d, grad };
}

/// How much of the pixel at `wx`, `wy` the instance's clip lets through:
/// all of it, but in the clip's rounded corners (as the shader's
/// `clip_cover`).
fn clipCover(i: *const gpu.Instance, wx: f32, wy: f32, inv: f32) f32 {
    if (i.clip_round <= 0) return 1;
    const round = gpu.clipCorners(i.clip_round);
    const c = i.clip;
    const hw = (c[2] - c[0]) * 0.5;
    const hh = (c[3] - c[1]) * 0.5;
    const r = @min(round.radius, @min(hw, hh));
    // Between the corners, nothing is cut.
    if ((wx > c[0] + r and wx < c[2] - r) or (wy > c[1] + r and wy < c[3] - r)) return 1;
    const qx = wx - c[0] - hw;
    const qy = wy - c[1] - hh;
    const bit: u4 = if (qy < 0) (if (qx < 0) 1 else 2) else (if (qx < 0) 8 else 4);
    if (round.corners & bit == 0) return 1;
    const sd = roundedBox(qx, qy, hw, hh, r);
    const aa = @max(sd[1] * inv, 0.0001) * 0.5;
    return 1 - smoothstep(-aa, aa, sd[0]);
}

fn quad(out: gpu.Pixels, i: *const gpu.Instance, scale: f32, b: [4]usize) void {
    const hw = i.rect[2] * 0.5;
    const hh = i.rect[3] * 0.5;
    const cx = i.rect[0] + hw;
    const cy = i.rect[1] + hh;
    const r = @min(i.radius, @min(hw, hh));
    const bw = i.border_width;
    const has_border = bw > 0 and i.border_color[3] > 0;
    const c = i.color;
    const bc = i.border_color;
    // Inside this, a pixel is wholly the fill: no edge, corner or border.
    const solid = @max(r, if (has_border) bw else 0) + 2 / scale;
    const inv = 1 / scale;
    for (b[1]..b[3]) |y| {
        const wy = (@as(f32, @floatFromInt(y)) + 0.5) * inv;
        const py = wy - cy;
        const row = y * out.width * 4;
        const inner_y = @abs(py) < hh - solid;
        for (b[0]..b[2]) |x| {
            const wx = (@as(f32, @floatFromInt(x)) + 0.5) * inv;
            const pxl = wx - cx;
            const cut = clipCover(i, wx, wy, inv);
            if (inner_y and @abs(pxl) < hw - solid) {
                const a = c[3] * cut;
                blend(out.bytes, row + x * 4, c[0] * a, c[1] * a, c[2] * a, a);
                continue;
            }
            const sd = roundedBox(pxl, py, hw, hh, r);
            const aa = @max(sd[1] * inv, 0.0001) * 0.5;
            const coverage = 1 - smoothstep(-aa, aa, sd[0]);
            if (coverage <= 0) continue;
            var col = c;
            if (has_border) {
                const t = smoothstep(-bw - aa, -bw + aa, sd[0]);
                for (0..4) |k| col[k] = c[k] + (bc[k] - c[k]) * t;
            }
            const a = col[3] * coverage * cut;
            blend(out.bytes, row + x * 4, col[0] * a, col[1] * a, col[2] * a, a);
        }
    }
}

/// The atlas sampled as Metal's linear filter with clamped edges does.
fn sample(mask: Mask, u: f32, v: f32) f32 {
    const s: f32 = @floatFromInt(mask.size);
    const fx = u * s - 0.5;
    const fy = v * s - 0.5;
    const x0f = @floor(fx);
    const y0f = @floor(fy);
    const tx = fx - x0f;
    const ty = fy - y0f;
    const max: i64 = @as(i64, mask.size) - 1;
    const x0: usize = @intCast(std.math.clamp(@as(i64, @intFromFloat(x0f)), 0, max));
    const y0: usize = @intCast(std.math.clamp(@as(i64, @intFromFloat(y0f)), 0, max));
    const x1: usize = @intCast(std.math.clamp(@as(i64, @intFromFloat(x0f)) + 1, 0, max));
    const y1: usize = @intCast(std.math.clamp(@as(i64, @intFromFloat(y0f)) + 1, 0, max));
    const n: usize = mask.size;
    const a = @as(f32, @floatFromInt(mask.pixels[y0 * n + x0]));
    const bb = @as(f32, @floatFromInt(mask.pixels[y0 * n + x1]));
    const c = @as(f32, @floatFromInt(mask.pixels[y1 * n + x0]));
    const d = @as(f32, @floatFromInt(mask.pixels[y1 * n + x1]));
    const top = a + (bb - a) * tx;
    const bottom = c + (d - c) * tx;
    return (top + (bottom - top) * ty) / 255;
}

fn glyph(out: gpu.Pixels, i: *const gpu.Instance, mask: Mask, scale: f32, b: [4]usize) void {
    if (mask.size == 0) return;
    const inv = 1 / scale;
    const c = i.color;
    for (b[1]..b[3]) |y| {
        const wy = (@as(f32, @floatFromInt(y)) + 0.5) * inv;
        const ty = (wy - i.rect[1]) / i.rect[3];
        const v = i.uv[1] + (i.uv[3] - i.uv[1]) * ty;
        const row = y * out.width * 4;
        for (b[0]..b[2]) |x| {
            const wx = (@as(f32, @floatFromInt(x)) + 0.5) * inv;
            const tx = (wx - i.rect[0]) / i.rect[2];
            const u = i.uv[0] + (i.uv[2] - i.uv[0]) * tx;
            const a = sample(mask, u, v) * c[3] * clipCover(i, wx, wy, inv);
            blend(out.bytes, row + x * 4, c[0] * a, c[1] * a, c[2] * a, a);
        }
    }
}

/// A BGRA texel of the image atlas, bilinear as Metal's sampler.
/// Pixels to sample: the image atlas, or a texture's rows.
const Source = struct {
    pixels: []const u8,
    w: usize,
    h: usize,
    stride: usize,

    fn atlas(p: Pictures) Source {
        return .{ .pixels = p.pixels, .w = p.size, .h = p.size, .stride = @as(usize, p.size) * 4 };
    }

    fn texture(t: gpu.Texture) Source {
        return .{ .pixels = t.bgra, .w = t.width, .h = t.height, .stride = if (t.stride > 0) t.stride else @as(usize, t.width) * 4 };
    }
};

fn samplePicture(p: Source, u: f32, v: f32) [4]f32 {
    const fx = u * @as(f32, @floatFromInt(p.w)) - 0.5;
    const fy = v * @as(f32, @floatFromInt(p.h)) - 0.5;
    const x0f = @floor(fx);
    const y0f = @floor(fy);
    const tx = fx - x0f;
    const ty = fy - y0f;
    const mx: i64 = @as(i64, @intCast(p.w)) - 1;
    const my: i64 = @as(i64, @intCast(p.h)) - 1;
    const xs = [2]usize{ @intCast(std.math.clamp(@as(i64, @intFromFloat(x0f)), 0, mx)), @intCast(std.math.clamp(@as(i64, @intFromFloat(x0f)) + 1, 0, mx)) };
    const ys = [2]usize{ @intCast(std.math.clamp(@as(i64, @intFromFloat(y0f)), 0, my)), @intCast(std.math.clamp(@as(i64, @intFromFloat(y0f)) + 1, 0, my)) };
    var out: [4]f32 = .{ 0, 0, 0, 0 };
    const weights = [4]f32{ (1 - tx) * (1 - ty), tx * (1 - ty), (1 - tx) * ty, tx * ty };
    for (0..4) |k| {
        const t = p.pixels[ys[k / 2] * p.stride + xs[k % 2] * 4 ..][0..4];
        for (0..4) |ch| out[ch] += @as(f32, @floatFromInt(t[ch])) / 255 * weights[k];
    }
    return out;
}

fn picture(out: gpu.Pixels, i: *const gpu.Instance, p: Source, scale: f32, b: [4]usize) void {
    if (p.w == 0 or p.h == 0 or p.pixels.len < p.stride * p.h) return;
    const inv = 1 / scale;
    const hw = i.rect[2] * 0.5;
    const hh = i.rect[3] * 0.5;
    const r = @min(i.radius, @min(hw, hh));
    for (b[1]..b[3]) |y| {
        const wy = (@as(f32, @floatFromInt(y)) + 0.5) * inv;
        const ty = (wy - i.rect[1]) / i.rect[3];
        const v = i.uv[1] + (i.uv[3] - i.uv[1]) * ty;
        const row = y * out.width * 4;
        for (b[0]..b[2]) |x| {
            const wx = (@as(f32, @floatFromInt(x)) + 0.5) * inv;
            const tx = (wx - i.rect[0]) / i.rect[2];
            const sd = roundedBox(wx - i.rect[0] - hw, wy - i.rect[1] - hh, hw, hh, r);
            const aa = @max(sd[1] * inv, 0.0001) * 0.5;
            const k = (1 - smoothstep(-aa, aa, sd[0])) * i.color[3] * clipCover(i, wx, wy, inv);
            if (k <= 0) continue;
            const t = samplePicture(p, i.uv[0] + (i.uv[2] - i.uv[0]) * tx, v);
            if (i.border_color[3] > 0) {
                // Tinted: the shape in one color, as the shader draws it.
                const a = t[3] * i.border_color[3] * k;
                blend(out.bytes, row + x * 4, i.border_color[0] * a, i.border_color[1] * a, i.border_color[2] * a, a);
                continue;
            }
            blend(out.bytes, row + x * 4, t[2] * k, t[1] * k, t[0] * k, t[3] * k);
        }
    }
}

/// A pane of glass over what was drawn before it, as `glass.metal` draws
/// it: its backdrop read from the pixels so far, then its color at each
/// pixel, by its rounded edge's coverage.
fn pane(out: gpu.Pixels, i: *const gpu.Instance, scale: f32, b: [4]usize) void {
    const plan = glass.backdropOf(i.rect, i.border_width, scale, out.width, out.height) orelse return;
    const im = glass.readBackdrop(std.heap.page_allocator, out, plan) catch return;
    defer std.heap.page_allocator.free(im.pix);
    const inv = 1 / scale;
    const hw = i.rect[2] * 0.5;
    const hh = i.rect[3] * 0.5;
    const r = @min(i.radius, @min(hw, hh));
    for (b[1]..b[3]) |y| {
        const wy = (@as(f32, @floatFromInt(y)) + 0.5) * inv;
        const row = y * out.width * 4;
        for (b[0]..b[2]) |x| {
            const wx = (@as(f32, @floatFromInt(x)) + 0.5) * inv;
            const sd = roundedBox(wx - i.rect[0] - hw, wy - i.rect[1] - hh, hw, hh, r);
            const aa = @max(sd[1] * inv, 0.0001) * 0.5;
            const k = (1 - smoothstep(-aa, aa, sd[0])) * clipCover(i, wx, wy, inv) * i.uv[2];
            if (k <= 0) continue;
            const c = glass.color(i, im, @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, scale);
            blend(out.bytes, row + x * 4, c[0] * k, c[1] * k, c[2] * k, k);
        }
    }
}

test "rounded boxes, borders, glyphs and shadows" {
    const gpa = std.testing.allocator;
    const bytes = try gpa.alloc(u8, 40 * 40 * 4);
    defer gpa.free(bytes);
    const out: gpu.Pixels = .{ .bytes = bytes, .width = 40, .height = 40 };
    var texels: [4]u8 = .{ 255, 255, 255, 255 };
    draw(out, &.{
        .{ .rect = .{ 2, 2, 16, 16 }, .color = .{ 1, 0, 0, 1 }, .radius = 4 },
        .{ .rect = .{ 0, 0, 10, 10 }, .color = .{ 0, 0, 1, 1 }, .uv = .{ 0, 0, 1, 1 }, .kind = gpu.Kind.text, .clip = .{ 0, 0, 5, 20 } },
    }, .{ .pixels = &texels, .size = 2 }, .{}, 2, .{ .r = 1, .g = 1, .b = 1 });
    const at = struct {
        fn f(o: gpu.Pixels, x: usize, y: usize) [4]u8 {
            return o.bytes[(y * o.width + x) * 4 ..][0..4].*;
        }
    }.f;
    // The middle of the box is red (BGRA); its rounded corner is not.
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(out, 20, 20));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(out, 4, 34));
    // The glyph is blue where its clip lets it be.
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, at(out, 2, 2));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(out, 15, 2));
}

test "a clip's rounded corners cut what it clips, only where asked" {
    const gpa = std.testing.allocator;
    const bytes = try gpa.alloc(u8, 40 * 40 * 4);
    defer gpa.free(bytes);
    const out: gpu.Pixels = .{ .bytes = bytes, .width = 40, .height = 40 };
    // A square filling its clip, whose left corners round by 8.
    draw(out, &.{
        .{ .rect = .{ 0, 0, 20, 20 }, .color = .{ 1, 0, 0, 1 }, .clip = .{ 0, 0, 20, 20 }, .clip_round = gpu.clipRound(8, 1 | 8) },
    }, .{ .pixels = &.{}, .size = 0 }, .{}, 2, .{ .r = 1, .g = 1, .b = 1 });
    const at = struct {
        fn f(o: gpu.Pixels, x: usize, y: usize) [4]u8 {
            return o.bytes[(y * o.width + x) * 4 ..][0..4].*;
        }
    }.f;
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(out, 0, 0));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(out, 0, 39));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(out, 39, 0));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(out, 39, 39));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(out, 20, 20));
    const unpacked = gpu.clipCorners(gpu.clipRound(8, 1 | 8));
    try std.testing.expectEqual(@as(f32, 8), unpacked.radius);
    try std.testing.expectEqual(@as(u4, 9), unpacked.corners);
}
