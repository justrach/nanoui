//! Video frames that aren't BGRA (`Texture.format`): two-plane Y'CbCr and
//! linear half floats are drawn as the real app's monitor draws them.
//! The oracle is the media core's reference for the post shader
//! (packages/media/src/color/color_pipeline.zig, `ycbcrToDisplaySrgbDepth`,
//! copied below); Metal and the CPU renderer must each land within one
//! 8-bit step of it at every pixel.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const text = @import("text.zig");
const pixel_buffer = @import("pixel_buffer.zig");

const n = 64;

// ── the oracle: color_pipeline.zig, as the media core has it ──

const Range = enum { video, full };
const Matrix = enum { bt709, bt601, bt2020 };
const Transfer = enum { rec709, srgb, linear, pq, hlg };
const BitDepth = enum { eight, ten };

fn ycbcrToDisplaySrgbDepth(y_code: f32, cb_code: f32, cr_code: f32, range: Range, matrix: Matrix, bit_depth: BitDepth, transfer: Transfer, tone_map_hdr: bool) [3]f32 {
    const code_max: f32 = if (bit_depth == .ten) 1023 else 255;
    const video_y_min: f32 = if (bit_depth == .ten) 64 else 16;
    const video_y_range: f32 = if (bit_depth == .ten) 876 else 219;
    const video_c_mid: f32 = if (bit_depth == .ten) 512 else 128;
    const video_c_range: f32 = if (bit_depth == .ten) 896 else 224;
    const y = switch (range) {
        .video => (y_code - video_y_min / code_max) * (code_max / video_y_range),
        .full => y_code,
    };
    const cb = switch (range) {
        .video => (cb_code - video_c_mid / code_max) * (code_max / video_c_range),
        .full => cb_code - 0.5,
    };
    const cr = switch (range) {
        .video => (cr_code - video_c_mid / code_max) * (code_max / video_c_range),
        .full => cr_code - 0.5,
    };
    const encoded: [3]f32 = switch (matrix) {
        .bt709 => .{ y + 1.5748 * cr, y - 0.187324 * cb - 0.468124 * cr, y + 1.8556 * cb },
        .bt601 => .{ y + 1.402 * cr, y - 0.344136 * cb - 0.714136 * cr, y + 1.772 * cb },
        .bt2020 => .{ y + 1.4746 * cr, y - 0.164553 * cb - 0.571353 * cr, y + 1.8814 * cb },
    };
    var linear: [3]f32 = undefined;
    for (encoded, 0..) |value, index| linear[index] = decodeTransfer(std.math.clamp(value, 0, 1), transfer);
    if (transfer == .pq or transfer == .hlg) linear = hdrToSdr(linear, transfer, tone_map_hdr);
    var result: [3]f32 = undefined;
    for (linear, 0..) |value, index| result[index] = linearToSrgb(std.math.clamp(value, 0, 1));
    return result;
}

fn decodeTransfer(value: f32, transfer: Transfer) f32 {
    return switch (transfer) {
        .rec709 => if (value < 0.081) value / 4.5 else std.math.pow(f32, (value + 0.099) / 1.099, 1.0 / 0.45),
        .srgb => if (value <= 0.04045) value / 12.92 else std.math.pow(f32, (value + 0.055) / 1.055, 2.4),
        .linear => value,
        .pq => blk: {
            const m1: f32 = 2610.0 / 16384.0;
            const m2: f32 = 2523.0 / 32.0;
            const c1: f32 = 3424.0 / 4096.0;
            const c2: f32 = 2413.0 / 128.0;
            const c3: f32 = 2392.0 / 128.0;
            const p = std.math.pow(f32, value, 1.0 / m2);
            break :blk std.math.pow(f32, @max((p - c1) / @max(c2 - c3 * p, 0.000001), 0), 1.0 / m1);
        },
        .hlg => if (value <= 0.5) value * value / 3.0 else (std.math.exp((value - 0.55991073) / 0.17883277) + 0.28466892) / 12.0,
    };
}

fn hdrToSdr(linear: [3]f32, transfer: Transfer, tone_map: bool) [3]f32 {
    const peak_nits: f32 = if (transfer == .pq) 10_000 else 1_000;
    const rgb_nits = [3]f32{ linear[0] * peak_nits, linear[1] * peak_nits, linear[2] * peak_nits };
    if (!tone_map) return .{ rgb_nits[0] / 100.0, rgb_nits[1] / 100.0, rgb_nits[2] / 100.0 };
    const luminance = @max(rgb_nits[0] * 0.2627 + rgb_nits[1] * 0.6780 + rgb_nits[2] * 0.0593, 0);
    if (luminance <= 0.000001) return .{ 0, 0, 0 };
    const mapped = luminance / (luminance + 100.0);
    const scale = mapped / luminance;
    return .{ rgb_nits[0] * scale, rgb_nits[1] * scale, rgb_nits[2] * scale };
}

fn linearToSrgb(value: f32) f32 {
    return if (value <= 0.0031308) 12.92 * value else 1.055 * std.math.pow(f32, value, 1.0 / 2.4) - 0.055;
}

// ── pixel buffers ──

extern "c" fn CVPixelBufferCreate(allocator: ?*anyopaque, width: usize, height: usize, format: u32, attrs: ?*anyopaque, out: *?*anyopaque) i32;
extern "c" fn CVPixelBufferLockBaseAddress(pb: *anyopaque, flags: u64) i32;
extern "c" fn CVPixelBufferUnlockBaseAddress(pb: *anyopaque, flags: u64) i32;
extern "c" fn CVPixelBufferGetBaseAddressOfPlane(pb: *anyopaque, plane: usize) ?[*]u8;
extern "c" fn CVPixelBufferGetBytesPerRowOfPlane(pb: *anyopaque, plane: usize) usize;
extern "c" fn CVPixelBufferGetBaseAddress(pb: *anyopaque) ?[*]u8;
extern "c" fn CVPixelBufferGetBytesPerRow(pb: *anyopaque) usize;
extern "c" fn CFRelease(obj: *anyopaque) void;
extern "c" const kCVPixelBufferMetalCompatibilityKey: *anyopaque;
extern "c" const kCVPixelBufferIOSurfacePropertiesKey: *anyopaque;

/// A Metal-compatible, IOSurface-backed buffer of `fourcc`, locked for
/// writing (`unlock` it).
fn makeBuffer(fourcc: *const [4]u8) !*anyopaque {
    const objc = @import("../objc.zig");
    const keys = [2]*anyopaque{ kCVPixelBufferMetalCompatibilityKey, kCVPixelBufferIOSurfacePropertiesKey };
    const values = [2]objc.Object{ objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{objc.YES}), objc.msg(objc.Object, objc.class("NSDictionary"), "dictionary", .{}) };
    const attrs = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObjects:forKeys:count:", .{ @as(*const anyopaque, &values), @as(*const anyopaque, &keys), @as(objc.NSUInteger, 2) });
    var pb: ?*anyopaque = null;
    if (CVPixelBufferCreate(null, n, n, std.mem.readInt(u32, fourcc, .big), @ptrCast(attrs), &pb) != 0) return error.SkipZigTest;
    _ = CVPixelBufferLockBaseAddress(pb.?, 0);
    return pb.?;
}

fn unlock(pb: *anyopaque) void {
    _ = CVPixelBufferUnlockBaseAddress(pb, 0);
}

// ── the scene ──

const Scene = struct {
    source: ui.Texture,
    fn view(s: *Scene, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull();
        defer root.end();
        ui.texture(c, .{ .width = .{ .px = n }, .height = .{ .px = n } }, s.source, .{ 0, 0, 1, 1 }, 1);
    }
};

/// Renders `source` at one pixel a texel, with Metal and on the CPU, and
/// checks each against `oracle(x, y)` within one 8-bit step.
fn expectMatches(source: ui.Texture, oracle: anytype) !void {
    const gpa = testing.allocator;
    var s: Scene = .{ .source = source };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = n, .height = n, .scale = 1 });
    defer t.deinit();
    t.settle(0.1);
    const shown = try t.render(gpa);
    defer shown.deinit(gpa);
    const cpu: gpu.Pixels = .{ .bytes = try gpa.alloc(u8, shown.bytes.len), .width = shown.width, .height = shown.height };
    defer cpu.deinit(gpa);
    var pictures = t.text.images.pictures();
    pictures.textures = t.ctx.textures.items;
    raster.draw(cpu, t.instances.items, .{ .pixels = &.{}, .size = 0 }, pictures, t.scale, t.theme.background);
    var worst: [2]f32 = .{ 0, 0 };
    for (0..n) |y| for (0..n) |x| {
        const want = oracle.at(x, y);
        for ([_]gpu.Pixels{ shown, cpu }, 0..) |px, r| {
            const got = px.bytes[(y * px.width + x) * 4 ..][0..4];
            for (0..3) |k| worst[r] = @max(worst[r], @abs(@as(f32, @floatFromInt(got[2 - k])) - want[k] * 255));
            try testing.expectEqual(@as(u8, 255), got[3]);
        }
    };
    if (worst[0] > 1 or worst[1] > 1) std.debug.print("worst difference from the oracle: Metal {d:.3}, CPU {d:.3} steps\n", .{ worst[0], worst[1] });
    try testing.expect(worst[0] <= 1 and worst[1] <= 1);
}

/// Bilinear at a luma texel's centre in a chroma plane `cw` × `ch` (code
/// values, normalized): what the post shader's linear sampler reads.
fn chromaAt(plane: []const [2]f32, cw: usize, ch: usize, x: usize, y: usize) [2]f32 {
    const fx = (@as(f32, @floatFromInt(x)) + 0.5) / n * @as(f32, @floatFromInt(cw)) - 0.5;
    const fy = (@as(f32, @floatFromInt(y)) + 0.5) / n * @as(f32, @floatFromInt(ch)) - 0.5;
    const x0 = @floor(fx);
    const y0 = @floor(fy);
    const tx = fx - x0;
    const ty = fy - y0;
    const cl = struct {
        fn f(v: f32, m: usize) usize {
            return @intFromFloat(std.math.clamp(v, 0, @as(f32, @floatFromInt(m - 1))));
        }
    }.f;
    const xs = [2]usize{ cl(x0, cw), cl(x0 + 1, cw) };
    const ys = [2]usize{ cl(y0, ch), cl(y0 + 1, ch) };
    var out: [2]f32 = .{ 0, 0 };
    const w = [4]f32{ (1 - tx) * (1 - ty), tx * (1 - ty), (1 - tx) * ty, tx * ty };
    for (0..4) |k| for (0..2) |c| {
        out[c] += plane[ys[k / 2] * cw + xs[k % 2]][c] * w[k];
    };
    return out;
}

test "an 8-bit 4:2:0 frame ('420v') matches the media core's conversion" {
    if (text.portable) return error.SkipZigTest;
    const pb = try makeBuffer("420v");
    defer CFRelease(pb);
    var chroma: [32 * 32][2]f32 = undefined;
    var luma: [n * n]f32 = undefined;
    const ybase = CVPixelBufferGetBaseAddressOfPlane(pb, 0).?;
    const ystride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    const cbase = CVPixelBufferGetBaseAddressOfPlane(pb, 1).?;
    const cstride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    for (0..n) |y| for (0..n) |x| {
        const v: u8 = @intCast(16 + (x * 3 + y * 2) % 220);
        ybase[y * ystride + x] = v;
        luma[y * n + x] = @as(f32, @floatFromInt(v)) / 255;
    };
    for (0..32) |y| for (0..32) |x| {
        const cb: u8 = @intCast(16 + (x * 7) % 225);
        const cr: u8 = @intCast(16 + (y * 7 + x * 3) % 225);
        cbase[y * cstride + x * 2] = cb;
        cbase[y * cstride + x * 2 + 1] = cr;
        chroma[y * 32 + x] = .{ @as(f32, @floatFromInt(cb)) / 255, @as(f32, @floatFromInt(cr)) / 255 };
    };
    unlock(pb);
    const tex = pixel_buffer.texture(pb);
    try testing.expectEqual(gpu.Format.ycbcr420_8, tex.format);
    try testing.expectEqual(gpu.Range.video, tex.range);
    const Oracle = struct {
        luma: *const [n * n]f32,
        chroma: *const [32 * 32][2]f32,
        fn at(o: @This(), x: usize, y: usize) [3]f32 {
            const c = chromaAt(o.chroma, 32, 32, x, y);
            return ycbcrToDisplaySrgbDepth(o.luma[y * n + x], c[0], c[1], .video, .bt709, .eight, .rec709, true);
        }
    };
    try expectMatches(tex, Oracle{ .luma = &luma, .chroma = &chroma });
}

test "a 10-bit 4:2:2 HDR frame ('x422', BT.2020 PQ, tone mapped) matches the media core's conversion" {
    if (text.portable) return error.SkipZigTest;
    const pb = try makeBuffer("x422");
    defer CFRelease(pb);
    var chroma: [32 * n][2]f32 = undefined;
    var luma: [n * n]f32 = undefined;
    const ybase = CVPixelBufferGetBaseAddressOfPlane(pb, 0).?;
    const ystride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    const cbase = CVPixelBufferGetBaseAddressOfPlane(pb, 1).?;
    const cstride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    const put = struct {
        // 10-bit codes sit in a 16-bit word's top bits.
        fn f(base: [*]u8, at: usize, code: u16) void {
            std.mem.writeInt(u16, base[at..][0..2], code << 6, .little);
        }
    }.f;
    for (0..n) |y| for (0..n) |x| {
        const v: u16 = @intCast(64 + (x * 13 + y * 7) % 877);
        put(ybase, y * ystride + x * 2, v);
        luma[y * n + x] = @as(f32, @floatFromInt(v)) / 1023;
    };
    for (0..n) |y| for (0..32) |x| {
        const cb: u16 = @intCast(64 + (x * 29 + y * 3) % 897);
        const cr: u16 = @intCast(64 + (y * 17 + x * 11) % 897);
        put(cbase, y * cstride + x * 4, cb);
        put(cbase, y * cstride + x * 4 + 2, cr);
        chroma[y * 32 + x] = .{ @as(f32, @floatFromInt(cb)) / 1023, @as(f32, @floatFromInt(cr)) / 1023 };
    };
    unlock(pb);
    var tex = pixel_buffer.texture(pb);
    try testing.expectEqual(gpu.Format.ycbcr422_10, tex.format);
    tex.matrix = .bt2020;
    tex.transfer = .pq;
    const Oracle = struct {
        luma: *const [n * n]f32,
        chroma: *const [32 * n][2]f32,
        fn at(o: @This(), x: usize, y: usize) [3]f32 {
            const c = chromaAt(o.chroma, 32, n, x, y);
            return ycbcrToDisplaySrgbDepth(o.luma[y * n + x], c[0], c[1], .video, .bt2020, .ten, .pq, true);
        }
    };
    try expectMatches(tex, Oracle{ .luma = &luma, .chroma = &chroma });
}

test "a linear half-float frame ('RGhA') is encoded for the display, tone mapped or clipped" {
    if (text.portable) return error.SkipZigTest;
    const pb = try makeBuffer("RGhA");
    defer CFRelease(pb);
    var lin: [n * n][3]f32 = undefined;
    const base = CVPixelBufferGetBaseAddress(pb).?;
    const stride = CVPixelBufferGetBytesPerRow(pb);
    for (0..n) |y| for (0..n) |x| {
        const v = [3]f32{ @as(f32, @floatFromInt(x)) / 40, @as(f32, @floatFromInt(y)) / 50, @as(f32, @floatFromInt((x + y) % 64)) / 70 };
        for (0..4) |k| {
            const h: f16 = if (k < 3) @floatCast(v[k]) else 1;
            std.mem.writeInt(u16, base[y * stride + x * 8 + k * 2 ..][0..2], @bitCast(h), .little);
        }
        // What the GPU reads: the half floats.
        for (0..3) |k| lin[y * n + x][k] = @floatCast(@as(f16, @floatCast(v[k])));
    };
    unlock(pb);
    var tex = pixel_buffer.texture(pb);
    try testing.expectEqual(gpu.Format.rgba16f, tex.format);
    inline for (.{ false, true }) |tone| {
        tex.tone_map = tone;
        const Oracle = struct {
            lin: *const [n * n][3]f32,
            fn at(o: @This(), x: usize, y: usize) [3]f32 {
                var out: [3]f32 = undefined;
                for (0..3) |k| {
                    const v = o.lin[y * n + x][k];
                    out[k] = linearToSrgb(std.math.clamp(if (tone) v / (1 + v) else v, 0, 1));
                }
                return out;
            }
        };
        try expectMatches(tex, Oracle{ .lin = &lin });
    }
}
