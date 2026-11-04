//! A texture made BGRA for the CPU renderer (`raster_picture.zig`): its
//! bytes as they are, or a CVPixelBuffer's planes (locked for reading)
//! or an app's MTLTexture (read back) converted at the frame's own size as
//! the colour stage converts them on the GPU (`color.zig`): luma nearest,
//! chroma bilinear at the texel's centre, then the transfer, the tone map
//! and the LUTs, stored as 8-bit unorms.
const std = @import("std");
const gpu = @import("gpu.zig");
const color = @import("color.zig");
const pixel_buffer = @import("pixel_buffer.zig");

/// BGRA, premultiplied, `stride` bytes a row.
pub const Bgra = struct {
    pixels: []const u8,
    width: usize,
    height: usize,
    stride: usize,
};

/// A texture's BGRA, with what to give back once it is drawn.
pub const Held = struct {
    bgra: Bgra,
    owned: ?[]u8 = null,
    locked: ?pixel_buffer.Locked = null,

    pub fn deinit(h: *Held, gpa: std.mem.Allocator) void {
        if (h.owned) |o| gpa.free(o);
        if (comptime pixel_buffer.enabled) if (h.locked) |l| l.unlock();
    }
};

/// `t` as BGRA; null if it has no pixels the CPU can read.
pub fn resolve(gpa: std.mem.Allocator, t: gpu.Texture) ?Held {
    if (comptime pixel_buffer.enabled) {
        if (t.mtl_texture) |mt| return readBack(gpa, t, mt);
        if (t.pixel_buffer) |pb| return fromPixelBuffer(gpa, t, pb);
    }
    if (t.bgra.len == 0 or t.width == 0 or t.height == 0) return null;
    const stride = if (t.stride > 0) t.stride else @as(usize, t.width) * 4;
    if (t.bgra.len < stride * t.height) return null;
    const bytes: Bgra = .{ .pixels = t.bgra, .width = t.width, .height = t.height, .stride = stride };
    if (!t.needsPost()) return .{ .bgra = bytes };
    var plane: Source = .{ .bytes = t.bgra.ptr, .width = t.width, .height = t.height, .stride = stride, .kind = .bgra8 };
    const out = convert(gpa, t, color.uniforms(t, 0), &plane, null) orelse return null;
    return .{ .bgra = out, .owned = @constCast(out.pixels) };
}

const Source = struct {
    bytes: [*]const u8,
    width: usize,
    height: usize,
    stride: usize,
    kind: enum { bgra8, r8, rg8, r16, rg16, rgba16f },

    /// Texel (x, y), each channel 0 to 1 (R, G, B, A order for the RGB
    /// kinds, as Metal samples a BGRA texture).
    fn texel(s: *const Source, x: usize, y: usize) [4]f32 {
        const row = s.bytes + y * s.stride;
        return switch (s.kind) {
            .bgra8 => .{ n8(row[x * 4 + 2]), n8(row[x * 4 + 1]), n8(row[x * 4]), n8(row[x * 4 + 3]) },
            .r8 => .{ n8(row[x]), 0, 0, 1 },
            .rg8 => .{ n8(row[x * 2]), n8(row[x * 2 + 1]), 0, 1 },
            .r16 => .{ n16(row + x * 2), 0, 0, 1 },
            .rg16 => .{ n16(row + x * 4), n16(row + x * 4 + 2), 0, 1 },
            .rgba16f => .{ h16(row + x * 8), h16(row + x * 8 + 2), h16(row + x * 8 + 4), h16(row + x * 8 + 6) },
        };
    }

    /// Bilinear at normalized (u, v), edges clamped: Metal's linear sampler.
    fn bilinear(s: *const Source, u: f32, v: f32) [4]f32 {
        const fx = u * @as(f32, @floatFromInt(s.width)) - 0.5;
        const fy = v * @as(f32, @floatFromInt(s.height)) - 0.5;
        const x0f = @floor(fx);
        const y0f = @floor(fy);
        const tx = fx - x0f;
        const ty = fy - y0f;
        const mx: i64 = @as(i64, @intCast(s.width)) - 1;
        const my: i64 = @as(i64, @intCast(s.height)) - 1;
        const xs = [2]usize{ @intCast(std.math.clamp(@as(i64, @intFromFloat(x0f)), 0, mx)), @intCast(std.math.clamp(@as(i64, @intFromFloat(x0f)) + 1, 0, mx)) };
        const ys = [2]usize{ @intCast(std.math.clamp(@as(i64, @intFromFloat(y0f)), 0, my)), @intCast(std.math.clamp(@as(i64, @intFromFloat(y0f)) + 1, 0, my)) };
        const w = [4]f32{ (1 - tx) * (1 - ty), tx * (1 - ty), (1 - tx) * ty, tx * ty };
        var out: [4]f32 = .{ 0, 0, 0, 0 };
        for (0..4) |k| {
            const t = s.texel(xs[k % 2], ys[k / 2]);
            for (0..4) |c| out[c] += t[c] * w[k];
        }
        return out;
    }
};

fn n8(b: u8) f32 {
    return @as(f32, @floatFromInt(b)) / 255;
}

fn n16(p: [*]const u8) f32 {
    return @as(f32, @floatFromInt(std.mem.readInt(u16, p[0..2], .little))) / 65535;
}

fn h16(p: [*]const u8) f32 {
    return @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, p[0..2], .little))));
}

/// `alc_post_fs` over every texel of `src` (and the chroma plane `chroma`).
fn convert(gpa: std.mem.Allocator, t: gpu.Texture, u: color.Uniforms, src: *const Source, chroma: ?*const Source) ?Bgra {
    const w = src.width;
    const h = src.height;
    const out = gpa.alloc(u8, w * h * 4) catch return null;
    for (0..h) |y| for (0..w) |x| {
        var c = src.texel(x, y);
        const fu = (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(w));
        const fv = (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(h));
        if (u.source_mode == 1 or u.source_mode == 2) {
            const cbcr = if (chroma) |ch| ch.bilinear(fu, fv) else [4]f32{ 0.5, 0.5, 0, 1 };
            // 10-bit codes in the top of 16-bit words, read back as codes.
            const ten: f32 = if (u.source_mode == 2) 65535.0 / 65472.0 else 1;
            const rgb = color.toDisplay(color.ycbcrToRgb(c[0] * ten, cbcr[0] * ten, cbcr[1] * ten, u), u);
            c = .{ rgb[0], rgb[1], rgb[2], 1 };
        } else if (u.source_mode == 3) {
            const rgb = color.linearToDisplay(.{ c[0], c[1], c[2] }, u);
            c = .{ rgb[0], rgb[1], rgb[2], 1 };
        }
        const graded = color.applyLuts(t, .{ c[0], c[1], c[2] });
        const o = out[(y * w + x) * 4 ..][0..4];
        o.* = .{ color.unorm8(graded[2]), color.unorm8(graded[1]), color.unorm8(graded[0]), color.unorm8(c[3]) };
    };
    return .{ .pixels = out, .width = w, .height = h, .stride = w * 4 };
}

fn fromPixelBuffer(gpa: std.mem.Allocator, t: gpu.Texture, pb: *anyopaque) ?Held {
    const locked = pixel_buffer.Locked.lock(pb) orelse return null;
    var held: Held = .{ .bgra = undefined, .locked = locked };
    const p0 = locked.planes[0] orelse {
        locked.unlock();
        return null;
    };
    if (!t.needsPost()) {
        held.bgra = .{ .pixels = p0.bytes[0 .. p0.stride * p0.height], .width = p0.width, .height = p0.height, .stride = p0.stride };
        return held;
    }
    const ten = t.format == .ycbcr420_10 or t.format == .ycbcr422_10 or t.format == .ycbcr444_10;
    const planar = t.format != .bgra8 and t.format != .rgba16f;
    const luma: Source = .{ .bytes = p0.bytes, .width = p0.width, .height = p0.height, .stride = p0.stride, .kind = if (!planar) (if (t.format == .rgba16f) .rgba16f else .bgra8) else if (ten) .r16 else .r8 };
    var chroma: ?Source = null;
    if (planar) {
        const p1 = locked.planes[1] orelse {
            locked.unlock();
            return null;
        };
        chroma = .{ .bytes = p1.bytes, .width = p1.width, .height = p1.height, .stride = p1.stride, .kind = if (ten) .rg16 else .rg8 };
    }
    const out = convert(gpa, t, color.uniforms(t, color.sourceMode(t.format)), &luma, if (chroma) |*c| c else null);
    locked.unlock();
    held.locked = null;
    held.bgra = out orelse return null;
    held.owned = @constCast(held.bgra.pixels);
    return held;
}

/// An app's MTLTexture read back (`getBytes:`; a private one through a
/// shared copy first), then converted as the GPU's colour stage does.
fn readBack(gpa: std.mem.Allocator, t: gpu.Texture, mt: *anyopaque) ?Held {
    const metal_app = @import("metal_app.zig");
    var rb = metal_app.readBack(gpa, mt) orelse return null;
    defer rb.deinit(gpa);
    const src: Source = .{ .bytes = rb.bytes.ptr, .width = rb.width, .height = rb.height, .stride = rb.stride, .kind = if (rb.half) .rgba16f else .bgra8 };
    const mode: u32 = if (rb.linear) 3 else 0;
    if (mode == 0 and t.lut == null and t.source_lut == null) {
        const copy = gpa.dupe(u8, rb.bytes) catch return null;
        return .{ .bgra = .{ .pixels = copy, .width = rb.width, .height = rb.height, .stride = rb.stride }, .owned = copy };
    }
    const out = convert(gpa, t, color.uniforms(t, mode), &src, null) orelse return null;
    return .{ .bgra = out, .owned = @constCast(out.pixels) };
}
